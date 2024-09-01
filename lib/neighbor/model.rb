module Neighbor
  module Model
    def has_neighbors(*attribute_names, dimensions: nil, normalize: nil)
      if attribute_names.empty?
        raise ArgumentError, "has_neighbors requires an attribute name"
      end
      attribute_names.map!(&:to_sym)

      class_eval do
        @neighbor_attributes ||= {}

        if @neighbor_attributes.empty?
          def self.neighbor_attributes
            parent_attributes =
              if superclass.respond_to?(:neighbor_attributes)
                superclass.neighbor_attributes
              else
                {}
              end

            parent_attributes.merge(@neighbor_attributes || {})
          end
        end

        attribute_names.each do |attribute_name|
          raise Error, "has_neighbors already called for #{attribute_name.inspect}" if neighbor_attributes[attribute_name]
          @neighbor_attributes[attribute_name] = {dimensions: dimensions, normalize: normalize}
        end

        return if @neighbor_attributes.size != attribute_names.size

        validate do
          self.class.neighbor_attributes.each do |k, v|
            value = read_attribute(k)
            next if value.nil?

            column_info = self.class.columns_hash[k.to_s]
            dimensions = v[:dimensions]
            dimensions ||= column_info&.limit unless column_info&.type == :binary

            if !Neighbor::Utils.validate_dimensions(value, column_info&.type, dimensions).nil?
              errors.add(k, "must have #{dimensions} dimensions")
            end
            if !Neighbor::Utils.validate_finite(value, column_info&.type)
              errors.add(k, "must have finite values")
            end
          end
        end

        # TODO move to normalizes when Active Record < 7.1 no longer supported
        before_save do
          self.class.neighbor_attributes.each do |k, v|
            next unless v[:normalize] && attribute_changed?(k)
            value = read_attribute(k)
            next if value.nil?
            self[k] = Neighbor::Utils.normalize(value, column_info: self.class.columns_hash[k.to_s])
          end
        end

        # cannot use keyword arguments with scope with Ruby 3.2 and Active Record 6.1
        # https://github.com/rails/rails/issues/46934
        scope :nearest_neighbors, ->(attribute_name, vector, options = nil) {
          raise ArgumentError, "missing keyword: :distance" unless options.is_a?(Hash) && options.key?(:distance)
          distance = options.delete(:distance)
          precision = options.delete(:precision)
          raise ArgumentError, "unknown keywords: #{options.keys.map(&:inspect).join(", ")}" if options.any?

          attribute_name = attribute_name.to_sym
          options = neighbor_attributes[attribute_name]
          raise ArgumentError, "Invalid attribute" unless options
          normalize = options[:normalize]
          dimensions = options[:dimensions]

          return none if vector.nil?

          distance = distance.to_s

          quoted_attribute = "#{connection.quote_table_name(table_name)}.#{connection.quote_column_name(attribute_name)}"

          column_info = columns_hash[attribute_name.to_s]
          column_type = column_info&.type

          adapter =
            case connection.adapter_name
            when /mysql|trilogy/i
              connection.try(:mariadb?) ? :mariadb : :mysql
            when /sqlite/i
              :sqlite
            else
              :postgresql
            end

          operator =
            case adapter
            when :postgresql
              case column_type
              when :bit
                case distance
                when "hamming"
                  "<~>"
                when "jaccard"
                  "<%>"
                when "hamming2"
                  "bit_count"
                end
              when :vector, :halfvec, :sparsevec
                case distance
                when "inner_product"
                  "<#>"
                when "cosine"
                  "<=>"
                when "euclidean"
                  "<->"
                when "taxicab"
                  "<+>"
                end
              when :cube
                case distance
                when "taxicab"
                  "<#>"
                when "chebyshev"
                  "<=>"
                when "euclidean", "cosine"
                  "<->"
                end
              else
                raise ArgumentError, "Unsupported type: #{column_type}"
              end
            when :mysql
              case column_type
              when :vector, nil # TODO remove nil in 0.5.0
                case distance
                when "cosine"
                  "COSINE"
                when "euclidean"
                  "EUCLIDEAN"
                # TODO support
                # when "inner_product"
                #   "DOT"
                end
              else
                raise ArgumentError, "Unsupported type: #{column_type}"
              end
            when :mariadb
              case column_type
              when :binary
                case distance
                when "euclidean", "cosine"
                  "VEC_DISTANCE"
                end
              else
                raise ArgumentError, "Unsupported type: #{column_type}"
              end
            else # :sqlite
              case column_type
              when nil
                case distance
                when "euclidean"
                  "vec_distance_L2"
                when "cosine"
                  "vec_distance_cosine"
                end
              else
                raise ArgumentError, "Unsupported type: #{column_type}"
              end
            end

          raise ArgumentError, "Invalid distance: #{distance}" unless operator

          # ensure normalize set (can be true or false)
          normalize_required =
            case adapter
            when :postgresql
              column_type == :cube
            when :mariadb
              true
            else
              false
            end

          if distance == "cosine" && normalize_required && normalize.nil?
            raise Neighbor::Error, "Set normalize for cosine distance with cube"
          end

          column_attribute = klass.type_for_attribute(attribute_name)
          vector = column_attribute.cast(vector)
          Neighbor::Utils.validate(vector, dimensions: dimensions, column_info: column_info)
          vector = Neighbor::Utils.normalize(vector, column_info: column_info) if normalize

          query = connection.quote(column_attribute.serialize(vector))

          if !precision.nil?
            raise ArgumentError, "Precision not supported for this adapter" if adapter != :postgresql

            case precision.to_s
            when "half"
              cast_dimensions = dimensions || column_info&.limit
              raise ArgumentError, "Unknown dimensions" unless cast_dimensions
              quoted_attribute += "::halfvec(#{connection.quote(cast_dimensions.to_i)})"
            else
              raise ArgumentError, "Invalid precision"
            end
          end

          order =
            case adapter
            when :postgresql
              if operator == "bit_count"
                "bit_count(#{quoted_attribute} # #{query})"
              else
                "#{quoted_attribute} #{operator} #{query}"
              end
            when :mysql
              "DISTANCE(#{quoted_attribute}, #{query}, #{connection.quote(operator)})"
            when :mariadb
              "VEC_DISTANCE(#{quoted_attribute}, #{query})"
            else # :sqlite
              "#{operator}(#{quoted_attribute}, #{query})"
            end

          # https://stats.stackexchange.com/questions/146221/is-cosine-similarity-identical-to-l2-normalized-euclidean-distance
          # with normalized vectors:
          # cosine similarity = 1 - (euclidean distance)**2 / 2
          # cosine distance = 1 - cosine similarity
          # this transformation doesn't change the order, so only needed for select
          neighbor_distance =
            if distance == "cosine" && normalize_required
              "POWER(#{order}, 2) / 2.0"
            elsif [:vector, :halfvec, :sparsevec].include?(column_type) && distance == "inner_product"
              "(#{order}) * -1"
            else
              order
            end

          # for select, use column_names instead of * to account for ignored columns
          select_columns = select_values.any? ? [] : column_names
          select(*select_columns, "#{neighbor_distance} AS neighbor_distance")
            .where.not(attribute_name => nil)
            .reorder(Arel.sql(order))
        }

        def nearest_neighbors(attribute_name, **options)
          attribute_name = attribute_name.to_sym
          # important! check if neighbor attribute before accessing
          raise ArgumentError, "Invalid attribute" unless self.class.neighbor_attributes[attribute_name]

          self.class
            .where.not(Array(self.class.primary_key).to_h { |k| [k, self[k]] })
            .nearest_neighbors(attribute_name, self[attribute_name], **options)
        end
      end
    end
  end
end

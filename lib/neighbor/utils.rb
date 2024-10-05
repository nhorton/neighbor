module Neighbor
  module Utils
    def self.validate_dimensions(value, type, expected)
      dimensions = type == :sparsevec ? value.dimensions : value.size
      if expected && dimensions != expected
        "Expected #{expected} dimensions, not #{dimensions}"
      end
    end

    def self.validate_finite(value, type)
      case type
      when :bit
        true
      when :sparsevec
        value.values.all?(&:finite?)
      else
        value.all?(&:finite?)
      end
    end

    def self.validate(value, dimensions:, column_info:)
      dimensions ||= column_info&.limit unless column_info&.type == :binary
      if (message = validate_dimensions(value, column_info&.type, dimensions))
        raise Error, message
      end

      if !validate_finite(value, column_info&.type)
        raise Error, "Values must be finite"
      end
    end

    def self.normalize(value, column_info:)
      raise Error, "Normalize not supported for type" unless [:cube, :vector, :halfvec, :binary].include?(column_info&.type)

      norm = Math.sqrt(value.sum { |v| v * v })

      # store zero vector as all zeros
      # since NaN makes the distance always 0
      # could also throw error
      norm > 0 ? value.map { |v| v / norm } : value
    end

    def self.array?(value)
      !value.nil? && value.respond_to?(:to_a)
    end

    def self.adapter(connection)
      case connection.adapter_name
      when /sqlite/i
        :sqlite
      when /mysql|trilogy/i
        connection.try(:mariadb?) ? :mariadb : :mysql
      else
        :postgresql
      end
    end

    def self.operator(adapter, column_type, distance)
      case adapter
      when :sqlite
        case distance
        when "euclidean"
          "vec_distance_L2"
        when "cosine"
          "vec_distance_cosine"
        when "taxicab"
          "vec_distance_L1"
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
      when :mysql
        case column_type
        when :vector
          case distance
          when "cosine"
            "COSINE"
          when "euclidean"
            "EUCLIDEAN"
          end
        else
          raise ArgumentError, "Unsupported type: #{column_type}"
        end
      else
        case column_type
        when :bit
          case distance
          when "hamming"
            "<~>"
          when "jaccard"
            "<%>"
          when "hamming2"
            "#"
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
      end
    end

    def self.normalize_required?(adapter, column_type)
      case adapter
      when :postgresql
        column_type == :cube
      when :mariadb
        true
      else
        false
      end
    end
  end
end

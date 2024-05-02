module Neighbor
  class Vector < ActiveRecord::Type::Value
    def initialize(dimensions:, normalize:, model:, attribute_name:)
      super()
      @dimensions = dimensions
      @normalize = normalize
      @model = model
      @attribute_name = attribute_name
    end

    def self.cast(value, dimensions:, normalize:, column_info:)
      if column_info[:type] == :bit
        value = value.to_s
      else
        value = value.to_a.map(&:to_f)
      end

      dimensions ||= column_info[:dimensions]
      raise Error, "Expected #{dimensions} dimensions, not #{value.size}" if dimensions && value.size != dimensions

      if column_info[:type] == :bit
        return value
      end

      raise Error, "Values must be finite" unless value.all?(&:finite?)

      if normalize
        norm = Math.sqrt(value.sum { |v| v * v })

        # store zero vector as all zeros
        # since NaN makes the distance always 0
        # could also throw error

        # safe to update in-place since earlier map dups
        value.map! { |v| v / norm } if norm > 0
      end

      value
    end

    def self.column_info(model, attribute_name)
      attribute_name = attribute_name.to_s
      column = model.columns.detect { |c| c.name == attribute_name }
      {
        type: column.try(:type),
        dimensions: column.try(:limit)
      }
    end

    # need to be careful to avoid loading column info before needed
    def column_info
      @column_info ||= self.class.column_info(@model, @attribute_name)
    end

    def cast(value)
      self.class.cast(value, dimensions: @dimensions, normalize: @normalize, column_info: column_info) unless value.nil?
    end

    def serialize(value)
      unless value.nil?
        case column_info[:type]
        when :vector, :halfvec
          "[#{cast(value).join(", ")}]"
        when :cube
          "(#{cast(value).join(", ")})"
        when :bit
          cast(value)
        else
          raise "Unsupported type: #{column_info[:type]}"
        end
      end
    end

    def deserialize(value)
      case column_info[:type]
      when :bit
        value
      else
        value[1..-1].split(",").map(&:to_f) unless value.nil?
      end
    end
  end
end

module Neighbor
  module Type
    class SqliteVector < ActiveRecord::Type::Binary
      def serialize(value)
        if Utils.array?(value)
          value = value.to_a.pack("f*")
        end
        super(value)
      end

      private

      def cast_value(value)
        if value.is_a?(String)
          value.unpack("f*")
        elsif Utils.array?(value)
          value.to_a
        else
          raise "can't cast #{value.class.name} to vector"
        end
      end
    end
  end
end

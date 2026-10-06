module CrystalClick
  # Applies one inherited value-depth coordinate across recursive storage
  # wrappers and their delegated BinaryValue descriptors/payload children.
  # This is deliberately depth-only: operation budgets remain owned by the
  # existing codec/materialization contexts.
  module StorageColumnDepthGuard
    def self.validate(
      value : StorageColumnValue,
      limits : BinaryCodecLimits,
      writing : Bool = true,
    ) : Nil
      validate_storage_value(value, 1_i32, limits, writing)
    end

    private def self.validate_storage_value(
      value : StorageColumnValue,
      depth : Int32,
      limits : BinaryCodecLimits,
      writing : Bool,
    ) : Nil
      ensure_depth!(depth, limits, writing)

      case value.kind
      when StorageColumnValue::TUPLE, StorageColumnValue::ARRAY
        if value.child_count > 0
          child_depth = next_depth(depth, writing)
          value.child_count.times do |index|
            validate_storage_value(value.child_at(index), child_depth, limits, writing)
          end
        end
      when StorageColumnValue::OBJECT
        document = value.object_document
        document.path_count.times do |index|
          path = document.path_at(index)
          validate_binary_value(document.value_for(path), depth, limits, writing)
        end
      when StorageColumnValue::BULK
        validate_binary_value(value.bulk_value, depth, limits, writing)
      else
        fail_depth!(writing, "unknown recursive storage value node")
      end

      nil
    end

    private def self.validate_binary_value(
      value : BinaryValue,
      depth : Int32,
      limits : BinaryCodecLimits,
      writing : Bool,
    ) : Nil
      ensure_depth!(depth, limits, writing)
      validate_type(value.type, depth, limits, writing)

      if value.element_count > 0
        child_depth = next_depth(depth, writing)
        value.element_count.times do |index|
          validate_binary_value(value.element_at(index), child_depth, limits, writing)
        end
      end

      nil
    end

    private def self.validate_type(
      type : BinaryDataType,
      depth : Int32,
      limits : BinaryCodecLimits,
      writing : Bool,
    ) : Nil
      ensure_depth!(depth, limits, writing)

      if type.child_count > 0
        child_depth = next_depth(depth, writing)
        type.child_count.times do |index|
          validate_type(type.child_at(index), child_depth, limits, writing)
        end
      end

      nil
    end

    private def self.next_depth(depth : Int32, writing : Bool) : Int32
      if depth == Int32::MAX
        fail_depth!(writing, "recursive storage value depth exceeds Int32")
      end
      depth + 1
    end

    private def self.ensure_depth!(depth : Int32, limits : BinaryCodecLimits, writing : Bool) : Nil
      if depth > limits.max_depth
        fail_depth!(writing, "recursive storage value exceeds binary depth limit")
      end
    end

    private def self.fail_depth!(writing : Bool, message : String) : NoReturn
      if writing
        raise UnsupportedFormatError.new(message)
      else
        raise CorruptPartError.new(message)
      end
    end
  end
end

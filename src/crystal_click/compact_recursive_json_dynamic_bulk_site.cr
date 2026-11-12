module CrystalClick
  # One direct Dynamic Bulk leaf owned by a recursive Compact JSON schema.
  # Physical callbacks are derived later from the existing Dynamic physical
  # plan, which preserves its variable-width structure-prefix grammar.
  struct CompactRecursiveJsonDynamicBulkSite
    getter key : String
    getter physical_prefix : String
    getter type : BinaryDataType
    getter descriptor_depth : Int32
    getter initial_array_level : UInt64

    def initialize(
      key : String,
      physical_prefix : String,
      @type : BinaryDataType,
      @descriptor_depth : Int32,
      @initial_array_level : UInt64,
    )
      unless @type.tag == BinaryDataType::TAG_DYNAMIC && !@type.contains_json?
        raise UnsupportedFormatError.new("recursive Compact Dynamic site must be a direct JSON-free Dynamic Bulk leaf")
      end
      @key = String.new(key.to_slice)
      @physical_prefix = String.new(physical_prefix.to_slice)
    end

    def validate_actual_roster!(structure : DynamicStructure, limits : BinaryCodecLimits) : Nil
      actual_depth64 = @descriptor_depth.to_i64 + 1_i64
      if actual_depth64 <= 0_i64 || actual_depth64 > limits.max_depth.to_i64 ||
         actual_depth64 > Int32::MAX.to_i64
        raise UnsupportedFormatError.new("recursive Compact Dynamic actual descriptor depth exceeds configured limit")
      end
      actual_depth = actual_depth64.to_i32
      structure.type_count.times do |index|
        arm = structure.type_at(index)
        if arm.contains_dynamic? || arm.contains_json? ||
           !CompactRecursiveJsonBulkAdmission.admitted?(arm, actual_depth, limits)
          raise UnsupportedFormatError.new("recursive Compact Dynamic actual arm is outside the admitted static Bulk grammar")
        end
        CompactDynamicBulkPrefixTraversal.validate_compact_type_admission!(arm, limits, actual_depth)
      end
      nil
    end

    def retained_workspace_bytes : UInt64
      bytes = sizeof(CompactRecursiveJsonDynamicBulkSite).to_u64
      bytes = checked_add(bytes, string_owner_bytes(@key))
      bytes = checked_add(bytes, string_owner_bytes(@physical_prefix))
      checked_add(bytes, instance_sizeof(BinaryDataType).to_u64)
    end

    private def string_owner_bytes(value : String) : UInt64
      checked_add(instance_sizeof(String).to_u64, value.bytesize.to_u64 + 1_u64)
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise UnsupportedFormatError.new("recursive Compact Dynamic site workspace exceeds UInt64")
      end
      left + right
    end
  end
end

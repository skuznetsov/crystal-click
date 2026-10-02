module CrystalClick
  # Role plan for one admitted recursive descriptor and explicit String
  # profile. Descriptor traversal/budget validation belongs to the codec and
  # must happen before asking this owner to materialize a potentially large
  # role roster.
  class BinaryBulkTypePlan
    getter type : BinaryDataType
    getter profile : BinaryBulkProfile

    def initialize(@type : BinaryDataType, @profile : BinaryBulkProfile)
    end

    def roles : Array(String)
      collected = [] of String
      append_roles(@type, "root", collected)
      collected.sort!
      collected
    end

    # Count the exact role roster without allocating path Strings or a role
    # Array. Codecs use this for aggregate metadata preflight before `roles`.
    def role_count : UInt64
      count_roles(@type)
    end

    private def count_roles(type : BinaryDataType) : UInt64
      case type.tag
      when BinaryDataType::TAG_STRING
        @profile.with_size_stream? ? 2_u64 : 1_u64
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NULLABLE
        checked_role_add(1_u64, count_roles(type.child_at(0)))
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        if type.child_count == 0
          1_u64
        else
          count = 0_u64
          type.child_count.times do |index|
            count = checked_role_add(count, count_roles(type.child_at(index)))
          end
          count
        end
      when BinaryDataType::TAG_MAP
        checked_role_add(1_u64, checked_role_add(count_roles(type.child_at(0)), count_roles(type.child_at(1))))
      when BinaryDataType::TAG_NOTHING, BinaryDataType::TAG_BOOL
        1_u64
      else
        if type.fixed_width
          1_u64
        else
          raise UnsupportedFormatError.new("unsupported binary bulk DataType")
        end
      end
    end

    private def checked_role_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("binary bulk lane count overflows UInt64")
      end
      left + right
    end

    private def append_roles(type : BinaryDataType, path : String, roles : Array(String)) : Nil
      case type.tag
      when BinaryDataType::TAG_STRING
        roles << "#{path}.data"
        roles << "#{path}.string_sizes" if @profile.with_size_stream?
      when BinaryDataType::TAG_ARRAY
        roles << "#{path}.sizes"
        append_roles(type.child_at(0), "#{path}.elements", roles)
      when BinaryDataType::TAG_NULLABLE
        roles << "#{path}.nulls"
        append_roles(type.child_at(0), "#{path}.nested", roles)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        if type.child_count == 0
          roles << "#{path}.data"
        else
          type.child_count.times do |index|
            append_roles(type.child_at(index), "#{path}.field.#{index}", roles)
          end
        end
      when BinaryDataType::TAG_MAP
        roles << "#{path}.sizes"
        append_roles(type.child_at(0), "#{path}.elements.field.0", roles)
        append_roles(type.child_at(1), "#{path}.elements.field.1", roles)
      when BinaryDataType::TAG_NOTHING, BinaryDataType::TAG_BOOL
        roles << "#{path}.data"
      else
        if type.fixed_width
          roles << "#{path}.data"
        else
          raise UnsupportedFormatError.new("unsupported binary bulk DataType")
        end
      end
      nil
    end
  end
end

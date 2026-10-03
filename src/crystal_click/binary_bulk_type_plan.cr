module CrystalClick
  # Role plan for one admitted recursive descriptor and explicit String
  # profile. Descriptor traversal/budget validation belongs to the codec and
  # must happen before asking this owner to materialize a potentially large
  # role roster.
  class BinaryBulkTypePlan
    getter type : BinaryDataType
    getter profile : BinaryBulkProfile

    struct LowCardinalitySite
      getter type : BinaryDataType
      getter path : String

      def initialize(@type : BinaryDataType, @path : String)
      end

      def dictionary_role : String
        "#{@path}.dictionary"
      end

      def indexes_role : String
        "#{@path}.indexes"
      end
    end

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

    # Roles traversed by the ordinary bulk visitor. LowCardinality roles and
    # its complete value subtree are owned by BinaryLowCardinalityStorageCodec.
    def ordinary_role_count : UInt64
      count_ordinary_roles(@type)
    end

    def low_cardinality_site_count : UInt64
      count_sites(@type)
    end

    # Array/Map size roles needed to census flattened LC occurrences. Nullable
    # flags do not affect physical child counts and are deliberately excluded.
    def ancestor_size_role_count : UInt64
      count_ancestor_size_roles(@type)[:count]
    end

    def ordinary_roles : Array(String)
      collected = [] of String
      append_ordinary_roles(@type, "root", collected)
      collected.sort!
    end

    def low_cardinality_sites : Array(LowCardinalitySite)
      collected = [] of LowCardinalitySite
      append_sites(@type, "root", collected)
      collected.sort_by!(&.path)
    end

    def ancestor_size_roles : Array(String)
      collected = [] of String
      append_ancestor_size_roles(@type, "root", collected)
      collected.sort!
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
      when BinaryDataType::TAG_LOW_CARDINALITY
        2_u64
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

    private def count_ordinary_roles(type : BinaryDataType) : UInt64
      case type.tag
      when BinaryDataType::TAG_LOW_CARDINALITY
        0_u64
      when BinaryDataType::TAG_STRING
        @profile.with_size_stream? ? 2_u64 : 1_u64
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NULLABLE
        checked_role_add(1_u64, count_ordinary_roles(type.child_at(0)))
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        if type.child_count == 0
          1_u64
        else
          count = 0_u64
          type.child_count.times do |index|
            count = checked_role_add(count, count_ordinary_roles(type.child_at(index)))
          end
          count
        end
      when BinaryDataType::TAG_MAP
        checked_role_add(1_u64, checked_role_add(count_ordinary_roles(type.child_at(0)), count_ordinary_roles(type.child_at(1))))
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

    private def count_sites(type : BinaryDataType) : UInt64
      case type.tag
      when BinaryDataType::TAG_LOW_CARDINALITY
        1_u64
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NULLABLE
        count_sites(type.child_at(0))
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE, BinaryDataType::TAG_MAP
        count = 0_u64
        type.child_count.times do |index|
          count = checked_role_add(count, count_sites(type.child_at(index)))
        end
        count
      else
        0_u64
      end
    end

    private def count_ancestor_size_roles(type : BinaryDataType) : NamedTuple(contains: Bool, count: UInt64)
      case type.tag
      when BinaryDataType::TAG_LOW_CARDINALITY
        {contains: true, count: 0_u64}
      when BinaryDataType::TAG_ARRAY
        child = count_ancestor_size_roles(type.child_at(0))
        {contains: child[:contains], count: child[:contains] ? checked_role_add(1_u64, child[:count]) : 0_u64}
      when BinaryDataType::TAG_NULLABLE
        count_ancestor_size_roles(type.child_at(0))
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        contains = false
        count = 0_u64
        type.child_count.times do |index|
          child = count_ancestor_size_roles(type.child_at(index))
          contains ||= child[:contains]
          count = checked_role_add(count, child[:count])
        end
        {contains: contains, count: count}
      when BinaryDataType::TAG_MAP
        key = count_ancestor_size_roles(type.child_at(0))
        value = count_ancestor_size_roles(type.child_at(1))
        contains = key[:contains] || value[:contains]
        count = checked_role_add(key[:count], value[:count])
        {contains: contains, count: contains ? checked_role_add(1_u64, count) : 0_u64}
      else
        {contains: false, count: 0_u64}
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
      when BinaryDataType::TAG_LOW_CARDINALITY
        roles << "#{path}.dictionary"
        roles << "#{path}.indexes"
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

    private def append_ordinary_roles(type : BinaryDataType, path : String, roles : Array(String)) : Nil
      case type.tag
      when BinaryDataType::TAG_LOW_CARDINALITY
        nil
      when BinaryDataType::TAG_STRING
        roles << "#{path}.data"
        roles << "#{path}.string_sizes" if @profile.with_size_stream?
      when BinaryDataType::TAG_ARRAY
        roles << "#{path}.sizes"
        append_ordinary_roles(type.child_at(0), "#{path}.elements", roles)
      when BinaryDataType::TAG_NULLABLE
        roles << "#{path}.nulls"
        append_ordinary_roles(type.child_at(0), "#{path}.nested", roles)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        if type.child_count == 0
          roles << "#{path}.data"
        else
          type.child_count.times do |index|
            append_ordinary_roles(type.child_at(index), "#{path}.field.#{index}", roles)
          end
        end
      when BinaryDataType::TAG_MAP
        roles << "#{path}.sizes"
        append_ordinary_roles(type.child_at(0), "#{path}.elements.field.0", roles)
        append_ordinary_roles(type.child_at(1), "#{path}.elements.field.1", roles)
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

    private def append_sites(type : BinaryDataType, path : String, sites : Array(LowCardinalitySite)) : Nil
      case type.tag
      when BinaryDataType::TAG_LOW_CARDINALITY
        sites << LowCardinalitySite.new(type, path)
      when BinaryDataType::TAG_ARRAY
        append_sites(type.child_at(0), "#{path}.elements", sites)
      when BinaryDataType::TAG_NULLABLE
        append_sites(type.child_at(0), "#{path}.nested", sites)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times do |index|
          append_sites(type.child_at(index), "#{path}.field.#{index}", sites)
        end
      when BinaryDataType::TAG_MAP
        append_sites(type.child_at(0), "#{path}.elements.field.0", sites)
        append_sites(type.child_at(1), "#{path}.elements.field.1", sites)
      end
      nil
    end

    private def append_ancestor_size_roles(type : BinaryDataType, path : String, roles : Array(String)) : Bool
      case type.tag
      when BinaryDataType::TAG_LOW_CARDINALITY
        true
      when BinaryDataType::TAG_ARRAY
        child_has_site = append_ancestor_size_roles(type.child_at(0), "#{path}.elements", roles)
        roles << "#{path}.sizes" if child_has_site
        child_has_site
      when BinaryDataType::TAG_NULLABLE
        append_ancestor_size_roles(type.child_at(0), "#{path}.nested", roles)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        contains_site = false
        type.child_count.times do |index|
          child_has_site = append_ancestor_size_roles(type.child_at(index), "#{path}.field.#{index}", roles)
          contains_site ||= child_has_site
        end
        contains_site
      when BinaryDataType::TAG_MAP
        key_has_site = append_ancestor_size_roles(type.child_at(0), "#{path}.elements.field.0", roles)
        value_has_site = append_ancestor_size_roles(type.child_at(1), "#{path}.elements.field.1", roles)
        contains_site = key_has_site || value_has_site
        roles << "#{path}.sizes" if contains_site
        contains_site
      else
        false
      end
    end
  end
end

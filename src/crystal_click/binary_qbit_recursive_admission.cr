module CrystalClick
  # One static composition bridge for QBit in recursive bulk storage.
  # Runtime-owned wrappers and alternate physical layouts retain their own
  # independent admission gates.
  module BinaryQBitRecursiveAdmission
    private alias Metadata = NamedTuple(
      site_count: UInt64,
      role_count: UInt64,
      name_bytes: UInt64,
      scratch_bytes: UInt64,
      entry_count: UInt64,
    )

    # A root QBit and Nullable(QBit) keep their dedicated W179 owners. Every
    # other admitted static composition receives one immutable site per leaf.
    def self.static_sites(
      type : BinaryDataType,
      limits : BinaryCodecLimits,
      writing : Bool,
    ) : Array(StaticSite)
      return [] of StaticSite unless type.contains_qbit?

      # Public plans can be created without the bulk encoder/decoder's
      # operation context. Validate the complete descriptor tree here before
      # the recursive size-only measurement and site materialization below;
      # this bounds depth, node count, and descriptor edges for those direct
      # callers too.
      BinaryCodecContext.new(limits, nil, writing).validate_type_tree(type)

      return [] of StaticSite if type.tag == BinaryDataType::TAG_QBIT ||
                                 (type.tag == BinaryDataType::TAG_NULLABLE && type.child_at(0).tag == BinaryDataType::TAG_QBIT)

      unless BinaryDataType.admitted_qbit_static_composition?(type)
        fail_type!(writing, "QBit is outside the admitted static product composition")
      end

      measured = measure(type, "root".bytesize.to_u64, 0_u64, 0_u64, 0_u64, 0_u64)
      if measured[:site_count] > Int32::MAX.to_u64 ||
         measured[:role_count] > limits.max_elements.to_u64 ||
         measured[:entry_count] > limits.max_elements.to_u64
        fail_limit!(writing, "static QBit site roster exceeds configured element limit")
      end
      if measured[:name_bytes] > limits.max_bytes.to_u64
        fail_limit!(writing, "static QBit site role names exceed configured byte limit")
      end
      if measured[:scratch_bytes] > limits.max_bytes.to_u64
        fail_limit!(writing, "static QBit site scratch exceeds configured byte limit")
      end

      sites = Array(StaticSite).new(measured[:site_count].to_i)
      append_sites(type, "root", [] of String, [] of String, nil, sites, limits, writing)
      unless sites.size.to_u64 == measured[:site_count]
        fail_limit!(writing, "static QBit site roster changed while it was materialized")
      end
      sites
    end

    # Legacy Array-chain adapter retained for W230 callers. The generic
    # multi-site owner below is authoritative for new static products.
    def self.static_array_site(
      type : BinaryDataType,
      limits : BinaryCodecLimits,
      writing : Bool,
    ) : StaticArraySite?
      return nil unless type.qbit_array_chain?
      site = static_sites(type, limits, writing).first?
      return nil unless site
      StaticArraySite.new(site.column, site.size_roles, site.nullable_role?, site.plane_roles)
    end

    # QBit-free trees do not need the static visitor. A QBit-bearing tree must
    # be either root/direct-nullable or in the explicitly admitted grammar.
    def self.validate_static_type!(type : BinaryDataType) : Nil
      return nil unless type.contains_qbit?
      return nil if BinaryDataType.admitted_qbit_static_composition?(type)

      BinaryQBitBulkCodec.column_type(type)
      nil
    end

    private def self.measure(
      type : BinaryDataType,
      path_bytes : UInt64,
      ancestor_size_bytes : UInt64,
      ancestor_size_count : UInt64,
      ancestor_nullable_bytes : UInt64,
      ancestor_nullable_count : UInt64,
    ) : Metadata
      return empty_metadata unless type.contains_qbit?

      case type.tag
      when BinaryDataType::TAG_QBIT
        qbit_type = type.qbit_type || raise UnsupportedFormatError.new("static QBit descriptor is missing its nominal type")
        plane_count = qbit_type.plane_count.to_u64
        suffix_size = BinaryQBitBulkCodec::ROLE_SUFFIX.bytesize.to_u64
        plane_bytes = 0_u64
        qbit_type.plane_count.times do |plane|
          plane_bytes = checked_add(plane_bytes, path_bytes)
          plane_bytes = checked_add(plane_bytes, suffix_size)
          plane_bytes = checked_add(plane_bytes, digit_count(plane.to_u64))
        end
        site_bytes = checked_add(path_bytes, ancestor_size_bytes)
        site_bytes = checked_add(site_bytes, ancestor_nullable_bytes)
        site_bytes = checked_add(site_bytes, plane_bytes)
        entries = checked_add(1_u64, ancestor_size_count)
        entries = checked_add(entries, ancestor_nullable_count)
        entries = checked_add(entries, plane_count)
        {
          site_count:    1_u64,
          role_count:    plane_count,
          name_bytes:    site_bytes,
          scratch_bytes: qbit_type.plane_width.to_u64,
          entry_count:   entries,
        }
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        size_bytes = checked_add(path_bytes, BinaryQBitBulkCodec::ARRAY_SIZE_SUFFIX.bytesize.to_u64)
        child_path_bytes = checked_add(path_bytes, BinaryQBitBulkCodec::ARRAY_PATH_SUFFIX.bytesize.to_u64)
        child = measure(
          type.child_at(0),
          child_path_bytes,
          checked_add(ancestor_size_bytes, size_bytes),
          checked_add(ancestor_size_count, 1_u64),
          ancestor_nullable_bytes,
          ancestor_nullable_count,
        )
        with_role(child, size_bytes)
      when BinaryDataType::TAG_NULLABLE
        null_bytes = checked_add(path_bytes, BinaryQBitBulkCodec::NULL_ROLE_SUFFIX.bytesize.to_u64)
        child_path_bytes = checked_add(path_bytes, BinaryQBitBulkCodec::NESTED_ROLE_SUFFIX.bytesize.to_u64)
        child = measure(
          type.child_at(0),
          child_path_bytes,
          ancestor_size_bytes,
          ancestor_size_count,
          checked_add(ancestor_nullable_bytes, null_bytes),
          checked_add(ancestor_nullable_count, 1_u64),
        )
        with_role(child, null_bytes)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        combined = empty_metadata
        type.child_count.times do |index|
          child = type.child_at(index)
          next unless child.contains_qbit?
          field_path_bytes = checked_add(path_bytes, ".field.".bytesize.to_u64)
          field_path_bytes = checked_add(field_path_bytes, digit_count(index.to_u64))
          combined = combine_metadata(
            combined,
            measure(child, field_path_bytes, ancestor_size_bytes, ancestor_size_count, ancestor_nullable_bytes, ancestor_nullable_count),
          )
        end
        combined
      when BinaryDataType::TAG_MAP
        size_bytes = checked_add(path_bytes, BinaryQBitBulkCodec::ARRAY_SIZE_SUFFIX.bytesize.to_u64)
        combined = empty_metadata
        2.times do |index|
          child = type.child_at(index)
          next unless child.contains_qbit?
          child_path_bytes = checked_add(path_bytes, ".elements.field.".bytesize.to_u64)
          child_path_bytes = checked_add(child_path_bytes, digit_count(index.to_u64))
          combined = combine_metadata(
            combined,
            measure(
              child,
              child_path_bytes,
              checked_add(ancestor_size_bytes, size_bytes),
              checked_add(ancestor_size_count, 1_u64),
              ancestor_nullable_bytes,
              ancestor_nullable_count,
            ),
          )
        end
        with_role(combined, size_bytes)
      when BinaryDataType::TAG_VARIANT
        discriminator_bytes = checked_add(path_bytes, ".discriminators".bytesize.to_u64)
        combined = empty_metadata
        type.child_count.times do |index|
          child = type.child_at(index)
          next unless child.contains_qbit?
          child_path_bytes = checked_add(path_bytes, ".arm.".bytesize.to_u64)
          child_path_bytes = checked_add(child_path_bytes, digit_count(index.to_u64))
          combined = combine_metadata(
            combined,
            measure(
              child,
              child_path_bytes,
              ancestor_size_bytes,
              ancestor_size_count,
              ancestor_nullable_bytes,
              ancestor_nullable_count,
            ),
          )
        end
        with_role(combined, discriminator_bytes)
      else
        raise UnsupportedFormatError.new("QBit is outside the admitted static product composition")
      end
    end

    private def self.append_sites(
      type : BinaryDataType,
      path : String,
      size_roles : Array(String),
      nullable_roles : Array(String),
      direct_nullable_role : String?,
      sites : Array(StaticSite),
      limits : BinaryCodecLimits,
      writing : Bool,
    ) : Nil
      return nil unless type.contains_qbit?

      case type.tag
      when BinaryDataType::TAG_QBIT
        qbit_type = type.qbit_type || fail_type!(writing, "static QBit descriptor is missing its nominal type")
        column = QBitColumnType.new(qbit_type, !direct_nullable_role.nil?)
        plane_column = QBitColumnType.new(qbit_type)
        planes = BinaryQBitBulkCodec.plane_roles(plane_column, path, limits, writing)
        sites << StaticSite.new(path, column, planes, size_roles, nullable_roles, direct_nullable_role)
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        size_roles << "#{path}#{BinaryQBitBulkCodec::ARRAY_SIZE_SUFFIX}"
        append_sites(
          type.child_at(0),
          "#{path}#{BinaryQBitBulkCodec::ARRAY_PATH_SUFFIX}",
          size_roles,
          nullable_roles,
          nil,
          sites,
          limits,
          writing,
        )
        size_roles.pop
      when BinaryDataType::TAG_NULLABLE
        role = "#{path}#{BinaryQBitBulkCodec::NULL_ROLE_SUFFIX}"
        nullable_roles << role
        child = type.child_at(0)
        append_sites(
          child,
          "#{path}#{BinaryQBitBulkCodec::NESTED_ROLE_SUFFIX}",
          size_roles,
          nullable_roles,
          child.tag == BinaryDataType::TAG_QBIT ? role : nil,
          sites,
          limits,
          writing,
        )
        nullable_roles.pop
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times do |index|
          child = type.child_at(index)
          next unless child.contains_qbit?
          append_sites(
            child,
            "#{path}.field.#{index}",
            size_roles,
            nullable_roles,
            nil,
            sites,
            limits,
            writing,
          )
        end
      when BinaryDataType::TAG_MAP
        size_roles << "#{path}#{BinaryQBitBulkCodec::ARRAY_SIZE_SUFFIX}"
        2.times do |index|
          child = type.child_at(index)
          next unless child.contains_qbit?
          append_sites(
            child,
            "#{path}.elements.field.#{index}",
            size_roles,
            nullable_roles,
            nil,
            sites,
            limits,
            writing,
          )
        end
        size_roles.pop
      when BinaryDataType::TAG_VARIANT
        type.child_count.times do |index|
          child = type.child_at(index)
          next unless child.contains_qbit?
          append_sites(
            child,
            "#{path}.arm.#{index}",
            size_roles,
            nullable_roles,
            nil,
            sites,
            limits,
            writing,
          )
        end
      else
        fail_type!(writing, "QBit is outside the admitted static product composition")
      end
      nil
    end

    private def self.empty_metadata : Metadata
      {site_count: 0_u64, role_count: 0_u64, name_bytes: 0_u64, scratch_bytes: 0_u64, entry_count: 0_u64}
    end

    private def self.with_role(metadata : Metadata, role_bytes : UInt64) : Metadata
      {
        site_count:    metadata[:site_count],
        role_count:    checked_add(metadata[:role_count], 1_u64),
        name_bytes:    checked_add(metadata[:name_bytes], role_bytes),
        scratch_bytes: metadata[:scratch_bytes],
        entry_count:   checked_add(metadata[:entry_count], 1_u64),
      }
    end

    private def self.combine_metadata(left : Metadata, right : Metadata) : Metadata
      {
        site_count:    checked_add(left[:site_count], right[:site_count]),
        role_count:    checked_add(left[:role_count], right[:role_count]),
        name_bytes:    checked_add(left[:name_bytes], right[:name_bytes]),
        scratch_bytes: checked_add(left[:scratch_bytes], right[:scratch_bytes]),
        entry_count:   checked_add(left[:entry_count], right[:entry_count]),
      }
    end

    private def self.checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("static QBit metadata overflows UInt64")
      end
      left + right
    end

    private def self.digit_count(value : UInt64) : UInt64
      count = 1_u64
      while value >= 10_u64
        value //= 10_u64
        count += 1_u64
      end
      count
    end

    private def self.fail_type!(writing : Bool, message : String) : NoReturn
      if writing
        raise UnsupportedFormatError.new(message)
      else
        raise CorruptPartError.new(message)
      end
    end

    private def self.fail_limit!(writing : Bool, message : String) : NoReturn
      if writing
        raise UnsupportedFormatError.new(message)
      else
        raise CorruptPartError.new(message)
      end
    end
  end
end

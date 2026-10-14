module CrystalClick
  # Stateless prefix-free Bulk role and body grammar shared by recursive
  # Compact JSON sites. The census allocates nothing; the DFS materializer and
  # data-dependent capture run only after their owners have preflighted bounds.
  class CompactRecursiveJsonStaticBulkGrammar
    def self.admitted_type?(type : BinaryDataType, depth : Int32, limits : BinaryCodecLimits) : Bool
      BinaryPrefixFreeStaticTypeAdmission.admitted?(type, depth, limits)
    end

    def self.measure_role_count(type : BinaryDataType, profile : BinaryBulkProfile) : UInt64
      case type.tag
      when BinaryDataType::TAG_CUSTOM, BinaryDataType::TAG_SIMPLE_AGGREGATE
        measure_role_count(type.child_at(0), profile)
      when BinaryDataType::TAG_STRING
        profile.with_size_stream? ? 2_u64 : 1_u64
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED,
           BinaryDataType::TAG_NULLABLE, BinaryDataType::TAG_MAP
        own = 1_u64
        type.child_count.times do |index|
          own = checked_add(own, measure_role_count(type.child_at(index), profile))
        end
        own
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        return 1_u64 if type.child_count == 0
        total = 0_u64
        type.child_count.times do |index|
          total = checked_add(total, measure_role_count(type.child_at(index), profile))
        end
        total
      when BinaryDataType::TAG_NOTHING
        1_u64
      else
        type.fixed_width ? 1_u64 : unsupported_type!
      end
    end

    def self.measure_role_name_bytes(
      type : BinaryDataType,
      profile : BinaryBulkProfile,
      prefix_bytes : UInt64,
    ) : UInt64
      case type.tag
      when BinaryDataType::TAG_CUSTOM, BinaryDataType::TAG_SIMPLE_AGGREGATE
        measure_role_name_bytes(type.child_at(0), profile, prefix_bytes)
      when BinaryDataType::TAG_STRING
        bytes = checked_add(prefix_bytes, 5_u64)                                                  # .data
        profile.with_size_stream? ? checked_add(bytes, checked_add(prefix_bytes, 13_u64)) : bytes # .string_sizes
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        own = checked_add(prefix_bytes, 6_u64)                                                                 # .sizes
        checked_add(own, measure_role_name_bytes(type.child_at(0), profile, checked_add(prefix_bytes, 9_u64))) # .elements
      when BinaryDataType::TAG_NULLABLE
        own = checked_add(prefix_bytes, 6_u64)                                                                 # .nulls
        checked_add(own, measure_role_name_bytes(type.child_at(0), profile, checked_add(prefix_bytes, 7_u64))) # .nested
      when BinaryDataType::TAG_MAP
        own = checked_add(prefix_bytes, 6_u64)                                                         # .sizes
        keys = measure_role_name_bytes(type.child_at(0), profile, checked_add(prefix_bytes, 17_u64))   # .elements.field.0
        values = measure_role_name_bytes(type.child_at(1), profile, checked_add(prefix_bytes, 17_u64)) # .elements.field.1
        checked_add(own, checked_add(keys, values))
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        return checked_add(prefix_bytes, 5_u64) if type.child_count == 0 # .data
        total = 0_u64
        type.child_count.times do |index|
          child_prefix = checked_add(prefix_bytes, checked_add(7_u64, decimal_digits(index.to_u64))) # .field.N
          total = checked_add(total, measure_role_name_bytes(type.child_at(index), profile, child_prefix))
        end
        total
      when BinaryDataType::TAG_NOTHING
        checked_add(prefix_bytes, 5_u64) # .data
      else
        type.fixed_width ? checked_add(prefix_bytes, 5_u64) : unsupported_type! # .data
      end
    end

    # Array and Nested size roles alone participate in the frozen parent
    # occurrence-size schedule. Map pair counts and String1 length lanes are
    # ordinary Bulk body callbacks, even though they are size metadata.
    def self.size_lane_count(type : BinaryDataType) : UInt64
      case type.tag
      when BinaryDataType::TAG_CUSTOM, BinaryDataType::TAG_SIMPLE_AGGREGATE,
           BinaryDataType::TAG_NULLABLE
        size_lane_count(type.child_at(0))
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        checked_add(1_u64, size_lane_count(type.child_at(0)))
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE, BinaryDataType::TAG_MAP
        total = 0_u64
        type.child_count.times do |index|
          total = checked_add(total, size_lane_count(type.child_at(index)))
        end
        total
      else
        0_u64
      end
    end

    def self.ordered_roles(type : BinaryDataType, profile : BinaryBulkProfile) : Array(CompactRecursiveJsonBulkSite::Role)
      count = measure_role_count(type, profile)
      if count > Int32::MAX.to_u64
        raise UnsupportedFormatError.new("recursive Compact Bulk role roster exceeds Int32")
      end
      roles = Array(CompactRecursiveJsonBulkSite::Role).new(count.to_i)
      append_roles(type, "root", profile, roles)
      unless roles.size.to_u64 == count
        raise UnsupportedFormatError.new("recursive Compact Bulk role census changed during materialization")
      end
      roles
    end

    def self.capture!(
      type : BinaryDataType,
      role_name : String,
      rows : UInt64,
      site : CompactRecursiveJsonBulkSite,
      mark : CompactRecursiveJsonBulkMark,
      ledger : CompactRecursiveJsonParentMarkLedger,
      limits : BinaryCodecLimits,
      budget : BinaryCodecBudget,
    ) : Nil
      profile = site.physical_plan.profile
      case type.tag
      when BinaryDataType::TAG_CUSTOM, BinaryDataType::TAG_SIMPLE_AGGREGATE
        capture!(type.child_at(0), role_name, rows, site, mark, ledger, limits, budget)
      when BinaryDataType::TAG_STRING
        if profile.with_size_stream?
          capture_string1!(role_name, rows, site, mark, ledger, budget)
        else
          capture_string0!(role_name, rows, site, mark, ledger, limits, budget)
        end
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        size_role = "#{role_name}.sizes"
        callback = site.callback_name_for(size_role)
        byte_count = checked_byte_count(rows, 8_u64, "Compact recursive Bulk Array size lane")
        budget.ensure_future_nodes(rows)
        budget.ensure_future_elements(rows)
        budget.ensure_wire_bytes(byte_count.to_u64)
        bytes = ledger.capture_mixed_array_size_lane(callback, byte_count)
        sizes = decode_uint64_lane(bytes, rows, "Compact recursive Bulk Array size lane", budget)
        mark.capture_lane(size_role, bytes)
        child_rows = checked_child_rows(sizes, "Compact recursive Bulk Array child occurrence count")
        capture!(type.child_at(0), "#{role_name}.elements", child_rows, site, mark, ledger, limits, budget)
      when BinaryDataType::TAG_NULLABLE
        null_role = "#{role_name}.nulls"
        null_bytes = checked_byte_count(rows, 1_u64, "Compact recursive Bulk Nullable null lane")
        budget.ensure_wire_bytes(null_bytes.to_u64)
        nulls = ledger.capture_bulk_body(site.callback_name_for(null_role), null_bytes)
        mark.capture_lane(null_role, nulls)
        capture!(type.child_at(0), "#{role_name}.nested", rows, site, mark, ledger, limits, budget)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        if type.child_count == 0
          capture_fixed_role!("#{role_name}.data", rows, 1_u64, site, mark, ledger, budget)
        else
          type.child_count.times do |index|
            capture!(type.child_at(index), "#{role_name}.field.#{index}", rows, site, mark, ledger, limits, budget)
          end
        end
      when BinaryDataType::TAG_MAP
        size_role = "#{role_name}.sizes"
        byte_count = checked_byte_count(rows, 8_u64, "Compact recursive Bulk Map pair-count lane")
        budget.ensure_future_nodes(rows)
        budget.ensure_future_elements(rows)
        budget.ensure_wire_bytes(byte_count.to_u64)
        bytes = ledger.capture_bulk_body(site.callback_name_for(size_role), byte_count)
        pairs = decode_uint64_lane(bytes, rows, "Compact recursive Bulk Map pair-count lane", budget)
        mark.capture_lane(size_role, bytes)
        pair_rows = checked_child_rows(pairs, "Compact recursive Bulk Map pair count")
        if pair_rows > Int32::MAX.to_u64 // 2_u64
          raise CorruptPartError.new("Compact recursive Bulk Map flat element count exceeds Int32")
        end
        capture!(type.child_at(0), "#{role_name}.elements.field.0", pair_rows, site, mark, ledger, limits, budget)
        capture!(type.child_at(1), "#{role_name}.elements.field.1", pair_rows, site, mark, ledger, limits, budget)
      when BinaryDataType::TAG_NOTHING
        capture_fixed_role!("#{role_name}.data", rows, 1_u64, site, mark, ledger, budget)
      else
        width = type.fixed_width || raise(CorruptPartError.new("Compact recursive Bulk grammar reached a non-prefix-free leaf"))
        capture_fixed_role!("#{role_name}.data", rows, width.to_u64, site, mark, ledger, budget)
      end
      nil
    end

    private def self.append_roles(
      type : BinaryDataType,
      path : String,
      profile : BinaryBulkProfile,
      output : Array(CompactRecursiveJsonBulkSite::Role),
    ) : Nil
      case type.tag
      when BinaryDataType::TAG_CUSTOM, BinaryDataType::TAG_SIMPLE_AGGREGATE
        append_roles(type.child_at(0), path, profile, output)
      when BinaryDataType::TAG_STRING
        if profile.with_size_stream?
          output << CompactRecursiveJsonBulkSite::Role.new("#{path}.string_sizes", false)
        end
        output << CompactRecursiveJsonBulkSite::Role.new("#{path}.data", false)
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        output << CompactRecursiveJsonBulkSite::Role.new("#{path}.sizes", true)
        append_roles(type.child_at(0), "#{path}.elements", profile, output)
      when BinaryDataType::TAG_NULLABLE
        output << CompactRecursiveJsonBulkSite::Role.new("#{path}.nulls", false)
        append_roles(type.child_at(0), "#{path}.nested", profile, output)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        if type.child_count == 0
          output << CompactRecursiveJsonBulkSite::Role.new("#{path}.data", false)
        else
          type.child_count.times do |index|
            append_roles(type.child_at(index), "#{path}.field.#{index}", profile, output)
          end
        end
      when BinaryDataType::TAG_MAP
        output << CompactRecursiveJsonBulkSite::Role.new("#{path}.sizes", false)
        append_roles(type.child_at(0), "#{path}.elements.field.0", profile, output)
        append_roles(type.child_at(1), "#{path}.elements.field.1", profile, output)
      when BinaryDataType::TAG_NOTHING
        output << CompactRecursiveJsonBulkSite::Role.new("#{path}.data", false)
      else
        raise UnsupportedFormatError.new("recursive Compact Bulk role materializer reached an unsupported leaf") unless type.fixed_width
        output << CompactRecursiveJsonBulkSite::Role.new("#{path}.data", false)
      end
      nil
    end

    private def self.capture_string0!(
      role_name : String,
      rows : UInt64,
      site : CompactRecursiveJsonBulkSite,
      mark : CompactRecursiveJsonBulkMark,
      ledger : CompactRecursiveJsonParentMarkLedger,
      limits : BinaryCodecLimits,
      budget : BinaryCodecBudget,
    ) : Nil
      role = "#{role_name}.data"
      callback = site.callback_name_for(role)
      extent, _capture = ledger.with_bulk_body_grammar_extent(callback) do |bytes|
        context = BinaryCodecContext.new(limits, bytes, false, budget, false, false)
        row = 0_u64
        while row < rows
          size = context.read_var_uint
          context.read_slice(size)
          row += 1_u64
        end
        consumed = context.input_offset
        budget.ensure_wire_bytes(consumed.to_u64)
        {context.consumed_input_slice(0), consumed}
      end
      # The ledger's extent transaction commits only after every row boundary
      # and the aggregate wire-byte bound have succeeded.
      mark.capture_lane(role, extent)
      nil
    end

    private def self.capture_string1!(
      role_name : String,
      rows : UInt64,
      site : CompactRecursiveJsonBulkSite,
      mark : CompactRecursiveJsonBulkMark,
      ledger : CompactRecursiveJsonParentMarkLedger,
      budget : BinaryCodecBudget,
    ) : Nil
      size_role = "#{role_name}.string_sizes"
      size_bytes = checked_byte_count(rows, 8_u64, "Compact recursive Bulk String1 length lane")
      budget.ensure_wire_bytes(size_bytes.to_u64)
      sizes = ledger.capture_bulk_body(site.callback_name_for(size_role), size_bytes)
      data_bytes = sum_string1_lengths(sizes, rows)
      budget.ensure_wire_bytes(data_bytes.to_u64)
      mark.capture_lane(size_role, sizes)
      data_role = "#{role_name}.data"
      data = ledger.capture_bulk_body(site.callback_name_for(data_role), data_bytes)
      mark.capture_lane(data_role, data)
      nil
    end

    private def self.capture_fixed_role!(
      role : String,
      rows : UInt64,
      width : UInt64,
      site : CompactRecursiveJsonBulkSite,
      mark : CompactRecursiveJsonBulkMark,
      ledger : CompactRecursiveJsonParentMarkLedger,
      budget : BinaryCodecBudget,
    ) : Nil
      byte_count = checked_byte_count(rows, width, "Compact recursive Bulk fixed-width lane")
      budget.ensure_wire_bytes(byte_count.to_u64)
      bytes = ledger.capture_bulk_body(site.callback_name_for(role), byte_count)
      mark.capture_lane(role, bytes)
      nil
    end

    private def self.decode_uint64_lane(bytes : Bytes, count : UInt64, label : String, budget : BinaryCodecBudget) : Array(UInt64)
      expected = checked_byte_count(count, 8_u64, label)
      unless bytes.size == expected
        raise CorruptPartError.new("#{label} has the wrong exact callback extent")
      end
      budget.ensure_future_nodes(count)
      budget.ensure_future_elements(count)
      budget.charge_elements(count) if count > 0_u64
      count.times { budget.charge_node }
      values = Array(UInt64).new(count.to_i)
      count.to_i.times do |value_index|
        value = 0_u64
        8.times do |byte_index|
          value |= bytes[value_index * 8 + byte_index].to_u64 << (byte_index * 8)
        end
        values << value
      end
      values
    end

    private def self.sum_string1_lengths(bytes : Bytes, rows : UInt64) : Int32
      expected = checked_byte_count(rows, 8_u64, "Compact recursive Bulk String1 length lane")
      unless bytes.size == expected
        raise CorruptPartError.new("Compact recursive Bulk String1 length lane has the wrong exact callback extent")
      end
      total = 0_u64
      rows.to_i.times do |row|
        length = 0_u64
        8.times do |byte_index|
          length |= bytes[row * 8 + byte_index].to_u64 << (byte_index * 8)
        end
        if length > Int32::MAX.to_u64 || total > Int32::MAX.to_u64 - length
          raise CorruptPartError.new("Compact recursive Bulk String1 data lane exceeds Int32")
        end
        total += length
      end
      total.to_i32
    end

    private def self.checked_child_rows(sizes : Array(UInt64), label : String) : UInt64
      children = 0_u64
      sizes.each do |size|
        if size > Int32::MAX.to_u64 || children > UInt64::MAX - size
          raise CorruptPartError.new("#{label} exceeds its supported domain")
        end
        children += size
      end
      if children > Int32::MAX.to_u64
        raise CorruptPartError.new("#{label} exceeds Int32")
      end
      children
    end

    private def self.checked_byte_count(count : UInt64, width : UInt64, label : String) : Int32
      if width > 0_u64 && count > UInt64::MAX // width
        raise CorruptPartError.new("#{label} exceeds the supported byte or row domain")
      end
      bytes = count * width
      if count > Int32::MAX.to_u64 || bytes > Int32::MAX.to_u64
        raise CorruptPartError.new("#{label} exceeds the supported byte or row domain")
      end
      bytes.to_i32
    end

    private def self.decimal_digits(value : UInt64) : UInt64
      digits = 1_u64
      while value >= 10_u64
        value //= 10_u64
        digits += 1_u64
      end
      digits
    end

    private def self.checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise UnsupportedFormatError.new("recursive Compact Bulk grammar measure exceeds UInt64")
      end
      left + right
    end

    private def self.unsupported_type! : NoReturn
      raise UnsupportedFormatError.new("recursive Compact Bulk grammar reached an unsupported type")
    end
  end
end

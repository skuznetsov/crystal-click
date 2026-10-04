module CrystalClick
  # Stages borrowed LC values by syntactic occurrence path, then delegates the
  # complete dictionary/index subtree to the W142 storage encoder.
  module BinaryBulkLowCardinalitySiteEncoder
    def self.encode(
      type : BinaryDataType,
      sites : Array(BinaryBulkTypePlan::LowCardinalitySite),
      granules : Array(Array(BinaryValue)),
      budget : BinaryCodecBudget,
    ) : Hash(String, BinaryBulkStream)
      encoded = Hash(String, BinaryBulkStream).new
      return encoded if sites.empty?

      # A root LC can borrow the caller's mark/value grid directly. Keeping
      # this exact fast path makes its W142 budget identical to standalone.
      if sites.size == 1 && sites[0].path == "root"
        site = sites[0]
        streams = BinaryLowCardinalityStorageEncoder.encode_prevalidated(site.type, granules, budget)
        encoded[site.dictionary_role] = streams.stream(BinaryLowCardinalityStorageStreams::DICTIONARY_ROLE)
        encoded[site.indexes_role] = streams.stream(BinaryLowCardinalityStorageStreams::INDEX_ROLE)
        return encoded
      end

      mark_count = granules.size.to_u64
      nested_sites = sites.reject { |site| site.path == "root" }
      count_cells = checked_multiply(mark_count, nested_sites.size.to_u64)
      budget.ensure_future_nodes(count_cells)
      budget.ensure_future_elements(count_cells)
      budget.charge_elements(count_cells)
      count_cells.times { budget.charge_node }

      counts = Hash(String, Array(UInt64)).new
      nested_sites.each do |site|
        counts[site.path] = Array(UInt64).new(granules.size, 0_u64)
      end
      has_default = Hash(String, Bool).new
      granules.each_with_index do |rows, mark|
        rows.each do |value|
          count_value(type, value, "root", mark, counts, has_default)
        end
      end

      total_handles = 0_u64
      total_default_materialization_bytes = 0_u64
      nested_sites.each do |site|
        counts[site.path].each do |count|
          if count > Int32::MAX.to_u64
            raise UnsupportedFormatError.new("LowCardinality occurrence count exceeds its supported domain")
          end
          total_handles = checked_add(total_handles, count)
        end
        if has_default[site.path]?
          total_default_materialization_bytes = checked_add(
            total_default_materialization_bytes,
            default_materialization_bytes(site.type)
          )
        end
      end
      # All per-site defaults remain live through append and W142 encoding.
      # Preflight their aggregate payload before building any proportional
      # FixedString byte arrays.
      budget.ensure_wire_bytes(total_default_materialization_bytes)

      # Retained mark buckets and borrowed BinaryValue handles are real staging
      # work, distinct from the LC logical tree/key/index charge owned by W142.
      bucket_records = count_cells
      staging_edges = checked_add(bucket_records, total_handles)
      budget.ensure_future_nodes(bucket_records)
      budget.ensure_future_elements(staging_edges)
      budget.charge_elements(staging_edges)
      bucket_records.times { budget.charge_node }

      buckets = Hash(String, Array(Array(BinaryValue))).new
      nested_sites.each do |site|
        per_mark = Array(Array(BinaryValue)).new(granules.size)
        granules.size.times do |mark|
          per_mark << Array(BinaryValue).new(counts[site.path][mark].to_i32)
        end
        buckets[site.path] = per_mark
      end

      default_values = Hash(String, BinaryValue).new
      nested_sites.each do |site|
        default_values[site.path] = BinaryBulkDefaultValue.build(site.type) if has_default[site.path]?
      end
      granules.each_with_index do |rows, mark|
        rows.each do |value|
          append_value(type, value, "root", mark, buckets, default_values)
        end
      end

      nested_sites.each do |site|
        site_streams = BinaryLowCardinalityStorageEncoder.encode_prevalidated(site.type, buckets[site.path], budget)
        encoded[site.dictionary_role] = site_streams.stream(BinaryLowCardinalityStorageStreams::DICTIONARY_ROLE)
        encoded[site.indexes_role] = site_streams.stream(BinaryLowCardinalityStorageStreams::INDEX_ROLE)
      end
      encoded
    end

    private def self.count_value(
      type : BinaryDataType,
      value : BinaryValue,
      path : String,
      mark : Int32,
      counts : Hash(String, Array(UInt64)),
      has_default : Hash(String, Bool),
    ) : Nil
      unless value.type == type
        raise UnsupportedFormatError.new("binary bulk value does not match its descriptor")
      end
      case type.tag
      when BinaryDataType::TAG_LOW_CARDINALITY
        increment_count(counts, path, mark)
      when BinaryDataType::TAG_VARIANT
        if index = value.variant_index?
          child_type = type.child_at(index.to_i)
          child_value = value.variant_child? || raise UnsupportedFormatError.new("non-NULL Variant value is missing its selected arm")
          count_value(child_type, child_value, "#{path}.arm.#{index}", mark, counts, has_default)
        end
      when BinaryDataType::TAG_ARRAY
        child_type = type.child_at(0)
        value.element_count.times do |index|
          count_value(child_type, value.element_at(index), "#{path}.elements", mark, counts, has_default)
        end
      when BinaryDataType::TAG_NULLABLE
        if value.is_null?
          count_default(type.child_at(0), "#{path}.nested", mark, counts, has_default)
        else
          count_value(type.child_at(0), value.child_at(0), "#{path}.nested", mark, counts, has_default)
        end
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        unless value.element_count == type.child_count
          raise UnsupportedFormatError.new("Tuple bulk value does not match its descriptor")
        end
        type.child_count.times do |index|
          count_value(type.child_at(index), value.element_at(index), "#{path}.field.#{index}", mark, counts, has_default)
        end
      when BinaryDataType::TAG_MAP
        flat_count = value.element_count
        unless flat_count.even?
          raise UnsupportedFormatError.new("Map bulk value has an incomplete key/value pair")
        end
        flat_count.times do |index|
          child_index = index.even? ? 0 : 1
          child_path = "#{path}.elements.field.#{child_index}"
          count_value(type.child_at(child_index), value.element_at(index), child_path, mark, counts, has_default)
        end
      end
      nil
    end

    private def self.count_default(
      type : BinaryDataType,
      path : String,
      mark : Int32,
      counts : Hash(String, Array(UInt64)),
      has_default : Hash(String, Bool),
    ) : Nil
      case type.tag
      when BinaryDataType::TAG_LOW_CARDINALITY
        increment_count(counts, path, mark)
        has_default[path] = true
      when BinaryDataType::TAG_NULLABLE
        count_default(type.child_at(0), "#{path}.nested", mark, counts, has_default)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times do |index|
          count_default(type.child_at(index), "#{path}.field.#{index}", mark, counts, has_default)
        end
      end
      nil
    end

    private def self.append_value(
      type : BinaryDataType,
      value : BinaryValue,
      path : String,
      mark : Int32,
      buckets : Hash(String, Array(Array(BinaryValue))),
      default_values : Hash(String, BinaryValue),
    ) : Nil
      case type.tag
      when BinaryDataType::TAG_LOW_CARDINALITY
        buckets[path][mark] << value
      when BinaryDataType::TAG_VARIANT
        if index = value.variant_index?
          child_type = type.child_at(index.to_i)
          child_value = value.variant_child? || raise UnsupportedFormatError.new("non-NULL Variant value is missing its selected arm")
          append_value(child_type, child_value, "#{path}.arm.#{index}", mark, buckets, default_values)
        end
      when BinaryDataType::TAG_ARRAY
        child_type = type.child_at(0)
        value.element_count.times do |index|
          append_value(child_type, value.element_at(index), "#{path}.elements", mark, buckets, default_values)
        end
      when BinaryDataType::TAG_NULLABLE
        if value.is_null?
          append_default(type.child_at(0), "#{path}.nested", mark, buckets, default_values)
        else
          append_value(type.child_at(0), value.child_at(0), "#{path}.nested", mark, buckets, default_values)
        end
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times do |index|
          append_value(type.child_at(index), value.element_at(index), "#{path}.field.#{index}", mark, buckets, default_values)
        end
      when BinaryDataType::TAG_MAP
        value.element_count.times do |index|
          child_index = index.even? ? 0 : 1
          child_path = "#{path}.elements.field.#{child_index}"
          append_value(type.child_at(child_index), value.element_at(index), child_path, mark, buckets, default_values)
        end
      end
      nil
    end

    private def self.append_default(
      type : BinaryDataType,
      path : String,
      mark : Int32,
      buckets : Hash(String, Array(Array(BinaryValue))),
      default_values : Hash(String, BinaryValue),
    ) : Nil
      case type.tag
      when BinaryDataType::TAG_LOW_CARDINALITY
        buckets[path][mark] << default_values[path]
      when BinaryDataType::TAG_NULLABLE
        append_default(type.child_at(0), "#{path}.nested", mark, buckets, default_values)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times do |index|
          append_default(type.child_at(index), "#{path}.field.#{index}", mark, buckets, default_values)
        end
      end
      nil
    end

    private def self.increment_count(counts : Hash(String, Array(UInt64)), path : String, mark : Int32) : Nil
      grid = counts[path]?
      unless grid
        raise UnsupportedFormatError.new("LowCardinality bulk plan is missing a value occurrence path")
      end
      count = grid[mark]
      if count == UInt64::MAX
        raise UnsupportedFormatError.new("LowCardinality occurrence count overflows UInt64")
      end
      grid[mark] = count + 1_u64
      nil
    end

    private def self.default_materialization_bytes(type : BinaryDataType) : UInt64
      case type.tag
      when BinaryDataType::TAG_LOW_CARDINALITY
        default_materialization_bytes(type.child_at(0))
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        total = 0_u64
        type.child_count.times do |index|
          total = checked_add(total, default_materialization_bytes(type.child_at(index)))
        end
        total
      when BinaryDataType::TAG_NULLABLE, BinaryDataType::TAG_STRING,
           BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_MAP,
           BinaryDataType::TAG_NOTHING, BinaryDataType::TAG_BOOL,
           BinaryDataType::TAG_VARIANT
        0_u64
      else
        if width = type.fixed_width
          width.to_u64
        else
          raise UnsupportedFormatError.new("unsupported LowCardinality default materialization type")
        end
      end
    end

    private def self.checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("binary bulk LowCardinality staging count overflows UInt64")
      end
      left + right
    end

    private def self.checked_multiply(left : UInt64, right : UInt64) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        raise UnsupportedFormatError.new("binary bulk LowCardinality staging count overflows UInt64")
      end
      left * right
    end
  end
end

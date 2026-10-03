module CrystalClick
  # Canonical bounded writer for the shared LowCardinality dictionary/index
  # lanes. It emits one part-global dictionary and one aligned index record per
  # nonempty mark; it does not claim arbitrary ClickHouse split-record support.
  module BinaryLowCardinalityStorageEncoder
    include BinaryLowCardinalityStorageStreams

    def self.encode(
      type : BinaryDataType,
      granules : Array(Array(BinaryValue)),
      budget : BinaryCodecBudget,
    ) : BinaryBulkStreams
      unless budget.writing?
        raise ArgumentError.new("LowCardinality storage encoder requires a write-direction budget")
      end
      if granules.size == Int32::MAX
        raise UnsupportedFormatError.new("LowCardinality mark grid exceeds the supported domain")
      end

      traversal = BinaryCodecContext.new(budget.limits, nil, true, budget, false, false)
      nullable, scalar_type = BinaryLowCardinalityStorageStreams.ensure_root_type(type, traversal)
      traversal.validate_type_tree(type)

      mark_count = granules.size
      total_rows = 0_u64
      input_nodes = 0_u64
      input_edges = 0_u64
      key_work = 0_u64
      granules.each do |rows|
        total_rows = add(total_rows, rows.size.to_u64)
        rows.each do |value|
          leaf = input_scalar(type, value, nullable, scalar_type)
          if nullable
            if leaf.nil?
              input_nodes = add(input_nodes, 2_u64)
              input_edges = add(input_edges, 1_u64)
            else
              input_nodes = add(input_nodes, 3_u64)
              input_edges = add(input_edges, 2_u64)
            end
          else
            input_nodes = add(input_nodes, 2_u64)
            input_edges = add(input_edges, 1_u64)
          end
          next unless leaf
          # max_bytes also caps cumulative logical key inspection/copy work.
          # It is a separate preflight work bound; only emitted lane bytes are
          # charged to the shared physical wire-byte counter below.
          key_work = add(key_work, leaf.byte_size.to_u64 + 1_u64)
          if key_work > budget.limits.max_bytes.to_u64
            raise UnsupportedFormatError.new("LowCardinality logical key work exceeds byte limit")
          end
        end
      end

      offsets_per_role = add(mark_count.to_u64, 1_u64)
      metadata = add(mul(2_u64, offsets_per_role), mark_count.to_u64)
      # Preflight exact input trees and ID-vector elements before allocating
      # proportional staging arrays, lookup keys, or the dictionary table.
      id_elements = total_rows
      budget.ensure_future_nodes(add(metadata, input_nodes))
      budget.ensure_future_elements(add(add(metadata, input_edges), id_elements))
      budget.charge_elements(metadata)
      metadata.times { budget.charge_node }
      budget.charge_elements(add(input_edges, id_elements))
      input_nodes.times { budget.charge_node }

      if total_rows == 0_u64
        budget.ensure_wire_bytes(8_u64)
        dictionary_context = BinaryCodecContext.new(budget.limits, nil, true, budget, false, true)
        BinaryLowCardinalityStorageStreams.write_u64(dictionary_context, BinaryLowCardinalityStorageStreams::VERSION)
        index_offsets = Array(UInt64).new(mark_count + 1, 0_u64)
        dictionary_bytes = dictionary_context.finish_bytes
        dictionary_offsets = Array(UInt64).new(mark_count + 1, 8_u64)
        streams = {
          BinaryLowCardinalityStorageStreams::DICTIONARY_ROLE => BinaryBulkStream.new(dictionary_bytes, dictionary_offsets),
          BinaryLowCardinalityStorageStreams::INDEX_ROLE      => BinaryBulkStream.new(Bytes.empty, index_offsets),
        } of String => BinaryBulkStream
        return BinaryBulkStreams.new(mark_count, streams)
      end

      # Bound the reserved default payload before constructing it. This matters
      # for large FixedString(N), even when the dictionary later remains tiny.
      reserve_slots = nullable ? 2_u64 : 1_u64
      reserve_wire = mul(reserve_slots, default_scalar_wire_size(scalar_type))
      min_nonempty_marks = granules.count { |rows| !rows.empty? }.to_u64
      min_index_wire = add(mul(min_nonempty_marks, 16_u64), total_rows)
      budget.ensure_future_nodes(reserve_slots)
      budget.ensure_future_elements(reserve_slots)
      budget.ensure_wire_bytes(add(add(16_u64, reserve_wire), min_index_wire))
      budget.charge_elements(reserve_slots)
      reserve_slots.times { budget.charge_node }

      dictionary_values = [] of BinaryValue
      id_by_key = Hash(String, UInt64).new
      default = BinaryLowCardinalityStorageStreams.default_scalar(scalar_type)
      if nullable
        # ClickHouse ColumnUnique reserves nullable key 0 for NULL and key 1
        # for the underlying default; both serialize the base scalar bytes.
        dictionary_values << default
        dictionary_values << default
        id_by_key[BinaryLowCardinalityStorageStreams.scalar_bytes(default)] = 1_u64
      else
        dictionary_values << default
        id_by_key[BinaryLowCardinalityStorageStreams.scalar_bytes(default)] = 0_u64
      end

      ids_by_mark = Array(Array(UInt64)).new(mark_count)
      first_nonempty_mark : Int32? = nil
      granules.each_with_index do |rows, mark|
        ids = Array(UInt64).new(rows.size)
        unless rows.empty?
          first_nonempty_mark ||= mark.to_i32
        end
        rows.each do |value|
          leaf = input_scalar(type, value, nullable, scalar_type)
          if nullable && leaf.nil?
            ids << 0_u64
            next
          end

          scalar = leaf || raise UnsupportedFormatError.new("LowCardinality value has no scalar key")
          if BinaryLowCardinalityStorageStreams.is_default_scalar?(scalar_type, scalar)
            ids << (nullable ? 1_u64 : 0_u64)
          else
            key = BinaryLowCardinalityStorageStreams.scalar_bytes(scalar)
            id = id_by_key[key]?
            unless id
              budget.ensure_future_nodes(1_u64)
              budget.ensure_future_elements(1_u64)
              budget.charge_node
              budget.charge_elements(1_u64)
              id = dictionary_values.size.to_u64
              dictionary_values << scalar
              id_by_key[key] = id
            end
            ids << id
          end
        end
        ids_by_mark << ids
      end

      has_dictionary = !first_nonempty_mark.nil?
      unless has_dictionary
        # No index occurrence means no physical global dictionary record.
        dictionary_values.clear
      end
      width_code = if has_dictionary
                     BinaryLowCardinalityStorageStreams.width_code_for_maximum(dictionary_values.size.to_u64 - 1_u64)
                   else
                     0_u64
                   end
      width = BinaryLowCardinalityStorageStreams.width_for_code(width_code)

      dictionary_size = 8_u64
      if has_dictionary
        dictionary_size = add(dictionary_size, 8_u64)
        dictionary_values.each do |value|
          dictionary_size = add(dictionary_size, scalar_wire_size(scalar_type, value))
        end
      end
      indexes_size = 0_u64
      ids_by_mark.each do |ids|
        next if ids.empty?
        indexes_size = add(indexes_size, add(16_u64, mul(ids.size.to_u64, width.to_u64)))
      end
      budget.ensure_wire_bytes(add(dictionary_size, indexes_size))

      dictionary_context = BinaryCodecContext.new(budget.limits, nil, true, budget, false, true)
      BinaryLowCardinalityStorageStreams.write_u64(dictionary_context, BinaryLowCardinalityStorageStreams::VERSION)
      if has_dictionary
        BinaryLowCardinalityStorageStreams.write_u64(dictionary_context, dictionary_values.size.to_u64)
        dictionary_values.each do |value|
          BinaryLowCardinalityStorageStreams.write_scalar(scalar_type, value, dictionary_context)
        end
      end

      index_context = BinaryCodecContext.new(budget.limits, nil, true, budget, false, true)
      index_offsets = [0_u64]
      ids_by_mark.each_with_index do |ids, mark|
        unless ids.empty?
          flags = width_code | BinaryLowCardinalityStorageStreams::GLOBAL_BIT
          if first_nonempty_mark == mark
            flags |= BinaryLowCardinalityStorageStreams::UPDATE_BIT
          end
          BinaryLowCardinalityStorageStreams.write_u64(index_context, flags)
          BinaryLowCardinalityStorageStreams.write_u64(index_context, ids.size.to_u64)
          ids.each { |id| BinaryLowCardinalityStorageStreams.write_index(index_context, id, width) }
        end
        index_offsets << index_context.output_size.to_u64
      end

      dictionary_bytes = dictionary_context.finish_bytes
      index_bytes = index_context.finish_bytes
      dictionary_offsets = Array(UInt64).new(mark_count + 1) do |index|
        index == mark_count ? dictionary_bytes.size.to_u64 : 8_u64
      end

      streams = {
        BinaryLowCardinalityStorageStreams::DICTIONARY_ROLE => BinaryBulkStream.new(dictionary_bytes, dictionary_offsets),
        BinaryLowCardinalityStorageStreams::INDEX_ROLE      => BinaryBulkStream.new(index_bytes, index_offsets),
      } of String => BinaryBulkStream
      BinaryBulkStreams.new(mark_count, streams)
    end

    private def self.input_scalar(
      type : BinaryDataType,
      value : BinaryValue,
      nullable : Bool,
      scalar_type : BinaryDataType,
    ) : BinaryValue?
      unless value.type == type && value.child_count == 1
        raise UnsupportedFormatError.new("LowCardinality value does not match its root descriptor")
      end
      child = value.child_at(0)
      if nullable
        nullable_type = type.child_at(0)
        unless child.type == nullable_type
          raise UnsupportedFormatError.new("LowCardinality Nullable value does not match its descriptor")
        end
        return nil if child.is_null?
        unless child.child_count == 1 && child.child_at(0).type == scalar_type
          raise UnsupportedFormatError.new("LowCardinality Nullable value has an invalid scalar child")
        end
        scalar = child.child_at(0)
      else
        unless child.type == scalar_type && child.child_count == 0
          raise UnsupportedFormatError.new("LowCardinality value has an invalid scalar key")
        end
        scalar = child
      end

      if scalar_type.tag == BinaryDataType::TAG_BOOL
        scalar.as_bool
      elsif scalar_type.tag != BinaryDataType::TAG_STRING
        width = scalar_type.fixed_width || raise UnsupportedFormatError.new("unsupported LowCardinality scalar")
        raise UnsupportedFormatError.new("LowCardinality key has an invalid fixed width") unless scalar.byte_size == width
      end
      scalar
    end

    private def self.scalar_wire_size(type : BinaryDataType, value : BinaryValue) : UInt64
      if type.tag == BinaryDataType::TAG_STRING
        size = value.byte_size.to_u64
        add(var_uint_size(size), size)
      else
        (type.fixed_width || 1).to_u64
      end
    end

    private def self.default_scalar_wire_size(type : BinaryDataType) : UInt64
      if type.tag == BinaryDataType::TAG_STRING
        1_u64
      else
        (type.fixed_width || 1).to_u64
      end
    end

    private def self.var_uint_size(value : UInt64) : UInt64
      remaining = value
      size = 1_u64
      while remaining >= 0x80_u64
        remaining >>= 7
        size += 1_u64
      end
      size
    end

    private def self.add(left : UInt64, right : UInt64) : UInt64
      BinaryLowCardinalityStorageStreams.checked_add(left, right, "LowCardinality size arithmetic overflows")
    end

    private def self.mul(left : UInt64, right : UInt64) : UInt64
      BinaryLowCardinalityStorageStreams.checked_multiply(left, right, "LowCardinality size arithmetic overflows")
    end
  end
end

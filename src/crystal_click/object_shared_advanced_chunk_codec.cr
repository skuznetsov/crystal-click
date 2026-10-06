module CrystalClick
  # Composes the independent whole-object Copy representation with the
  # per-path Dynamic columns for one exact logical Object chunk.
  module ObjectSharedAdvancedChunkCodec
    DYNAMIC_TYPE             = BinaryDataType.dynamic(max_types: 0)
    EMPTY_DYNAMIC_STRUCTURE  = DynamicStructure.new([] of BinaryDataType)
    EMPTY_DYNAMIC_STRUCTURES = {"root" => EMPTY_DYNAMIC_STRUCTURE}

    private struct PathCursor
      getter name : String
      getter bucket : Int32

      def initialize(@name : String, @bucket : Int32)
      end

      def name_byte_size : Int32
        @name.bytesize
      end
    end

    def self.encode(
      rows : Array(ObjectSharedMapRow),
      bucket_count : Int32,
      budget : BinaryCodecBudget,
      profile : BinaryBulkProfile = ObjectSharedPathCodec::COMPACT_PROFILE,
    ) : ObjectSharedAdvancedChunk
      unless budget.writing?
        raise ArgumentError.new("Object shared advanced chunk encode requires a write-direction budget")
      end
      unless 1 <= bucket_count <= ObjectSharedBucketLayout::MAX_BUCKET_COUNT.to_i
        raise UnsupportedFormatError.new("Object shared advanced chunk bucket count must be between 1 and 256")
      end
      if rows.size > Int32::MAX
        raise UnsupportedFormatError.new("Object shared advanced chunk row count exceeds Int32")
      end

      row_count = rows.size.to_u64
      total_entries, _referenced_path_bytes = preflight_input_rows(rows, budget)
      unique_paths = collect_paths(rows, bucket_count, total_entries, budget)
      ordered_paths = sort_paths(unique_paths, budget)
      structures = bucket_structures(ordered_paths, bucket_count, row_count, budget)

      # Copy is one exact chunk and retains the original per-row path order.
      # The same budget then continues through all full-cardinality path rows.
      copy_streams = ObjectSharedCopyCodec.encode_with_budget(rows, structures, budget)
      chunks = encode_path_chunks(rows, ordered_paths, bucket_count, row_count, budget, profile)
      ObjectSharedAdvancedChunk.new(row_count, copy_streams, chunks)
    end

    def self.decode(
      bucket_chunks : Array(ObjectSharedPhysicalChunk),
      copy : ObjectSharedCopyStreams,
      budget : BinaryCodecBudget,
      profile : BinaryBulkProfile = ObjectSharedPathCodec::COMPACT_PROFILE,
    ) : Array(ObjectSharedMapRow)
      if budget.writing?
        raise ArgumentError.new("Object shared advanced chunk decode requires a read-direction budget")
      end
      unless 1 <= bucket_chunks.size <= ObjectSharedBucketLayout::MAX_BUCKET_COUNT
        raise CorruptPartError.new("Object shared advanced chunk has an invalid bucket count")
      end
      preflight_stream_snapshots!(bucket_chunks, copy, budget)

      row_count = bucket_chunks[0].row_count
      if row_count > Int32::MAX.to_u64
        raise CorruptPartError.new("Object shared advanced chunk row count exceeds Int32")
      end
      path_count, path_bytes = preflight_bucket_chunks(bucket_chunks, row_count, budget)
      structures = structures_from_chunks(bucket_chunks, row_count, path_count, path_bytes, budget)

      rows = ObjectSharedCopyCodec.decode_with_budget(
        copy.sizes,
        copy.indexes,
        copy.values,
        structures,
        budget,
      )
      unless rows.size.to_u64 == row_count
        raise CorruptPartError.new("Object shared Copy row count disagrees with its per-path chunks")
      end

      ordered_paths = order_physical_paths(bucket_chunks, path_count, path_bytes, budget)
      verify_path_values(rows, ordered_paths, budget, profile)
      rows
    end

    private def self.preflight_input_rows(
      rows : Array(ObjectSharedMapRow),
      budget : BinaryCodecBudget,
    ) : Tuple(UInt64, UInt64)
      entry_count = 0_u64
      path_bytes = 0_u64
      rows.each do |row|
        count = row.entry_count.to_u64
        if count > Int32::MAX.to_u64 - entry_count
          raise UnsupportedFormatError.new("Object shared advanced chunk entry count exceeds Int32")
        end
        entry_count += count
        row.entry_count.times do |index|
          entry = row.entry_at(index)
          if entry.value.is_null?
            raise UnsupportedFormatError.new("Object shared advanced Copy omits top-level NULL values")
          end
          size = entry.path_byte_size.to_u64
          if size > UInt64::MAX - path_bytes
            raise UnsupportedFormatError.new("Object shared advanced path work overflows UInt64")
          end
          path_bytes += size
        end
      end
      # Charge the borrowed path-byte comparisons and one entry visit before
      # building any retained path keys or arrays proportional to input rows.
      budget.preflight_children(entry_count)
      budget.charge_elements(path_bytes)
      {entry_count, path_bytes}
    end

    private def self.collect_paths(
      rows : Array(ObjectSharedMapRow),
      bucket_count : Int32,
      total_entries : UInt64,
      budget : BinaryCodecBudget,
    ) : Hash(String, Int32)
      unique = Hash(String, Int32).new
      rows.each do |row|
        row.entry_count.times do |index|
          entry = row.entry_at(index)
          name = String.build(entry.path_byte_size) do |io|
            entry.path_byte_size.times { |byte_index| io.write_byte(entry.path_byte_at(byte_index)) }
          end
          bucket = ObjectSharedBucketLayout.bucket_for(name, bucket_count)
          existing = unique[name]?
          if existing && existing != bucket
            raise UnsupportedFormatError.new("Object shared path has inconsistent hash-bucket ownership")
          end
          unique[name] = bucket unless existing
          budget.charge_node
        end
      end
      unless unique.size.to_u64 <= total_entries
        raise UnsupportedFormatError.new("Object shared path dictionary exceeds its entry domain")
      end
      unique
    end

    private def self.sort_paths(
      unique_paths : Hash(String, Int32),
      budget : BinaryCodecBudget,
    ) : Array(PathCursor)
      count = unique_paths.size.to_u64
      budget.preflight_children(count)
      paths = Array(PathCursor).new(unique_paths.size)
      unique_paths.each do |name, bucket|
        detached = String.new(name.to_slice)
        paths << PathCursor.new(detached, bucket)
        budget.charge_node
      end
      path_bytes = 0_u64
      paths.each do |path|
        path_size = path.name_byte_size.to_u64
        if path_size > UInt64::MAX - path_bytes
          raise UnsupportedFormatError.new("Object shared dictionary path work overflows UInt64")
        end
        path_bytes += path_size
      end
      comparisons = sort_depth(count)
      budget.charge_elements(checked_multiply(path_bytes, comparisons, true, "path sort work"))
      paths.sort! do |left, right|
        ObjectSharedChunkStructure.compare_paths(left.name, right.name)
      end
      paths
    end

    private def self.bucket_structures(
      paths : Array(PathCursor),
      bucket_count : Int32,
      row_count : UInt64,
      budget : BinaryCodecBudget,
    ) : Array(ObjectSharedChunkStructure)
      edge_count = bucket_count.to_u64 + paths.size.to_u64
      budget.preflight_children(edge_count)
      path_bytes = 0_u64
      paths.each do |path|
        size = path.name_byte_size.to_u64
        if size > UInt64::MAX - path_bytes
          raise UnsupportedFormatError.new("Object shared dictionary path work overflows UInt64")
        end
        path_bytes += size
      end
      budget.charge_elements(path_bytes)
      grouped = Array(Array(String)).new(bucket_count) { [] of String }
      paths.each do |path|
        grouped[path.bucket] << path.name
        budget.charge_node
      end
      structures = Array(ObjectSharedChunkStructure).new(bucket_count)
      grouped.each do |names|
        structures << ObjectSharedChunkStructure.new(
          row_count,
          names,
          {0_u64, 0_u64},
          {0_u64, 0_u64},
          {0_u64, 0_u64},
        )
        budget.charge_node
      end
      structures
    end

    private def self.encode_path_chunks(
      rows : Array(ObjectSharedMapRow),
      paths : Array(PathCursor),
      bucket_count : Int32,
      row_count : UInt64,
      budget : BinaryCodecBudget,
      profile : BinaryBulkProfile,
    ) : Array(ObjectSharedPhysicalChunk)
      slots = checked_multiply(paths.size.to_u64, row_count, true, "per-path row slots")
      budget.preflight_children(slots)
      # Reserve every per-path row reference before materializing the first
      # Array, so path-count x chunk-rows cannot fail only after partial output.
      budget.charge_elements(slots)
      cursors = Array(Int32).new(rows.size, 0)
      path_records = Array(Array(ObjectSharedPhysicalPath)).new(bucket_count) { [] of ObjectSharedPhysicalPath }
      paths.each do |path|
        path_rows = Array(BinaryValue).new(rows.size)
        rows.each_with_index do |row, row_index|
          cursor = cursors[row_index]
          value : BinaryValue? = nil
          if cursor < row.entry_count
            entry = row.entry_at(cursor)
            comparison = compare_entry_path(entry, path.name, budget)
            if comparison < 0
              raise UnsupportedFormatError.new("Object shared path cursor skipped an input entry")
            elsif comparison == 0
              value = entry.value
              cursors[row_index] = cursor + 1
            end
          end
          path_rows << BinaryValue.dynamic(DYNAMIC_TYPE, value)
          budget.charge_node
        end
        streams = ObjectSharedPathCodec.encode_with_budget(
          DYNAMIC_TYPE,
          EMPTY_DYNAMIC_STRUCTURES,
          path_rows,
          budget,
          profile: profile,
        )
        path_records[path.bucket] << ObjectSharedPhysicalPath.new(path.name, streams)
        budget.charge_node
      end
      rows.each_with_index do |row, index|
        unless cursors[index] == row.entry_count
          raise UnsupportedFormatError.new("Object shared per-path rows did not consume every Copy entry")
        end
      end
      chunks = Array(ObjectSharedPhysicalChunk).new(bucket_count)
      path_records.each do |bucket_paths|
        chunks << ObjectSharedPhysicalChunk.new(row_count, bucket_paths)
        budget.charge_node
      end
      chunks
    end

    private def self.preflight_bucket_chunks(
      bucket_chunks : Array(ObjectSharedPhysicalChunk),
      row_count : UInt64,
      budget : BinaryCodecBudget,
    ) : Tuple(UInt64, UInt64)
      path_count = 0_u64
      path_bytes = 0_u64
      bucket_chunks.each do |bucket|
        unless bucket.row_count == row_count
          raise CorruptPartError.new("Object shared bucket logical row counts disagree")
        end
        bucket.path_count.times do |index|
          if path_count == Int32::MAX.to_u64
            raise CorruptPartError.new("Object shared path dictionary exceeds Int32")
          end
          path_count += 1_u64
          size = bucket.path_at(index).name_byte_size.to_u64
          if size > UInt64::MAX - path_bytes
            raise CorruptPartError.new("Object shared path dictionary work overflows UInt64")
          end
          path_bytes += size
        end
      end
      edges = bucket_chunks.size.to_u64 + path_count
      budget.preflight_children(edges)
      budget.charge_elements(path_bytes)
      edges.times { budget.charge_node }
      {path_count, path_bytes}
    end

    private def self.preflight_stream_snapshots!(
      bucket_chunks : Array(ObjectSharedPhysicalChunk),
      copy : ObjectSharedCopyStreams,
      budget : BinaryCodecBudget,
    ) : Nil
      copy_bytes = copy.sizes_size.to_u64 + copy.indexes_size.to_u64 + copy.values_size.to_u64
      path_count = 0_u64
      bucket_chunks.each do |bucket|
        count = bucket.path_count.to_u64
        if count > UInt64::MAX - path_count
          raise CorruptPartError.new("Object shared path count overflows UInt64")
        end
        path_count += count
      end
      # Bound the path-by-path scan before inspecting any path-owned extents.
      budget.ensure_future_nodes(path_count)
      budget.ensure_future_elements(path_count)

      path_bytes = 0_u64
      event_count = 0_u64
      bucket_chunks.each do |bucket|
        bucket.path_count.times do |index|
          streams = bucket.path_at(index).streams
          data_size = streams.data_size.to_u64
          if data_size > UInt64::MAX - path_bytes
            raise CorruptPartError.new("Object shared path input bytes overflow UInt64")
          end
          path_bytes += data_size
          count = streams.event_count.to_u64
          if count > UInt64::MAX - event_count
            raise CorruptPartError.new("Object shared path event count overflows UInt64")
          end
          event_count += count
        end
      end
      if path_bytes > UInt64::MAX - copy_bytes
        raise CorruptPartError.new("Object shared chunk input bytes overflow UInt64")
      end
      # These non-consumptive checks run before any lane/data/event getter makes
      # a detached snapshot. Copy and path codecs still make the sole actual
      # wire charges, once each, on this shared budget.
      budget.ensure_wire_bytes(copy_bytes + path_bytes)
      budget.ensure_future_elements(event_count)
      nil
    end

    private def self.structures_from_chunks(
      bucket_chunks : Array(ObjectSharedPhysicalChunk),
      row_count : UInt64,
      path_count : UInt64,
      path_bytes : UInt64,
      budget : BinaryCodecBudget,
    ) : Array(ObjectSharedChunkStructure)
      # Physical path getters and ObjectSharedChunkStructure each take an owned
      # snapshot; account both copies before requesting either one.
      budget.charge_elements(checked_multiply(path_bytes, 2_u64, false, "path metadata snapshot work"))
      structures = Array(ObjectSharedChunkStructure).new(bucket_chunks.size)
      bucket_chunks.each do |bucket|
        paths = Array(String).new(bucket.path_count)
        bucket.path_count.times do |index|
          paths << bucket.path_at(index).name
        end
        structures << ObjectSharedChunkStructure.new(
          row_count,
          paths,
          {0_u64, 0_u64},
          {0_u64, 0_u64},
          {0_u64, 0_u64},
        )
      end
      actual_path_count = 0_u64
      structures.each do |structure|
        actual_path_count += structure.path_count.to_u64
      end
      unless actual_path_count == path_count
        raise CorruptPartError.new("Object shared path structure changed during materialization")
      end
      structures
    end

    private def self.order_physical_paths(
      bucket_chunks : Array(ObjectSharedPhysicalChunk),
      path_count : UInt64,
      path_bytes : UInt64,
      budget : BinaryCodecBudget,
    ) : Array(ObjectSharedPhysicalPath)
      budget.preflight_children(path_count)
      paths = Array(ObjectSharedPhysicalPath).new(path_count.to_i)
      bucket_chunks.each do |bucket|
        bucket.path_count.times do |index|
          paths << bucket.path_at(index)
        end
      end
      comparisons = sort_depth(path_count)
      budget.charge_elements(checked_multiply(path_bytes, comparisons, false, "path ordering work"))
      paths.sort! do |left, right|
        compare_physical_paths(left, right)
      end
      paths
    end

    private def self.compare_physical_paths(
      left : ObjectSharedPhysicalPath,
      right : ObjectSharedPhysicalPath,
    ) : Int32
      left_size = left.name_byte_size
      right_size = right.name_byte_size
      common_size = Math.min(left_size, right_size)
      common_size.times do |index|
        left_byte = left.name_byte_at(index)
        right_byte = right.name_byte_at(index)
        return -1 if left_byte < right_byte
        return 1 if left_byte > right_byte
      end
      left_size <=> right_size
    end

    private def self.verify_path_values(
      rows : Array(ObjectSharedMapRow),
      paths : Array(ObjectSharedPhysicalPath),
      budget : BinaryCodecBudget,
      profile : BinaryBulkProfile,
    ) : Nil
      slots = checked_multiply(rows.size.to_u64, paths.size.to_u64, false, "path value checks")
      budget.preflight_children(slots)
      # Charge the cross-representation cell walk before decoding any path
      # arrays. The per-path codec then charges its own recursive decoding.
      slots.times { budget.charge_node }
      cursors = Array(Int32).new(rows.size, 0)
      rows.each { budget.charge_node }
      paths.each do |path|
        budget.ensure_wire_bytes(path.streams.data_size.to_u64)
        budget.ensure_future_elements(path.streams.event_count.to_u64)
        decoded = ObjectSharedPathCodec.decode_with_budget(
          path.streams.data,
          path.streams.events,
          rows.size,
          DYNAMIC_TYPE,
          budget,
          profile: profile,
        )
        unless decoded.size == rows.size
          raise CorruptPartError.new("Object shared path Dynamic row count disagrees with Copy")
        end
        rows.each_with_index do |row, row_index|
          current = cursors[row_index]
          if current < row.entry_count
            entry = row.entry_at(current)
            comparison = compare_entry_path(entry, path, budget)
            if comparison < 0
              raise CorruptPartError.new("Object shared Copy path has no matching per-path Data stream")
            elsif comparison == 0
              if entry.value.is_null?
                raise CorruptPartError.new("Object shared Copy contains a NULL value omitted by native extraction")
              end
              value = decoded[row_index]
              unless !value.is_null? && value.child_count == 1 &&
                     values_equal?(entry.value, value.child_at(0), budget, 1)
                raise CorruptPartError.new("Object shared Copy value disagrees with its per-path Dynamic row")
              end
              cursors[row_index] = current + 1
            else
              ensure_absent_path_value!(decoded[row_index])
            end
          else
            ensure_absent_path_value!(decoded[row_index])
          end
        end
      end
      rows.each_with_index do |row, index|
        unless cursors[index] == row.entry_count
          raise CorruptPartError.new("Object shared Copy entry has no corresponding per-path Data stream")
        end
      end
      nil
    end

    private def self.ensure_absent_path_value!(value : BinaryValue) : Nil
      unless value.is_null? && value.child_count == 0
        raise CorruptPartError.new("absent Object shared path has a non-NULL Dynamic row")
      end
    end

    private def self.values_equal?(
      left : BinaryValue,
      right : BinaryValue,
      budget : BinaryCodecBudget,
      depth : Int32,
    ) : Bool
      budget.visit_node(depth)
      return false unless left.type == right.type
      return false unless left.is_null? == right.is_null?
      return true if left.is_null?

      if left.type.tag == BinaryDataType::TAG_VARIANT
        return false unless left.variant_index? == right.variant_index?
      end
      if composite_value?(left.type)
        child_count = left.child_count
        return false unless child_count == right.child_count
        budget.preflight_children(child_count.to_u64)
        child_count.times do |index|
          return false unless values_equal?(left.child_at(index), right.child_at(index), budget, depth + 1)
        end
        true
      else
        if left.type.tag == BinaryDataType::TAG_JSON
          return left == right
        end
        return false unless left.byte_size == right.byte_size
        budget.charge_elements(left.byte_size.to_u64)
        left.byte_size.times do |index|
          return false unless left.byte_at(index) == right.byte_at(index)
        end
        true
      end
    end

    private def self.composite_value?(type : BinaryDataType) : Bool
      case type.tag
      when BinaryDataType::TAG_ARRAY,
           BinaryDataType::TAG_UNNAMED_TUPLE,
           BinaryDataType::TAG_NAMED_TUPLE,
           BinaryDataType::TAG_MAP,
           BinaryDataType::TAG_NESTED,
           BinaryDataType::TAG_NULLABLE,
           BinaryDataType::TAG_LOW_CARDINALITY,
           BinaryDataType::TAG_VARIANT,
           BinaryDataType::TAG_DYNAMIC,
           BinaryDataType::TAG_SIMPLE_AGGREGATE
        true
      else
        false
      end
    end

    private def self.compare_entry_path(
      entry : ObjectSharedMapEntry,
      path : String,
      budget : BinaryCodecBudget,
    ) : Int32
      common_size = Math.min(entry.path_byte_size, path.bytesize)
      budget.charge_elements(common_size.to_u64)
      common_size.times do |index|
        left = entry.path_byte_at(index)
        right = path.to_slice[index]
        return -1 if left < right
        return 1 if left > right
      end
      entry.path_byte_size <=> path.bytesize
    end

    private def self.compare_entry_path(
      entry : ObjectSharedMapEntry,
      path : ObjectSharedPhysicalPath,
      budget : BinaryCodecBudget,
    ) : Int32
      path_size = path.name_byte_size
      common_size = Math.min(entry.path_byte_size, path_size)
      budget.charge_elements(common_size.to_u64)
      common_size.times do |index|
        left = entry.path_byte_at(index)
        right = path.name_byte_at(index)
        return -1 if left < right
        return 1 if left > right
      end
      entry.path_byte_size <=> path_size
    end

    private def self.sort_depth(count : UInt64) : UInt64
      depth = 1_u64
      value = count
      while value > 1_u64
        value = value // 2_u64 + value % 2_u64
        depth += 1_u64
      end
      depth
    end

    private def self.checked_multiply(
      left : UInt64,
      right : UInt64,
      writing : Bool,
      description : String,
    ) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        if writing
          raise UnsupportedFormatError.new("Object shared #{description} overflows UInt64")
        else
          raise CorruptPartError.new("Object shared #{description} overflows UInt64")
        end
      end
      left * right
    end
  end
end

module CrystalClick
  # Composes one Array(JSON) wrapper over the existing normalized Object V3
  # owner. Parent rows determine .size0 and physical mark rows; flattened
  # Object documents determine child-lane byte offsets and Dynamic rows.
  module ArrayObjectColumnWriter
    MAX_FILE_NAME_BYTES = PartChecksums::MAX_NAME_BYTES

    def self.encode(
      column_name : String,
      plan : ObjectDocumentPlan,
      granules : Array(Array(Array(ObjectDocument))),
      mode : UInt64 = DynamicDiscriminatorCodec::BASIC_MODE,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      shared_profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      hashed : Bool = false,
      frame_bytes : Int = 4096,
      limits : BinaryCodecLimits = ObjectDocumentCodec::DEFAULT_LIMITS,
      transport_limits : CompressedStreamLimits = CompressedStreamLimits.new,
    ) : ArrayObjectColumnFiles
      unless mode == DynamicDiscriminatorCodec::BASIC_MODE
        raise UnsupportedFormatError.new("Array(JSON) Object lanes require the BASIC Dynamic profile")
      end
      if granules.empty?
        raise ArgumentError.new("a physical Array(JSON) column requires at least one real mark")
      end
      if frame_bytes <= 0 || frame_bytes > Int32::MAX
        raise ArgumentError.new("frame size must be a positive Int32 value")
      end
      if frame_bytes < DynamicDiscriminatorCodec::HEADER_BYTES.to_i
        raise ArgumentError.new("frame size must contain the complete Dynamic discriminator prefix")
      end
      child_limits = child_limits_for(limits)
      codec_budget = BinaryCodecBudget.new(child_limits, true)
      mark_count, physical_rows, child_rows, total_parents, total_children =
        inspect_input_grid!(granules, codec_budget)

      size_bytes_u64 = checked_multiply(total_parents, 8_u64)
      if size_bytes_u64 > Int32::MAX.to_u64
        raise UnsupportedFormatError.new("Array(JSON) size stream exceeds the supported byte domain")
      end
      # Charge the retained parent schedule, flattened mark containers, child
      # references, and occurrence grid before creating proportional copies.
      flattened_elements = checked_add(total_parents, total_children)
      retained_nodes = checked_add(total_parents, checked_add(mark_count.to_u64, mark_count.to_u64 * 2_u64))
      retained_elements = checked_add(
        flattened_elements,
        checked_add(mark_count.to_u64, mark_count.to_u64 * 2_u64)
      )
      codec_budget.ensure_future_nodes(retained_nodes)
      codec_budget.ensure_future_elements(retained_elements)
      codec_budget.charge_wire_bytes(size_bytes_u64)
      total_parents.times { codec_budget.charge_node }
      codec_budget.charge_elements(total_parents)
      mark_count.times { codec_budget.charge_node }
      codec_budget.charge_elements(mark_count.to_u64)
      codec_budget.charge_elements(total_children)

      grid = StorageOccurrenceGrid.new(physical_rows, child_rows, codec_budget)
      flattened = flatten_children(granules, child_rows)

      physical = ObjectDocumentPhysicalPlan.new(
        column_name,
        plan,
        profile,
        shared_profile,
        child_limits,
        1_u64
      )
      object_roster = ObjectDocumentColumnWriter.file_roster_for_child_site(physical, hashed)
      inner_file_roster = Hash(String, Tuple(String, String)).new(initial_capacity: object_roster.size)
      object_roster.each { |name, files| inner_file_roster[name] = files }
      size_name, size_files = preflight_combined_roster!(
        object_roster,
        column_name,
        hashed,
        child_limits
      )

      fresh_plan = ObjectDocumentStatistics.recompute_child_site_with_budget(
        plan,
        flattened,
        grid,
        codec_budget
      )
      streams = ObjectDocumentCodec.encode_child_site_with_budget(
        fresh_plan,
        flattened,
        grid,
        codec_budget,
        mode: mode,
        profile: profile,
        shared_profile: shared_profile
      )
      ObjectDocumentColumnWriter.preflight_child_site_variant_prefixes!(physical, fresh_plan, streams, codec_budget)
      lanes = ObjectDocumentColumnWriter.bind_child_site_lanes(physical, fresh_plan, streams)

      # Include the wrapper in aggregate transport admission before any
      # lane copies, prefix adaptation, or compressed outputs are constructed.
      transport_budget = CompressedStreamBudget.new(transport_limits, true)
      raw_sizes = Array(Int32).new(lanes.size + 1)
      lanes.each { |lane| raw_sizes << lane.byte_size }
      raw_sizes << size_bytes_u64.to_i
      CompressedMarkWriter.preflight_batch(raw_sizes, mark_count + 1, frame_bytes, transport_budget)

      size_bytes, size_offsets = encode_sizes(granules, size_bytes_u64.to_i)
      size_stream = BinaryBulkStream.new(size_bytes, size_offsets)
      size_lane = ObjectDocumentColumnLane.new(size_name, size_bytes, bulk_source: size_stream)
      pairs = Hash(String, CompressedMarkFiles).new(initial_capacity: lanes.size)
      lanes.each { |lane| pairs[lane.name] = lane.encode_child_site(grid, frame_bytes, transport_budget) }
      ObjectDocumentColumnWriter.append_child_site_advanced_pairs!(
        pairs,
        physical,
        fresh_plan,
        streams,
        physical_rows,
        codec_budget,
        transport_budget,
        frame_bytes,
        profile,
      )
      ObjectDocumentTypedDynamicJsonPhysical.append_pairs!(
        pairs,
        physical,
        fresh_plan,
        streams,
        physical_rows,
        codec_budget,
        transport_budget,
        frame_bytes,
        profile,
      )
      inner_files = ObjectDocumentColumnFiles.new(fresh_plan, physical, pairs, inner_file_roster)
      size_pair = size_lane.encode_child_site(grid, frame_bytes, transport_budget)
      ArrayObjectColumnFiles.new(inner_files, size_name, size_pair, size_files)
    end

    private def self.child_limits_for(limits : BinaryCodecLimits) : BinaryCodecLimits
      if limits.max_depth < 1
        raise UnsupportedFormatError.new("Array(JSON) wrapper exceeds the configured codec depth limit")
      end
      BinaryCodecLimits.new(
        limits.max_depth - 1,
        limits.max_nodes,
        limits.max_elements,
        limits.max_bytes
      )
    end

    private def self.inspect_input_grid!(
      granules : Array(Array(Array(ObjectDocument))),
      budget : BinaryCodecBudget,
    ) : Tuple(Int32, Array(UInt64), Array(UInt64), UInt64, UInt64)
      mark_count = granules.size
      if mark_count > StorageOccurrenceGrid::MAX_MARK_COUNT
        raise UnsupportedFormatError.new("Array(JSON) mark grid exceeds the supported domain")
      end
      # Preflight the K-sized count copies before inspecting later mark data.
      budget.ensure_future_nodes(mark_count.to_u64 * 2_u64)
      budget.ensure_future_elements(mark_count.to_u64 * 2_u64)
      mark_count.times { budget.charge_node }
      budget.charge_elements(mark_count.to_u64 * 2_u64)
      physical_rows = Array(UInt64).new(mark_count)
      child_rows = Array(UInt64).new(mark_count)
      total_parents = 0_u64
      total_children = 0_u64
      granules.each do |parents|
        physical = parents.size.to_u64
        if physical == 0_u64 || physical > Int32::MAX.to_u64
          raise ArgumentError.new("Array(JSON) real marks must contain positive Int32 parent rows")
        end
        children = 0_u64
        parents.each do |documents|
          if documents.size > Int32::MAX
            raise UnsupportedFormatError.new("Array(JSON) child row exceeds the supported domain")
          end
          children = checked_add(children, documents.size.to_u64)
        end
        if children > Int32::MAX.to_u64
          raise UnsupportedFormatError.new("Array(JSON) child occurrences per mark exceed the supported domain")
        end
        total_parents = checked_add(total_parents, physical)
        total_children = checked_add(total_children, children)
        if total_children > Int32::MAX.to_u64
          raise UnsupportedFormatError.new("Array(JSON) flattened child rows exceed the supported domain")
        end
        physical_rows << physical
        child_rows << children
      end
      {mark_count.to_i32, physical_rows, child_rows, total_parents, total_children}
    end

    private def self.flatten_children(
      granules : Array(Array(Array(ObjectDocument))),
      child_rows : Array(UInt64),
    ) : Array(Array(ObjectDocument))
      flattened = Array(Array(ObjectDocument)).new(granules.size)
      granules.each_with_index do |parents, mark_index|
        count = child_rows[mark_index].to_i
        children = Array(ObjectDocument).new(count)
        parents.each { |documents| documents.each { |document| children << document } }
        flattened << children
      end
      flattened
    end

    private def self.encode_sizes(
      granules : Array(Array(Array(ObjectDocument))),
      byte_size : Int,
    ) : Tuple(Bytes, Array(UInt64))
      bytes = Bytes.new(byte_size)
      offsets = Array(UInt64).new(granules.size + 1)
      offsets << 0_u64
      cursor = 0
      granules.each do |parents|
        parents.each do |documents|
          value = documents.size.to_u64
          8.times do |index|
            bytes[cursor] = ((value >> (index * 8)) & 0xff).to_u8
            cursor += 1
          end
        end
        offsets << cursor.to_u64
      end
      unless cursor == byte_size
        raise UnsupportedFormatError.new("Array(JSON) size stream changed after preflight")
      end
      {bytes, offsets}
    end

    private def self.preflight_combined_roster!(
      object_roster : Hash(String, Tuple(String, String)),
      column_name : String,
      hashed : Bool,
      limits : BinaryCodecLimits,
    ) : Tuple(String, Tuple(String, String))
      prefix = PhysicalStreamName.escape(column_name)
      size_name = PhysicalStreamName.append_literal(prefix, ".size0")
      base = hashed ? StreamName.hash(size_name) : size_name
      data_name = PhysicalStreamName.append_literal(base, ".bin")
      marks_name = PhysicalStreamName.append_literal(base, ".mrk2")
      {size_name, data_name, marks_name}.each do |name|
        if name.bytesize.to_u64 > limits.max_bytes.to_u64 || name.bytesize > MAX_FILE_NAME_BYTES
          raise UnsupportedFormatError.new("Array(JSON) filename exceeds its configured bound")
        end
      end
      if object_roster.size + 1 > PartChecksums::MAX_ENTRIES // 2
        raise UnsupportedFormatError.new("Array(JSON) combined checksum roster exceeds its entry limit")
      end
      seen_files = Hash(String, Bool).new
      object_roster.each do |logical, files|
        if logical == size_name
          raise UnsupportedFormatError.new("Array(JSON) wrapper stream collides with an inner Object lane")
        end
        {files[0], files[1]}.each { |name| seen_files[name] = true }
      end
      if seen_files.has_key?(data_name) || seen_files.has_key?(marks_name) || data_name == marks_name
        raise UnsupportedFormatError.new("Array(JSON) wrapper filenames collide with an inner Object lane")
      end
      {size_name, {data_name, marks_name}}
    end

    private def self.checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("Array(JSON) cardinality overflows UInt64")
      end
      left + right
    end

    private def self.checked_multiply(left : UInt64, right : UInt64) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        raise UnsupportedFormatError.new("Array(JSON) size stream length overflows UInt64")
      end
      left * right
    end
  end
end

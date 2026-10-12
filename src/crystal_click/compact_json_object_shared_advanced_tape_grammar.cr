module CrystalClick
  # Delimits the native MRK3 parent lanes for Object SharedData ADVANCED and
  # ADVANCED_CHUNKED. It retains only borrowed path slices and count metadata;
  # Dynamic values and Copy value envelopes remain opaque for later owners.
  class CompactJsonObjectSharedAdvancedTapeGrammar
    EXPECTED_BUCKETS        = 2
    EXPECTED_ADVANCED_ROLES = 2 * ObjectSharedPhysicalBucketRawLayout::LANE_NAMES.size +
                              ObjectSharedAdvancedCopyLayout::COPY_LANES.size

    private class Chunk
      getter row_count : UInt64
      getter paths : Array(Bytes)
      getter child_callback_counts : Array(UInt64)
      property copy_entry_count : UInt64

      def initialize(@row_count : UInt64, @paths : Array(Bytes))
        @child_callback_counts = [] of UInt64
        @copy_entry_count = 0_u64
      end
    end

    @prefix : ObjectDocumentCallbackPrefix
    @physical_plan : ObjectDocumentPhysicalPlan
    @schedule : CompactJsonObjectRoleSchedule
    @row_count : UInt64
    @nested_data_string_profile : BinaryBulkProfile
    @limits : BinaryCodecLimits
    @budget : BinaryCodecBudget
    @shared_data_version : UInt64
    @chunks : Array(Array(Chunk))
    @bucket_role_masks : Array(UInt8)
    @copy_role_mask : UInt8
    @next_role_index : Int32
    @copy_entries_total : UInt64

    def initialize(
      @prefix : ObjectDocumentCallbackPrefix,
      @physical_plan : ObjectDocumentPhysicalPlan,
      @schedule : CompactJsonObjectRoleSchedule,
      @row_count : UInt64,
      profile : BinaryBulkProfile,
      @limits : BinaryCodecLimits,
      @budget : BinaryCodecBudget,
    )
      # Compact Object metadata admits propagated nested versions for this
      # reader. SerializationObject creates fresh bulk settings for SharedData,
      # but its already-created Dynamic serializer retains the propagated
      # SerializationInfoSettings. Thus this profile applies to nested Data
      # arms; the separately serialized Copy envelopes remain S0 below.
      @nested_data_string_profile = profile

      if @budget.writing?
        raise ArgumentError.new("Compact MRK3 Advanced tape grammar requires a reading budget")
      end
      unless @schedule.advanced
        raise UnsupportedFormatError.new("Compact MRK3 Advanced tape grammar requires the sealed advanced role schedule")
      end
      @prefix.validate_physical_owner!(@physical_plan)

      @shared_data_version = @prefix.plan.structures.object.shared_data_version
      unless @shared_data_version == 2_u64 || @shared_data_version == 3_u64
        raise UnsupportedFormatError.new("Compact MRK3 Advanced tape grammar admits SharedData v2 or v3")
      end
      unless @physical_plan.shared_bucket_count == EXPECTED_BUCKETS
        raise UnsupportedFormatError.new("Compact MRK3 Advanced tape grammar requires exactly two buckets")
      end
      if @row_count > Int32::MAX.to_u64
        raise UnsupportedFormatError.new("Compact MRK3 Advanced mark rows exceed the parser domain")
      end

      validate_advanced_schedule!
      @chunks = [Array(Chunk).new, Array(Chunk).new]
      @bucket_role_masks = [0_u8, 0_u8]
      @copy_role_mask = 0_u8
      @next_role_index = 0_i32
      @copy_entries_total = 0_u64
    end

    # Consumes exactly one parent role from the caller's current remaining
    # tape. The extent is the cursor delta, not saved-pair coordinates: MRK3
    # stores separate contiguous parent lanes in the native callback order.
    def parse!(owner_path : String, role : String, context : BinaryCodecContext, borrowed_tape : Bytes) : Nil
      unless context.input_offset == 0_i32 && context.remaining_input_bytes == borrowed_tape.size.to_u64
        raise CorruptPartError.new("Compact MRK3 Advanced role context does not begin at its borrowed tape")
      end
      unless context.budget.same?(@budget) && !context.budget.writing?
        raise CorruptPartError.new("Compact MRK3 Advanced role context changed its read budget")
      end
      unless same_limits?(context.limits, @limits)
        raise CorruptPartError.new("Compact MRK3 Advanced role context changed its codec limits")
      end
      if @next_role_index >= EXPECTED_ADVANCED_ROLES
        raise CorruptPartError.new("Compact MRK3 Advanced role schedule contains an extra lane")
      end

      expected_owner, expected_role = expected_role_at(@next_role_index)
      unless owner_path == expected_owner && role == expected_role
        raise CorruptPartError.new("Compact MRK3 Advanced role callback is duplicated, omitted, or out of order")
      end

      start = context.input_offset
      if @next_role_index < EXPECTED_BUCKETS * ObjectSharedPhysicalBucketRawLayout::LANE_NAMES.size
        bucket_index = @next_role_index // ObjectSharedPhysicalBucketRawLayout::LANE_NAMES.size
        parse_bucket_lane!(bucket_index, role, context)
        lane_index = ObjectSharedPhysicalBucketRawLayout::LANE_NAMES.index(role) ||
                     raise(CorruptPartError.new("Compact MRK3 Advanced bucket role is outside its lane roster"))
        bit = 1_u8 << lane_index
        if (@bucket_role_masks[bucket_index] & bit) != 0_u8
          raise CorruptPartError.new("Compact MRK3 Advanced bucket role was consumed more than once")
        end
        @bucket_role_masks[bucket_index] |= bit
      else
        parse_copy_lane!(role, context)
        lane_index = ObjectSharedAdvancedCopyLayout::COPY_LANES.index(role) ||
                     raise(CorruptPartError.new("Compact MRK3 Advanced Copy role is outside its lane roster"))
        bit = 1_u8 << lane_index
        if (@copy_role_mask & bit) != 0_u8
          raise CorruptPartError.new("Compact MRK3 Advanced Copy role was consumed more than once")
        end
        @copy_role_mask |= bit
      end

      if context.input_offset < start
        raise CorruptPartError.new("Compact MRK3 Advanced role cursor moved backwards")
      end
      @next_role_index += 1_i32
      nil
    end

    # The last Copy lane closes the schedule only after all seven roles for
    # each bucket and all three Copy lanes have been consumed.
    def finish! : Nil
      unless @next_role_index == EXPECTED_ADVANCED_ROLES
        raise CorruptPartError.new("Compact MRK3 Advanced role schedule is incomplete")
      end
      expected_bucket_mask = (1_u8 << ObjectSharedPhysicalBucketRawLayout::LANE_NAMES.size) - 1_u8
      unless @bucket_role_masks.size == EXPECTED_BUCKETS &&
             @bucket_role_masks.all? { |mask| mask == expected_bucket_mask }
        raise CorruptPartError.new("Compact MRK3 Advanced bucket callback roster is incomplete")
      end
      expected_copy_mask = (1_u8 << ObjectSharedAdvancedCopyLayout::COPY_LANES.size) - 1_u8
      unless @copy_role_mask == expected_copy_mask
        raise CorruptPartError.new("Compact MRK3 Advanced Copy callback roster is incomplete")
      end
      validate_complete_bucket_grids!
      nil
    end

    private def validate_advanced_schedule! : Nil
      role_index = 0_i32
      advanced_started = false
      @schedule.body_bindings.each do |binding|
        _name, owner_kind, owner_path, role = binding
        if owner_kind != :advanced_bucket && owner_kind != :advanced_copy
          if advanced_started
            raise CorruptPartError.new("Compact MRK3 Advanced lanes are not a contiguous suffix of the body schedule")
          end
          next
        end

        advanced_started = true
        expected_owner, expected_role = expected_role_at(role_index)
        expected_kind = role_index < EXPECTED_BUCKETS * ObjectSharedPhysicalBucketRawLayout::LANE_NAMES.size ? :advanced_bucket : :advanced_copy
        unless owner_kind == expected_kind && owner_path == expected_owner && role == expected_role
          raise CorruptPartError.new("Compact MRK3 Advanced role schedule differs from its source lane roster")
        end
        role_index += 1_i32
      end
      unless role_index == EXPECTED_ADVANCED_ROLES
        raise CorruptPartError.new("Compact MRK3 Advanced role schedule omits a bucket or Copy lane")
      end
      nil
    end

    private def expected_role_at(index : Int32) : Tuple(String, String)
      bucket_role_count = EXPECTED_BUCKETS * ObjectSharedPhysicalBucketRawLayout::LANE_NAMES.size
      if index < 0 || index >= EXPECTED_ADVANCED_ROLES
        raise CorruptPartError.new("Compact MRK3 Advanced role index is outside its sealed roster")
      end
      if index < bucket_role_count
        bucket_index = index // ObjectSharedPhysicalBucketRawLayout::LANE_NAMES.size
        lane_index = index % ObjectSharedPhysicalBucketRawLayout::LANE_NAMES.size
        {bucket_index.to_s, ObjectSharedPhysicalBucketRawLayout::LANE_NAMES[lane_index]}
      else
        lane_index = index - bucket_role_count
        {"copy", ObjectSharedAdvancedCopyLayout::COPY_LANES[lane_index]}
      end
    end

    private def parse_bucket_lane!(bucket_index : Int32, role : String, context : BinaryCodecContext) : Nil
      case role
      when "structure_prefix"
        parse_structure_prefix!(bucket_index, context)
      when "data"
        parse_data!(bucket_index, context)
      when "paths_marks"
        chunks = require_chunks!(bucket_index, "PathsMarks")
        consume_fixed!(context, checked_multiply(path_count(chunks), 16_u64, "PathsMarks extent"))
      when "substreams"
        parse_substreams!(bucket_index, context)
      when "substreams_marks"
        chunks = require_chunks!(bucket_index, "SubstreamsMarks")
        consume_fixed!(context, checked_multiply(callback_count(chunks), 16_u64, "SubstreamsMarks extent"))
      when "paths_substreams_metadata"
        chunks = require_chunks!(bucket_index, "PathsSubstreamsMetadata")
        consume_fixed!(context, checked_multiply(path_count(chunks), 32_u64, "PathsSubstreamsMetadata extent"))
      when "structure_suffix"
        chunks = require_chunks!(bucket_index, "StructureSuffix")
        consume_fixed!(context, checked_multiply(chunks.size.to_u64, ObjectSharedChunkStructureCodec::TRANSPORT_SUFFIX_BYTES, "StructureSuffix extent"))
      else
        raise UnsupportedFormatError.new("Compact MRK3 Advanced bucket role is outside the admitted lane grammar")
      end
      nil
    end

    private def parse_structure_prefix!(bucket_index : Int32, context : BinaryCodecContext) : Nil
      unless @chunks[bucket_index].empty?
        raise CorruptPartError.new("Compact MRK3 Advanced StructurePrefix was parsed more than once")
      end

      rows_seen = 0_u64
      empty_mark = @row_count == 0_u64
      loop do
        break if !empty_mark && rows_seen == @row_count

        context.visit_node(1)
        chunk_rows = context.read_var_uint
        raw_path_count = context.read_var_uint
        path_count = context.preflight_metadata(
          raw_path_count,
          1_u64,
          Int32::MAX.to_u64,
          "Object shared chunk path count",
        )
        context.ensure_remaining_input_bytes(raw_path_count)
        context.visit_metadata_nodes(raw_path_count, 1)

        if empty_mark
          unless chunk_rows == 0_u64 && raw_path_count == 0_u64
            raise CorruptPartError.new("Compact MRK3 empty mark must contain one pathless zero-row chunk")
          end
        else
          if chunk_rows == 0_u64 || chunk_rows > @row_count - rows_seen
            raise CorruptPartError.new("Compact MRK3 chunk rows are zero or exceed the remaining mark rows")
          end
        end

        paths = Array(Bytes).new(path_count)
        previous_path : Bytes? = nil
        path_count.times do
          path_size = context.read_var_uint
          path = context.read_slice(path_size)
          context.charge_elements(path_size)
          if previous = previous_path
            unless compare_path_bytes(previous, path) < 0
              raise CorruptPartError.new("Compact MRK3 chunk paths are not byte-sorted and unique")
            end
          end
          bucket_for_path = (ClickHouseSipHash.hash64(path) % EXPECTED_BUCKETS.to_u64).to_i32
          unless bucket_for_path == bucket_index
            raise CorruptPartError.new("Compact MRK3 chunk path is assigned to the wrong bucket")
          end
          paths << path
          previous_path = path
        end

        @chunks[bucket_index] << Chunk.new(chunk_rows, paths)
        rows_seen = checked_add(rows_seen, chunk_rows, "chunk row total")
        break if empty_mark
      end

      unless rows_seen == @row_count
        raise CorruptPartError.new("Compact MRK3 chunk rows do not equal the root mark rows")
      end
      if @shared_data_version == 2_u64 && @chunks[bucket_index].size != 1
        raise CorruptPartError.new("Compact MRK3 ADVANCED v2 must contain exactly one chunk per bucket")
      end
      if bucket_index == 1
        validate_matching_chunk_rows!
      end
      nil
    end

    private def parse_data!(bucket_index : Int32, context : BinaryCodecContext) : Nil
      chunks = require_chunks!(bucket_index, "Data")
      chunks.each do |chunk|
        chunk.paths.each do |_path|
          structure = DynamicStructureCodec.read_prefix_without_statistics(context, 1, 1, true)
          unless structure.version == DynamicStructure::VERSION_V3
            raise CorruptPartError.new("Compact MRK3 nested SharedData Dynamic prefix is not V3")
          end
          arms = BinaryDynamicBulkPlan.canonical_arm_types_for_compact_prefix(structure, @budget, 2)
          if arms.empty? || arms.size > DynamicDiscriminatorCodec::NULL_TAG.to_i
            raise CorruptPartError.new("Compact MRK3 nested Dynamic canonical arm roster exceeds its discriminator domain")
          end

          mode = read_u64_le(context)
          unless mode == DynamicDiscriminatorCodec::COMPACT_MODE
            raise CorruptPartError.new("Compact MRK3 nested SharedData Dynamic discriminator mode is not COMPACT")
          end

          counts = Array(UInt64).new(arms.size, 0_u64)
          if chunk.row_count > 0_u64
            frame_rows = context.read_var_uint
            unless frame_rows == chunk.row_count
              raise CorruptPartError.new("Compact MRK3 nested Dynamic discriminator rows differ from the chunk")
            end
            format = context.read_byte
            case format
            when DynamicDiscriminatorBodyValidator::COMPACT_ROW_TAGS
              @budget.charge_elements(chunk.row_count)
              tags = context.read_slice(chunk.row_count)
              tags.each { |tag| count_tag!(counts, tag) }
            when DynamicDiscriminatorBodyValidator::COMPACT_UNIFORM_TAG
              @budget.charge_elements(chunk.row_count)
              count_tag!(counts, context.read_byte, chunk.row_count)
            else
              raise CorruptPartError.new("Compact MRK3 nested Dynamic COMPACT format is unsupported")
            end
          end

          arms.each_with_index do |arm_type, arm_index|
            scan_scalar_arm!(arm_type, counts[arm_index], context)
          end
          child_callbacks = nested_dynamic_callback_count(arms)
          chunk.child_callback_counts << child_callbacks
        end
      end
      nil
    end

    private def scan_scalar_arm!(type : BinaryDataType, count : UInt64, context : BinaryCodecContext) : Nil
      if width = type.fixed_width
        if width <= 0
          raise UnsupportedFormatError.new("Compact MRK3 nested Dynamic fixed-width arm has no positive width")
        end
        @budget.charge_elements(count)
        consume_fixed!(context, checked_multiply(count, width.to_u64, "Dynamic scalar extent"))
      elsif type.tag == BinaryDataType::TAG_STRING
        if @nested_data_string_profile.with_size_stream?
          scan_s1_strings!(count, context)
        else
          context.ensure_remaining_input_bytes(count)
          @budget.charge_elements(count)
          count.times do
            value_size = context.read_var_uint
            context.read_slice(value_size)
          end
        end
      else
        raise UnsupportedFormatError.new("Compact MRK3 nested Dynamic arm is composite or outside the admitted scalar leaf grammar")
      end
      nil
    end

    private def nested_dynamic_callback_count(arms : Array(BinaryDataType)) : UInt64
      # Dynamic contributes Structure, VariantDiscriminatorsPrefix, and
      # VariantDiscriminators callbacks, plus one callback per arm. String-v1
      # adds a StringSizes callback for every String arm, even if that arm has
      # zero values in this chunk.
      count = checked_add(3_u64, arms.size.to_u64, "nested callback count")
      if @nested_data_string_profile.with_size_stream?
        arms.each do |arm|
          if arm.tag == BinaryDataType::TAG_STRING
            count = checked_add(count, 1_u64, "nested String size callback count")
          end
        end
      end
      count
    end

    private def scan_s1_strings!(count : UInt64, context : BinaryCodecContext) : Nil
      # SerializationString S1 writes the per-row UInt64 byte-size lane first,
      # then concatenated raw characters. ColumnString stores the bytes without
      # NUL terminators; values remain opaque to this framing pass.
      size_lane_bytes = checked_multiply(count, 8_u64, "String-v1 size lane extent")
      context.ensure_remaining_input_bytes(size_lane_bytes)
      @budget.charge_elements(count)

      raw_bytes = 0_u64
      count.times do
        size = read_u64_le(context)
        raw_bytes = checked_add(raw_bytes, size, "String-v1 raw character extent")
      end
      context.ensure_remaining_input_bytes(raw_bytes)
      context.read_slice(raw_bytes)
      nil
    end

    private def count_tag!(counts : Array(UInt64), tag : UInt8, occurrences : UInt64 = 1_u64) : Nil
      return if tag == DynamicDiscriminatorCodec::NULL_TAG
      arm_index = tag.to_i
      unless arm_index < counts.size
        raise CorruptPartError.new("Compact MRK3 Dynamic discriminator tag is outside its canonical arm roster")
      end
      count = counts[arm_index]
      if occurrences > UInt64::MAX - count
        raise CorruptPartError.new("Compact MRK3 Dynamic arm occurrence count overflows")
      end
      counts[arm_index] = count + occurrences
      nil
    end

    private def parse_substreams!(bucket_index : Int32, context : BinaryCodecContext) : Nil
      chunks = require_chunks!(bucket_index, "Substreams")
      chunks.each do |chunk|
        unless chunk.child_callback_counts.size == chunk.paths.size
          raise CorruptPartError.new("Compact MRK3 Substreams precede nested Dynamic callback census")
        end
        chunk.paths.size.times do |path_index|
          expected = chunk.child_callback_counts[path_index]
          count = context.read_var_uint
          unless count == expected
            raise CorruptPartError.new("Compact MRK3 Substreams count differs from the nested Dynamic callback census")
          end
          checked_count = context.preflight_metadata(
            count,
            1_u64,
            expected,
            "Object shared path substream count",
          )
          context.visit_metadata_nodes(checked_count.to_u64, 1)
          checked_count.times do
            name_size = context.read_var_uint
            context.read_slice(name_size)
          end
        end
      end
      nil
    end

    private def parse_copy_lane!(role : String, context : BinaryCodecContext) : Nil
      case role
      when "sizes"
        parse_copy_sizes!(context)
      when "indexes"
        parse_copy_indexes!(context)
      when "values"
        parse_copy_values!(context)
      else
        raise UnsupportedFormatError.new("Compact MRK3 Advanced Copy role is outside the admitted lane grammar")
      end
      nil
    end

    private def parse_copy_sizes!(context : BinaryCodecContext) : Nil
      unless @bucket_role_masks.all? { |mask| mask == (1_u8 << ObjectSharedPhysicalBucketRawLayout::LANE_NAMES.size) - 1_u8 }
        raise CorruptPartError.new("Compact MRK3 Copy Sizes precede complete bucket roles")
      end
      chunks = require_chunks!(0, "Copy Sizes")
      total_bytes = checked_multiply(@row_count, 8_u64, "Copy Sizes extent")
      context.ensure_remaining_input_bytes(total_bytes)
      @budget.charge_elements(@row_count)

      total_entries = 0_u64
      chunks.each do |chunk|
        chunk.copy_entry_count = 0_u64
        chunk.row_count.times do
          row_entries = read_u64_le(context)
          if row_entries > Int32::MAX.to_u64 || row_entries > Int32::MAX.to_u64 - total_entries
            raise CorruptPartError.new("Compact MRK3 Copy row or total entry count exceeds Int32")
          end
          total_entries += row_entries
          chunk.copy_entry_count = checked_add(chunk.copy_entry_count, row_entries, "chunk Copy entries")
        end
      end
      @budget.charge_elements(total_entries)
      @copy_entries_total = total_entries
      nil
    end

    private def parse_copy_indexes!(context : BinaryCodecContext) : Nil
      chunks = require_chunks!(0, "Copy Indexes")
      total_bytes = 0_u64
      chunks.each_with_index do |chunk, chunk_index|
        paths = checked_add(
          @chunks[0][chunk_index].paths.size.to_u64,
          @chunks[1][chunk_index].paths.size.to_u64,
          "chunk Copy dictionary paths",
        )
        if chunk.copy_entry_count > 0_u64 && paths == 0_u64
          raise CorruptPartError.new("Compact MRK3 Copy entries reference an empty chunk dictionary")
        end
        width = copy_index_width(paths)
        extent = checked_multiply(chunk.copy_entry_count, width.to_u64, "Copy index extent")
        total_bytes = checked_add(total_bytes, extent, "Copy indexes lane extent")
      end
      consume_fixed!(context, total_bytes)
      nil
    end

    private def parse_copy_values!(context : BinaryCodecContext) : Nil
      chunks = require_chunks!(0, "Copy Values")
      unless @copy_entries_total <= context.remaining_input_bytes
        raise CorruptPartError.new("Compact MRK3 Copy Values cannot contain the declared entries")
      end
      @budget.charge_elements(@copy_entries_total)
      chunks.each do |chunk|
        chunk.copy_entry_count.times do
          envelope_size = context.read_var_uint
          context.read_slice(envelope_size)
        end
      end
      nil
    end

    private def validate_matching_chunk_rows! : Nil
      left = @chunks[0]
      right = @chunks[1]
      unless left.size == right.size
        raise CorruptPartError.new("Compact MRK3 bucket chunk counts disagree")
      end
      left.each_with_index do |chunk, index|
        unless chunk.row_count == right[index].row_count
          raise CorruptPartError.new("Compact MRK3 bucket chunk row boundaries disagree")
        end
      end
      nil
    end

    private def validate_complete_bucket_grids! : Nil
      validate_matching_chunk_rows!
      @chunks.each_with_index do |chunks, bucket_index|
        unless chunks.size > 0
          raise CorruptPartError.new("Compact MRK3 Advanced bucket has no chunk headers")
        end
        rows = 0_u64
        chunks.each do |chunk|
          rows = checked_add(rows, chunk.row_count, "bucket chunk row total")
          unless chunk.child_callback_counts.size == chunk.paths.size
            raise CorruptPartError.new("Compact MRK3 bucket Data callback census is incomplete")
          end
        end
        unless rows == @row_count
          raise CorruptPartError.new("Compact MRK3 bucket chunks do not cover the root mark")
        end
        if @shared_data_version == 2_u64 && chunks.size != 1
          raise CorruptPartError.new("Compact MRK3 ADVANCED v2 bucket has more than one chunk")
        end
        if bucket_index == 1 && chunks.size != @chunks[0].size
          raise CorruptPartError.new("Compact MRK3 bucket chunk grids differ")
        end
      end
      nil
    end

    private def require_chunks!(bucket_index : Int32, role : String) : Array(Chunk)
      chunks = @chunks[bucket_index]?
      unless chunks && !chunks.empty?
        raise CorruptPartError.new("Compact MRK3 #{role} role precedes its StructurePrefix lane")
      end
      chunks
    end

    private def path_count(chunks : Array(Chunk)) : UInt64
      total = 0_u64
      chunks.each do |chunk|
        total = checked_add(total, chunk.paths.size.to_u64, "bucket path count")
      end
      total
    end

    private def callback_count(chunks : Array(Chunk)) : UInt64
      total = 0_u64
      chunks.each do |chunk|
        unless chunk.child_callback_counts.size == chunk.paths.size
          raise CorruptPartError.new("Compact MRK3 metadata lane precedes nested callback census")
        end
        chunk.child_callback_counts.each do |count|
          total = checked_add(total, count, "substream callback count")
        end
      end
      total
    end

    private def copy_index_width(path_count : UInt64) : Int32
      if path_count <= 256_u64
        1
      elsif path_count <= 65_536_u64
        2
      else
        4
      end
    end

    private def consume_fixed!(context : BinaryCodecContext, extent : UInt64) : Nil
      context.read_slice(extent)
      nil
    end

    private def read_u64_le(context : BinaryCodecContext) : UInt64
      value = 0_u64
      8.times do |index|
        value |= context.read_byte.to_u64 << (index * 8)
      end
      value
    end

    private def compare_path_bytes(left : Bytes, right : Bytes) : Int32
      common_size = Math.min(left.size, right.size)
      common_size.times do |index|
        return -1 if left[index] < right[index]
        return 1 if left[index] > right[index]
      end
      left.size <=> right.size
    end

    private def same_limits?(left : BinaryCodecLimits, right : BinaryCodecLimits) : Bool
      left.max_depth == right.max_depth && left.max_nodes == right.max_nodes &&
        left.max_elements == right.max_elements && left.max_bytes == right.max_bytes
    end

    private def checked_add(left : UInt64, right : UInt64, label : String) : UInt64
      if right > UInt64::MAX - left
        raise CorruptPartError.new("Compact MRK3 #{label} overflows UInt64")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64, label : String) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise CorruptPartError.new("Compact MRK3 #{label} overflows UInt64")
      end
      left * right
    end
  end
end

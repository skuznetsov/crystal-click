module CrystalClick
  # Paired logical-value codec for the admitted Dynamic V3 discriminator and
  # decompressed bulk-arm profile. Physical compression and outer mark parsing
  # remain the responsibility of the storage adapter.
  class DynamicValueCodec
    DEFAULT_LIMITS = BinaryCodecLimits.new(
      max_depth: 64,
      max_nodes: 1_000_000,
      max_elements: 3_000_000,
      max_bytes: 64 * 1024 * 1024
    )

    NULL_TAG = DynamicDiscriminatorCodec::NULL_TAG

    def self.encode(
      structure : DynamicStructure,
      granules : Array(Array(BinaryValue)),
      mode : UInt64 = DynamicDiscriminatorCodec::DEFAULT_MODE,
      limits : BinaryCodecLimits = DEFAULT_LIMITS,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
    ) : DynamicValueStreams
      budget = BinaryCodecBudget.new(limits, true)
      encode_with_budget(structure, granules, budget, mode: mode, profile: profile)
    end

    # Convention-internal entry point for a parent operation that owns the
    # aggregate budget. The same budget flows through discriminator, all arm
    # codecs, and every typed SharedVariant envelope.
    def self.encode_with_budget(
      structure : DynamicStructure,
      granules : Array(Array(BinaryValue)),
      budget : BinaryCodecBudget,
      mode : UInt64 = DynamicDiscriminatorCodec::DEFAULT_MODE,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
    ) : DynamicValueStreams
      unless budget.writing?
        raise ArgumentError.new("Dynamic value encode requires a writing budget")
      end
      unless mode == DynamicDiscriminatorCodec::BASIC_MODE || mode == DynamicDiscriminatorCodec::COMPACT_MODE
        raise ArgumentError.new("unsupported Dynamic discriminator write mode")
      end

      real_marks = checked_mark_count(granules.size, budget)
      variant_count = structure.canonical_variant_count.to_u64
      mark_records = real_marks + 1_u64
      budget.ensure_depth(1)
      validate_descriptor_trees(structure, budget)
      total_rows = 0_u64
      granules.each do |granule|
        if granule.empty?
          raise ArgumentError.new("Dynamic value real granules must contain rows")
        end
        if granule.size > Int32::MAX
          raise UnsupportedFormatError.new("Dynamic mark row count exceeds the supported domain")
        end
        rows = granule.size.to_u64
        if total_rows > UInt64::MAX - rows
          raise UnsupportedFormatError.new("Dynamic value row count overflows UInt64")
        end
        total_rows += rows
      end

      # Validate value and roster descriptors before name-based routing. The
      # encoder's historical budget contract charges descriptor traversal but
      # not SQL display-name materialization.
      validate_value_descriptor_trees(granules, budget)

      # The discriminator will charge these same logical records and edges.
      # This early lower bound protects the tag matrix from being the first
      # count-derived allocation that discovers an impossible operation.
      preflight_discriminator_work(budget, mark_records, real_marks, total_rows, variant_count)

      variant_names = structure.canonical_variant_names
      routes = Hash(String, Tuple(BinaryDataType, UInt8)).new
      structure.type_count.times do |index|
        type = structure.type_at(index)
        name = type.name
        canonical_index = variant_names.index(name) || raise UnsupportedFormatError.new("Dynamic type is absent from its canonical roster")
        routes[name] = {type, canonical_index.to_u8}
      end
      shared_index = structure.shared_index
      ordinary_types = Array(BinaryDataType?).new(variant_names.size, nil)
      routes.each_value do |route|
        type, canonical_index = route
        ordinary_types[canonical_index] = type
      end

      tags = Array(Array(UInt8)).new(granules.size)
      granules.each do |granule|
        mark_tags = Array(UInt8).new(granule.size)
        granule.each do |value|
          type = value.type
          if type.tag == BinaryDataType::TAG_NOTHING
            unless value.is_null?
              raise UnsupportedFormatError.new("top-level Nothing is admitted only as Dynamic NULL")
            end
            mark_tags << NULL_TAG
          elsif type.tag == BinaryDataType::TAG_NULLABLE
            raise UnsupportedFormatError.new("top-level Nullable is outside the Dynamic V3 canonical profile")
          else
            name = type.name
            mark_tags << route_index(type, name, routes, shared_index.to_u8)
          end
        end
        tags << mark_tags
      end

      discriminator = DynamicDiscriminatorCodec.encode_with_budget(structure, tags, budget, mode: mode)
      arms = Hash(String, BinaryBulkStreams).new

      # SharedVariant is emitted first so its aggregate envelope framing can
      # be preflighted before retaining any encoded String copies. Other arms
      # are independent lanes, emitted in canonical order below.
      shared_name = DynamicStructure::SHARED_VARIANT_NAME
      shared_streams = encode_arm(
        granules,
        tags,
        shared_index,
        ordinary_types[shared_index],
        shared_name,
        budget,
        profile
      )
      arms[shared_name] = shared_streams

      variant_names.each_with_index do |name, arm_index|
        next if arm_index == shared_index
        type = ordinary_types[arm_index] || raise UnsupportedFormatError.new("Dynamic canonical arm has no descriptor")
        arm_streams = encode_arm(
          granules,
          tags,
          arm_index,
          type,
          name,
          budget,
          profile
        )
        arms[name] = arm_streams
      end

      DynamicValueStreams.new(discriminator, arms)
    end

    def self.decode(
      structure : DynamicStructure,
      streams : DynamicValueStreams,
      first_mark : Int = 0,
      mark_count : Int? = nil,
      limits : BinaryCodecLimits = DEFAULT_LIMITS,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
    ) : Array(Array(BinaryValue))
      budget = BinaryCodecBudget.new(limits)
      decode_with_budget(structure, streams, budget, first_mark: first_mark, mark_count: mark_count, profile: profile)
    end

    # Convention-internal entry point for a parent operation that owns the
    # aggregate budget. All selected arm values and envelopes are validated
    # before any logical rows are returned.
    def self.decode_with_budget(
      structure : DynamicStructure,
      streams : DynamicValueStreams,
      budget : BinaryCodecBudget,
      first_mark : Int = 0,
      mark_count : Int? = nil,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
    ) : Array(Array(BinaryValue))
      if budget.writing?
        raise ArgumentError.new("Dynamic value decode requires a reading budget")
      end

      variant_count = structure.canonical_variant_count
      validate_descriptor_trees(structure, budget)
      if streams.arm_count != variant_count
        corrupt!("Dynamic arm set does not match the canonical roster")
      end
      budget.ensure_future_nodes(variant_count.to_u64)
      budget.ensure_future_elements(variant_count.to_u64)
      variant_names = structure.canonical_variant_names
      variant_names.each do |name|
        unless streams.has_arm?(name)
          corrupt!("Dynamic arm set is missing a canonical lane")
        end
      end

      schedules = DynamicDiscriminatorCodec.decode_with_budget(
        structure,
        streams.discriminators,
        budget,
        first_mark: first_mark,
        mark_count: mark_count
      )
      mark_records = streams.discriminators.mark_count
      if mark_records == 0
        # Normally diagnosed by W121, kept explicit before subtracting one so
        # this owner never relies on an underflowing grid-derived count.
        corrupt!("Dynamic discriminator mark grid has no terminal mark")
      end
      real_marks = mark_records - 1
      selected_marks = schedules.size
      shared_index = structure.shared_index

      # Decoding the selected children needs one full K-count vector at a
      # time because BinaryBulkCodec receives parent occurrence counts for
      # the complete physical grid. Only selected W121 schedules provide
      # nonzero counts; zeroes outside selection are deliberately not claims
      # about unselected child bodies.
      budget.ensure_future_nodes(variant_count.to_u64)
      budget.ensure_future_elements(variant_count.to_u64)
      decoded_arms = Array(Array(Array(BinaryValue))).new(variant_count)
      shared_string = BinaryDataType.primitive("String")
      variant_names.each_with_index do |name, arm_index|
        type = if arm_index == shared_index
                 shared_string
               else
                 type_for_name(structure, name) || corrupt_type!("Dynamic canonical arm has no descriptor")
               end
        budget.ensure_future_nodes(real_marks.to_u64)
        budget.ensure_future_elements(real_marks.to_u64)
        rows_per_mark = Array(UInt64).new(real_marks, 0_u64)
        schedules.each do |schedule|
          if schedule.mark_index < 0 || schedule.mark_index >= real_marks
            corrupt!("Dynamic selected schedule is outside the physical mark grid")
          end
          if schedule.variant_count != variant_count
            corrupt!("Dynamic selected schedule arm-count width is inconsistent")
          end
          rows_per_mark[schedule.mark_index] = schedule.arm_count_at(arm_index)
        end
        arm_rows = BinaryBulkCodec.decode_with_budget(
          type,
          streams.arm(name),
          rows_per_mark,
          budget,
          first_mark: first_mark,
          mark_count: mark_count,
          profile: profile
        )
        if arm_rows.size != selected_marks
          corrupt!("Dynamic bulk arm selection disagrees with discriminator schedules")
        end
        decoded_arms << arm_rows
      end

      shared_rows = decoded_arms[shared_index]
      budget.ensure_future_nodes(selected_marks.to_u64)
      budget.ensure_future_elements(selected_marks.to_u64)
      logical_shared_rows = Array(Array(BinaryValue)).new(selected_marks)
      selected_marks.times do |mark_index|
        envelope_values = shared_rows[mark_index]
        budget.ensure_future_nodes(envelope_values.size.to_u64)
        budget.ensure_future_elements(envelope_values.size.to_u64)
        logical_values = Array(BinaryValue).new(envelope_values.size)
        envelope_values.each do |envelope|
          unless envelope.type.tag == BinaryDataType::TAG_STRING
            corrupt!("SharedVariant bulk lane did not decode as String")
          end
          logical = BinaryValueCodec.decode_borrowed(envelope.bytes, budget)
          if logical.type.tag == BinaryDataType::TAG_NOTHING || logical.type.tag == BinaryDataType::TAG_NULLABLE
            corrupt!("top-level Nothing and Nullable SharedVariant envelopes are outside the canonical profile")
          end
          logical_values << logical
        end
        logical_shared_rows << logical_values
      end
      decoded_arms[shared_index] = logical_shared_rows

      total_rows = 0_u64
      schedules.each do |schedule|
        rows = streams.discriminators.mark_at(schedule.mark_index).rows
        if total_rows > UInt64::MAX - rows
          corrupt!("Dynamic selected row count overflows UInt64")
        end
        total_rows += rows
      end
      if total_rows > UInt64::MAX - selected_marks.to_u64 - 1_u64
        corrupt!("Dynamic selected assembly node count overflows UInt64")
      end
      budget.ensure_future_nodes(1_u64 + selected_marks.to_u64 + total_rows)
      budget.ensure_future_elements(selected_marks.to_u64 + total_rows)
      budget.visit_node(1)

      result = Array(Array(BinaryValue)).new(selected_marks)
      schedules.each_with_index do |schedule, selected_index|
        row_count = schedule.row_count
        if schedule.rank_count != row_count
          corrupt!("Dynamic selected rank vector does not match its tags")
        end
        if schedule.variant_count != variant_count
          corrupt!("Dynamic selected schedule variant width is inconsistent")
        end
        budget.charge_node
        budget.charge_elements(1_u64)
        mark_values = Array(BinaryValue).new(row_count)
        row_count.times do |row_index|
          budget.charge_node
          tag = schedule.tag_at(row_index)
          if tag == NULL_TAG
            mark_values << BinaryValue.null
            next
          end
          arm_index = tag.to_i32
          if arm_index < 0 || arm_index >= variant_count
            corrupt!("Dynamic row tag is outside the canonical roster")
          end
          rank = schedule.rank_at(row_index) || corrupt_rank!("non-NULL Dynamic row has no arm rank")
          lane = decoded_arms[arm_index][selected_index]
          if rank < 0 || rank >= lane.size
            corrupt!("Dynamic row rank is outside its selected arm mark")
          end
          mark_values << lane[rank]
        end
        budget.charge_elements(row_count.to_u64)
        result << mark_values
      end
      result
    end

    private def self.encode_arm(
      granules : Array(Array(BinaryValue)),
      tags : Array(Array(UInt8)),
      arm_index : Int32,
      type : BinaryDataType?,
      name : String,
      budget : BinaryCodecBudget,
      profile : BinaryBulkProfile,
    ) : BinaryBulkStreams
      arm_type = type || BinaryDataType.primitive("String")
      mark_count = granules.size
      arm_rows = 0_u64
      shared = name == DynamicStructure::SHARED_VARIANT_NAME
      granules.each_with_index do |granule, mark_index|
        granule.each_with_index do |_value, row_index|
          arm_rows += 1_u64 if tags[mark_index][row_index] == arm_index.to_u8
        end
      end
      budget.ensure_future_nodes(mark_count.to_u64 + arm_rows)
      budget.ensure_future_elements(mark_count.to_u64 + arm_rows)

      lane_granules = Array(Array(BinaryValue)).new(mark_count) do
        [] of BinaryValue
      end
      pending_frame_bytes = 0_u64
      granules.each_with_index do |granule, mark_index|
        granule.each_with_index do |value, row_index|
          next unless tags[mark_index][row_index] == arm_index.to_u8
          if shared
            if value.type.tag == BinaryDataType::TAG_NOTHING
              # Dynamic Nothing NULL is tag 255 and never has a child lane.
              corrupt!("Dynamic NULL tag was incorrectly assigned to SharedVariant")
            end
            if value.type.tag == BinaryDataType::TAG_NULLABLE
              raise UnsupportedFormatError.new("top-level Nullable cannot be emitted as SharedVariant")
            end
            minimum_frame_overhead = profile.with_size_stream? ? 8_u64 : 1_u64
            if pending_frame_bytes > UInt64::MAX - minimum_frame_overhead
              raise UnsupportedFormatError.new("Dynamic SharedVariant reservation overflows UInt64")
            end
            reserved_wire_bytes = pending_frame_bytes + minimum_frame_overhead
            envelope = BinaryValueCodec.encode_borrowed(
              value,
              budget,
              reserved_wire_bytes: reserved_wire_bytes,
            )
            frame_size = if profile.with_size_stream?
                           8_u64 + envelope.size.to_u64
                         else
                           var_uint_size(envelope.size.to_u64) + envelope.size.to_u64
                         end
            if pending_frame_bytes > UInt64::MAX - frame_size
              raise UnsupportedFormatError.new("Dynamic SharedVariant framed byte count overflows UInt64")
            end
            pending_frame_bytes += frame_size
            budget.ensure_wire_bytes(pending_frame_bytes)
            lane_granules[mark_index] << BinaryValue.string(String.new(envelope))
          else
            lane_granules[mark_index] << value
          end
        end
      end

      BinaryBulkCodec.encode_with_budget(arm_type, lane_granules, budget, profile: profile)
    end

    private def self.type_for_name(structure : DynamicStructure, name : String) : BinaryDataType?
      structure.type_count.times do |index|
        type = structure.type_at(index)
        return type if type.name == name
      end
      nil
    end

    # Shared route decision used by encoding and fresh Object/Dynamic
    # statistics. The caller renders the name under its own accounting policy.
    def self.route_index(
      type : BinaryDataType,
      name : String,
      routes : Hash(String, Tuple(BinaryDataType, UInt8)),
      shared_index : UInt8,
    ) : UInt8
      if route = routes[name]?
        route[0] == type ? route[1] : shared_index
      else
        shared_index
      end
    end

    private def self.validate_descriptor_trees(structure : DynamicStructure, budget : BinaryCodecBudget) : Nil
      context = BinaryCodecContext.new(budget.limits, nil, budget.writing?, budget, false, false)
      structure.type_count.times do |index|
        context.validate_type_tree(structure.type_at(index))
      end
      nil
    end

    private def self.validate_value_descriptor_trees(
      granules : Array(Array(BinaryValue)),
      budget : BinaryCodecBudget,
    ) : Nil
      context = BinaryCodecContext.new(budget.limits, nil, budget.writing?, budget, false, false)
      granules.each do |granule|
        granule.each do |value|
          context.validate_type_tree(value.type)
        end
      end
      nil
    end

    private def self.preflight_discriminator_work(
      budget : BinaryCodecBudget,
      mark_records : UInt64,
      real_marks : UInt64,
      rows : UInt64,
      variants : UInt64,
    ) : Nil
      if mark_records > UInt64::MAX - rows - 1_u64
        raise UnsupportedFormatError.new("Dynamic discriminator node count overflows UInt64")
      end
      budget.ensure_future_nodes(1_u64 + mark_records + rows)

      if real_marks > (UInt64::MAX - 1_u64) // 2_u64
        raise UnsupportedFormatError.new("Dynamic discriminator mark metadata overflows UInt64")
      end
      metadata_marks = (2_u64 * real_marks) + 1_u64
      if variants > 0_u64 && metadata_marks > (UInt64::MAX - mark_records) // variants
        raise UnsupportedFormatError.new("Dynamic discriminator roster edge count overflows UInt64")
      end
      if rows > (UInt64::MAX - mark_records - metadata_marks * variants) // 2_u64
        raise UnsupportedFormatError.new("Dynamic discriminator row edge count overflows UInt64")
      end
      budget.ensure_future_elements(mark_records + (2_u64 * rows) + (metadata_marks * variants))
    end

    private def self.checked_mark_count(count : Int, budget : BinaryCodecBudget) : UInt64
      if count < 0 || count >= Int32::MAX
        raise UnsupportedFormatError.new("Dynamic mark count exceeds the supported domain")
      end
      budget.ensure_future_nodes(count.to_u64 + 2_u64)
      count.to_u64
    end

    private def self.var_uint_size(value : UInt64) : UInt64
      size = 1_u64
      remaining = value
      while remaining >= 0x80_u64
        remaining >>= 7
        size += 1_u64
      end
      size
    end

    private def self.corrupt!(message : String) : NoReturn
      raise CorruptPartError.new(message)
    end

    private def self.corrupt_type!(message : String) : NoReturn
      raise CorruptPartError.new(message)
    end

    private def self.corrupt_rank!(message : String) : NoReturn
      raise CorruptPartError.new(message)
    end
  end
end

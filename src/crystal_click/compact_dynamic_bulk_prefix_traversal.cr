module CrystalClick
  # Reads Compact prefix callbacks in serializer traversal order. Its first
  # pass discovers actual Dynamic arm trees online; later passes bind every
  # repeated structure prefix to that one prepared part-wide roster.
  class CompactDynamicBulkPrefixTraversal
    alias PhysicalPlan = BinaryDynamicBulkPhysicalPlan
    alias PrefixResult = Tuple(Hash(String, DynamicStructure), Hash(String, UInt64))
    alias WorkspacePreflight = Proc(Hash(String, DynamicStructure), String, DynamicStructure, Nil)

    @type : BinaryDataType
    @limits : BinaryCodecLimits
    @profile : BinaryBulkProfile

    def self.validate_compact_type_admission!(
      type : BinaryDataType,
      limits : BinaryCodecLimits,
      depth : Int32 = 1,
    ) : Nil
      if depth <= 0 || depth > limits.max_depth
        raise UnsupportedFormatError.new("Compact Dynamic descriptor depth exceeds configured limit")
      end
      case type.tag
      when BinaryDataType::TAG_JSON
        raise UnsupportedFormatError.new("JSON in Compact Dynamic is outside the admitted recursive callback profile")
      when BinaryDataType::TAG_AGGREGATE_FUNCTION
        raise UnsupportedFormatError.new("AggregateFunction in Compact Dynamic is outside the admitted recursive callback profile")
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        raise UnsupportedFormatError.new("SimpleAggregateFunction in Compact Dynamic is outside the admitted recursive callback profile")
      when BinaryDataType::TAG_QBIT
        raise UnsupportedFormatError.new("QBit in Compact Dynamic is outside the admitted recursive callback profile")
      when BinaryDataType::TAG_CUSTOM
        raise UnsupportedFormatError.new("custom Geo in Compact Dynamic is outside the admitted recursive callback profile")
      else
        type.child_count.times do |index|
          validate_compact_type_admission!(type.child_at(index), limits, depth + 1)
        end
      end
      nil
    end

    def initialize(
      @type : BinaryDataType,
      @profile : BinaryBulkProfile,
      @limits : BinaryCodecLimits,
    )
      unless @type.contains_dynamic?
        raise ArgumentError.new("Compact Dynamic prefix traversal requires a Dynamic-bearing descriptor")
      end
      self.class.validate_compact_type_admission!(@type, @limits)
    end

    # The caller charges the complete physical granule before invoking this
    # method. Structure parsing then borrows the remaining tape and advances by
    # the observed parser offset, so mrk3's later values are never charged as a
    # second prefix input.
    def discover(
      cursor : CompactBinaryBulkGranuleCursor,
      budget : BinaryCodecBudget,
      workspace_preflight : WorkspacePreflight? = nil,
    ) : PrefixResult
      structures = Hash(String, DynamicStructure).new
      modes = Hash(String, UInt64).new
      walk_discovery(@type, "root", 1, cursor, budget, structures, modes, workspace_preflight)
      {structures, modes}
    end

    # Replays one later granule against the immutable prepared roster. Each
    # site is compared before recursion into its arms, preventing changed
    # parent metadata from redirecting the traversal to another descriptor
    # subtree. Statistics may differ because same_roster? intentionally omits
    # them.
    def replay(
      cursor : CompactBinaryBulkGranuleCursor,
      budget : BinaryCodecBudget,
      prepared : CompactDynamicBulkPreparedContext,
    ) : Hash(String, UInt64)
      structures = Hash(String, DynamicStructure).new
      modes = Hash(String, UInt64).new
      walk_prepared(@type, "root", 1, cursor, budget, prepared, structures, modes)
      prepared.validate_granule_roster!(structures)
      modes
    end

    # Compact mrk4 exposes prefix and body callbacks as an ordered roster.
    # Compose it from the same actual-arm traversal that reads prefixes.
    def expected_callback_roster(prepared : CompactDynamicBulkPreparedContext) : Array(String)
      expected_callback_roster(prepared.physical, prepared.plan)
    end

    # Context-neutral writer/reader seam over the shared physical callback
    # grammar. The prepared-context overload above remains the read owner's
    # public entry point; writers already own a write-direction plan and must
    # not manufacture a read context or duplicate recursive traversal.
    def expected_callback_roster(
      physical : BinaryDynamicBulkPhysicalPlan,
      plan : BinaryDynamicBulkPlan,
    ) : Array(String)
      unless @type == plan.type && @profile == plan.profile && physical.same_prepared_plan?(plan)
        raise ArgumentError.new("Compact Dynamic callback traversal differs from its prepared physical plan")
      end
      expected = [] of String
      append_prefix_roster(@type, "root", physical, plan, expected)
      append_body_roster(@type, "root", physical, plan, expected)

      seen = Set(String).new
      expected.each do |name|
        unless seen.add?(name)
          raise CorruptPartError.new("Compact serializer maps multiple callbacks to one physical stream")
        end
      end
      expected
    end

    private def walk_discovery(
      type : BinaryDataType,
      role : String,
      depth : Int32,
      cursor : CompactBinaryBulkGranuleCursor,
      budget : BinaryCodecBudget,
      structures : Hash(String, DynamicStructure),
      modes : Hash(String, UInt64),
      workspace_preflight : WorkspacePreflight?,
    ) : Nil
      budget.ensure_depth(depth)
      case type.tag
      when BinaryDataType::TAG_DYNAMIC
        structure = read_structure(cursor, budget, depth, nil, role)
        if preflight = workspace_preflight
          preflight.call(structures, role, structure)
        end
        if structures.has_key?(role)
          raise CorruptPartError.new("Compact Dynamic structure site path is duplicated")
        end
        structure.type_count.times do |index|
          self.class.validate_compact_type_admission!(structure.type_at(index), @limits, depth + 1)
        end
        structures[role] = structure
        read_variant_mode(cursor, nil, "#{role}.discriminators", modes)
        arms = BinaryDynamicBulkPlan.canonical_arm_types_for_compact_prefix(
          structure, budget, depth + 1
        )
        arms.each_with_index do |arm, index|
          walk_discovery(
            arm, "#{role}.arm.#{index}", depth + 1, cursor, budget,
            structures, modes, workspace_preflight,
          )
        end
      when BinaryDataType::TAG_CUSTOM, BinaryDataType::TAG_SIMPLE_AGGREGATE
        walk_discovery(type.child_at(0), role, depth + 1, cursor, budget, structures, modes, workspace_preflight)
      when BinaryDataType::TAG_LOW_CARDINALITY
        version = read_u64_event(cursor, nil)
        unless version == BinaryLowCardinalityStorageStreams::VERSION
          raise UnsupportedFormatError.new("unsupported Compact LowCardinality state-prefix version")
        end
      when BinaryDataType::TAG_VARIANT
        read_variant_mode(cursor, nil, "#{role}.discriminators", modes)
        type.child_count.times do |index|
          walk_discovery(type.child_at(index), "#{role}.arm.#{index}", depth + 1, cursor, budget, structures, modes, workspace_preflight)
        end
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        walk_discovery(type.child_at(0), "#{role}.elements", depth + 1, cursor, budget, structures, modes, workspace_preflight)
      when BinaryDataType::TAG_NULLABLE
        walk_discovery(type.child_at(0), "#{role}.nested", depth + 1, cursor, budget, structures, modes, workspace_preflight)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times do |index|
          walk_discovery(type.child_at(index), "#{role}.field.#{index}", depth + 1, cursor, budget, structures, modes, workspace_preflight)
        end
      when BinaryDataType::TAG_MAP
        walk_discovery(type.child_at(0), "#{role}.elements.field.0", depth + 1, cursor, budget, structures, modes, workspace_preflight)
        walk_discovery(type.child_at(1), "#{role}.elements.field.1", depth + 1, cursor, budget, structures, modes, workspace_preflight)
      end
      nil
    end

    private def walk_prepared(
      type : BinaryDataType,
      role : String,
      depth : Int32,
      cursor : CompactBinaryBulkGranuleCursor,
      budget : BinaryCodecBudget,
      prepared : CompactDynamicBulkPreparedContext,
      structures : Hash(String, DynamicStructure),
      modes : Hash(String, UInt64),
    ) : Nil
      budget.ensure_depth(depth)
      physical = prepared.physical
      plan = prepared.plan
      case type.tag
      when BinaryDataType::TAG_DYNAMIC
        structure = read_structure(cursor, budget, depth, physical.structure_name_for(role), role)
        prepared.validate_site_roster!(role, structure)
        structures[role] = structure
        read_variant_mode(cursor, physical, "#{role}.discriminators", modes)
        plan.arm_count(role).times do |index|
          walk_prepared(
            plan.arm_type(role, index), "#{role}.arm.#{index}", depth + 1,
            cursor, budget, prepared, structures, modes
          )
        end
      when BinaryDataType::TAG_CUSTOM, BinaryDataType::TAG_SIMPLE_AGGREGATE
        walk_prepared(type.child_at(0), role, depth + 1, cursor, budget, prepared, structures, modes)
      when BinaryDataType::TAG_LOW_CARDINALITY
        role_name = "#{role}.dictionary"
        version = read_u64_event(cursor, prefix_name(role_name, physical))
        unless version == BinaryLowCardinalityStorageStreams::VERSION
          raise UnsupportedFormatError.new("unsupported Compact LowCardinality state-prefix version")
        end
      when BinaryDataType::TAG_VARIANT
        read_variant_mode(cursor, physical, "#{role}.discriminators", modes)
        type.child_count.times do |index|
          walk_prepared(type.child_at(index), "#{role}.arm.#{index}", depth + 1, cursor, budget, prepared, structures, modes)
        end
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        walk_prepared(type.child_at(0), "#{role}.elements", depth + 1, cursor, budget, prepared, structures, modes)
      when BinaryDataType::TAG_NULLABLE
        walk_prepared(type.child_at(0), "#{role}.nested", depth + 1, cursor, budget, prepared, structures, modes)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times do |index|
          walk_prepared(type.child_at(index), "#{role}.field.#{index}", depth + 1, cursor, budget, prepared, structures, modes)
        end
      when BinaryDataType::TAG_MAP
        walk_prepared(type.child_at(0), "#{role}.elements.field.0", depth + 1, cursor, budget, prepared, structures, modes)
        walk_prepared(type.child_at(1), "#{role}.elements.field.1", depth + 1, cursor, budget, prepared, structures, modes)
      end
      nil
    end

    private def read_structure(
      cursor : CompactBinaryBulkGranuleCursor,
      budget : BinaryCodecBudget,
      depth : Int32,
      expected_name : String?,
      role : String,
    ) : DynamicStructure
      if name = expected_name
        cursor.begin_event(name)
      else
        cursor.begin_next_discovery_event
      end
      bytes = cursor.remaining_slice
      context = BinaryCodecContext.new(budget.limits, bytes, false, budget, false, false)
      structure, _statistics_offset = DynamicStructureCodec.read_with_statistics_offset(
        context, depth, checked_depth(depth), true
      )
      cursor.advance_borrowed_prefix(context.input_offset)
      cursor.finish_event
      structure
    rescue ex : KeyError
      raise CorruptPartError.new("Compact Dynamic structure role is outside the selected physical plan: #{role}")
    end

    private def checked_depth(depth : Int32) : Int32
      if depth == Int32::MAX
        raise CorruptPartError.new("Compact Dynamic structure depth overflows Int32")
      end
      depth + 1
    end

    private def read_variant_mode(
      cursor : CompactBinaryBulkGranuleCursor,
      physical : PhysicalPlan?,
      role : String,
      modes : Hash(String, UInt64),
    ) : Nil
      name = physical.try { |plan| prefix_name(role, plan) }
      mode = read_u64_event(cursor, name)
      unless mode == DynamicDiscriminatorBodyValidator::BASIC_MODE ||
             mode == DynamicDiscriminatorBodyValidator::COMPACT_MODE
        raise UnsupportedFormatError.new("unsupported Compact Variant discriminator mode")
      end
      modes[role] = mode
      nil
    end

    private def read_u64_event(cursor : CompactBinaryBulkGranuleCursor, expected_name : String?) : UInt64
      if name = expected_name
        cursor.begin_event(name)
      else
        cursor.begin_next_discovery_event
      end
      bytes = cursor.read_exact(8)
      value = 0_u64
      8.times { |index| value |= bytes[index].to_u64 << (index * 8) }
      cursor.finish_event
      value
    end

    private def append_prefix_roster(
      type : BinaryDataType,
      role : String,
      physical : PhysicalPlan,
      plan : BinaryDynamicBulkPlan,
      expected : Array(String),
    ) : Nil
      case type.tag
      when BinaryDataType::TAG_CUSTOM, BinaryDataType::TAG_SIMPLE_AGGREGATE
        append_prefix_roster(type.child_at(0), role, physical, plan, expected)
      when BinaryDataType::TAG_DYNAMIC
        expected << physical.structure_name_for(role)
        expected << prefix_name("#{role}.discriminators", physical)
        plan.arm_count(role).times do |index|
          append_prefix_roster(plan.arm_type(role, index), "#{role}.arm.#{index}", physical, plan, expected)
        end
      when BinaryDataType::TAG_LOW_CARDINALITY
        expected << prefix_name("#{role}.dictionary", physical)
      when BinaryDataType::TAG_VARIANT
        expected << prefix_name("#{role}.discriminators", physical)
        type.child_count.times do |index|
          append_prefix_roster(type.child_at(index), "#{role}.arm.#{index}", physical, plan, expected)
        end
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        append_prefix_roster(type.child_at(0), "#{role}.elements", physical, plan, expected)
      when BinaryDataType::TAG_NULLABLE
        append_prefix_roster(type.child_at(0), "#{role}.nested", physical, plan, expected)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times do |index|
          append_prefix_roster(type.child_at(index), "#{role}.field.#{index}", physical, plan, expected)
        end
      when BinaryDataType::TAG_MAP
        append_prefix_roster(type.child_at(0), "#{role}.elements.field.0", physical, plan, expected)
        append_prefix_roster(type.child_at(1), "#{role}.elements.field.1", physical, plan, expected)
      end
      nil
    end

    private def append_body_roster(
      type : BinaryDataType,
      role : String,
      physical : PhysicalPlan,
      plan : BinaryDynamicBulkPlan,
      expected : Array(String),
    ) : Nil
      case type.tag
      when BinaryDataType::TAG_CUSTOM, BinaryDataType::TAG_SIMPLE_AGGREGATE
        append_body_roster(type.child_at(0), role, physical, plan, expected)
      when BinaryDataType::TAG_DYNAMIC
        expected << physical.stream_name_for("#{role}.discriminators")
        plan.arm_count(role).times do |index|
          append_body_roster(plan.arm_type(role, index), "#{role}.arm.#{index}", physical, plan, expected)
        end
      when BinaryDataType::TAG_STRING
        if @profile.with_size_stream?
          expected << physical.stream_name_for("#{role}.string_sizes")
        end
        expected << physical.stream_name_for("#{role}.data")
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        expected << physical.stream_name_for("#{role}.sizes")
        append_body_roster(type.child_at(0), "#{role}.elements", physical, plan, expected)
      when BinaryDataType::TAG_NULLABLE
        expected << physical.stream_name_for("#{role}.nulls")
        append_body_roster(type.child_at(0), "#{role}.nested", physical, plan, expected)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        if type.child_count == 0
          expected << physical.stream_name_for("#{role}.data")
        else
          type.child_count.times do |index|
            append_body_roster(type.child_at(index), "#{role}.field.#{index}", physical, plan, expected)
          end
        end
      when BinaryDataType::TAG_MAP
        expected << physical.stream_name_for("#{role}.sizes")
        append_body_roster(type.child_at(0), "#{role}.elements.field.0", physical, plan, expected)
        append_body_roster(type.child_at(1), "#{role}.elements.field.1", physical, plan, expected)
      when BinaryDataType::TAG_LOW_CARDINALITY
        expected << physical.stream_name_for("#{role}.dictionary")
        expected << physical.stream_name_for("#{role}.indexes")
      when BinaryDataType::TAG_VARIANT
        expected << physical.stream_name_for("#{role}.discriminators")
        type.child_count.times do |index|
          append_body_roster(type.child_at(index), "#{role}.arm.#{index}", physical, plan, expected)
        end
      else
        expected << physical.stream_name_for("#{role}.data")
      end
      nil
    end

    private def prefix_name(role : String, physical : PhysicalPlan) : String
      unless physical.prefix_size_for(role) == BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES
        raise CorruptPartError.new("Compact state-prefix role has no admitted eight-byte prefix")
      end
      PhysicalStreamName.append_literal(physical.stream_name_for(role), "_prefix")
    rescue ex : KeyError
      raise CorruptPartError.new("Compact prefix role is outside the selected Dynamic physical plan")
    end
  end
end

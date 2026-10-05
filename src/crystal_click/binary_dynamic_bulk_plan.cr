module CrystalClick
  # Occurrence-specific metadata plan for declared Dynamic descriptors and
  # every actual roster selected beneath them. This is a planning prerequisite;
  # it does not encode Dynamic value/discriminator or ordinary bulk streams.
  class BinaryDynamicBulkPlan
    getter type : BinaryDataType
    getter profile : BinaryBulkProfile

    private struct Site
      getter type : BinaryDataType
      getter structure : DynamicStructure
      getter depth : Int32
      getter arms : Array(BinaryDataType)
      getter statistics_offset : Int32

      def initialize(
        @type : BinaryDataType,
        @structure : DynamicStructure,
        @depth : Int32,
        @arms : Array(BinaryDataType),
        @statistics_offset : Int32,
      )
      end
    end

    struct ArmSelection
      getter index : UInt8
      getter shared : Bool

      def initialize(@index : UInt8, @shared : Bool)
      end
    end

    private struct Prepared
      getter type : BinaryDataType
      getter profile : BinaryBulkProfile
      getter sites : Hash(String, Site)
      getter site_paths : Array(String)
      getter data_roles : Array(String)
      getter structure_roles : Array(String)
      getter ordinary_roles : Array(String)
      getter low_cardinality_site_paths : Array(Tuple(BinaryDataType, String))
      getter ancestor_size_roles : Array(String)
      getter low_cardinality_shape_roles : Array(String)
      getter low_cardinality_schedule_grid_count : UInt64
      getter data_role_count : UInt64
      getter ordinary_role_count : UInt64

      def initialize(
        @type : BinaryDataType,
        @profile : BinaryBulkProfile,
        @sites : Hash(String, Site),
        @site_paths : Array(String),
        @data_roles : Array(String),
        @structure_roles : Array(String),
        @ordinary_roles : Array(String),
        @low_cardinality_site_paths : Array(Tuple(BinaryDataType, String)),
        @ancestor_size_roles : Array(String),
        @low_cardinality_shape_roles : Array(String),
        @low_cardinality_schedule_grid_count : UInt64,
        @data_role_count : UInt64,
        @ordinary_role_count : UInt64,
      )
      end
    end

    @sites : Hash(String, Site)
    @site_paths : Array(String)
    @data_roles : Array(String)
    @structure_roles : Array(String)
    @ordinary_roles : Array(String)
    @low_cardinality_site_paths : Array(Tuple(BinaryDataType, String))
    @ancestor_size_roles : Array(String)
    @low_cardinality_shape_roles : Array(String)
    @low_cardinality_schedule_grid_count : UInt64
    @data_role_count : UInt64
    @ordinary_role_count : UInt64

    def self.new(
      type : BinaryDataType,
      structures : Hash(String, DynamicStructure),
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      limits : BinaryCodecLimits = BinaryCodecLimits.default,
    ) : BinaryDynamicBulkPlan
      prepared = prepare_from_structures(type, structures, profile, limits)
      new(prepared)
    end

    # Paired bulk callers already own the operation budget. Unlike the
    # standalone convenience constructor, planning therefore participates in
    # the same aggregate limits as structure and data serialization.
    def self.new_with_budget(
      type : BinaryDataType,
      structures : Hash(String, DynamicStructure),
      budget : BinaryCodecBudget,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
    ) : BinaryDynamicBulkPlan
      unless budget.writing?
        raise ArgumentError.new("Dynamic structure plan requires a writing budget")
      end
      prepared = prepare_from_structures(type, structures, profile, budget.limits, budget, false)
      new(prepared)
    end

    private def initialize(prepared : Prepared)
      @type = prepared.type
      @profile = prepared.profile
      @sites = prepared.sites
      @site_paths = prepared.site_paths
      @data_roles = prepared.data_roles
      @structure_roles = prepared.structure_roles
      @ordinary_roles = prepared.ordinary_roles
      @low_cardinality_site_paths = prepared.low_cardinality_site_paths
      @ancestor_size_roles = prepared.ancestor_size_roles
      @low_cardinality_shape_roles = prepared.low_cardinality_shape_roles
      @low_cardinality_schedule_grid_count = prepared.low_cardinality_schedule_grid_count
      @data_role_count = prepared.data_role_count
      @ordinary_role_count = prepared.ordinary_role_count
    end

    def site_count : Int32
      @site_paths.size
    end

    def site_paths : Array(String)
      copy_strings(@site_paths)
    end

    def has_site?(path : String) : Bool
      @sites.has_key?(path)
    end

    def type_for_site(path : String) : BinaryDataType
      site = @sites[path]? || raise(KeyError.new("Dynamic site not found: #{path.inspect}"))
      site.type
    end

    def structure_for(path : String) : DynamicStructure
      site = @sites[path]? || raise(KeyError.new("Dynamic site not found: #{path.inspect}"))
      site.structure
    end

    # Byte offset of the statistics flag relative to this site's structure
    # blob. Use only with exact decoded bytes or bytes emitted by this plan.
    # Writer plans retain the offset from planning serialization; reader plans
    # retain it from the exact per-site bytes parsed during discovery.
    def statistics_offset_for(path : String) : Int32
      site = @sites[path]? || raise(KeyError.new("Dynamic site not found: #{path.inspect}"))
      site.statistics_offset
    end

    def arm_count(path : String) : Int32
      site = @sites[path]? || raise(KeyError.new("Dynamic site not found: #{path.inspect}"))
      site.arms.size
    end

    def arm_type(path : String, index : Int) : BinaryDataType
      site = @sites[path]? || raise(KeyError.new("Dynamic site not found: #{path.inspect}"))
      site.arms[index]
    end

    def shared_index(path : String) : Int32
      site = @sites[path]? || raise(KeyError.new("Dynamic site not found: #{path.inspect}"))
      site.structure.shared_index
    end

    # An exact actual-roster type uses its ordinary canonical arm. Anything
    # else routes through the site's separate implicit SharedVariant String
    # arm. This is codec policy, not ColumnDynamic insertion promotion.
    def select_arm(path : String, type : BinaryDataType) : ArmSelection
      site = @sites[path]? || raise(KeyError.new("Dynamic site not found: #{path.inspect}"))
      structure = site.structure
      index = structure.shared_index
      ordinary = false
      structure.type_count.times do |candidate_index|
        if structure.type_at(candidate_index) == type
          index = structure.canonical_index_for(type)
          ordinary = true
          break
        end
      end
      ArmSelection.new(index.to_u8, !ordinary)
    end

    # Actual-arm-aware recursion is intentionally separate from the nominal
    # BinaryDataType#contains_low_cardinality? bit: a Dynamic cap says nothing
    # about the site's concrete roster.
    def contains_low_cardinality?(type : BinaryDataType, path : String, context : BinaryCodecContext) : Bool
      case type.tag
      when BinaryDataType::TAG_LOW_CARDINALITY
        true
      when BinaryDataType::TAG_DYNAMIC
        count = arm_count(path)
        count.times do |index|
          child = contextual_generated_name(context, path, ".arm.", index)
          return true if contains_low_cardinality?(arm_type(path, index), child, context)
        end
        false
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NULLABLE
        suffix = type.tag == BinaryDataType::TAG_ARRAY ? ".elements" : ".nested"
        contains_low_cardinality?(type.child_at(0), contextual_generated_name(context, path, suffix), context)
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        contains_low_cardinality?(type.child_at(0), path, context)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times do |index|
          child = contextual_generated_name(context, path, ".field.", index)
          return true if contains_low_cardinality?(type.child_at(index), child, context)
        end
        false
      when BinaryDataType::TAG_MAP
        key = contains_low_cardinality?(type.child_at(0), contextual_generated_name(context, path, ".elements.field.0"), context)
        value = contains_low_cardinality?(type.child_at(1), contextual_generated_name(context, path, ".elements.field.1"), context)
        key || value
      when BinaryDataType::TAG_VARIANT
        type.child_count.times do |index|
          child = contextual_generated_name(context, path, ".arm.", index)
          return true if contains_low_cardinality?(type.child_at(index), child, context)
        end
        false
      else
        false
      end
    end

    def role_count : UInt64
      @data_role_count
    end

    def ordinary_role_count : UInt64
      @ordinary_role_count
    end

    def ordinary_roles : Array(String)
      copy_strings(@ordinary_roles)
    end

    def low_cardinality_site_paths : Array(Tuple(BinaryDataType, String))
      @low_cardinality_site_paths.map { |entry| {entry[0], String.new(entry[1].to_slice)} }
    end

    def low_cardinality_site_count : UInt64
      @low_cardinality_site_paths.size.to_u64
    end

    def low_cardinality_sites : Array(BinaryBulkTypePlan::LowCardinalitySite)
      @low_cardinality_site_paths.map do |entry|
        BinaryBulkTypePlan::LowCardinalitySite.new(entry[0], String.new(entry[1].to_slice))
      end
    end

    def ancestor_size_roles : Array(String)
      copy_strings(@ancestor_size_roles)
    end

    def ancestor_size_role_count : UInt64
      @ancestor_size_roles.size.to_u64
    end

    def low_cardinality_shape_roles : Array(String)
      copy_strings(@low_cardinality_shape_roles)
    end

    def low_cardinality_schedule_grid_count : UInt64
      @low_cardinality_schedule_grid_count
    end

    def data_roles : Array(String)
      copy_strings(@data_roles)
    end

    def structure_roles : Array(String)
      copy_strings(@structure_roles)
    end

    # Encode only the per-occurrence Dynamic structure blobs under one caller
    # budget. Descriptor/value and physical bulk lanes remain separate owners.
    def encode_structure_streams(budget : BinaryCodecBudget) : BinaryDynamicStructureStreams
      unless budget.writing?
        raise ArgumentError.new("Dynamic structure stream encode requires a writing budget")
      end

      context = BinaryCodecContext.new(budget.limits, nil, true, budget, false, false)
      context.validate_type_tree(@type)
      site_metadata = @site_paths.size.to_u64 * 2_u64
      total_metadata = site_metadata + @data_roles.size.to_u64
      context.preflight_metadata(total_metadata, maximum_count: Int32::MAX.to_u64, label: "Dynamic plan metadata count")
      context.visit_metadata_nodes(total_metadata, 1)

      encoded = Hash(String, Bytes).new
      @site_paths.each do |path|
        site = @sites[path]
        structure_context = BinaryCodecContext.new(budget.limits, nil, true, budget, false, true)
        DynamicStructureCodec.write_to(site.structure, structure_context, site.depth, site.depth + 1)
        context.preflight_children(1_u64)
        context.validate_type_tree(BinaryDataType.primitive("String"), site.depth + 1)
        encoded[copy_planned_path(context, path)] = structure_context.finish_bytes
      end
      BinaryDynamicStructureStreams.new(encoded)
    end

    # Parse structure blobs only after charging the complete borrowed envelope.
    # Nested Dynamic sites are discovered from actual roster descriptors, not
    # from nominal Dynamic caps or row/mark occurrences.
    def self.decode_structure_streams(
      type : BinaryDataType,
      streams : BinaryDynamicStructureStreams,
      budget : BinaryCodecBudget,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
    ) : BinaryDynamicBulkPlan
      if budget.writing?
        raise ArgumentError.new("Dynamic structure stream decode requires a reading budget")
      end
      unless type.contains_dynamic?
        raise ArgumentError.new("Dynamic bulk plan requires at least one Dynamic site")
      end

      context = BinaryCodecContext.new(budget.limits, nil, false, budget, false, false)
      preflight_external_site_count(context, streams.site_count, "Dynamic structure stream site count")
      budget.charge_wire_bytes(streams.total_input_byte_size)
      context.validate_type_tree(type)

      sites = Hash(String, Site).new
      discover_read_sites(type, "root", 1, streams, context, sites)
      unless sites.size == streams.site_count
        context.corrupt!("Dynamic structure stream site set is incomplete")
      end

      data_role_count = count_type_roles(type, "root", sites, profile, context)
      ordinary_role_count = count_ordinary_type_roles(type, "root", sites, profile, context)
      site_path_count = count_low_cardinality_sites(type, "root", sites, context)
      ancestor_role_count = count_ancestor_size_roles(type, "root", sites, context)[:count]
      schedule_metrics = low_cardinality_schedule_metrics(type, "root", sites, context)
      retained_metadata = checked_role_add(ordinary_role_count, checked_role_add(site_path_count, checked_role_add(ancestor_role_count, schedule_metrics[:shape_roles])))
      charge_plan_metadata(context, sites.size.to_u64, checked_role_add(data_role_count, retained_metadata))
      site_paths = sites.keys.sort!
      data_roles = Array(String).new(data_role_count.to_i)
      append_type_roles(type, "root", sites, profile, context, data_roles)
      data_roles.sort!
      structure_roles = Array(String).new(site_paths.size)
      site_paths.each { |path| append_role(context, path, ".dynamic_structure", structure_roles) }
      structure_roles.sort!
      ordinary_roles = Array(String).new(ordinary_role_count.to_i)
      append_ordinary_type_roles(type, "root", sites, profile, context, ordinary_roles)
      ordinary_roles.sort!
      low_cardinality_sites = [] of Tuple(BinaryDataType, String)
      append_low_cardinality_sites(type, "root", sites, context, low_cardinality_sites)
      low_cardinality_sites.sort_by! { |entry| entry[1] }
      ancestor_size_roles = [] of String
      append_ancestor_size_roles(type, "root", sites, context, ancestor_size_roles)
      ancestor_size_roles.sort!
      shape_roles = [] of String
      append_low_cardinality_shape_roles(type, "root", sites, context, shape_roles)
      shape_roles.sort!

      new(Prepared.new(type, profile, sites, site_paths, data_roles, structure_roles, ordinary_roles, low_cardinality_sites, ancestor_size_roles, shape_roles, schedule_metrics[:grids], data_role_count, ordinary_role_count))
    end

    private def self.prepare_from_structures(
      type : BinaryDataType,
      structures : Hash(String, DynamicStructure),
      profile : BinaryBulkProfile,
      limits : BinaryCodecLimits,
      budget : BinaryCodecBudget? = nil,
      account_output_bytes : Bool = true,
    ) : Prepared
      unless type.contains_dynamic?
        raise ArgumentError.new("Dynamic bulk plan requires at least one Dynamic site")
      end

      operation_budget = budget || BinaryCodecBudget.new(limits, true)
      context = BinaryCodecContext.new(limits, nil, true, operation_budget, false, account_output_bytes)
      preflight_external_site_count(context, structures.size, "Dynamic structure site count")
      context.validate_type_tree(type)

      sites = Hash(String, Site).new
      discover_write_sites(type, "root", 1, structures, context, sites)
      unless sites.size == structures.size
        raise ArgumentError.new("Dynamic structure site set is incomplete")
      end

      data_role_count = count_type_roles(type, "root", sites, profile, context)
      ordinary_role_count = count_ordinary_type_roles(type, "root", sites, profile, context)
      site_path_count = count_low_cardinality_sites(type, "root", sites, context)
      ancestor_role_count = count_ancestor_size_roles(type, "root", sites, context)[:count]
      schedule_metrics = low_cardinality_schedule_metrics(type, "root", sites, context)
      retained_metadata = checked_role_add(ordinary_role_count, checked_role_add(site_path_count, checked_role_add(ancestor_role_count, schedule_metrics[:shape_roles])))
      charge_plan_metadata(context, sites.size.to_u64, checked_role_add(data_role_count, retained_metadata))
      site_paths = sites.keys.sort!
      data_roles = Array(String).new(data_role_count.to_i)
      append_type_roles(type, "root", sites, profile, context, data_roles)
      data_roles.sort!
      structure_roles = Array(String).new(site_paths.size)
      site_paths.each { |path| append_role(context, path, ".dynamic_structure", structure_roles) }
      structure_roles.sort!
      ordinary_roles = Array(String).new(ordinary_role_count.to_i)
      append_ordinary_type_roles(type, "root", sites, profile, context, ordinary_roles)
      ordinary_roles.sort!
      low_cardinality_sites = [] of Tuple(BinaryDataType, String)
      append_low_cardinality_sites(type, "root", sites, context, low_cardinality_sites)
      low_cardinality_sites.sort_by! { |entry| entry[1] }
      ancestor_size_roles = [] of String
      append_ancestor_size_roles(type, "root", sites, context, ancestor_size_roles)
      ancestor_size_roles.sort!
      shape_roles = [] of String
      append_low_cardinality_shape_roles(type, "root", sites, context, shape_roles)
      shape_roles.sort!
      Prepared.new(type, profile, sites, site_paths, data_roles, structure_roles, ordinary_roles, low_cardinality_sites, ancestor_size_roles, shape_roles, schedule_metrics[:grids], data_role_count, ordinary_role_count)
    end

    private def self.discover_write_sites(
      type : BinaryDataType,
      path : String,
      depth : Int32,
      structures : Hash(String, DynamicStructure),
      context : BinaryCodecContext,
      sites : Hash(String, Site),
    ) : Nil
      context.ensure_depth(depth)
      case type.tag
      when BinaryDataType::TAG_DYNAMIC
        structure = structures[path]? || raise(ArgumentError.new("Dynamic structure is missing for site #{path.inspect}"))
        if sites.has_key?(path)
          raise ArgumentError.new("Dynamic structure site path is duplicated")
        end

        statistics_offset = DynamicStructureCodec.write_with_statistics_offset(structure, context, depth, depth + 1)
        charge_shared_variant_arm(context, depth + 1)
        arms = canonical_arm_types(structure, context, depth + 1)
        sites[path] = Site.new(type, structure, depth, arms, statistics_offset)
        arms.each_with_index do |arm, index|
          child = child_path(context, path, ".arm.", index)
          discover_write_sites(arm, child, depth + 1, structures, context, sites)
        end
      when BinaryDataType::TAG_ARRAY
        discover_write_sites(type.child_at(0), child_path(context, path, ".elements"), depth + 1, structures, context, sites)
      when BinaryDataType::TAG_NULLABLE
        discover_write_sites(type.child_at(0), child_path(context, path, ".nested"), depth + 1, structures, context, sites)
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        discover_write_sites(type.child_at(0), path, depth + 1, structures, context, sites)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times do |index|
          child = child_path(context, path, ".field.", index)
          discover_write_sites(type.child_at(index), child, depth + 1, structures, context, sites)
        end
      when BinaryDataType::TAG_MAP
        key_path = child_path(context, path, ".elements.field.0")
        discover_write_sites(type.child_at(0), key_path, depth + 1, structures, context, sites)
        value_path = child_path(context, path, ".elements.field.1")
        discover_write_sites(type.child_at(1), value_path, depth + 1, structures, context, sites)
      when BinaryDataType::TAG_VARIANT
        type.child_count.times do |index|
          child = child_path(context, path, ".arm.", index)
          discover_write_sites(type.child_at(index), child, depth + 1, structures, context, sites)
        end
      end
      nil
    end

    private def self.discover_read_sites(
      type : BinaryDataType,
      path : String,
      depth : Int32,
      streams : BinaryDynamicStructureStreams,
      context : BinaryCodecContext,
      sites : Hash(String, Site),
    ) : Nil
      context.ensure_depth(depth)
      case type.tag
      when BinaryDataType::TAG_DYNAMIC
        unless streams.has_site?(path)
          context.corrupt!("Dynamic structure stream is missing for site #{path.inspect}")
        end
        if sites.has_key?(path)
          context.corrupt!("Dynamic structure stream site path is duplicated")
        end

        bytes = streams.structure_bytes_for(path)
        structure_context = BinaryCodecContext.new(context.limits, bytes, false, context.budget, false, false)
        structure, statistics_offset = DynamicStructureCodec.read_with_statistics_offset(
          structure_context, depth, depth + 1, true,
        )
        structure_context.ensure_consumed
        charge_shared_variant_arm(context, depth + 1)
        arms = canonical_arm_types(structure, context, depth + 1)
        sites[path] = Site.new(type, structure, depth, arms, statistics_offset)
        arms.each_with_index do |arm, index|
          child = child_path(context, path, ".arm.", index)
          discover_read_sites(arm, child, depth + 1, streams, context, sites)
        end
      when BinaryDataType::TAG_ARRAY
        discover_read_sites(type.child_at(0), child_path(context, path, ".elements"), depth + 1, streams, context, sites)
      when BinaryDataType::TAG_NULLABLE
        discover_read_sites(type.child_at(0), child_path(context, path, ".nested"), depth + 1, streams, context, sites)
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        discover_read_sites(type.child_at(0), path, depth + 1, streams, context, sites)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times do |index|
          child = child_path(context, path, ".field.", index)
          discover_read_sites(type.child_at(index), child, depth + 1, streams, context, sites)
        end
      when BinaryDataType::TAG_MAP
        key_path = child_path(context, path, ".elements.field.0")
        discover_read_sites(type.child_at(0), key_path, depth + 1, streams, context, sites)
        value_path = child_path(context, path, ".elements.field.1")
        discover_read_sites(type.child_at(1), value_path, depth + 1, streams, context, sites)
      when BinaryDataType::TAG_VARIANT
        type.child_count.times do |index|
          child = child_path(context, path, ".arm.", index)
          discover_read_sites(type.child_at(index), child, depth + 1, streams, context, sites)
        end
      end
      nil
    end

    private def self.canonical_arm_types(
      structure : DynamicStructure,
      context : BinaryCodecContext,
      descriptor_depth : Int32,
    ) : Array(BinaryDataType)
      count = structure.canonical_variant_count
      context.preflight_metadata(count.to_u64, maximum_count: 255_u64, label: "Dynamic canonical arm count")

      name_work_bytes = 0_u64
      structure.type_count.times do |index|
        bounds = BinaryTypeNameBudget.measure(structure.type_at(index), context.budget, descriptor_depth)
        if bounds[1] > UInt64::MAX - name_work_bytes
          context.unsupported!("Dynamic canonical-name work size overflows UInt64")
        end
        name_work_bytes += bounds[1]
      end
      context.budget.ensure_wire_bytes(name_work_bytes)
      context.budget.charge_wire_bytes(name_work_bytes)

      arms = Array(BinaryDataType?).new(count, nil)
      arms[structure.shared_index] = BinaryDataType.primitive("String")
      structure.type_count.times do |index|
        type = structure.type_at(index)
        canonical_index = begin
          structure.canonical_index_for(type)
        rescue ex : ArgumentError
          context.unsupported!("invalid Dynamic canonical arm mapping: #{ex.message}")
        end
        if arms[canonical_index]?
          context.unsupported!("Dynamic canonical arm mapping is duplicated")
        end
        arms[canonical_index] = type
      end
      Array(BinaryDataType).new(count) do |index|
        arms[index] || context.unsupported!("Dynamic canonical arm descriptor is missing")
      end
    end

    private def self.charge_shared_variant_arm(context : BinaryCodecContext, depth : Int) : Nil
      context.preflight_children(1_u64)
      context.validate_type_tree(BinaryDataType.primitive("String"), depth)
    end

    private def self.child_path(
      context : BinaryCodecContext,
      path : String,
      suffix : String,
      index : Int32? = nil,
    ) : String
      generated_name(context, path, suffix, index)
    end

    private def self.append_role(
      context : BinaryCodecContext,
      path : String,
      suffix : String,
      roles : Array(String),
    ) : Nil
      roles << generated_name(context, path, suffix)
      nil
    end

    private def self.generated_name(
      context : BinaryCodecContext,
      path : String,
      suffix : String,
      index : Int32? = nil,
    ) : String
      size = path.bytesize.to_u64
      suffix_size = suffix.bytesize.to_u64
      if suffix_size > UInt64::MAX - size
        context.unsupported!("Dynamic site path size overflows UInt64")
      end
      size += suffix_size
      index_size = 0_u64
      if index
        index_size = decimal_digits(index).to_u64
        if index_size > UInt64::MAX - size
          context.unsupported!("Dynamic site path size overflows UInt64")
        end
        size += index_size
      end
      work = checked_string_work_bytes(context, size)
      if index_size > UInt64::MAX - work
        context.unsupported!("Dynamic site path work size overflows UInt64")
      end
      work += index_size
      context.budget.charge_wire_bytes(work)
      value = String.build do |builder|
        builder << path << suffix
        builder << index.to_s if index
      end
      value
    end

    private def copy_planned_path(context : BinaryCodecContext, path : String) : String
      size = path.bytesize.to_u64
      if size > UInt64::MAX // 4_u64
        context.unsupported!("Dynamic site path copy size overflows UInt64")
      end
      work = size * 4_u64
      # The encoded map key is copied here and the detached stream owner takes
      # one additional snapshot of that key. Precharge both before the first.
      context.budget.ensure_wire_bytes(work)
      context.budget.charge_wire_bytes(work)
      detached = String.new(path.to_slice)
      detached
    end

    private def self.checked_string_work_bytes(context : BinaryCodecContext, size : UInt64) : UInt64
      if size > UInt64::MAX // 2_u64
        context.unsupported!("Dynamic path or role work size overflows UInt64")
      end
      size * 2_u64
    end

    private def self.decimal_digits(value : Int32) : Int32
      digits = 1
      remaining = value
      while remaining >= 10
        remaining //= 10
        digits += 1
      end
      digits
    end

    private def self.preflight_external_site_count(context : BinaryCodecContext, count : Int, label : String) : Nil
      context.preflight_metadata(count.to_u64, maximum_count: Int32::MAX.to_u64, label: label)
      context.visit_metadata_nodes(count.to_u64, 1)
    end

    private def self.charge_plan_metadata(context : BinaryCodecContext, site_count : UInt64, data_role_count : UInt64) : Nil
      # One retained site path, one structure-role path, and every data-role
      # path are count-derived planner metadata, separate from type edges.
      site_metadata = site_count
      if site_metadata > UInt64::MAX // 2_u64
        context.unsupported!("Dynamic plan metadata count overflows UInt64")
      end
      site_metadata *= 2_u64
      if data_role_count > UInt64::MAX - site_metadata
        context.unsupported!("Dynamic plan metadata count overflows UInt64")
      end
      total = site_metadata + data_role_count
      context.preflight_metadata(total, maximum_count: Int32::MAX.to_u64, label: "Dynamic plan metadata count")
      context.visit_metadata_nodes(total, 1)
    end

    private def self.count_type_roles(
      type : BinaryDataType,
      path : String,
      sites : Hash(String, Site),
      profile : BinaryBulkProfile,
      context : BinaryCodecContext,
    ) : UInt64
      case type.tag
      when BinaryDataType::TAG_DYNAMIC
        site = sites[path]? || raise(UnsupportedFormatError.new("Dynamic structure site is missing from its plan"))
        count = 1_u64 # discriminators
        site.arms.each_with_index do |arm, index|
          child = child_path(context, path, ".arm.", index)
          count = checked_role_add(count, count_type_roles(arm, child, sites, profile, context))
        end
        count
      when BinaryDataType::TAG_STRING
        profile.with_size_stream? ? 2_u64 : 1_u64
      when BinaryDataType::TAG_ARRAY
        child = child_path(context, path, ".elements")
        checked_role_add(1_u64, count_type_roles(type.child_at(0), child, sites, profile, context))
      when BinaryDataType::TAG_NULLABLE
        child = child_path(context, path, ".nested")
        checked_role_add(1_u64, count_type_roles(type.child_at(0), child, sites, profile, context))
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        count_type_roles(type.child_at(0), path, sites, profile, context)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        if type.child_count == 0
          1_u64
        else
          count = 0_u64
          type.child_count.times do |index|
            child = child_path(context, path, ".field.", index)
            count = checked_role_add(count, count_type_roles(type.child_at(index), child, sites, profile, context))
          end
          count
        end
      when BinaryDataType::TAG_MAP
        checked_role_add(
          1_u64,
          checked_role_add(
            count_type_roles(type.child_at(0), child_path(context, path, ".elements.field.0"), sites, profile, context),
            count_type_roles(type.child_at(1), child_path(context, path, ".elements.field.1"), sites, profile, context)
          )
        )
      when BinaryDataType::TAG_VARIANT
        count = 1_u64
        type.child_count.times do |index|
          child = child_path(context, path, ".arm.", index)
          count = checked_role_add(count, count_type_roles(type.child_at(index), child, sites, profile, context))
        end
        count
      when BinaryDataType::TAG_LOW_CARDINALITY
        2_u64
      when BinaryDataType::TAG_NOTHING, BinaryDataType::TAG_BOOL
        1_u64
      else
        if type.fixed_width
          1_u64
        else
          raise UnsupportedFormatError.new("unsupported binary Dynamic bulk DataType")
        end
      end
    end

    private def self.append_type_roles(
      type : BinaryDataType,
      path : String,
      sites : Hash(String, Site),
      profile : BinaryBulkProfile,
      context : BinaryCodecContext,
      roles : Array(String),
    ) : Nil
      case type.tag
      when BinaryDataType::TAG_DYNAMIC
        site = sites[path]? || raise(UnsupportedFormatError.new("Dynamic structure site is missing from its plan"))
        append_role(context, path, ".discriminators", roles)
        site.arms.each_with_index do |arm, index|
          child = child_path(context, path, ".arm.", index)
          append_type_roles(arm, child, sites, profile, context, roles)
        end
      when BinaryDataType::TAG_STRING
        append_role(context, path, ".data", roles)
        append_role(context, path, ".string_sizes", roles) if profile.with_size_stream?
      when BinaryDataType::TAG_ARRAY
        append_role(context, path, ".sizes", roles)
        child = child_path(context, path, ".elements")
        append_type_roles(type.child_at(0), child, sites, profile, context, roles)
      when BinaryDataType::TAG_NULLABLE
        append_role(context, path, ".nulls", roles)
        child = child_path(context, path, ".nested")
        append_type_roles(type.child_at(0), child, sites, profile, context, roles)
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        append_type_roles(type.child_at(0), path, sites, profile, context, roles)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        if type.child_count == 0
          append_role(context, path, ".data", roles)
        else
          type.child_count.times do |index|
            child = child_path(context, path, ".field.", index)
            append_type_roles(type.child_at(index), child, sites, profile, context, roles)
          end
        end
      when BinaryDataType::TAG_MAP
        append_role(context, path, ".sizes", roles)
        key_path = child_path(context, path, ".elements.field.0")
        append_type_roles(type.child_at(0), key_path, sites, profile, context, roles)
        value_path = child_path(context, path, ".elements.field.1")
        append_type_roles(type.child_at(1), value_path, sites, profile, context, roles)
      when BinaryDataType::TAG_VARIANT
        append_role(context, path, ".discriminators", roles)
        type.child_count.times do |index|
          child = child_path(context, path, ".arm.", index)
          append_type_roles(type.child_at(index), child, sites, profile, context, roles)
        end
      when BinaryDataType::TAG_LOW_CARDINALITY
        append_role(context, path, ".dictionary", roles)
        append_role(context, path, ".indexes", roles)
      when BinaryDataType::TAG_NOTHING, BinaryDataType::TAG_BOOL
        append_role(context, path, ".data", roles)
      else
        if type.fixed_width
          append_role(context, path, ".data", roles)
        else
          raise UnsupportedFormatError.new("unsupported binary Dynamic bulk DataType")
        end
      end
      nil
    end

    private def self.count_ordinary_type_roles(
      type : BinaryDataType,
      path : String,
      sites : Hash(String, Site),
      profile : BinaryBulkProfile,
      context : BinaryCodecContext,
    ) : UInt64
      case type.tag
      when BinaryDataType::TAG_DYNAMIC
        site = sites[path]? || raise(UnsupportedFormatError.new("Dynamic structure site is missing from its plan"))
        count = 1_u64
        site.arms.each_with_index do |arm, index|
          child = child_path(context, path, ".arm.", index)
          count = checked_role_add(count, count_ordinary_type_roles(arm, child, sites, profile, context))
        end
        count
      when BinaryDataType::TAG_LOW_CARDINALITY
        0_u64
      when BinaryDataType::TAG_STRING
        profile.with_size_stream? ? 2_u64 : 1_u64
      when BinaryDataType::TAG_ARRAY
        child = child_path(context, path, ".elements")
        checked_role_add(1_u64, count_ordinary_type_roles(type.child_at(0), child, sites, profile, context))
      when BinaryDataType::TAG_NULLABLE
        child = child_path(context, path, ".nested")
        checked_role_add(1_u64, count_ordinary_type_roles(type.child_at(0), child, sites, profile, context))
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        count_ordinary_type_roles(type.child_at(0), path, sites, profile, context)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        if type.child_count == 0
          1_u64
        else
          count = 0_u64
          type.child_count.times do |index|
            child = child_path(context, path, ".field.", index)
            count = checked_role_add(count, count_ordinary_type_roles(type.child_at(index), child, sites, profile, context))
          end
          count
        end
      when BinaryDataType::TAG_MAP
        checked_role_add(
          1_u64,
          checked_role_add(
            count_ordinary_type_roles(type.child_at(0), child_path(context, path, ".elements.field.0"), sites, profile, context),
            count_ordinary_type_roles(type.child_at(1), child_path(context, path, ".elements.field.1"), sites, profile, context)
          )
        )
      when BinaryDataType::TAG_VARIANT
        count = 1_u64
        type.child_count.times do |index|
          child = child_path(context, path, ".arm.", index)
          count = checked_role_add(count, count_ordinary_type_roles(type.child_at(index), child, sites, profile, context))
        end
        count
      when BinaryDataType::TAG_NOTHING, BinaryDataType::TAG_BOOL
        1_u64
      else
        type.fixed_width ? 1_u64 : raise(UnsupportedFormatError.new("unsupported binary Dynamic bulk DataType"))
      end
    end

    private def self.count_low_cardinality_sites(
      type : BinaryDataType,
      path : String,
      sites : Hash(String, Site),
      context : BinaryCodecContext,
    ) : UInt64
      case type.tag
      when BinaryDataType::TAG_LOW_CARDINALITY
        1_u64
      when BinaryDataType::TAG_DYNAMIC
        site = sites[path]? || raise(UnsupportedFormatError.new("Dynamic structure site is missing from its plan"))
        count = 0_u64
        site.arms.each_with_index do |arm, index|
          child = child_path(context, path, ".arm.", index)
          count = checked_role_add(count, count_low_cardinality_sites(arm, child, sites, context))
        end
        count
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NULLABLE
        suffix = type.tag == BinaryDataType::TAG_ARRAY ? ".elements" : ".nested"
        count_low_cardinality_sites(type.child_at(0), child_path(context, path, suffix), sites, context)
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        count_low_cardinality_sites(type.child_at(0), path, sites, context)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE, BinaryDataType::TAG_VARIANT
        count = 0_u64
        type.child_count.times do |index|
          suffix = type.tag == BinaryDataType::TAG_VARIANT ? ".arm." : ".field."
          child = child_path(context, path, suffix, index)
          count = checked_role_add(count, count_low_cardinality_sites(type.child_at(index), child, sites, context))
        end
        count
      when BinaryDataType::TAG_MAP
        checked_role_add(
          count_low_cardinality_sites(type.child_at(0), child_path(context, path, ".elements.field.0"), sites, context),
          count_low_cardinality_sites(type.child_at(1), child_path(context, path, ".elements.field.1"), sites, context)
        )
      else
        0_u64
      end
    end

    private def self.count_ancestor_size_roles(
      type : BinaryDataType,
      path : String,
      sites : Hash(String, Site),
      context : BinaryCodecContext,
    ) : NamedTuple(contains: Bool, count: UInt64)
      case type.tag
      when BinaryDataType::TAG_LOW_CARDINALITY
        {contains: true, count: 0_u64}
      when BinaryDataType::TAG_DYNAMIC
        site = sites[path]? || raise(UnsupportedFormatError.new("Dynamic structure site is missing from its plan"))
        contains = false
        count = 0_u64
        site.arms.each_with_index do |arm, index|
          child = count_ancestor_size_roles(arm, child_path(context, path, ".arm.", index), sites, context)
          contains ||= child[:contains]
          count = checked_role_add(count, child[:count])
        end
        {contains: contains, count: count}
      when BinaryDataType::TAG_ARRAY
        child = count_ancestor_size_roles(type.child_at(0), child_path(context, path, ".elements"), sites, context)
        {contains: child[:contains], count: child[:contains] ? checked_role_add(1_u64, child[:count]) : 0_u64}
      when BinaryDataType::TAG_NULLABLE
        count_ancestor_size_roles(type.child_at(0), child_path(context, path, ".nested"), sites, context)
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        count_ancestor_size_roles(type.child_at(0), path, sites, context)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE, BinaryDataType::TAG_VARIANT
        contains = false
        count = 0_u64
        type.child_count.times do |index|
          suffix = type.tag == BinaryDataType::TAG_VARIANT ? ".arm." : ".field."
          child = count_ancestor_size_roles(type.child_at(index), child_path(context, path, suffix, index), sites, context)
          contains ||= child[:contains]
          count = checked_role_add(count, child[:count])
        end
        {contains: contains, count: count}
      when BinaryDataType::TAG_MAP
        key = count_ancestor_size_roles(type.child_at(0), child_path(context, path, ".elements.field.0"), sites, context)
        value = count_ancestor_size_roles(type.child_at(1), child_path(context, path, ".elements.field.1"), sites, context)
        contains = key[:contains] || value[:contains]
        count = checked_role_add(key[:count], value[:count])
        {contains: contains, count: contains ? checked_role_add(1_u64, count) : 0_u64}
      else
        {contains: false, count: 0_u64}
      end
    end

    private def self.low_cardinality_schedule_metrics(
      type : BinaryDataType,
      path : String,
      sites : Hash(String, Site),
      context : BinaryCodecContext,
    ) : NamedTuple(contains: Bool, grids: UInt64, shape_roles: UInt64)
      case type.tag
      when BinaryDataType::TAG_LOW_CARDINALITY
        {contains: true, grids: 0_u64, shape_roles: 0_u64}
      when BinaryDataType::TAG_DYNAMIC, BinaryDataType::TAG_VARIANT
        arm_count = type.tag == BinaryDataType::TAG_DYNAMIC ? (sites[path]? || raise(UnsupportedFormatError.new("Dynamic structure site is missing from its plan"))).arms.size : type.child_count
        grids = 0_u64
        shapes = 0_u64
        contains = false
        arm_count.times do |index|
          arm = type.tag == BinaryDataType::TAG_DYNAMIC ? sites[path].arms[index] : type.child_at(index)
          arm_path = child_path(context, path, ".arm.", index)
          metrics = low_cardinality_schedule_metrics(arm, arm_path, sites, context)
          if metrics[:contains]
            contains = true
            grids = checked_role_add(grids, checked_role_add(metrics[:grids], 1_u64))
            shapes = checked_role_add(shapes, metrics[:shape_roles])
          end
        end
        if contains
          {contains: true, grids: grids, shape_roles: checked_role_add(shapes, 1_u64)}
        else
          {contains: false, grids: 0_u64, shape_roles: 0_u64}
        end
      when BinaryDataType::TAG_ARRAY
        child = low_cardinality_schedule_metrics(type.child_at(0), child_path(context, path, ".elements"), sites, context)
        if child[:contains]
          {contains: true, grids: checked_role_add(child[:grids], 1_u64), shape_roles: checked_role_add(child[:shape_roles], 1_u64)}
        else
          child
        end
      when BinaryDataType::TAG_NULLABLE
        low_cardinality_schedule_metrics(type.child_at(0), child_path(context, path, ".nested"), sites, context)
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        low_cardinality_schedule_metrics(type.child_at(0), path, sites, context)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE, BinaryDataType::TAG_MAP
        contains = false
        grids = 0_u64
        shapes = 0_u64
        type.child_count.times do |index|
          child_path_value = if type.tag == BinaryDataType::TAG_MAP
                               child_path(context, path, ".elements.field.", index)
                             else
                               child_path(context, path, ".field.", index)
                             end
          child = low_cardinality_schedule_metrics(type.child_at(index), child_path_value, sites, context)
          contains ||= child[:contains]
          grids = checked_role_add(grids, child[:grids])
          shapes = checked_role_add(shapes, child[:shape_roles])
        end
        if type.tag == BinaryDataType::TAG_MAP && contains
          {contains: true, grids: checked_role_add(grids, 1_u64), shape_roles: checked_role_add(shapes, 1_u64)}
        else
          {contains: contains, grids: grids, shape_roles: shapes}
        end
      else
        {contains: false, grids: 0_u64, shape_roles: 0_u64}
      end
    end

    private def self.append_ordinary_type_roles(
      type : BinaryDataType,
      path : String,
      sites : Hash(String, Site),
      profile : BinaryBulkProfile,
      context : BinaryCodecContext,
      roles : Array(String),
    ) : Nil
      case type.tag
      when BinaryDataType::TAG_LOW_CARDINALITY
        nil
      when BinaryDataType::TAG_DYNAMIC
        site = sites[path]? || raise(UnsupportedFormatError.new("Dynamic structure site is missing from its plan"))
        append_role(context, path, ".discriminators", roles)
        site.arms.each_with_index do |arm, index|
          append_ordinary_type_roles(arm, child_path(context, path, ".arm.", index), sites, profile, context, roles)
        end
      when BinaryDataType::TAG_STRING
        append_role(context, path, ".data", roles)
        append_role(context, path, ".string_sizes", roles) if profile.with_size_stream?
      when BinaryDataType::TAG_ARRAY
        append_role(context, path, ".sizes", roles)
        append_ordinary_type_roles(type.child_at(0), child_path(context, path, ".elements"), sites, profile, context, roles)
      when BinaryDataType::TAG_NULLABLE
        append_role(context, path, ".nulls", roles)
        append_ordinary_type_roles(type.child_at(0), child_path(context, path, ".nested"), sites, profile, context, roles)
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        append_ordinary_type_roles(type.child_at(0), path, sites, profile, context, roles)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        if type.child_count == 0
          append_role(context, path, ".data", roles)
        else
          type.child_count.times do |index|
            append_ordinary_type_roles(type.child_at(index), child_path(context, path, ".field.", index), sites, profile, context, roles)
          end
        end
      when BinaryDataType::TAG_MAP
        append_role(context, path, ".sizes", roles)
        append_ordinary_type_roles(type.child_at(0), child_path(context, path, ".elements.field.0"), sites, profile, context, roles)
        append_ordinary_type_roles(type.child_at(1), child_path(context, path, ".elements.field.1"), sites, profile, context, roles)
      when BinaryDataType::TAG_VARIANT
        append_role(context, path, ".discriminators", roles)
        type.child_count.times do |index|
          append_ordinary_type_roles(type.child_at(index), child_path(context, path, ".arm.", index), sites, profile, context, roles)
        end
      when BinaryDataType::TAG_NOTHING, BinaryDataType::TAG_BOOL
        append_role(context, path, ".data", roles)
      else
        if type.fixed_width
          append_role(context, path, ".data", roles)
        else
          raise UnsupportedFormatError.new("unsupported binary Dynamic bulk DataType")
        end
      end
      nil
    end

    private def self.append_low_cardinality_sites(
      type : BinaryDataType,
      path : String,
      sites_by_path : Hash(String, Site),
      context : BinaryCodecContext,
      result : Array(Tuple(BinaryDataType, String)),
    ) : Nil
      case type.tag
      when BinaryDataType::TAG_LOW_CARDINALITY
        result << {type, copy_generated_path(context, path)}
      when BinaryDataType::TAG_DYNAMIC
        site = sites_by_path[path]? || raise(UnsupportedFormatError.new("Dynamic structure site is missing from its plan"))
        site.arms.each_with_index do |arm, index|
          append_low_cardinality_sites(arm, child_path(context, path, ".arm.", index), sites_by_path, context, result)
        end
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NULLABLE
        suffix = type.tag == BinaryDataType::TAG_ARRAY ? ".elements" : ".nested"
        append_low_cardinality_sites(type.child_at(0), child_path(context, path, suffix), sites_by_path, context, result)
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        append_low_cardinality_sites(type.child_at(0), path, sites_by_path, context, result)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE, BinaryDataType::TAG_VARIANT
        type.child_count.times do |index|
          suffix = type.tag == BinaryDataType::TAG_VARIANT ? ".arm." : ".field."
          append_low_cardinality_sites(type.child_at(index), child_path(context, path, suffix, index), sites_by_path, context, result)
        end
      when BinaryDataType::TAG_MAP
        append_low_cardinality_sites(type.child_at(0), child_path(context, path, ".elements.field.0"), sites_by_path, context, result)
        append_low_cardinality_sites(type.child_at(1), child_path(context, path, ".elements.field.1"), sites_by_path, context, result)
      end
      nil
    end

    private def self.append_ancestor_size_roles(
      type : BinaryDataType,
      path : String,
      sites : Hash(String, Site),
      context : BinaryCodecContext,
      roles : Array(String),
    ) : Bool
      case type.tag
      when BinaryDataType::TAG_LOW_CARDINALITY
        true
      when BinaryDataType::TAG_DYNAMIC
        site = sites[path]? || raise(UnsupportedFormatError.new("Dynamic structure site is missing from its plan"))
        found = false
        site.arms.each_with_index do |arm, index|
          child_found = append_ancestor_size_roles(arm, child_path(context, path, ".arm.", index), sites, context, roles)
          found = found || child_found
        end
        found
      when BinaryDataType::TAG_ARRAY
        found = append_ancestor_size_roles(type.child_at(0), child_path(context, path, ".elements"), sites, context, roles)
        append_role(context, path, ".sizes", roles) if found
        found
      when BinaryDataType::TAG_NULLABLE
        append_ancestor_size_roles(type.child_at(0), child_path(context, path, ".nested"), sites, context, roles)
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        append_ancestor_size_roles(type.child_at(0), path, sites, context, roles)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE, BinaryDataType::TAG_VARIANT
        found = false
        type.child_count.times do |index|
          suffix = type.tag == BinaryDataType::TAG_VARIANT ? ".arm." : ".field."
          child_found = append_ancestor_size_roles(type.child_at(index), child_path(context, path, suffix, index), sites, context, roles)
          found = found || child_found
        end
        found
      when BinaryDataType::TAG_MAP
        key_found = append_ancestor_size_roles(type.child_at(0), child_path(context, path, ".elements.field.0"), sites, context, roles)
        value_found = append_ancestor_size_roles(type.child_at(1), child_path(context, path, ".elements.field.1"), sites, context, roles)
        found = key_found || value_found
        append_role(context, path, ".sizes", roles) if found
        found
      else
        false
      end
    end

    private def self.append_low_cardinality_shape_roles(
      type : BinaryDataType,
      path : String,
      sites : Hash(String, Site),
      context : BinaryCodecContext,
      roles : Array(String),
    ) : Nil
      case type.tag
      when BinaryDataType::TAG_DYNAMIC, BinaryDataType::TAG_VARIANT
        arm_count = type.tag == BinaryDataType::TAG_DYNAMIC ? (sites[path]? || raise(UnsupportedFormatError.new("Dynamic structure site is missing from its plan"))).arms.size : type.child_count
        contains = false
        arm_count.times do |index|
          arm = type.tag == BinaryDataType::TAG_DYNAMIC ? sites[path].arms[index] : type.child_at(index)
          arm_path = child_path(context, path, ".arm.", index)
          child_metrics = low_cardinality_schedule_metrics(arm, arm_path, sites, context)
          if child_metrics[:contains]
            contains = true
            append_low_cardinality_shape_roles(arm, arm_path, sites, context, roles)
          end
        end
        append_role(context, path, ".discriminators", roles) if contains
      when BinaryDataType::TAG_ARRAY
        child_path_value = child_path(context, path, ".elements")
        child_metrics = low_cardinality_schedule_metrics(type.child_at(0), child_path_value, sites, context)
        if child_metrics[:contains]
          append_role(context, path, ".sizes", roles)
          append_low_cardinality_shape_roles(type.child_at(0), child_path_value, sites, context, roles)
        end
      when BinaryDataType::TAG_NULLABLE
        append_low_cardinality_shape_roles(type.child_at(0), child_path(context, path, ".nested"), sites, context, roles)
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        append_low_cardinality_shape_roles(type.child_at(0), path, sites, context, roles)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times do |index|
          append_low_cardinality_shape_roles(type.child_at(index), child_path(context, path, ".field.", index), sites, context, roles)
        end
      when BinaryDataType::TAG_MAP
        key_path = child_path(context, path, ".elements.field.0")
        value_path = child_path(context, path, ".elements.field.1")
        key_type = type.child_at(0)
        value_type = type.child_at(1)
        key_metrics = low_cardinality_schedule_metrics(key_type, key_path, sites, context)
        value_metrics = low_cardinality_schedule_metrics(value_type, value_path, sites, context)
        if key_metrics[:contains] || value_metrics[:contains]
          append_role(context, path, ".sizes", roles)
          append_low_cardinality_shape_roles(key_type, key_path, sites, context, roles)
          append_low_cardinality_shape_roles(value_type, value_path, sites, context, roles)
        end
      end
      nil
    end

    private def self.copy_generated_path(context : BinaryCodecContext, path : String) : String
      size = path.bytesize.to_u64
      work = checked_string_work_bytes(context, size)
      context.budget.charge_wire_bytes(work)
      String.new(path.to_slice)
    end

    private def self.checked_role_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("binary Dynamic bulk lane count overflows UInt64")
      end
      left + right
    end

    private def copy_strings(values : Array(String)) : Array(String)
      values.map { |value| String.new(value.to_slice) }
    end

    private def contextual_generated_name(
      context : BinaryCodecContext,
      path : String,
      suffix : String,
      index : Int32? = nil,
    ) : String
      size = path.bytesize.to_u64 + suffix.bytesize.to_u64
      if index
        digits = index == 0 ? 1 : index.to_s.bytesize
        size += digits.to_u64
      end
      if size > UInt64::MAX // 2_u64
        context.unsupported!("Dynamic path or role work size overflows UInt64")
      end
      context.budget.charge_wire_bytes(size * 2_u64)
      String.build do |builder|
        builder << path << suffix
        builder << index.to_s if index
      end
    end
  end
end

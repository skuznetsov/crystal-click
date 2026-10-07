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
      getter qbit_sites : Array(BinaryDynamicQBitSite)
      getter low_cardinality_site_paths : Array(Tuple(BinaryDataType, String))
      getter ancestor_size_roles : Array(String)
      getter low_cardinality_shape_roles : Array(String)
      getter low_cardinality_schedule_grid_count : UInt64
      getter data_role_count : UInt64
      getter ordinary_role_count : UInt64
      getter json_object_bindings : Hash(BinaryDynamicJsonLeafKey, DynamicJsonObjectBinding)

      def initialize(
        @type : BinaryDataType,
        @profile : BinaryBulkProfile,
        @sites : Hash(String, Site),
        @site_paths : Array(String),
        @data_roles : Array(String),
        @structure_roles : Array(String),
        @ordinary_roles : Array(String),
        @qbit_sites : Array(BinaryDynamicQBitSite),
        @low_cardinality_site_paths : Array(Tuple(BinaryDataType, String)),
        @ancestor_size_roles : Array(String),
        @low_cardinality_shape_roles : Array(String),
        @low_cardinality_schedule_grid_count : UInt64,
        @data_role_count : UInt64,
        @ordinary_role_count : UInt64,
        @json_object_bindings : Hash(BinaryDynamicJsonLeafKey, DynamicJsonObjectBinding),
      )
      end
    end

    @sites : Hash(String, Site)
    @site_paths : Array(String)
    @data_roles : Array(String)
    @structure_roles : Array(String)
    @ordinary_roles : Array(String)
    @qbit_sites : Array(BinaryDynamicQBitSite)
    @low_cardinality_site_paths : Array(Tuple(BinaryDataType, String))
    @ancestor_size_roles : Array(String)
    @low_cardinality_shape_roles : Array(String)
    @low_cardinality_schedule_grid_count : UInt64
    @data_role_count : UInt64
    @ordinary_role_count : UInt64
    @json_object_bindings : Hash(BinaryDynamicJsonLeafKey, DynamicJsonObjectBinding)

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
      json_object_plans : Array(Tuple(String, Int32, ObjectDocumentPlan))? = nil,
      json_object_leaf_plans : Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))? = nil,
    ) : BinaryDynamicBulkPlan
      unless budget.writing?
        raise ArgumentError.new("Dynamic structure plan requires a writing budget")
      end
      prepared = prepare_from_structures(type, structures, profile, budget.limits, budget, false, true, json_object_plans, json_object_leaf_plans)
      new(prepared)
    end

    # Paired Compact Object callers own a budget across the descriptor prefix
    # and value lanes. This constructor plans actual sites without emitting the
    # statistics suffix used by the complete Dynamic metadata profile.
    def self.new_with_prefix_without_statistics(
      type : BinaryDataType,
      structures : Hash(String, DynamicStructure),
      budget : BinaryCodecBudget,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
    ) : BinaryDynamicBulkPlan
      unless budget.writing?
        raise ArgumentError.new("Dynamic prefix plan requires a writing budget")
      end
      prepared = prepare_from_structures(type, structures, profile, budget.limits, budget, false, false)
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
      @qbit_sites = prepared.qbit_sites
      @low_cardinality_site_paths = prepared.low_cardinality_site_paths
      @ancestor_size_roles = prepared.ancestor_size_roles
      @low_cardinality_shape_roles = prepared.low_cardinality_shape_roles
      @low_cardinality_schedule_grid_count = prepared.low_cardinality_schedule_grid_count
      @data_role_count = prepared.data_role_count
      @ordinary_role_count = prepared.ordinary_role_count
      @json_object_bindings = prepared.json_object_bindings
    end

    def site_count : Int32
      @site_paths.size
    end

    # Validate a prepared site's complete declared-plus-actual descriptor
    # tree at the depth inherited from its enclosing storage schema. The
    # structure owners are separate from the nominal Dynamic descriptor, so
    # their actual types must be checked explicitly as well.
    def validate_inherited_depth!(initial_depth : Int32, budget : BinaryCodecBudget) : Nil
      context = BinaryCodecContext.new(budget.limits, nil, budget.writing?, budget, false, false)
      context.validate_type_tree(@type, initial_depth)
      depth_offset = initial_depth - 1
      @site_paths.each do |path|
        site = @sites[path]
        actual_depth64 = site.depth.to_i64 + depth_offset.to_i64 + 1_i64
        if actual_depth64 > Int32::MAX.to_i64
          raise UnsupportedFormatError.new("Dynamic actual descriptor depth exceeds Int32")
        end
        actual_depth = actual_depth64.to_i
        # The implicit SharedVariant String arm exists even for an empty
        # actual roster and therefore inherits the storage-site depth too.
        BinaryTypeNameBudget.measure(BinaryDataType.primitive("String"), budget, actual_depth)
        site.structure.type_count.times do |index|
          # Measurement validates every descriptor edge and inherited depth
          # without materializing another SQL name or codec representation.
          BinaryTypeNameBudget.measure(site.structure.type_at(index), budget, actual_depth)
        end
      end
      if has_json_object_bindings?
        json_object_leaf_keys(budget).each do |key|
          site = @sites[key.dynamic_site]? || raise(CorruptPartError.new("Dynamic JSON binding has no actual site"))
          json_depth64 = initial_depth.to_i64 + site.depth.to_i64 + key.descriptor_path_size.to_i64
          if json_depth64 <= 0_i64 || json_depth64 > Int32::MAX.to_i64
            raise UnsupportedFormatError.new("Dynamic JSON descriptor depth exceeds Int32")
          end
          binding = json_object_binding(key)
          begin
            binding.schema.validate_plan(binding.plan, budget, json_depth64.to_i)
          rescue ex : ArgumentError
            raise UnsupportedFormatError.new(ex.message || "Dynamic JSON Object schema exceeds its inherited depth")
          end
        end
      end
      nil
    end

    def site_paths : Array(String)
      copy_strings(@site_paths)
    end

    # Allocation-free traversal for codec owners that only inspect all sites.
    # Prefer this to detaching another path roster when the caller does not
    # retain it.
    def each_site_path(&block : String ->) : Nil
      @site_paths.each { |path| yield path }
      nil
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

    def depth_for_site(path : String) : Int32
      site = @sites[path]? || raise(KeyError.new("Dynamic site not found: #{path.inspect}"))
      site.depth
    end

    # Byte offset of the statistics flag relative to this site's structure
    # blob. No-statistics prefix plans have no flag and reject this accessor.
    # Complete writer plans retain the offset from planning serialization;
    # complete reader plans retain it from the exact per-site bytes parsed.
    def statistics_offset_for(path : String) : Int32
      site = @sites[path]? || raise(KeyError.new("Dynamic site not found: #{path.inspect}"))
      if site.statistics_offset < 0
        raise ArgumentError.new("Dynamic structure prefix has no statistics flag")
      end
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

    def has_json_object_bindings? : Bool
      !@json_object_bindings.empty?
    end

    def json_object_binding(path : String, index : Int) : DynamicJsonObjectBinding
      json_object_binding(BinaryDynamicJsonLeafKey.new(path, index, [] of Int32))
    end

    def json_object_binding(key : BinaryDynamicJsonLeafKey) : DynamicJsonObjectBinding
      @json_object_bindings[key]? ||
        raise UnsupportedFormatError.new("Dynamic JSON arm has no Object child binding")
    end

    # Legacy tuple keys expose only direct JSON actuals. Wrapped leaf callers
    # must use #json_object_leaf_keys to avoid collapsing sibling leaves.
    def json_object_binding_keys : Array(Tuple(String, Int32))
      json_object_leaf_keys.compact_map do |key|
        next unless key.descriptor_path_size == 0
        {String.new(key.dynamic_site.to_slice), key.canonical_arm_index}
      end
    end

    def json_object_binding_count : Int32
      @json_object_bindings.size
    end

    def json_object_binding_key_bytesize_total : UInt64
      total = 0_u64
      @json_object_bindings.each_key do |key|
        size = key.dynamic_site_bytesize.to_u64 + key.descriptor_path_size.to_u64 * 4_u64
        if total > UInt64::MAX - size
          raise UnsupportedFormatError.new("Dynamic JSON binding key bytes overflow UInt64")
        end
        total += size
      end
      total
    end

    # Detached key rosters are retained work: preflight their logical records,
    # then account the copied site-key bytes before allocating either.
    def json_object_binding_keys(budget : BinaryCodecBudget) : Array(Tuple(String, Int32))
      count = 0_u64
      bytes = 0_u64
      @json_object_bindings.each_key do |key|
        next unless key.descriptor_path_size == 0
        if count == UInt64::MAX
          raise UnsupportedFormatError.new("Dynamic JSON binding key count overflows UInt64")
        end
        count += 1_u64
        size = key.dynamic_site_bytesize.to_u64
        if bytes > UInt64::MAX - size
          raise UnsupportedFormatError.new("Dynamic JSON binding key bytes overflow UInt64")
        end
        bytes += size
      end
      budget.preflight_children(count) if count > 0_u64
      budget.charge_wire_bytes(bytes) if bytes > 0_u64
      count.times { budget.charge_node }
      keys = Array(Tuple(String, Int32)).new(count.to_i)
      @json_object_bindings.each_key do |key|
        next unless key.descriptor_path_size == 0
        keys << {key.dynamic_site, key.canonical_arm_index}
      end
      keys.sort_by! { |key| {key[0], key[1]} }
      keys
    end

    def json_object_leaf_keys : Array(BinaryDynamicJsonLeafKey)
      keys = @json_object_bindings.keys
      keys.sort! do |left, right|
        compare_json_leaf_keys(left, right)
      end
      keys
    end

    def json_object_leaf_keys(budget : BinaryCodecBudget) : Array(BinaryDynamicJsonLeafKey)
      count = @json_object_bindings.size.to_u64
      path_elements = 0_u64
      @json_object_bindings.each_key do |key|
        size = key.descriptor_path_size.to_u64
        if path_elements > UInt64::MAX - size
          raise UnsupportedFormatError.new("Dynamic JSON binding path element count overflows UInt64")
        end
        path_elements += size
      end
      budget.preflight_children(count) if count > 0_u64
      budget.ensure_future_elements(path_elements)
      budget.charge_wire_bytes(json_object_binding_key_bytesize_total) if count > 0_u64
      count.times { budget.charge_node }
      budget.charge_elements(path_elements) if path_elements > 0_u64
      json_object_leaf_keys
    end

    def json_object_leaf_depth(key : BinaryDynamicJsonLeafKey, initial_depth : Int = 1) : Int32
      site = @sites[key.dynamic_site]? || raise(KeyError.new("Dynamic site not found: #{key.dynamic_site.inspect}"))
      depth64 = initial_depth.to_i64 + site.depth.to_i64 + key.descriptor_path_size.to_i64
      if depth64 <= 0_i64 || depth64 > Int32::MAX.to_i64
        raise UnsupportedFormatError.new("Dynamic JSON descriptor depth exceeds Int32")
      end
      depth64.to_i32
    end

    def json_object_leaf_type(key : BinaryDynamicJsonLeafKey) : BinaryDataType
      root = arm_type(key.dynamic_site, key.canonical_arm_index)
      key.resolve_json_type(root)
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
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED, BinaryDataType::TAG_NULLABLE
        suffix = case type.tag
                 when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED then ".elements"
                 else                                                            ".nested"
                 end
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

    # Borrowed traversal over the immutable planned role roster. W209's paired
    # reader validates lane maps without creating an uncharged detached copy.
    def each_data_role(&block : String ->) : Nil
      @data_roles.each { |role| yield role }
      nil
    end

    def has_data_role?(role : String) : Bool
      @data_roles.includes?(role)
    end

    # Return the already-owned discriminator role string without interpolating
    # a new name during the paired JSON census.
    def discriminator_role_for(path : String) : String
      suffix = ".discriminators"
      expected_size = path.bytesize + suffix.bytesize
      @data_roles.each do |role|
        next unless role.bytesize == expected_size
        matches = true
        path.bytesize.times do |index|
          if role.byte_at(index) != path.byte_at(index)
            matches = false
            break
          end
        end
        next unless matches
        suffix.bytesize.times do |index|
          if role.byte_at(path.bytesize + index) != suffix.byte_at(index)
            matches = false
            break
          end
        end
        return role if matches
      end
      raise KeyError.new("Dynamic discriminator role not found: #{path.inspect}")
    end

    def ordinary_role_count : UInt64
      @ordinary_role_count
    end

    def ordinary_roles : Array(String)
      copy_strings(@ordinary_roles)
    end

    # Detached traversal data for direct QBit actual arms. Site role names
    # retain numeric plane order, independently of the sorted public roster.
    def qbit_sites : Array(BinaryDynamicQBitSite)
      @qbit_sites.map(&.detached_copy)
    end

    # The site object exposes no mutable retained state; plane role getters
    # return detached strings. This avoids cloning the full roster on each
    # encoder/decoder lookup.
    def each_qbit_site(&block : BinaryDynamicQBitSite ->) : Nil
      @qbit_sites.each { |site| yield site }
      nil
    end

    def qbit_site_for(path : String) : BinaryDynamicQBitSite?
      @qbit_sites.each do |site|
        return site if site.matches_path?(path)
      end
      nil
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
      encode_structure_streams_internal(budget, false)
    end

    # Emits the exact Dynamic descriptor prefixes used by Compact Object
    # substreams. The complete Dynamic metadata API above remains unchanged.
    def encode_structure_prefix_streams_without_statistics(
      budget : BinaryCodecBudget,
    ) : BinaryDynamicStructureStreams
      encode_structure_streams_internal(budget, true)
    end

    private def encode_structure_streams_internal(
      budget : BinaryCodecBudget,
      prefix_without_statistics : Bool,
    ) : BinaryDynamicStructureStreams
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
        if prefix_without_statistics
          DynamicStructureCodec.write_prefix_without_statistics(site.structure, structure_context, site.depth, site.depth + 1)
        else
          DynamicStructureCodec.write_to(site.structure, structure_context, site.depth, site.depth + 1)
        end
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
      decode_structure_streams_internal(type, streams, budget, profile, true, nil)
    end

    # The explicitly paired overload keeps JSON Object bindings opt-in while
    # preserving the legacy three/four-argument entry point and its callers.
    # A nil fifth argument is supported for owners that forward an optional
    # binding roster without splitting their call path.
    def self.decode_structure_streams(
      type : BinaryDataType,
      streams : BinaryDynamicStructureStreams,
      budget : BinaryCodecBudget,
      profile : BinaryBulkProfile,
      json_object_plans : Array(Tuple(String, Int32, ObjectDocumentPlan))?,
      json_object_leaf_plans : Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))? = nil,
    ) : BinaryDynamicBulkPlan
      decode_structure_streams_internal(type, streams, budget, profile, true, json_object_plans, json_object_leaf_plans)
    end

    # Discovers structure lanes parent-first from their physical owner. The
    # loader receives only already-decoded ancestor rosters; its budget
    # argument lets it preflight the next lane's logical size before reading
    # that lane. Returned bytes are charged here before parsing.
    def self.decode_structure_streams_with_loader(
      type : BinaryDataType,
      budget : BinaryCodecBudget,
      loader : Proc(String, Hash(String, DynamicStructure), BinaryCodecBudget, Bytes),
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      initial_depth : Int32 = 1,
      descriptor_preflight : BinaryDynamicBulkDescriptorPreflight? = nil,
      json_object_plan_loader : Proc(
        String, Int32, Int32, DynamicStructure, Hash(String, DynamicStructure), BinaryCodecBudget,
        ObjectDocumentPlan,
      )? = nil,
      json_object_leaf_plan_loader : Proc(
        BinaryDynamicJsonLeafKey, Int32, DynamicStructure, Hash(String, DynamicStructure), BinaryCodecBudget,
        ObjectDocumentPlan,
      )? = nil,
    ) : BinaryDynamicBulkPlan
      if budget.writing?
        raise ArgumentError.new("Dynamic structure stream decode requires a read-direction budget")
      end

      context = BinaryCodecContext.new(budget.limits, nil, false, budget, false, false)
      if preflight = descriptor_preflight
        preflight.consume!(type, budget, initial_depth)
      else
        preflight_dynamic_descriptor!(type, budget.limits, budget, initial_depth)
      end
      context.validate_type_tree(type, initial_depth)
      unless type.contains_dynamic?
        raise ArgumentError.new("Dynamic bulk plan requires at least one Dynamic site")
      end

      sites = Hash(String, Site).new
      parsed_structures = Hash(String, DynamicStructure).new
      discover_read_sites(
        type, "root", initial_depth, 1, nil, loader, parsed_structures, context, sites, true,
        !json_object_plan_loader.nil? || !json_object_leaf_plan_loader.nil?
      )
      json_object_plans = if plan_loader = json_object_plan_loader
                            load_json_object_plans(sites, parsed_structures, plan_loader, context, initial_depth)
                          else
                            nil
                          end
      json_object_leaf_plans = if plan_loader = json_object_leaf_plan_loader
                                 load_json_object_leaf_plans(sites, parsed_structures, plan_loader, context, initial_depth)
                               else
                                 nil
                               end
      plan = decoded_plan(type, profile, context, sites, nil, json_object_plans, json_object_leaf_plans)
      plan.validate_inherited_depth!(initial_depth, budget) if plan.has_json_object_bindings?
      plan
    end

    private def self.load_json_object_plans(
      sites : Hash(String, Site),
      structures : Hash(String, DynamicStructure),
      loader : Proc(
        String, Int32, Int32, DynamicStructure, Hash(String, DynamicStructure), BinaryCodecBudget,
        ObjectDocumentPlan,
      ),
      context : BinaryCodecContext,
      initial_depth : Int32,
    ) : Array(Tuple(String, Int32, ObjectDocumentPlan))
      count = 0_u64
      sites.each_value do |site|
        site.arms.each { |arm| count += 1_u64 if arm.tag == BinaryDataType::TAG_JSON }
      end
      context.preflight_children(count) if count > 0_u64
      context.budget.ensure_future_elements(count)
      context.budget.charge_elements(count)
      plans = Array(Tuple(String, Int32, ObjectDocumentPlan)).new(count.to_i)
      sites.keys.sort!.each do |site_path|
        site = sites[site_path]
        site.arms.each_with_index do |arm, arm_index|
          next unless arm.tag == BinaryDataType::TAG_JSON
          json_descriptor_depth = initial_depth.to_i64 + site.depth.to_i64
          if json_descriptor_depth <= 0_i64 || json_descriptor_depth > Int32::MAX.to_i64
            context.unsupported!("Dynamic JSON descriptor depth exceeds Int32")
          end
          plans << {
            site_path,
            arm_index.to_i32,
            loader.call(site_path, arm_index, json_descriptor_depth.to_i32, site.structure, structures, context.budget),
          }
        end
      end
      unless plans.size.to_u64 == count
        context.corrupt!("Dynamic JSON child-plan loader did not cover every direct JSON actual")
      end
      plans
    end

    private def self.load_json_object_leaf_plans(
      sites : Hash(String, Site),
      structures : Hash(String, DynamicStructure),
      loader : Proc(
        BinaryDynamicJsonLeafKey, Int32, DynamicStructure, Hash(String, DynamicStructure), BinaryCodecBudget,
        ObjectDocumentPlan,
      ),
      context : BinaryCodecContext,
      initial_depth : Int32,
    ) : Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))
      count = 0_u64
      path_elements = 0_u64
      key_bytes = 0_u64
      sites.each do |site_path, site|
        site.arms.each do |arm|
          leaf_shape = json_leaf_shape(arm, 0)
          count = checked_role_add(count, leaf_shape[:leaves])
          path_elements = checked_role_add(path_elements, leaf_shape[:path_elements])
          per_site_bytes = checked_role_add(
            checked_role_multiply(site_path.bytesize.to_u64, leaf_shape[:leaves]),
            checked_role_multiply(leaf_shape[:path_elements], 4_u64),
          )
          key_bytes = checked_role_add(key_bytes, per_site_bytes)
        end
      end
      context.preflight_children(count) if count > 0_u64
      context.budget.ensure_future_elements(path_elements)
      context.budget.ensure_wire_bytes(key_bytes)
      context.budget.charge_elements(count) if count > 0_u64
      context.budget.charge_elements(path_elements) if path_elements > 0_u64
      context.budget.charge_wire_bytes(key_bytes) if key_bytes > 0_u64
      count.times { context.budget.charge_node }

      plans = Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan)).new(count.to_i)
      sites.keys.sort!.each do |site_path|
        site = sites[site_path]
        site.arms.each_with_index do |arm, arm_index|
          each_json_leaf_path(arm) do |path|
            key = BinaryDynamicJsonLeafKey.new(site_path, arm_index, path)
            depth64 = initial_depth.to_i64 + site.depth.to_i64 + key.descriptor_path_size.to_i64
            if depth64 <= 0_i64 || depth64 > Int32::MAX.to_i64
              context.unsupported!("Dynamic JSON descriptor depth exceeds Int32")
            end
            plans << {
              key,
              loader.call(key, depth64.to_i32, site.structure, structures, context.budget),
            }
            nil
          end
        end
      end
      unless plans.size.to_u64 == count
        context.corrupt!("Dynamic JSON leaf-plan loader did not cover every JSON descriptor leaf")
      end
      plans
    end

    private def self.json_leaf_shape(
      type : BinaryDataType,
      path_length : Int,
    ) : NamedTuple(leaves: UInt64, path_elements: UInt64)
      return {leaves: 0_u64, path_elements: 0_u64} if type.tag == BinaryDataType::TAG_DYNAMIC
      return {leaves: 1_u64, path_elements: path_length.to_u64} if type.tag == BinaryDataType::TAG_JSON

      leaves = 0_u64
      path_elements = 0_u64
      type.child_count.times do |index|
        child = json_leaf_shape(type.child_at(index), path_length + 1)
        leaves = checked_role_add(leaves, child[:leaves])
        path_elements = checked_role_add(path_elements, child[:path_elements])
      end
      {leaves: leaves, path_elements: path_elements}
    end

    private def self.each_json_leaf_path(
      type : BinaryDataType,
      &block : Array(Int32) -> Nil
    ) : Nil
      walk_json_leaf_paths(type, [] of Int32, block)
    end

    # Recursive callback is an ordinary Proc argument rather than a yielded
    # block, avoiding recursive block inlining during Crystal specialization.
    private def self.walk_json_leaf_paths(
      type : BinaryDataType,
      path : Array(Int32),
      callback : Proc(Array(Int32), Nil),
    ) : Nil
      if type.tag == BinaryDataType::TAG_JSON
        callback.call(path)
        return nil
      end
      return nil if type.tag == BinaryDataType::TAG_DYNAMIC

      type.child_count.times do |index|
        path << index.to_i32
        walk_json_leaf_paths(type.child_at(index), path, callback)
        path.pop
      end
      nil
    end

    private def self.decode_structure_streams_internal(
      type : BinaryDataType,
      streams : BinaryDynamicStructureStreams,
      budget : BinaryCodecBudget,
      profile : BinaryBulkProfile,
      include_statistics : Bool,
      json_object_plans : Array(Tuple(String, Int32, ObjectDocumentPlan))? = nil,
      json_object_leaf_plans : Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))? = nil,
    ) : BinaryDynamicBulkPlan
      if budget.writing?
        raise ArgumentError.new("Dynamic structure stream decode requires a reading budget")
      end
      preflight_dynamic_descriptor!(type, budget.limits)
      context = BinaryCodecContext.new(budget.limits, nil, false, budget, false, false)
      context.validate_type_tree(type)
      unless type.contains_dynamic?
        raise ArgumentError.new("Dynamic bulk plan requires at least one Dynamic site")
      end

      preflight_external_site_count(context, streams.site_count, "Dynamic structure stream site count")
      budget.charge_wire_bytes(streams.total_input_byte_size)

      sites = Hash(String, Site).new
      parsed_structures = Hash(String, DynamicStructure).new
      discover_read_sites(type, "root", 1, 1, streams, nil, parsed_structures, context, sites, include_statistics, !json_object_plans.nil? || !json_object_leaf_plans.nil?)
      decoded_plan(type, profile, context, sites, streams.site_count, json_object_plans, json_object_leaf_plans)
    end

    private def self.decoded_plan(
      type : BinaryDataType,
      profile : BinaryBulkProfile,
      context : BinaryCodecContext,
      sites : Hash(String, Site),
      expected_site_count : Int?,
      json_object_plans : Array(Tuple(String, Int32, ObjectDocumentPlan))? = nil,
      json_object_leaf_plans : Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))? = nil,
    ) : BinaryDynamicBulkPlan
      if count = expected_site_count
        unless sites.size == count
          context.corrupt!("Dynamic structure stream site set is incomplete")
        end
      end
      if type.contains_json?
        context.unsupported!("JSON in the nominal Dynamic bulk descriptor is outside the admitted profile")
      end
      json_object_bindings = build_json_object_bindings(sites, json_object_plans, json_object_leaf_plans, context)
      data_role_count = count_type_roles(type, "root", sites, profile, context)
      ordinary_role_count = count_ordinary_type_roles(type, "root", sites, profile, context)
      qbit_metadata = qbit_site_metadata(sites, context)
      qbit_site_count = qbit_metadata[:sites]
      site_path_count = count_low_cardinality_sites(type, "root", sites, context)
      ancestor_role_count = count_ancestor_size_roles(type, "root", sites, context)[:count]
      schedule_metrics = low_cardinality_schedule_metrics(type, "root", sites, context)
      retained_metadata = checked_role_add(qbit_site_count, checked_role_add(qbit_metadata[:slots], checked_role_add(ordinary_role_count, checked_role_add(site_path_count, checked_role_add(ancestor_role_count, schedule_metrics[:shape_roles])))))
      charge_plan_metadata(context, sites.size.to_u64, checked_role_add(data_role_count, retained_metadata))
      preflight_qbit_site_snapshots(context, qbit_metadata[:snapshot_bytes])
      site_paths = sites.keys.sort!
      data_roles = Array(String).new(data_role_count.to_i)
      qbit_sites = Array(BinaryDynamicQBitSite).new(qbit_site_count.to_i)
      append_type_roles(type, "root", sites, profile, context, data_roles, qbit_sites)
      unless qbit_sites.size.to_u64 == qbit_site_count
        context.corrupt!("Dynamic QBit actual-site roster changed after preflight")
      end
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

      new(Prepared.new(type, profile, sites, site_paths, data_roles, structure_roles, ordinary_roles, qbit_sites, low_cardinality_sites, ancestor_size_roles, shape_roles, schedule_metrics[:grids], data_role_count, ordinary_role_count, json_object_bindings))
    end

    private def self.preflight_dynamic_descriptor!(
      type : BinaryDataType,
      limits : BinaryCodecLimits,
      shared_budget : BinaryCodecBudget? = nil,
      initial_depth : Int32 = 1,
    ) : Nil
      # contains_dynamic? is recursive over descriptor children. Bound its full
      # type-name/tree walk first, even when callers enter through this public
      # loader instead of the part column reader.
      budget = shared_budget || BinaryCodecBudget.new(limits)
      bounds = BinaryTypeNameBudget.measure(type, budget, initial_depth)
      BinaryTypeNameBudget.materialize(type, budget, bounds)
      nil
    end

    # Parses the exact no-statistics prefixes under the caller's read budget.
    # No writer plan or synthetic statistics flag is used to discover sites.
    def self.decode_structure_prefix_streams_without_statistics(
      type : BinaryDataType,
      streams : BinaryDynamicStructureStreams,
      budget : BinaryCodecBudget,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
    ) : BinaryDynamicBulkPlan
      decode_structure_streams_internal(type, streams, budget, profile, false)
    end

    private def self.prepare_from_structures(
      type : BinaryDataType,
      structures : Hash(String, DynamicStructure),
      profile : BinaryBulkProfile,
      limits : BinaryCodecLimits,
      budget : BinaryCodecBudget? = nil,
      account_output_bytes : Bool = true,
      include_statistics : Bool = true,
      json_object_plans : Array(Tuple(String, Int32, ObjectDocumentPlan))? = nil,
      json_object_leaf_plans : Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))? = nil,
    ) : Prepared
      unless type.contains_dynamic?
        raise ArgumentError.new("Dynamic bulk plan requires at least one Dynamic site")
      end

      operation_budget = budget || BinaryCodecBudget.new(limits, true)
      context = BinaryCodecContext.new(limits, nil, true, operation_budget, false, account_output_bytes)
      preflight_external_site_count(context, structures.size, "Dynamic structure site count")
      context.validate_type_tree(type)

      sites = Hash(String, Site).new
      discover_write_sites(type, "root", 1, structures, context, sites, include_statistics, !json_object_plans.nil? || !json_object_leaf_plans.nil?)
      unless sites.size == structures.size
        raise ArgumentError.new("Dynamic structure site set is incomplete")
      end
      if type.contains_json?
        context.unsupported!("JSON in the nominal Dynamic bulk descriptor is outside the admitted profile")
      end

      json_object_bindings = build_json_object_bindings(sites, json_object_plans, json_object_leaf_plans, context)
      data_role_count = count_type_roles(type, "root", sites, profile, context)
      ordinary_role_count = count_ordinary_type_roles(type, "root", sites, profile, context)
      qbit_metadata = qbit_site_metadata(sites, context)
      qbit_site_count = qbit_metadata[:sites]
      site_path_count = count_low_cardinality_sites(type, "root", sites, context)
      ancestor_role_count = count_ancestor_size_roles(type, "root", sites, context)[:count]
      schedule_metrics = low_cardinality_schedule_metrics(type, "root", sites, context)
      retained_metadata = checked_role_add(qbit_site_count, checked_role_add(qbit_metadata[:slots], checked_role_add(ordinary_role_count, checked_role_add(site_path_count, checked_role_add(ancestor_role_count, schedule_metrics[:shape_roles])))))
      charge_plan_metadata(context, sites.size.to_u64, checked_role_add(data_role_count, retained_metadata))
      preflight_qbit_site_snapshots(context, qbit_metadata[:snapshot_bytes])
      site_paths = sites.keys.sort!
      data_roles = Array(String).new(data_role_count.to_i)
      qbit_sites = Array(BinaryDynamicQBitSite).new(qbit_site_count.to_i)
      append_type_roles(type, "root", sites, profile, context, data_roles, qbit_sites)
      unless qbit_sites.size.to_u64 == qbit_site_count
        context.unsupported!("Dynamic QBit actual-site roster changed after preflight")
      end
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
      Prepared.new(type, profile, sites, site_paths, data_roles, structure_roles, ordinary_roles, qbit_sites, low_cardinality_sites, ancestor_size_roles, shape_roles, schedule_metrics[:grids], data_role_count, ordinary_role_count, json_object_bindings)
    end

    private def self.discover_write_sites(
      type : BinaryDataType,
      path : String,
      depth : Int32,
      structures : Hash(String, DynamicStructure),
      context : BinaryCodecContext,
      sites : Hash(String, Site),
      include_statistics : Bool,
      allow_direct_json : Bool = false,
    ) : Nil
      context.ensure_depth(depth)
      case type.tag
      when BinaryDataType::TAG_DYNAMIC
        structure = structures[path]? || raise(ArgumentError.new("Dynamic structure is missing for site #{path.inspect}"))
        if sites.has_key?(path)
          raise ArgumentError.new("Dynamic structure site path is duplicated")
        end

        statistics_offset = if include_statistics
                              DynamicStructureCodec.write_with_statistics_offset(structure, context, depth, depth + 1)
                            else
                              DynamicStructureCodec.write_prefix_without_statistics(structure, context, depth, depth + 1)
                              -1_i32
                            end
        charge_shared_variant_arm(context, depth + 1)
        arms = canonical_arm_types(structure, context, depth + 1, allow_direct_json)
        sites[path] = Site.new(type, structure, depth, arms, statistics_offset)
        arms.each_with_index do |arm, index|
          child = child_path(context, path, ".arm.", index)
          discover_write_sites(arm, child, depth + 1, structures, context, sites, include_statistics, allow_direct_json)
        end
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        discover_write_sites(type.child_at(0), child_path(context, path, ".elements"), depth + 1, structures, context, sites, include_statistics, allow_direct_json)
      when BinaryDataType::TAG_NULLABLE
        discover_write_sites(type.child_at(0), child_path(context, path, ".nested"), depth + 1, structures, context, sites, include_statistics, allow_direct_json)
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        discover_write_sites(type.child_at(0), path, depth + 1, structures, context, sites, include_statistics, allow_direct_json)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times do |index|
          child = child_path(context, path, ".field.", index)
          discover_write_sites(type.child_at(index), child, depth + 1, structures, context, sites, include_statistics, allow_direct_json)
        end
      when BinaryDataType::TAG_MAP
        key_path = child_path(context, path, ".elements.field.0")
        discover_write_sites(type.child_at(0), key_path, depth + 1, structures, context, sites, include_statistics, allow_direct_json)
        value_path = child_path(context, path, ".elements.field.1")
        discover_write_sites(type.child_at(1), value_path, depth + 1, structures, context, sites, include_statistics, allow_direct_json)
      when BinaryDataType::TAG_VARIANT
        type.child_count.times do |index|
          child = child_path(context, path, ".arm.", index)
          discover_write_sites(type.child_at(index), child, depth + 1, structures, context, sites, include_statistics, allow_direct_json)
        end
      end
      nil
    end

    private def self.discover_read_sites(
      type : BinaryDataType,
      path : String,
      depth : Int32,
      local_depth : Int32,
      streams : BinaryDynamicStructureStreams?,
      loader : Proc(String, Hash(String, DynamicStructure), BinaryCodecBudget, Bytes)?,
      parsed_structures : Hash(String, DynamicStructure),
      context : BinaryCodecContext,
      sites : Hash(String, Site),
      include_statistics : Bool,
      allow_direct_json : Bool = false,
    ) : Nil
      context.ensure_depth(depth)
      case type.tag
      when BinaryDataType::TAG_DYNAMIC
        if sites.has_key?(path)
          context.corrupt!("Dynamic structure stream site path is duplicated")
        end

        bytes = if structure_streams = streams
                  unless structure_streams.has_site?(path)
                    context.corrupt!("Dynamic structure stream is missing for site #{path.inspect}")
                  end
                  structure_streams.structure_bytes_for(path)
                else
                  structure_loader = loader || context.corrupt!("Dynamic structure stream loader is missing")
                  preflight_external_site_count(context, 1, "Dynamic structure stream site count")
                  loaded = structure_loader.call(path, parsed_structures, context.budget)
                  context.budget.ensure_wire_bytes(loaded.size.to_u64)
                  context.budget.charge_wire_bytes(loaded.size.to_u64)
                  loaded
                end
        structure_context = BinaryCodecContext.new(context.limits, bytes, false, context.budget, false, false)
        structure, statistics_offset = if include_statistics
                                         DynamicStructureCodec.read_with_statistics_offset(
                                           structure_context, depth, depth + 1, true,
                                         )
                                       else
                                         parsed = DynamicStructureCodec.read_prefix_without_statistics(
                                           structure_context, depth, depth + 1, true,
                                         )
                                         {parsed, -1_i32}
                                       end
        structure_context.ensure_consumed
        charge_shared_variant_arm(context, depth + 1)
        arms = canonical_arm_types(structure, context, depth + 1, allow_direct_json)
        # Discovery budgets and parses at the inherited absolute depth, while
        # the retained plan remains local to its Dynamic root so it can be
        # rebound at another recursive storage site without double-rebasing.
        sites[path] = Site.new(type, structure, local_depth, arms, statistics_offset)
        parsed_structures[path] = structure
        arms.each_with_index do |arm, index|
          child = child_path(context, path, ".arm.", index)
          discover_read_sites(arm, child, depth + 1, local_depth + 1, streams, loader, parsed_structures, context, sites, include_statistics, allow_direct_json)
        end
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        discover_read_sites(type.child_at(0), child_path(context, path, ".elements"), depth + 1, local_depth + 1, streams, loader, parsed_structures, context, sites, include_statistics, allow_direct_json)
      when BinaryDataType::TAG_NULLABLE
        discover_read_sites(type.child_at(0), child_path(context, path, ".nested"), depth + 1, local_depth + 1, streams, loader, parsed_structures, context, sites, include_statistics, allow_direct_json)
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        discover_read_sites(type.child_at(0), path, depth + 1, local_depth + 1, streams, loader, parsed_structures, context, sites, include_statistics, allow_direct_json)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times do |index|
          child = child_path(context, path, ".field.", index)
          discover_read_sites(type.child_at(index), child, depth + 1, local_depth + 1, streams, loader, parsed_structures, context, sites, include_statistics, allow_direct_json)
        end
      when BinaryDataType::TAG_MAP
        key_path = child_path(context, path, ".elements.field.0")
        discover_read_sites(type.child_at(0), key_path, depth + 1, local_depth + 1, streams, loader, parsed_structures, context, sites, include_statistics, allow_direct_json)
        value_path = child_path(context, path, ".elements.field.1")
        discover_read_sites(type.child_at(1), value_path, depth + 1, local_depth + 1, streams, loader, parsed_structures, context, sites, include_statistics, allow_direct_json)
      when BinaryDataType::TAG_VARIANT
        type.child_count.times do |index|
          child = child_path(context, path, ".arm.", index)
          discover_read_sites(type.child_at(index), child, depth + 1, local_depth + 1, streams, loader, parsed_structures, context, sites, include_statistics, allow_direct_json)
        end
      end
      nil
    end

    private def self.canonical_arm_types(
      structure : DynamicStructure,
      context : BinaryCodecContext,
      descriptor_depth : Int32,
      allow_direct_json : Bool = false,
    ) : Array(BinaryDataType)
      count = structure.canonical_variant_count
      context.preflight_metadata(count.to_u64, maximum_count: 255_u64, label: "Dynamic canonical arm count")

      # Nested is carried by the same size-plus-implicit-Tuple recursion as an
      # Array. Descendant LowCardinality sites use that shared size lane when
      # building their per-mark occurrence schedule.
      structure.type_count.times do |index|
        actual_type = structure.type_at(index)
        if actual_type.contains_json? && !allow_direct_json
          context.unsupported!("JSON in Dynamic actual rosters is outside the admitted bulk profile")
        end
        if actual_type.contains_qbit? && actual_type.tag != BinaryDataType::TAG_QBIT
          context.unsupported!("QBit is admitted only as a direct Dynamic actual type")
        end
      end

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

    private def self.build_json_object_bindings(
      sites : Hash(String, Site),
      supplied : Array(Tuple(String, Int32, ObjectDocumentPlan))?,
      supplied_leaves : Array(Tuple(BinaryDynamicJsonLeafKey, ObjectDocumentPlan))?,
      context : BinaryCodecContext,
    ) : Hash(BinaryDynamicJsonLeafKey, DynamicJsonObjectBinding)
      expected_count = 0_u64
      expected_path_elements = 0_u64
      expected_key_bytes = 0_u64
      direct_expected_count = 0_u64
      sites.each do |site_path, site|
        site.arms.each_with_index do |arm, arm_index|
          shape = json_leaf_shape(arm, 0)
          expected_count = checked_role_add(expected_count, shape[:leaves])
          expected_path_elements = checked_role_add(expected_path_elements, shape[:path_elements])
          expected_key_bytes = checked_role_add(
            expected_key_bytes,
            checked_role_add(
              checked_role_multiply(site_path.bytesize.to_u64, shape[:leaves]),
              checked_role_multiply(shape[:path_elements], 4_u64),
            ),
          )
          direct_expected_count = checked_role_add(
            direct_expected_count,
            1_u64,
          ) if arm.tag == BinaryDataType::TAG_JSON
        end
      end

      if expected_count == 0_u64 && supplied.nil? && supplied_leaves.nil?
        return Hash(BinaryDynamicJsonLeafKey, DynamicJsonObjectBinding).new
      end

      if expected_count > 0_u64
        if expected_count > UInt64::MAX // 2_u64
          context.unsupported!("Dynamic JSON binding map count overflows UInt64")
        end
        map_records = expected_count * 2_u64
        context.preflight_children(map_records)
        map_records.times { context.budget.charge_node }
      end
      context.budget.ensure_future_elements(expected_path_elements)
      context.budget.charge_elements(expected_path_elements) if expected_path_elements > 0_u64
      context.budget.ensure_wire_bytes(expected_key_bytes)
      context.budget.charge_wire_bytes(expected_key_bytes) if expected_key_bytes > 0_u64

      expected = Hash(BinaryDynamicJsonLeafKey, Site).new(initial_capacity: expected_count.to_i)
      sites.each do |site_path, site|
        site.arms.each_with_index do |arm, arm_index|
          each_json_leaf_path(arm) do |path|
            key = BinaryDynamicJsonLeafKey.new(site_path, arm_index, path)
            if expected.has_key?(key)
              context.unsupported!("Dynamic JSON leaf binding identity is duplicated")
            end
            expected[key] = site
            nil
          end
        end
      end

      if expected_count > 0_u64 && supplied.nil? && supplied_leaves.nil?
        if direct_expected_count > 0_u64
          context.unsupported!("direct Dynamic JSON actuals require complete Object child bindings")
        else
          context.unsupported!("wrapped Dynamic JSON actuals require complete Object child bindings")
        end
      end

      supplied_count = (supplied.try(&.size) || 0).to_u64 + (supplied_leaves.try(&.size) || 0).to_u64
      unless supplied_count == expected_count
        raise ArgumentError.new("Dynamic JSON Object bindings must exactly cover every JSON leaf")
      end

      bindings = Hash(BinaryDynamicJsonLeafKey, DynamicJsonObjectBinding).new(initial_capacity: expected_count.to_i)
      bind_leaf = ->(key : BinaryDynamicJsonLeafKey, object_plan : ObjectDocumentPlan) do
        unless site = expected[key]?
          raise ArgumentError.new("Dynamic JSON Object binding names an unknown or non-JSON leaf")
        end
        if bindings.has_key?(key)
          raise ArgumentError.new("Dynamic JSON Object binding is duplicated")
        end
        leaf_depth = site.depth.to_i64 + 1_i64 + key.descriptor_path_size.to_i64
        if leaf_depth <= 0_i64 || leaf_depth > Int32::MAX.to_i64
          context.unsupported!("Dynamic JSON descriptor depth exceeds Int32")
        end
        binding = DynamicJsonObjectBinding.new(
          key,
          site.structure,
          object_plan,
          context.budget,
          depth: leaf_depth.to_i,
        )
        bindings[key] = binding
      end
      if plans = supplied
        plans.each do |entry|
          site_path, arm_index, object_plan = entry
          bind_leaf.call(BinaryDynamicJsonLeafKey.new(site_path, arm_index, [] of Int32), object_plan)
        end
      end
      if plans = supplied_leaves
        plans.each do |entry|
          key, object_plan = entry
          bind_leaf.call(key, object_plan)
        end
      end
      unless bindings.size == expected.size
        raise ArgumentError.new("Dynamic JSON Object bindings omit a JSON leaf")
      end
      bindings
    end

    private def compare_json_leaf_keys(
      left : BinaryDynamicJsonLeafKey,
      right : BinaryDynamicJsonLeafKey,
    ) : Int32
      site_order = left.compare_dynamic_site(right)
      return site_order unless site_order == 0
      arm_order = left.canonical_arm_index <=> right.canonical_arm_index
      return arm_order unless arm_order == 0
      common_path = Math.min(left.descriptor_path_size, right.descriptor_path_size)
      common_path.times do |index|
        child_order = left.descriptor_child_at(index) <=> right.descriptor_child_at(index)
        return child_order unless child_order == 0
      end
      left.descriptor_path_size <=> right.descriptor_path_size
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
      when BinaryDataType::TAG_JSON
        0_u64
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
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
      when BinaryDataType::TAG_QBIT
        qbit = type.qbit_type || raise UnsupportedFormatError.new("QBit bulk descriptor is missing its nominal type")
        qbit.plane_count.to_u64
      else
        if type.fixed_width
          1_u64
        else
          raise UnsupportedFormatError.new("unsupported binary Dynamic bulk DataType")
        end
      end
    end

    private def self.qbit_site_metadata(
      sites : Hash(String, Site),
      context : BinaryCodecContext,
    ) : NamedTuple(sites: UInt64, slots: UInt64, snapshot_bytes: UInt64)
      # Actual rosters are already discovered and their canonical arms are
      # owned by Site. Counting only direct QBit arms avoids a second generated
      # path walk (and preserves the pre-W199 budget for all other plans).
      site_count = 0_u64
      slot_count = 0_u64
      snapshot_bytes = 0_u64
      sites.each do |site_path, site|
        site.arms.each_with_index do |arm, index|
          next unless arm.tag == BinaryDataType::TAG_QBIT

          qbit = arm.qbit_type || context.unsupported!("Dynamic QBit actual arm is missing its nominal descriptor")
          begin
            QBitColumnType.new(qbit)
          rescue ex : ArgumentError
            context.unsupported!("Dynamic QBit descriptor exceeds the bounded plane profile")
          end
          site_count = checked_role_add(site_count, 1_u64)
          slot_count = checked_role_add(slot_count, qbit.plane_count.to_u64)

          # BinaryDynamicQBitSite owns snapshots of the actual path and every
          # numeric-order role. Preflight their total work before constructors
          # copy any borrowed/generated names.
          path_bytes = checked_role_add(site_path.bytesize.to_u64, ".arm.".bytesize.to_u64)
          path_bytes = checked_role_add(path_bytes, decimal_digits(index).to_u64)
          snapshot_bytes = checked_role_add(snapshot_bytes, path_bytes)
          plane = 0
          while plane < qbit.plane_count
            role_bytes = checked_role_add(path_bytes, BinaryQBitBulkCodec::ROLE_SUFFIX.bytesize.to_u64)
            role_bytes = checked_role_add(role_bytes, decimal_digits(plane).to_u64)
            snapshot_bytes = checked_role_add(snapshot_bytes, role_bytes)
            plane += 1
          end
        end
      end
      {sites: site_count, slots: slot_count, snapshot_bytes: snapshot_bytes}
    end

    private def self.preflight_qbit_site_snapshots(context : BinaryCodecContext, snapshot_bytes : UInt64) : Nil
      return if snapshot_bytes == 0_u64
      context.budget.ensure_wire_bytes(snapshot_bytes)
      context.budget.charge_wire_bytes(snapshot_bytes)
    end

    private def self.append_type_roles(
      type : BinaryDataType,
      path : String,
      sites : Hash(String, Site),
      profile : BinaryBulkProfile,
      context : BinaryCodecContext,
      roles : Array(String),
      qbit_sites : Array(BinaryDynamicQBitSite),
    ) : Nil
      case type.tag
      when BinaryDataType::TAG_DYNAMIC
        site = sites[path]? || raise(UnsupportedFormatError.new("Dynamic structure site is missing from its plan"))
        append_role(context, path, ".discriminators", roles)
        site.arms.each_with_index do |arm, index|
          child = child_path(context, path, ".arm.", index)
          append_type_roles(arm, child, sites, profile, context, roles, qbit_sites)
        end
      when BinaryDataType::TAG_STRING
        append_role(context, path, ".data", roles)
        append_role(context, path, ".string_sizes", roles) if profile.with_size_stream?
      when BinaryDataType::TAG_JSON
        # Bound direct JSON actuals are owned by the paired Object child map.
        nil
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
        append_role(context, path, ".sizes", roles)
        child = child_path(context, path, ".elements")
        append_type_roles(type.child_at(0), child, sites, profile, context, roles, qbit_sites)
      when BinaryDataType::TAG_NULLABLE
        append_role(context, path, ".nulls", roles)
        child = child_path(context, path, ".nested")
        append_type_roles(type.child_at(0), child, sites, profile, context, roles, qbit_sites)
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        append_type_roles(type.child_at(0), path, sites, profile, context, roles, qbit_sites)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        if type.child_count == 0
          append_role(context, path, ".data", roles)
        else
          type.child_count.times do |index|
            child = child_path(context, path, ".field.", index)
            append_type_roles(type.child_at(index), child, sites, profile, context, roles, qbit_sites)
          end
        end
      when BinaryDataType::TAG_MAP
        append_role(context, path, ".sizes", roles)
        key_path = child_path(context, path, ".elements.field.0")
        append_type_roles(type.child_at(0), key_path, sites, profile, context, roles, qbit_sites)
        value_path = child_path(context, path, ".elements.field.1")
        append_type_roles(type.child_at(1), value_path, sites, profile, context, roles, qbit_sites)
      when BinaryDataType::TAG_VARIANT
        append_role(context, path, ".discriminators", roles)
        type.child_count.times do |index|
          child = child_path(context, path, ".arm.", index)
          append_type_roles(type.child_at(index), child, sites, profile, context, roles, qbit_sites)
        end
      when BinaryDataType::TAG_LOW_CARDINALITY
        append_role(context, path, ".dictionary", roles)
        append_role(context, path, ".indexes", roles)
      when BinaryDataType::TAG_QBIT
        qbit = type.qbit_type || context.unsupported!("QBit bulk descriptor is missing its nominal type")
        plane_roles = Array(String).new(qbit.plane_count)
        qbit.plane_count.times do |plane|
          role = generated_name(context, path, BinaryQBitBulkCodec::ROLE_SUFFIX, plane)
          roles << role
          plane_roles << role
        end
        qbit_sites << BinaryDynamicQBitSite.new(path, type, plane_roles)
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
      when BinaryDataType::TAG_JSON
        0_u64
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
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
      when BinaryDataType::TAG_QBIT
        qbit = type.qbit_type || raise UnsupportedFormatError.new("QBit bulk descriptor is missing its nominal type")
        qbit.plane_count.to_u64
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
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED, BinaryDataType::TAG_NULLABLE
        suffix = case type.tag
                 when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED then ".elements"
                 else                                                            ".nested"
                 end
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
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
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
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
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
      when BinaryDataType::TAG_JSON
        # No ordinary Bulk lane exists for a bound JSON/Object handoff.
        nil
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
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
      when BinaryDataType::TAG_QBIT
        qbit = type.qbit_type || context.unsupported!("QBit bulk descriptor is missing its nominal type")
        qbit.plane_count.times do |plane|
          role = generated_name(context, path, BinaryQBitBulkCodec::ROLE_SUFFIX, plane)
          roles << role
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
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED, BinaryDataType::TAG_NULLABLE
        suffix = case type.tag
                 when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED then ".elements"
                 else                                                            ".nested"
                 end
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
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
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
      when BinaryDataType::TAG_ARRAY, BinaryDataType::TAG_NESTED
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

    private def self.checked_role_multiply(left : UInt64, right : UInt64) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        raise UnsupportedFormatError.new("binary Dynamic bulk lane count overflows UInt64")
      end
      left * right
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

module CrystalClick
  # Seals the schema-owned static JSON sites and the exact Compact callback
  # order for one immutable Object-context input. The recursive schema walker
  # owns event order; this plan only binds each site's existing Object codec
  # callbacks to their physical source.
  class CompactJsonCallbackPlan
    alias CallbackPair = ObjectDocumentInlineCallbackOrder::CallbackPair

    struct StructureSource
      getter site_key : String
      getter kind : Symbol
      getter owner_path : String
      getter structure_path : String
      getter owner_plan : ObjectDocumentPlan
      getter owner_physical_plan : ObjectDocumentPhysicalPlan

      def initialize(
        @site_key : String,
        @kind : Symbol,
        @owner_path : String,
        @structure_path : String,
        @owner_plan : ObjectDocumentPlan,
        @owner_physical_plan : ObjectDocumentPhysicalPlan,
      )
      end
    end

    struct SiteBinding
      getter site : CompactRecursiveJsonSchemaPlan::JsonSite
      getter object_plan : ObjectDocumentPlan
      getter physical_plan : ObjectDocumentPhysicalPlan

      @prefix_pairs : Array(CallbackPair)
      @body_pairs : Array(CallbackPair)

      def initialize(
        @site : CompactRecursiveJsonSchemaPlan::JsonSite,
        @object_plan : ObjectDocumentPlan,
        @physical_plan : ObjectDocumentPhysicalPlan,
        prefix_pairs : Array(CallbackPair),
        body_pairs : Array(CallbackPair),
      )
        @prefix_pairs = prefix_pairs.dup
        @body_pairs = body_pairs.dup
      end

      def prefix_pairs : Array(CallbackPair)
        @prefix_pairs.dup
      end

      def body_pairs : Array(CallbackPair)
        @body_pairs.dup
      end

      def each_prefix_pair(&block : CallbackPair -> Nil) : Nil
        @prefix_pairs.each { |pair| yield pair }
        nil
      end

      def each_body_pair(&block : CallbackPair -> Nil) : Nil
        @body_pairs.each { |pair| yield pair }
        nil
      end

      def prefix_callback_count : Int32
        @prefix_pairs.size
      end

      def body_callback_count : Int32
        @body_pairs.size
      end

      def has_prefix_callback?(name : String) : Bool
        @prefix_pairs.any? { |pair| pair[1] == name }
      end

      def has_body_callback?(name : String) : Bool
        @body_pairs.any? { |pair| pair[1] == name }
      end
    end

    getter type : BinaryDataType
    getter profile : BinaryBulkProfile
    getter column_name : String
    getter variant_discriminator_mode : CompactVariantDiscriminatorMode
    getter schema_plan : CompactRecursiveJsonSchemaPlan

    def bound_schema : StorageColumnSchema
      @bound_input.schema
    end

    @bound_input : CompactJsonColumnInput
    @bound_grid : Array(Array(StorageColumnValue))
    @json_context : CompactJsonWriteContext
    @site_bindings : Hash(String, SiteBinding)
    @structure_sources : Hash(String, StructureSource)
    @body_callbacks : Hash(String, String)
    @callback_events : Array(CompactBinaryBulkCallback)
    @physical_callback_names : Array(String)

    def initialize(
      input : CompactJsonColumnInput,
      limits : BinaryCodecLimits,
      budget : BinaryCodecBudget,
      @variant_discriminator_mode : CompactVariantDiscriminatorMode = CompactVariantDiscriminatorMode::Compact,
    )
      unless budget.writing? && same_limits?(budget.limits, limits)
        raise ArgumentError.new("Compact JSON callback planning requires a compatible write codec budget")
      end
      unless input.profile.single_stream? && input.map_basic?
        raise UnsupportedFormatError.new("Compact JSON writer requires the source single-stream BASIC Map profile")
      end
      if input.name.empty?
        raise ArgumentError.new("Compact JSON column name must be nonempty")
      end
      @variant_discriminator_mode.wire_value

      @type = input.type
      @profile = input.profile
      @column_name = String.new(input.name.to_slice)
      @bound_input = input
      @json_context = input.json_context
      # The operation separately reserves transport workspace for this bound
      # duplicate. Charge codec nodes/edges before allocating any container;
      # recursive StorageColumnValue owners are immutable and not deep-copied.
      mark_count = input.granules.size.to_u64
      container_nodes = checked_add(mark_count, 1_u64)
      reference_slots = mark_count
      input.granules.each do |rows|
        reference_slots = checked_add(reference_slots, rows.size.to_u64)
      end
      budget.ensure_future_nodes(container_nodes)
      budget.ensure_future_elements(reference_slots)
      container_nodes.times { budget.charge_node }
      budget.charge_elements(reference_slots) if reference_slots > 0_u64
      @bound_grid = Array(Array(StorageColumnValue)).new(input.granules.size)
      input.granules.each { |rows| @bound_grid << rows.dup }

      @schema_plan = CompactRecursiveJsonSchemaPlan.new(input.schema, input.name, limits, budget)
      json_site_count = @schema_plan.json_site_count
      array_site_count = @schema_plan.array_site_count
      uint8_site_count = @schema_plan.uint8_site_count
      site_slots = checked_add(
        checked_add(json_site_count.to_u64, array_site_count.to_u64),
        uint8_site_count.to_u64,
      )
      unless json_site_count > 0 && site_slots <= 4_u64
        raise UnsupportedFormatError.new("Compact JSON callback plan has an inconsistent schema-site roster")
      end
      budget.ensure_future_nodes(3_u64)
      budget.ensure_future_elements(site_slots)
      3.times { budget.charge_node }
      budget.charge_elements(site_slots) if site_slots > 0_u64
      sites = @schema_plan.json_sites
      array_sites = @schema_plan.array_sites
      uint8_sites = @schema_plan.uint8_sites
      object_schemas = Hash(String, ObjectDocumentSchema).new(initial_capacity: sites.size)
      input.schema.each_json_site { |path, schema| object_schemas[String.new(path.to_slice)] = schema }
      unless @json_context.site_count == sites.size
        raise UnsupportedFormatError.new("Compact JSON context sites differ from the declared schema")
      end
      sites.each do |site|
        unless @json_context.has_site?(site.key)
          raise UnsupportedFormatError.new("Compact JSON context is missing declared Object site #{site.key}")
        end
      end
      @json_context.each_site_plan do |path, _plan|
        unless sites.any? { |site| site.key == path }
          raise UnsupportedFormatError.new("Compact JSON context contains an undeclared Object site")
        end
      end

      @site_bindings = Hash(String, SiteBinding).new(initial_capacity: sites.size)
      @structure_sources = Hash(String, StructureSource).new
      @body_callbacks = Hash(String, String).new
      prefixes = Hash(String, Array(String)).new(initial_capacity: sites.size)
      body_pairs_by_site = Hash(String, Array(CallbackPair)).new(initial_capacity: sites.size)
      seen_callback_names = Set(String).new

      physical_context = PhysicalStreamPlanContext.new(limits)
      sites.each do |site|
        object_schema = object_schemas[site.key]? ||
                        raise(UnsupportedFormatError.new("Compact JSON schema site has no Object declaration"))
        object_plan = @json_context.site_plan_for(site.key)
        object_schema.validate_plan(object_plan, budget, site.descriptor_depth)

        physical = ObjectDocumentPhysicalPlan.from_escaped_prefix(
          site.physical_prefix,
          object_plan,
          BinaryBulkProfile.single_stream,
          BinaryBulkProfile.single_stream,
          limits,
          site.array_level,
          physical_context,
          site.descriptor_depth + 1,
          site.descriptor_depth + 1,
        )
        unless physical.shared_bucket_count == object_plan.structures.object.bucket_count.to_i32
          raise UnsupportedFormatError.new("Compact JSON Object bucket plan differs from its structure")
        end

        descendants = CompactJsonCallbackOwners.for_owner(
          physical,
          object_plan,
          site.callback_prefix,
          budget,
        )
        validate_object_layout!(object_plan, limits, site.descriptor_depth, budget)
        validate_first_prefix_statistics!(object_plan)
        descendants.each { |owner| validate_first_prefix_statistics!(owner[3]) }

        root_owner : ObjectDocumentInlineCallbackOrder::CallbackOwner = {
          ObjectDocumentInlineCallbackOrder.canonical_root_prefix(physical),
          site.callback_prefix,
          physical,
          object_plan,
        }
        owners_by_root = Hash(String, ObjectDocumentInlineCallbackOrder::CallbackOwner).new(
          initial_capacity: descendants.size + 1,
        )
        owners_by_root[root_owner[0]] = root_owner
        descendants.each do |owner|
          if owners_by_root.has_key?(owner[0])
            raise UnsupportedFormatError.new("Compact JSON callback owner root is duplicated")
          end
          owners_by_root[owner[0]] = owner
        end

        prefix_events = ObjectDocumentInlineCallbackOrder.prefix_callback_events(
          physical,
          object_plan,
          site.callback_prefix,
          budget,
          false,
          descendants,
        )
        body_events = ObjectDocumentInlineCallbackOrder.body_callback_events(
          physical,
          object_plan,
          BinaryBulkProfile.single_stream,
          site.callback_prefix,
          budget,
          false,
          true,
          descendants,
        )
        prefix_pairs = callback_pairs(prefix_events, budget)
        body_pairs = callback_pairs(body_events, budget)
        validate_unique_pair_roster!(prefix_pairs, seen_callback_names)
        validate_unique_pair_roster!(body_pairs, seen_callback_names)
        prefixes[site.key] = prefix_pairs.map { |pair| String.new(pair[1].to_slice) }
        body_pairs_by_site[site.key] = body_pairs
        @site_bindings[String.new(site.key.to_slice)] = SiteBinding.new(
          site,
          object_plan,
          physical,
          prefix_pairs,
          body_pairs,
        )
        bind_structure_sources!(site, prefix_events, owners_by_root)
        body_pairs.each do |pair|
          @body_callbacks[String.new(pair[1].to_slice)] = String.new(site.key.to_slice)
        end
      end

      array_sites.each do |site|
        if seen_callback_names.includes?(site.callback_name)
          raise UnsupportedFormatError.new("Compact JSON callback schedule repeats a physical callback")
        end
        seen_callback_names << site.callback_name
      end
      uint8_sites.each do |site|
        if seen_callback_names.includes?(site.callback_name)
          raise UnsupportedFormatError.new("Compact JSON callback schedule repeats a physical callback")
        end
        seen_callback_names << site.callback_name
      end

      ordered_names = @schema_plan.expected_event_names(prefixes, body_pairs_by_site)
      seen_ordered = Set(String).new
      ordered_names.each do |name|
        unless seen_ordered.add?(name)
          raise UnsupportedFormatError.new("Compact JSON callback schedule repeats a physical callback")
        end
      end
      expected_count = seen_callback_names.size
      unless ordered_names.size == expected_count && ordered_names.all? { |name| seen_callback_names.includes?(name) }
        raise UnsupportedFormatError.new("Compact JSON callback schedule differs from its bound physical role roster")
      end

      # Keep the logical event names untouched for ObjectDocument encoding.
      # MRK4 metadata instead needs an exact one-to-one physical projection
      # from the canonical/raw pairs produced by the existing Object planner.
      # Charge the temporary lookup/set and retained physical-reference array
      # before allocating any of those containers; the canonical strings are
      # already retained by their site bindings and are not copied here.
      callback_count = ordered_names.size.to_u64
      added_nodes = checked_add(3_u64, checked_multiply(callback_count, 2_u64))
      added_elements = checked_multiply(callback_count, 4_u64)
      budget.ensure_future_nodes(added_nodes)
      budget.ensure_future_elements(added_elements)
      added_nodes.times { budget.charge_node }
      budget.charge_elements(added_elements) if added_elements > 0_u64

      canonical_by_callback = Hash(String, String).new(initial_capacity: ordered_names.size)
      seen_canonical = Set(String).new(initial_capacity: ordered_names.size)
      @site_bindings.each_value do |binding|
        binding.each_prefix_pair do |canonical, callback|
          register_physical_pair!(canonical_by_callback, seen_canonical, canonical, callback)
        end
        binding.each_body_pair do |canonical, callback|
          register_physical_pair!(canonical_by_callback, seen_canonical, canonical, callback)
        end
      end
      array_sites.each do |site|
        register_physical_pair!(canonical_by_callback, seen_canonical, site.callback_name, site.callback_name)
      end
      uint8_sites.each do |site|
        register_physical_pair!(canonical_by_callback, seen_canonical, site.callback_name, site.callback_name)
      end
      unless canonical_by_callback.size == expected_count
        raise UnsupportedFormatError.new("Compact JSON physical callback projection is not a complete roster")
      end
      @physical_callback_names = Array(String).new(ordered_names.size)
      ordered_names.each do |name|
        physical_name = canonical_by_callback[name]? ||
                        raise UnsupportedFormatError.new("Compact JSON logical callback has no parsed physical-name pair")
        @physical_callback_names << physical_name
      end
      unless @physical_callback_names.size == ordered_names.size &&
             @physical_callback_names.all? { |name| seen_canonical.includes?(name) }
        raise UnsupportedFormatError.new("Compact JSON physical callback projection changed its ordered roster")
      end

      @callback_events = Array(CompactBinaryBulkCallback).new(ordered_names.size)
      ordered_names.each do |name|
        @callback_events << CompactBinaryBulkCallback.new(name, name, 0)
      end
      nil
    end

    def callback_names : Array(String)
      @callback_events.map(&.name)
    end

    def physical_callback_name_count : Int32
      @physical_callback_names.size
    end

    def each_physical_callback_name(&block : String -> Nil) : Nil
      @physical_callback_names.each { |name| yield name }
      nil
    end

    def callback_event_count : Int32
      @callback_events.size
    end

    def callback_events : Array(CompactBinaryBulkCallback)
      @callback_events.dup
    end

    def each_callback_event(&block : CompactBinaryBulkCallback -> Nil) : Nil
      @callback_events.each { |event| yield event }
      nil
    end

    def includes_callback_event?(candidate : CompactBinaryBulkCallback) : Bool
      @callback_events.any? do |event|
        event.name == candidate.name && event.role == candidate.role &&
          event.prefix_size == candidate.prefix_size
      end
    end

    def json_sites : Array(CompactRecursiveJsonSchemaPlan::JsonSite)
      @schema_plan.json_sites
    end

    def json_site_count : Int32
      @schema_plan.json_site_count
    end

    def array_sites : Array(CompactRecursiveJsonSchemaPlan::ArraySite)
      @schema_plan.array_sites
    end

    def array_site_count : Int32
      @schema_plan.array_site_count
    end

    def uint8_sites : Array(CompactRecursiveJsonSchemaPlan::UInt8Site)
      @schema_plan.uint8_sites
    end

    def uint8_site_count : Int32
      @schema_plan.uint8_site_count
    end

    def site_binding(path : String) : SiteBinding
      @site_bindings[path]? || raise(UnsupportedFormatError.new("Compact JSON Object site is outside its callback plan"))
    end

    def structure_source_for_callback(name : String) : StructureSource?
      @structure_sources[name]?
    end

    def body_site_for_callback(name : String) : String?
      @body_callbacks[name]?
    end

    def bound_mark_count : Int32
      @bound_grid.size
    end

    def bound_row_count(mark_index : Int32) : Int32
      @bound_grid[mark_index].size
    end

    def bound_value_at(mark_index : Int32, row_index : Int32) : StorageColumnValue
      @bound_grid[mark_index][row_index]
    end

    def same_context?(context : CompactJsonWriteContext) : Bool
      @json_context.same_context?(context)
    end

    def same_input?(candidate : CompactJsonColumnInput) : Bool
      return false unless candidate.same?(@bound_input)
      return false unless candidate.name == @column_name && candidate.type == @type &&
                          candidate.profile == @profile && candidate.map_basic?
      return false unless candidate.schema.same_tree?(@bound_input.schema)
      return false unless @json_context.same_context?(candidate.json_context)
      rows = candidate.granules
      return false unless rows.size == @bound_grid.size
      rows.each_with_index do |row, mark_index|
        bound_row = @bound_grid[mark_index]?
        return false unless bound_row && row.size == bound_row.size
        row.each_with_index do |value, row_index|
          return false unless value.same?(bound_row[row_index])
        end
      end
      true
    rescue ex : IndexError | KeyError | ArgumentError
      false
    end

    def validate_bound_input! : Nil
      unless same_input?(@bound_input)
        raise UnsupportedFormatError.new("Compact JSON input grid changed after callback planning")
      end
      nil
    end

    private def validate_object_layout!(
      plan : ObjectDocumentPlan,
      limits : BinaryCodecLimits,
      descriptor_depth : Int32,
      budget : BinaryCodecBudget,
    ) : Nil
      object = plan.structures.object
      unless object.version == 4_u64 &&
             ((object.shared_data_version == 0_u64 && object.bucket_count == 1_u64) ||
             (object.shared_data_version == 1_u64 && object.bucket_count == 2_u64))
        raise UnsupportedFormatError.new("Compact JSON writer admits Object V3 MAP or MAP_WITH_BUCKETS only")
      end

      plan.typed_path_count.times do |index|
        path = plan.typed_path_at(index)
        type = plan.typed_type_for(path)
        if plan.has_typed_dynamic?(path)
          CompactDynamicBulkPrefixTraversal.validate_compact_type_admission!(type, limits, descriptor_depth + 1)
          plan.typed_dynamic_site_count_for(path).times do |site_index|
            site_path = plan.typed_dynamic_site_path_at(path, site_index)
            structure = plan.typed_dynamic_site_structure_for(path, site_path)
            dynamic_depth = descriptor_depth.to_i64 - 1_i64 +
                            plan.typed_dynamic_site_object_depth_for(path, site_path).to_i64
            actual_depth = dynamic_depth + 1_i64
            if actual_depth <= 0_i64 || actual_depth > limits.max_depth.to_i64 ||
               actual_depth > Int32::MAX.to_i64
              raise UnsupportedFormatError.new("Compact JSON typed Dynamic actual arm exceeds the configured depth")
            end
            structure.type_count.times do |type_index|
              actual_type = structure.type_at(type_index)
              next if bound_direct_typed_dynamic_json_actual?(plan, path, actual_type, budget)
              CompactDynamicBulkPrefixTraversal.validate_compact_type_admission!(actual_type, limits, actual_depth.to_i32)
            end
          end
        else
          unless BinaryValueTypedBatchAdapter.admitted?(type)
            raise UnsupportedFormatError.new("Compact JSON typed Object callback type is outside its admitted carrier profile")
          end
          StaticBinaryBulkColumnDeclaration.new(type, limits)
        end
      end

      object.dynamic_path_count.times do |index|
        path = object.dynamic_path_at(index)
        structure = plan.structures.dynamic_for(path)
        actual_depth = descriptor_depth + 1
        structure.type_count.times do |type_index|
          CompactDynamicBulkPrefixTraversal.validate_compact_type_admission!(
            structure.type_at(type_index), limits, actual_depth
          )
        end
      end
      nil
    end

    private def bound_direct_typed_dynamic_json_actual?(
      plan : ObjectDocumentPlan,
      path : String,
      actual_type : BinaryDataType,
      budget : BinaryCodecBudget,
    ) : Bool
      return false unless actual_type.tag == BinaryDataType::TAG_JSON &&
                          plan.typed_type_for(path).tag == BinaryDataType::TAG_DYNAMIC &&
                          plan.typed_dynamic_site_count_for(path) == 1 &&
                          plan.typed_dynamic_site_path_at(path, 0) == "root"

      structure = plan.typed_dynamic_for(path)
      canonical_arm_index = structure.canonical_index_for(actual_type)
      plan.typed_dynamic_json_object_leaf_plans_for(path, budget).any? do |entry|
        key = entry[0]
        key.dynamic_site == "root" && key.canonical_arm_index == canonical_arm_index &&
          key.descriptor_path_size == 0
      end
    end

    private def validate_first_prefix_statistics!(plan : ObjectDocumentPlan) : Nil
      unless plan.structures.object.statistics
        raise UnsupportedFormatError.new("Compact JSON first Object prefix requires full statistics")
      end
      plan.structures.object.dynamic_path_count.times do |index|
        dynamic = plan.structures.dynamic_for(plan.structures.object.dynamic_path_at(index))
        unless dynamic.statistics
          raise UnsupportedFormatError.new("Compact JSON first Dynamic prefix requires full statistics")
        end
      end
      plan.typed_dynamic_count.times do |index|
        path = plan.typed_dynamic_path_at(index)
        plan.typed_dynamic_site_count_for(path).times do |site_index|
          site_path = plan.typed_dynamic_site_path_at(path, site_index)
          dynamic = plan.typed_dynamic_site_structure_for(path, site_path)
          unless dynamic.statistics
            raise UnsupportedFormatError.new("Compact JSON first typed Dynamic prefix requires full statistics")
          end
        end
      end
      nil
    end

    private def callback_pairs(
      events : Array(ObjectDocumentInlineCallbackOrder::CallbackEvent),
      budget : BinaryCodecBudget,
    ) : Array(CallbackPair)
      count = events.size.to_u64
      budget.ensure_future_nodes(count + 1_u64)
      budget.ensure_future_elements(count)
      (count + 1_u64).times { budget.charge_node }
      budget.charge_elements(count) if count > 0_u64
      pairs = Array(CallbackPair).new(events.size)
      events.each { |event| pairs << {event[1], event[2]} }
      pairs
    end

    private def bind_structure_sources!(
      site : CompactRecursiveJsonSchemaPlan::JsonSite,
      events : Array(ObjectDocumentInlineCallbackOrder::CallbackEvent),
      owners_by_root : Hash(String, ObjectDocumentInlineCallbackOrder::CallbackOwner),
    ) : Nil
      events.each do |event|
        owner_root, canonical, callback = event
        owner = owners_by_root[owner_root]? ||
                raise(UnsupportedFormatError.new("Compact JSON structure callback has no exact Object owner"))
        object_plan = owner[3]
        physical = owner[2]
        source = if canonical == physical.object_structure_stream
                   StructureSource.new(site.key, :object, "", "", object_plan, physical)
                 else
                   object_path = nil.as(String?)
                   object_plan.structures.object.dynamic_path_count.times do |index|
                     path = object_plan.structures.object.dynamic_path_at(index)
                     if canonical == physical.dynamic_structure_stream(path)
                       object_path = path
                       break
                     end
                   end
                   if path = object_path
                     StructureSource.new(site.key, :object_dynamic, path, "", object_plan, physical)
                   else
                     typed_owner = nil.as(String?)
                     typed_site = nil.as(String?)
                     object_plan.typed_path_count.times do |typed_index|
                       typed_path = object_plan.typed_path_at(typed_index)
                       next unless object_plan.has_typed_dynamic?(typed_path)
                       dynamic_physical = physical.typed_dynamic(typed_path)
                       object_plan.typed_dynamic_site_count_for(typed_path).times do |site_index|
                         path = object_plan.typed_dynamic_site_path_at(typed_path, site_index)
                         if canonical == dynamic_physical.structure_name_for(path)
                           typed_owner = typed_path
                           typed_site = path
                           break
                         end
                       end
                       break if typed_owner
                     end
                     if owner = typed_owner
                       StructureSource.new(site.key, :typed_dynamic, owner, typed_site.not_nil!, object_plan, physical)
                     else
                       next
                     end
                   end
                 end
        if @structure_sources.has_key?(callback)
          raise UnsupportedFormatError.new("Compact JSON structure callback aliases are not unique")
        end
        @structure_sources[String.new(callback.to_slice)] = source
      end
      nil
    end

    private def validate_unique_pair_roster!(
      pairs : Array(CallbackPair),
      seen : Set(String),
    ) : Nil
      pairs.each do |pair|
        canonical, callback = pair
        if canonical.empty? || callback.empty? || !seen.add?(callback)
          raise UnsupportedFormatError.new("Compact JSON Object callback schedule is invalid or duplicated")
        end
      end
      nil
    end

    private def register_physical_pair!(
      canonical_by_callback : Hash(String, String),
      seen_canonical : Set(String),
      canonical : String,
      callback : String,
    ) : Nil
      if canonical.empty? || callback.empty? || canonical_by_callback.has_key?(callback) ||
         !seen_canonical.add?(canonical)
        raise UnsupportedFormatError.new("Compact JSON physical callback projection is invalid or not one-to-one")
      end
      canonical_by_callback[callback] = canonical
      nil
    end

    private def same_limits?(left : BinaryCodecLimits, right : BinaryCodecLimits) : Bool
      left.max_depth == right.max_depth && left.max_nodes == right.max_nodes &&
        left.max_elements == right.max_elements && left.max_bytes == right.max_bytes
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise UnsupportedFormatError.new("Compact JSON bound input grid workspace overflows UInt64")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise UnsupportedFormatError.new("Compact JSON physical callback projection workspace overflows UInt64")
      end
      left * right
    end
  end
end

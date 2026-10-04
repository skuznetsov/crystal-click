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

      def initialize(@type : BinaryDataType, @structure : DynamicStructure, @depth : Int32, @arms : Array(BinaryDataType))
      end
    end

    private struct Prepared
      getter type : BinaryDataType
      getter profile : BinaryBulkProfile
      getter sites : Hash(String, Site)
      getter site_paths : Array(String)
      getter data_roles : Array(String)
      getter structure_roles : Array(String)

      def initialize(
        @type : BinaryDataType,
        @profile : BinaryBulkProfile,
        @sites : Hash(String, Site),
        @site_paths : Array(String),
        @data_roles : Array(String),
        @structure_roles : Array(String),
      )
      end
    end

    @sites : Hash(String, Site)
    @site_paths : Array(String)
    @data_roles : Array(String)
    @structure_roles : Array(String)

    def self.new(
      type : BinaryDataType,
      structures : Hash(String, DynamicStructure),
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      limits : BinaryCodecLimits = BinaryCodecLimits.default,
    ) : BinaryDynamicBulkPlan
      prepared = prepare_from_structures(type, structures, profile, limits)
      new(prepared)
    end

    private def initialize(prepared : Prepared)
      @type = prepared.type
      @profile = prepared.profile
      @sites = prepared.sites
      @site_paths = prepared.site_paths
      @data_roles = prepared.data_roles
      @structure_roles = prepared.structure_roles
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
      charge_plan_metadata(context, sites.size.to_u64, data_role_count)
      site_paths = sites.keys.sort!
      data_roles = Array(String).new(data_role_count.to_i)
      append_type_roles(type, "root", sites, profile, context, data_roles)
      data_roles.sort!
      structure_roles = Array(String).new(site_paths.size)
      site_paths.each { |path| append_role(context, path, ".dynamic_structure", structure_roles) }
      structure_roles.sort!

      new(Prepared.new(type, profile, sites, site_paths, data_roles, structure_roles))
    end

    private def self.prepare_from_structures(
      type : BinaryDataType,
      structures : Hash(String, DynamicStructure),
      profile : BinaryBulkProfile,
      limits : BinaryCodecLimits,
    ) : Prepared
      unless type.contains_dynamic?
        raise ArgumentError.new("Dynamic bulk plan requires at least one Dynamic site")
      end

      budget = BinaryCodecBudget.new(limits, true)
      context = BinaryCodecContext.new(limits, nil, true, budget, false, true)
      preflight_external_site_count(context, structures.size, "Dynamic structure site count")
      context.validate_type_tree(type)

      sites = Hash(String, Site).new
      discover_write_sites(type, "root", 1, structures, context, sites)
      unless sites.size == structures.size
        raise ArgumentError.new("Dynamic structure site set is incomplete")
      end

      data_role_count = count_type_roles(type, "root", sites, profile, context)
      charge_plan_metadata(context, sites.size.to_u64, data_role_count)
      site_paths = sites.keys.sort!
      data_roles = Array(String).new(data_role_count.to_i)
      append_type_roles(type, "root", sites, profile, context, data_roles)
      data_roles.sort!
      structure_roles = Array(String).new(site_paths.size)
      site_paths.each { |path| append_role(context, path, ".dynamic_structure", structure_roles) }
      structure_roles.sort!
      Prepared.new(type, profile, sites, site_paths, data_roles, structure_roles)
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

        DynamicStructureCodec.write_to(structure, context, depth, depth + 1)
        charge_shared_variant_arm(context, depth + 1)
        arms = canonical_arm_types(structure, context, depth + 1)
        sites[path] = Site.new(type, structure, depth, arms)
        arms.each_with_index do |arm, index|
          child = child_path(context, path, ".arm.", index)
          discover_write_sites(arm, child, depth + 1, structures, context, sites)
        end
      when BinaryDataType::TAG_ARRAY
        discover_write_sites(type.child_at(0), child_path(context, path, ".elements"), depth + 1, structures, context, sites)
      when BinaryDataType::TAG_NULLABLE
        discover_write_sites(type.child_at(0), child_path(context, path, ".nested"), depth + 1, structures, context, sites)
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
        structure = DynamicStructureCodec.read_from(structure_context, depth, depth + 1, true)
        structure_context.ensure_consumed
        charge_shared_variant_arm(context, depth + 1)
        arms = canonical_arm_types(structure, context, depth + 1)
        sites[path] = Site.new(type, structure, depth, arms)
        arms.each_with_index do |arm, index|
          child = child_path(context, path, ".arm.", index)
          discover_read_sites(arm, child, depth + 1, streams, context, sites)
        end
      when BinaryDataType::TAG_ARRAY
        discover_read_sites(type.child_at(0), child_path(context, path, ".elements"), depth + 1, streams, context, sites)
      when BinaryDataType::TAG_NULLABLE
        discover_read_sites(type.child_at(0), child_path(context, path, ".nested"), depth + 1, streams, context, sites)
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

    private def self.checked_role_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("binary Dynamic bulk lane count overflows UInt64")
      end
      left + right
    end

    private def copy_strings(values : Array(String)) : Array(String)
      values.map { |value| String.new(value.to_slice) }
    end
  end
end

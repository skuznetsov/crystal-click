module CrystalClick
  # Exact encoder-side association between paired Object metadata and the
  # separately declared typed field schema. Dynamic-bearing typed fields keep
  # an explicit, exact map from generic site path to DynamicStructure.
  class ObjectDocumentPlan
    MAX_TYPED_PATHS = 1_000
    DEFAULT_LIMITS  = BinaryBulkCodec::DEFAULT_LIMITS

    private struct TypedDynamicSite
      getter path : String
      getter type : BinaryDataType
      getter object_depth : Int32
      getter structure : DynamicStructure

      def initialize(@path : String, @type : BinaryDataType, @object_depth : Int32, @structure : DynamicStructure)
      end
    end

    @structures : ObjectDynamicStructureSet
    @typed_types : Hash(String, BinaryDataType)
    @typed_paths : Array(String)
    @typed_dynamic_sites : Hash(String, Hash(String, TypedDynamicSite))
    @typed_dynamic_site_paths : Hash(String, Array(String))
    @typed_dynamic_paths : Array(String)

    def initialize(
      structures : ObjectDynamicStructureSet,
      typed_paths : Hash(String, BinaryDataType),
      typed_dynamics : Hash(String, DynamicStructure) = Hash(String, DynamicStructure).new,
      typed_dynamic_sites : Hash(String, Hash(String, DynamicStructure)) = Hash(String, Hash(String, DynamicStructure)).new,
    )
      # Root Object Dynamic metadata is representable without a child binding,
      # but this value-ready plan has no JSON arm-to-Object association. Reject
      # those actuals before copying any plan roster or allocating lane maps.
      object = structures.object
      object.dynamic_path_count.times do |index|
        path = object.dynamic_path_at(index)
        structure = structures.dynamic_for(path)
        structure.type_count.times do |type_index|
          if structure.type_at(type_index).contains_json?
            raise ArgumentError.new("JSON is not admitted as an unbound root Object Dynamic actual type")
          end
        end
      end

      @structures = structures
      limits = DEFAULT_LIMITS
      raise ArgumentError.new("typed Object paths exceed the admitted count") if typed_paths.size > MAX_TYPED_PATHS

      # Preflight the whole explicit roster before copying a path, site key, or
      # per-field Hash. Ordinary descriptors retain the old constructor
      # behavior; only Dynamic-bearing descriptors are validated here.
      budget = BinaryCodecBudget.new(limits, true)
      budget.visit_node(1)
      budget.preflight_children(typed_paths.size.to_u64) if typed_paths.size > 0
      schema_context = BinaryCodecContext.new(limits, nil, true, budget, false, false)
      path_copy_bytes = 0_u64
      site_count = 0_u64
      dynamic_field_count = 0_u64
      generated_path_bytes = 0_u64
      typed_paths.each do |path, type|
        budget.visit_node(2)
        if type.contains_json?
          raise ArgumentError.new("root JSON is outside the persisted Object declaration grammar")
        end
        # Bound every raw descriptor before contains_dynamic? can recurse. This
        # generic walk preserves the constructor's prior ordinary-field
        # admission policy while making the new recursive predicate finite.
        schema_context.validate_type_tree(type, 2)
        if type.contains_qbit?
          raise ArgumentError.new("typed Object QBit descriptor is outside the persisted Object declaration grammar")
        end
        if structures.object.has_dynamic_path?(path)
          raise ArgumentError.new("typed and Dynamic Object paths must be disjoint")
        end
        path_copy_bytes = checked_add(path_copy_bytes, path.bytesize.to_u64)
        next unless type.contains_dynamic?

        ObjectRecursiveDeclaration.account_descriptor(type, budget, limits, 2) ||
          raise ArgumentError.new("typed Object Dynamic descriptor is outside the Object recursive declaration grammar")
        shape = ObjectDeclaredDynamicSites.shape_for(type, limits, 2)
        dynamic_field_count = checked_add(dynamic_field_count, 1_u64)
        site_count = checked_add(site_count, shape.count)
        generated_path_bytes = checked_add(generated_path_bytes, shape.path_bytes)
        # A separate field key is retained by the nested site map.
        path_copy_bytes = checked_add(path_copy_bytes, path.bytesize.to_u64)
      end
      unless typed_dynamics.size + typed_dynamic_sites.size <= dynamic_field_count
        raise ArgumentError.new("typed Object Dynamic roster has an unknown or duplicate field")
      end
      if site_count > limits.max_nodes.to_u64 || site_count > limits.max_elements.to_u64
        raise ArgumentError.new("typed Object Dynamic site count exceeds codec limits")
      end

      supplied_site_count = typed_dynamics.size.to_u64
      supplied_key_bytes = 0_u64
      typed_dynamics.each_key do |path|
        supplied_key_bytes = checked_add(supplied_key_bytes, path.bytesize.to_u64)
      end
      typed_dynamic_sites.each do |path, roster|
        supplied_key_bytes = checked_add(supplied_key_bytes, path.bytesize.to_u64)
        supplied_site_count = checked_add(supplied_site_count, roster.size.to_u64)
        roster.each_key do |site_path|
          supplied_key_bytes = checked_add(supplied_key_bytes, site_path.bytesize.to_u64)
        end
      end
      if supplied_site_count > limits.max_nodes.to_u64 || supplied_key_bytes > limits.max_bytes.to_u64
        raise ArgumentError.new("typed Object Dynamic supplied roster exceeds codec limits")
      end

      # Generated path prefixes are temporary during canonical path building;
      # use depth as a conservative multiplier before any site-key allocation.
      path_work_bytes = checked_multiply(
        generated_path_bytes,
        checked_add(limits.max_depth.to_u64, 1_u64)
      )
      copied_bytes = checked_add(path_copy_bytes, path_work_bytes)
      budget.charge_wire_bytes(copied_bytes)
      budget.preflight_children(site_count) if site_count > 0_u64
      budget.preflight_children(dynamic_field_count) if dynamic_field_count > 0_u64

      # Reject source maps that cannot correspond to a declared Dynamic field
      # before materializing any per-field site maps.
      typed_dynamics.each do |path, _structure|
        type = typed_paths[path]?
        unless type && type.tag == BinaryDataType::TAG_DYNAMIC
          raise ArgumentError.new("legacy typed Object Dynamic rosters require a direct Dynamic declaration")
        end
        if typed_dynamic_sites.has_key?(path)
          raise ArgumentError.new("typed Object Dynamic field has both legacy and site rosters")
        end
      end
      typed_dynamic_sites.each do |path, _roster|
        type = typed_paths[path]?
        unless type && type.contains_dynamic?
          raise ArgumentError.new("typed Object Dynamic site roster has no Dynamic-bearing declaration")
        end
      end

      @typed_types = Hash(String, BinaryDataType).new(initial_capacity: typed_paths.size)
      @typed_paths = Array(String).new(typed_paths.size)
      typed_paths.each do |path, type|
        detached_path = String.new(path.to_slice)
        @typed_types[detached_path] = type
        @typed_paths << detached_path
      end
      @typed_paths.sort! { |left, right| compare_paths(left, right) }

      @typed_dynamic_sites = Hash(String, Hash(String, TypedDynamicSite)).new(initial_capacity: dynamic_field_count.to_i)
      @typed_dynamic_site_paths = Hash(String, Array(String)).new(initial_capacity: dynamic_field_count.to_i)
      typed_paths.each do |path, type|
        next unless type.contains_dynamic?

        legacy_structure = typed_dynamics[path]?
        supplied_roster = typed_dynamic_sites[path]?
        if legacy_structure && supplied_roster
          raise ArgumentError.new("typed Object Dynamic field has both legacy and site rosters")
        end
        unless legacy_structure || supplied_roster
          raise ArgumentError.new("typed Object Dynamic structure is missing declared field: #{path.inspect}")
        end

        site_entries = Hash(String, TypedDynamicSite).new
        if structure = legacy_structure
          maximum = ObjectDeclaredDynamicDeclaration.max_types_for(type) ||
                    raise ArgumentError.new("legacy typed Object Dynamic roster requires a direct canonical descriptor")
          if structure.type_count > maximum
            raise ArgumentError.new("typed Object Dynamic roster exceeds its declared max_types cap")
          end
          begin
            ObjectDeclaredDynamicDeclaration.validate_actual_structure!(structure, limits, 3, budget)
          rescue ex : UnsupportedFormatError
            raise ArgumentError.new("invalid typed Object Dynamic actual roster: #{ex.message}")
          end
          spec = ObjectDeclaredDynamicSites::SiteSpec.new("root", type, 2)
          site_entries[spec.path] = TypedDynamicSite.new(spec.path, spec.type, spec.object_depth, structure)
        else
          roster = supplied_roster.not_nil!
          specs = begin
            ObjectDeclaredDynamicSites.validate_roster!(type, roster, limits, 2, budget)
          rescue ex : UnsupportedFormatError
            raise ArgumentError.new("invalid typed Object Dynamic site roster: #{ex.message}")
          end
          specs.each do |spec|
            structure = roster[spec.path]? || raise(ArgumentError.new("typed Object Dynamic structure is missing site: #{spec.path.inspect}"))
            site_entries[spec.path] = TypedDynamicSite.new(spec.path, spec.type, spec.object_depth, structure)
          end
        end
        detached_path = String.new(path.to_slice)
        @typed_dynamic_sites[detached_path] = site_entries
        # Keep one stable index per field. Rebuilding and sorting the full key
        # table from typed_dynamic_site_path_at would make an indexed walk
        # quadratic in the explicit site roster.
        site_paths = site_entries.keys
        site_paths.sort! { |left, right| compare_paths(left, right) }
        @typed_dynamic_site_paths[detached_path] = site_paths
      end

      # A site roster with no corresponding typed field is never ignored.
      typed_dynamic_sites.each_key do |path|
        unless @typed_dynamic_sites.has_key?(path)
          raise ArgumentError.new("typed Object Dynamic site roster has no declared field: #{path.inspect}")
        end
      end
      @typed_dynamic_paths = Array(String).new(@typed_dynamic_sites.size)
      @typed_dynamic_sites.each_key { |path| @typed_dynamic_paths << path }
      @typed_dynamic_paths.sort! { |left, right| compare_paths(left, right) }
    end

    def structures : ObjectDynamicStructureSet
      @structures
    end

    def typed_paths : Hash(String, BinaryDataType)
      detached = Hash(String, BinaryDataType).new(initial_capacity: @typed_types.size)
      @typed_types.each do |path, type|
        detached[String.new(path.to_slice)] = type
      end
      detached
    end

    def typed_path_count : Int32
      @typed_paths.size
    end

    def typed_path_at(index : Int) : String
      String.new(@typed_paths[index].to_slice)
    end

    def typed_path_byte_size_at(index : Int) : Int32
      @typed_paths[index].bytesize
    end

    def typed_path_byte_at(index : Int, byte_index : Int) : UInt8
      @typed_paths[index].to_slice[byte_index]
    end

    def has_typed_path?(path : String) : Bool
      @typed_types.has_key?(path)
    end

    def typed_type_for(path : String) : BinaryDataType
      @typed_types[path]? || raise(KeyError.new("typed Object path not found: #{path.inspect}"))
    end

    # Backward-compatible direct-root accessor. Recursive declarations must
    # use typed_dynamic_sites_for rather than selecting an arbitrary site.
    def typed_dynamics : Hash(String, DynamicStructure)
      detached = Hash(String, DynamicStructure).new
      @typed_dynamic_paths.each do |path|
        next unless @typed_types[path]?.try(&.tag) == BinaryDataType::TAG_DYNAMIC
        detached[String.new(path.to_slice)] = typed_dynamic_for(path)
      end
      detached
    end

    # Number of typed fields containing at least one declared Dynamic site.
    def typed_dynamic_count : Int32
      @typed_dynamic_paths.size
    end

    def typed_dynamic_path_at(index : Int) : String
      String.new(@typed_dynamic_paths[index].to_slice)
    end

    def typed_dynamic_path_byte_size_at(index : Int) : Int32
      @typed_dynamic_paths[index].bytesize
    end

    def typed_dynamic_path_byte_at(index : Int, byte_index : Int) : UInt8
      @typed_dynamic_paths[index].to_slice[byte_index]
    end

    def has_typed_dynamic?(path : String) : Bool
      @typed_dynamic_sites.has_key?(path)
    end

    def typed_dynamic_for(path : String) : DynamicStructure
      type = @typed_types[path]?
      unless type && type.tag == BinaryDataType::TAG_DYNAMIC
        raise KeyError.new("typed Object Dynamic root structure not found: #{path.inspect}")
      end
      typed_dynamic_site_structure_for(path, "root")
    end

    def typed_dynamic_site_count_for(path : String) : Int32
      typed_dynamic_site_map(path).size
    end

    def typed_dynamic_site_path_at(path : String, index : Int) : String
      paths = @typed_dynamic_site_paths[path]? || raise(KeyError.new("typed Object Dynamic sites not found: #{path.inspect}"))
      site_path = paths[index]
      String.new(site_path.to_slice)
    end

    def typed_dynamic_site_path_byte_size_at(path : String, index : Int) : Int32
      paths = @typed_dynamic_site_paths[path]? || raise(KeyError.new("typed Object Dynamic sites not found: #{path.inspect}"))
      paths[index].bytesize
    end

    def typed_dynamic_site_structure_for(path : String, site_path : String) : DynamicStructure
      typed_site = typed_dynamic_site_map(path)[site_path]? || raise(KeyError.new("typed Object Dynamic site not found: #{path.inspect}:#{site_path.inspect}"))
      typed_site.structure
    end

    def typed_dynamic_site_type_for(path : String, site_path : String) : BinaryDataType
      typed_dynamic_site_map(path)[site_path]?.try(&.type) ||
        raise(KeyError.new("typed Object Dynamic site not found: #{path.inspect}:#{site_path.inspect}"))
    end

    def typed_dynamic_site_object_depth_for(path : String, site_path : String) : Int32
      typed_dynamic_site_map(path)[site_path]?.try(&.object_depth) ||
        raise(KeyError.new("typed Object Dynamic site not found: #{path.inspect}:#{site_path.inspect}"))
    end

    def typed_dynamic_sites_for(path : String) : Hash(String, DynamicStructure)
      budget = BinaryCodecBudget.new(DEFAULT_LIMITS, true)
      typed_dynamic_sites_for(path, budget)
    end

    # Borrowed-budget snapshot for an in-flight Object operation. This keeps
    # site-key and map-copy work in the caller's aggregate limits.
    def typed_dynamic_sites_for(path : String, budget : BinaryCodecBudget) : Hash(String, DynamicStructure)
      unless budget.writing?
        raise ArgumentError.new("typed Object Dynamic roster copy requires a writing budget")
      end
      entries = typed_dynamic_site_map(path)
      copied_bytes = 0_u64
      entries.each_key { |site_path| copied_bytes = checked_add(copied_bytes, site_path.bytesize.to_u64) }
      count = entries.size.to_u64
      budget.preflight_children(count) if count > 0_u64
      budget.charge_wire_bytes(copied_bytes)
      detached = Hash(String, DynamicStructure).new(initial_capacity: entries.size)
      entries.each do |site_path, site|
        detached[String.new(site_path.to_slice)] = site.structure
      end
      detached
    end

    private def typed_dynamic_site_map(path : String) : Hash(String, TypedDynamicSite)
      @typed_dynamic_sites[path]? || raise(KeyError.new("typed Object Dynamic sites not found: #{path.inspect}"))
    end

    private def compare_paths(left : String, right : String) : Int32
      left_bytes = left.to_slice
      right_bytes = right.to_slice
      common_size = Math.min(left_bytes.size, right_bytes.size)
      common_size.times do |index|
        return -1 if left_bytes[index] < right_bytes[index]
        return 1 if left_bytes[index] > right_bytes[index]
      end
      left_bytes.size <=> right_bytes.size
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise ArgumentError.new("typed Object Dynamic plan size overflows UInt64")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        raise ArgumentError.new("typed Object Dynamic plan size overflows UInt64")
      end
      left * right
    end
  end
end

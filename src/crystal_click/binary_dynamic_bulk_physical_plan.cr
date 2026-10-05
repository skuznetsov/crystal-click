module CrystalClick
  # Binds a prepared Dynamic roster to ClickHouse physical names without
  # changing the legacy static-only BinaryBulkPhysicalPlan contract.
  class BinaryDynamicBulkPhysicalPlan
    alias NameBounds = BinaryTypeNameBudget::Bounds

    private struct EscapedPrefix
      getter value : String

      private def initialize(value : String)
        PhysicalStreamName.validate_escaped_prefix(value)
        @value = String.new(value.to_slice)
      end

      def self.validated(value : String) : EscapedPrefix
        new(value)
      end
    end

    private struct ArmNameEntry
      getter type : BinaryDataType
      getter bounds : NameBounds
      getter shared : Bool

      def initialize(@type : BinaryDataType, @bounds : NameBounds, @shared : Bool)
      end
    end

    @prepared : BinaryDynamicBulkPlan
    @context : PhysicalStreamPlanContext
    @sql_budget : BinaryCodecBudget
    @data_names : Hash(String, String)
    @structure_names : Hash(String, String)
    @prefix_sizes : Hash(String, Int32)
    @arm_entries : Array(ArmNameEntry)
    @arm_names : Array(String)
    @site_offsets : Array(Int32)
    @site_counts : Array(Int32)
    @append_site_cursor : Int32
    @name_preflight_complete : Bool

    @data_role_count : UInt64
    @structure_role_count : UInt64
    @prefix_role_count : UInt64
    @variant_site_count : UInt64
    @arm_occurrence_count : UInt64
    @role_bytes : UInt64
    @prefix_role_bytes : UInt64
    @physical_name_bytes : UInt64
    @sql_work_bytes : UInt64

    def initialize(
      prepared : BinaryDynamicBulkPlan,
      column_name : String,
      limits : BinaryCodecLimits? = nil,
      context : PhysicalStreamPlanContext? = nil,
    )
      @prepared = prepared
      selected_limits = limits || context.try(&.limits) || BinaryBulkCodec::DEFAULT_LIMITS
      if context && limits && !same_limits?(selected_limits, context.limits)
        raise ArgumentError.new("Dynamic physical plan and physical context limits differ")
      end
      @context = context || PhysicalStreamPlanContext.new(selected_limits)
      @sql_budget = BinaryCodecBudget.new(selected_limits, true)
      @data_names = Hash(String, String).new
      @structure_names = Hash(String, String).new
      @prefix_sizes = Hash(String, Int32).new
      @arm_entries = [] of ArmNameEntry
      @arm_names = [] of String
      @site_offsets = [] of Int32
      @site_counts = [] of Int32
      @append_site_cursor = 0
      @name_preflight_complete = false
      @data_role_count = 0_u64
      @structure_role_count = 0_u64
      @prefix_role_count = 0_u64
      @variant_site_count = 0_u64
      @arm_occurrence_count = 0_u64
      @role_bytes = 0_u64
      @prefix_role_bytes = 0_u64
      @physical_name_bytes = 0_u64
      @sql_work_bytes = 0_u64
      escaped_bytes = PhysicalStreamName.escaped_size(column_name)
      @context.preflight_name_bytes(escaped_bytes)
      prefix = PhysicalStreamName.escape(column_name)
      initialize_bindings(prefix)
    end

    private def initialize(
      prepared : BinaryDynamicBulkPlan,
      escaped_prefix : EscapedPrefix,
      limits : BinaryCodecLimits? = nil,
      context : PhysicalStreamPlanContext? = nil,
    )
      @prepared = prepared
      selected_limits = limits || context.try(&.limits) || BinaryBulkCodec::DEFAULT_LIMITS
      if context && limits && !same_limits?(selected_limits, context.limits)
        raise ArgumentError.new("Dynamic physical plan and physical context limits differ")
      end
      @context = context || PhysicalStreamPlanContext.new(selected_limits)
      @sql_budget = BinaryCodecBudget.new(selected_limits, true)
      @data_names = Hash(String, String).new
      @structure_names = Hash(String, String).new
      @prefix_sizes = Hash(String, Int32).new
      @arm_entries = [] of ArmNameEntry
      @arm_names = [] of String
      @site_offsets = [] of Int32
      @site_counts = [] of Int32
      @append_site_cursor = 0
      @name_preflight_complete = false
      @data_role_count = 0_u64
      @structure_role_count = 0_u64
      @prefix_role_count = 0_u64
      @variant_site_count = 0_u64
      @arm_occurrence_count = 0_u64
      @role_bytes = 0_u64
      @prefix_role_bytes = 0_u64
      @physical_name_bytes = 0_u64
      @sql_work_bytes = 0_u64
      @context.preflight_name_bytes(escaped_prefix.value.bytesize.to_u64)
      initialize_bindings(escaped_prefix.value)
    end

    # Composition entry point for a prefix already rendered by the physical
    # filename grammar. Opaque bytes and malformed percent escapes are rejected.
    def self.from_escaped_prefix(
      prepared : BinaryDynamicBulkPlan,
      escaped_prefix : String,
      limits : BinaryCodecLimits? = nil,
      context : PhysicalStreamPlanContext? = nil,
    ) : BinaryDynamicBulkPhysicalPlan
      selected_context = context || PhysicalStreamPlanContext.new(limits || BinaryBulkCodec::DEFAULT_LIMITS)
      selected_context.preflight_name_bytes(escaped_prefix.bytesize.to_u64)
      new(prepared, EscapedPrefix.validated(escaped_prefix), limits, selected_context)
    end

    # Detached role-to-basename snapshots. Structure roles are included in the
    # combined map and retain their `.dynamic_structure` physical suffix.
    def stream_names : Hash(String, String)
      detached = detached_copy(@data_names)
      @structure_names.each do |role, name|
        detached[String.new(role.to_slice)] = String.new(name.to_slice)
      end
      detached
    end

    def data_stream_names : Hash(String, String)
      detached_copy(@data_names)
    end

    def structure_stream_names : Hash(String, String)
      detached_copy(@structure_names)
    end

    def stream_name_for(role : String) : String
      name = @data_names[role]? || @structure_names[role]? ||
             raise(KeyError.new("binary Dynamic physical role not found: #{role.inspect}"))
      String.new(name.to_slice)
    end

    # Prefix metadata belongs only to data lanes; a structure role is not a
    # discriminator or a dictionary stream even though it shares the basename.
    def prefix_size_for(role : String) : Int32
      unless @data_names.has_key?(role)
        raise KeyError.new("binary Dynamic data role not found: #{role.inspect}")
      end
      @prefix_sizes[role]? || 0
    end

    def structure_name_for(site_path : String) : String
      role = "#{site_path}.dynamic_structure"
      name = @structure_names[role]? || raise(KeyError.new("Dynamic structure site not found: #{site_path.inspect}"))
      String.new(name.to_slice)
    end

    def data_file_for(role : String, hashed : Bool = false) : String
      file_for_data_role(role, ".bin", hashed)
    end

    def marks_file_for(role : String, hashed : Bool = false) : String
      file_for_data_role(role, ".mrk2", hashed)
    end

    private def file_for_data_role(role : String, extension : String, hashed : Bool) : String
      name = @data_names[role]? || @structure_names[role]? ||
             raise(KeyError.new("binary Dynamic physical role not found: #{role.inspect}"))
      basename = hashed ? StreamName.hash(name) : String.new(name.to_slice)
      PhysicalStreamName.append_literal(basename, extension)
    end

    private def initialize_bindings(prefix : String) : Nil
      # Pass one validates and counts the complete declared-plus-actual tree.
      # Actual arms are children of their Dynamic occurrence for both depth
      # and node accounting; no name/role roster is built in this pass.
      scan_type(@prepared.type, "root", 0)
      unless @data_role_count == @prepared.role_count
        raise UnsupportedFormatError.new("Dynamic physical data role count does not match its prepared plan")
      end
      unless @structure_role_count == @prepared.site_count.to_u64
        raise UnsupportedFormatError.new("Dynamic physical structure role count does not match its prepared plan")
      end
      ensure_memory_domain!(@variant_site_count, "Dynamic physical Variant site roster")
      ensure_memory_domain!(@arm_occurrence_count, "Dynamic physical Variant arm roster")

      roster_elements = add_size(
        add_size(@data_role_count, @structure_role_count),
        add_size(@prefix_role_count, add_size(@variant_site_count, @arm_occurrence_count))
      )
      @context.record_elements(roster_elements)

      # Pass two measures every escaped SQL component and every physical output
      # bound. The only allocated tables contain bounded type references and
      # numeric bounds; no SQL or final role/name map is materialized yet.
      @arm_entries = Array(ArmNameEntry).new(@arm_occurrence_count.to_i)
      @site_offsets = Array(Int32).new(@variant_site_count.to_i)
      @site_counts = Array(Int32).new(@variant_site_count.to_i)
      @physical_name_bytes = 0_u64
      @sql_work_bytes = 0_u64
      measure_bindings(@prepared.type, "root", prefix.bytesize.to_u64, 0_u64)
      unless @site_offsets.size.to_u64 == @variant_site_count && @arm_entries.size.to_u64 == @arm_occurrence_count
        raise UnsupportedFormatError.new("Dynamic physical SQL name roster changed after measurement")
      end
      @sql_budget.ensure_wire_bytes(@sql_work_bytes)

      retained_bytes = add_size(@role_bytes, @physical_name_bytes)
      retained_bytes = add_size(retained_bytes, @prefix_role_bytes)
      # The escaped root prefix is live during binding, and SQL work is included
      # in the same aggregate physical-byte certificate. These are logical
      # work bounds, not allocator/RSS claims.
      combined_bytes = add_size(prefix.bytesize.to_u64, add_size(retained_bytes, @sql_work_bytes))
      @context.preflight_name_bytes(combined_bytes)

      # The complete aggregate bound has passed before SQL rendering or final
      # role/basename maps are allocated.
      @context.charge_name_bytes(combined_bytes)
      @name_preflight_complete = true
      @arm_names = Array(String).new(@arm_entries.size)
      @arm_entries.each do |entry|
        name = if entry.shared
                 String.new("SharedVariant".to_slice)
               else
                 BinaryTypeNameBudget.materialize(entry.type, @sql_budget, entry.bounds)
               end
        @arm_names << name
      end

      expected_data_roles = @prepared.data_roles
      expected_structure_roles = @prepared.structure_roles
      unless expected_data_roles.size.to_u64 == @data_role_count &&
             expected_structure_roles.size.to_u64 == @structure_role_count
        raise UnsupportedFormatError.new("Dynamic physical prepared role roster changed after preflight")
      end

      @data_names = Hash(String, String).new
      @structure_names = Hash(String, String).new
      @prefix_sizes = Hash(String, Int32).new
      @append_site_cursor = 0
      append_bindings(@prepared.type, "root", prefix, 0_u64)
      unless @append_site_cursor.to_u64 == @variant_site_count
        raise UnsupportedFormatError.new("Dynamic physical binding did not consume every measured Variant site")
      end

      unless @data_names.keys.sort == expected_data_roles.sort
        raise UnsupportedFormatError.new("Dynamic physical data roles do not match the prepared role grammar")
      end
      unless @structure_names.keys.sort == expected_structure_roles.sort
        raise UnsupportedFormatError.new("Dynamic physical structure roles do not match the prepared role grammar")
      end
      unless @data_names.size.to_u64 == @data_role_count && @structure_names.size.to_u64 == @structure_role_count
        raise UnsupportedFormatError.new("Dynamic physical lane count does not match the prepared role grammar")
      end
      unless @prefix_sizes.size.to_u64 == @prefix_role_count
        raise UnsupportedFormatError.new("Dynamic physical prefix roster changed after preflight")
      end

      validate_unique_physical_names!
      validate_actual_byte_bound!(retained_bytes)
      nil
    end

    # Count the complete role grammar and validate descriptors before any
    # count-derived name table or output map is admitted.
    private def scan_type(type : BinaryDataType, path : String, depth : Int) : Nil
      @context.record_type_node(depth)
      metadata_count = type.metadata_entry_count
      @context.record_elements(metadata_count.to_u64) if metadata_count > 0
      child_count = type.child_count
      @context.record_elements(child_count.to_u64) if child_count > 0

      case type.tag
      when BinaryDataType::TAG_DYNAMIC
        arms = @prepared.arm_count(path)
        @context.record_elements(arms.to_u64) if arms > 0
        add_data_role(path, ".discriminators", 8)
        add_structure_role(path)
        add_variant_site(arms.to_u64)
        shared_index = @prepared.shared_index(path)
        arms.times do |index|
          arm = @prepared.arm_type(path, index)
          child = arm_path(path, index)
          scan_type(arm, child, depth + 1)
        end
        if shared_index < 0 || shared_index >= arms
          raise UnsupportedFormatError.new("Dynamic physical shared arm index is outside its prepared roster")
        end
      when BinaryDataType::TAG_VARIANT
        add_data_role(path, ".discriminators", 8)
        add_variant_site(child_count.to_u64)
        child_count.times do |index|
          scan_type(type.child_at(index), arm_path(path, index), depth + 1)
        end
      when BinaryDataType::TAG_STRING
        add_data_role(path, ".data")
        add_data_role(path, ".string_sizes") if @prepared.profile.with_size_stream?
      when BinaryDataType::TAG_ARRAY
        add_data_role(path, ".sizes")
        scan_type(type.child_at(0), child_path(path, ".elements"), depth + 1)
      when BinaryDataType::TAG_NULLABLE
        add_data_role(path, ".nulls")
        scan_type(type.child_at(0), child_path(path, ".nested"), depth + 1)
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        scan_type(type.child_at(0), path, depth + 1)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        if child_count == 0
          add_data_role(path, ".data")
        else
          child_count.times do |index|
            scan_type(type.child_at(index), field_path(path, index), depth + 1)
          end
        end
      when BinaryDataType::TAG_MAP
        add_data_role(path, ".sizes")
        scan_type(type.child_at(0), child_path(path, ".elements.field.0"), depth + 1)
        scan_type(type.child_at(1), child_path(path, ".elements.field.1"), depth + 1)
      when BinaryDataType::TAG_LOW_CARDINALITY
        add_data_role(path, ".dictionary", 8)
        add_data_role(path, ".indexes")
        # LC is a physical stop-site, but its child descriptors still consume
        # the shared descriptor budget just as they do in the static planner.
        # Walk them without adding dictionary-internal physical roles.
        scan_hidden_descriptors(type.child_at(0), depth + 1)
      when BinaryDataType::TAG_NOTHING, BinaryDataType::TAG_BOOL
        add_data_role(path, ".data")
      else
        unless type.fixed_width
          raise UnsupportedFormatError.new("unsupported binary Dynamic physical DataType")
        end
        add_data_role(path, ".data")
      end
      nil
    end

    # Traverse descriptors hidden behind physical stop-sites such as LC. This
    # path deliberately creates no logical path strings or physical bindings.
    private def scan_hidden_descriptors(type : BinaryDataType, depth : Int) : Nil
      @context.record_type_node(depth)
      metadata_count = type.metadata_entry_count
      @context.record_elements(metadata_count.to_u64) if metadata_count > 0
      child_count = type.child_count
      @context.record_elements(child_count.to_u64) if child_count > 0
      child_count.times do |index|
        scan_hidden_descriptors(type.child_at(index), depth + 1)
      end
      nil
    end

    private def measure_bindings(
      type : BinaryDataType,
      path : String,
      prefix_length : UInt64,
      array_level : UInt64,
    ) : Nil
      case type.tag
      when BinaryDataType::TAG_STRING
        add_physical_name(prefix_length)
        if @prepared.profile.with_size_stream?
          add_physical_name(add_size(prefix_length, 5_u64))
        end
      when BinaryDataType::TAG_ARRAY
        add_physical_name(add_size(prefix_length, add_size(5_u64, digit_count(array_level))))
        measure_bindings(type.child_at(0), child_path(path, ".elements"), prefix_length, add_size(array_level, 1_u64))
      when BinaryDataType::TAG_NULLABLE
        add_physical_name(add_size(prefix_length, 5_u64))
        measure_bindings(type.child_at(0), child_path(path, ".nested"), prefix_length, array_level)
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        measure_bindings(type.child_at(0), path, prefix_length, array_level)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        if type.child_count == 0
          add_physical_name(prefix_length)
        else
          type.child_count.times do |index|
            field_suffix = if type.named_tuple?
                             escaped_field_suffix_size(type, index)
                           else
                             add_size(3_u64, digit_count(index.to_u64 + 1_u64))
                           end
            measure_bindings(
              type.child_at(index), field_path(path, index), add_size(prefix_length, field_suffix), array_level
            )
          end
        end
      when BinaryDataType::TAG_MAP
        add_physical_name(add_size(prefix_length, add_size(5_u64, digit_count(array_level))))
        measure_bindings(type.child_at(0), child_path(path, ".elements.field.0"), add_size(prefix_length, 7_u64), add_size(array_level, 1_u64))
        measure_bindings(type.child_at(1), child_path(path, ".elements.field.1"), add_size(prefix_length, 9_u64), add_size(array_level, 1_u64))
      when BinaryDataType::TAG_LOW_CARDINALITY
        add_physical_name(add_size(prefix_length, 5_u64))
        add_physical_name(prefix_length)
      when BinaryDataType::TAG_DYNAMIC
        add_physical_name(add_size(prefix_length, ".dynamic_structure".bytesize.to_u64))
        measure_variant_site(type, path, prefix_length, array_level, true)
      when BinaryDataType::TAG_VARIANT
        measure_variant_site(type, path, prefix_length, array_level, false)
      when BinaryDataType::TAG_NOTHING, BinaryDataType::TAG_BOOL
        add_physical_name(prefix_length)
      else
        unless type.fixed_width
          raise UnsupportedFormatError.new("unsupported binary Dynamic physical DataType")
        end
        add_physical_name(prefix_length)
      end
      nil
    end

    private def measure_variant_site(
      type : BinaryDataType,
      path : String,
      prefix_length : UInt64,
      array_level : UInt64,
      dynamic : Bool,
    ) : Nil
      add_physical_name(add_size(prefix_length, ".variant_discr".bytesize.to_u64))
      offset = @arm_entries.size
      arm_count = dynamic ? @prepared.arm_count(path) : type.child_count
      @site_offsets << offset
      @site_counts << arm_count
      shared_index = dynamic ? @prepared.shared_index(path) : -1

      arm_count.times do |index|
        arm = dynamic ? @prepared.arm_type(path, index) : type.child_at(index)
        shared = dynamic && index == shared_index
        bounds = if shared
                   {"SharedVariant".bytesize.to_u64, 0_u64}
                 else
                   measured = BinaryTypeNameBudget.measure(arm, @sql_budget)
                   @sql_work_bytes = add_size(@sql_work_bytes, measured[1])
                   measured
                 end
        @arm_entries << ArmNameEntry.new(arm, bounds, shared)
      end

      # Reserve this site's complete flat arm span before visiting descendants.
      # Nested Variant/Dynamic sites are appended after it, matching the binding
      # pass's offset-plus-index lookup even when the first arm is recursive.
      arm_count.times do |index|
        entry = @arm_entries[offset + index]
        component_length = if entry.shared
                             "SharedVariant".bytesize.to_u64
                           else
                             multiply_size(entry.bounds[0], 3_u64)
                           end
        arm_prefix_length = add_size(prefix_length, add_size(1_u64, component_length))
        measure_bindings(entry.type, arm_path(path, index), arm_prefix_length, array_level)
      end
      nil
    end

    private def append_bindings(
      type : BinaryDataType,
      path : String,
      prefix : String,
      array_level : UInt64,
    ) : Nil
      case type.tag
      when BinaryDataType::TAG_STRING
        add_data_binding("#{path}.data", String.new(prefix.to_slice))
        if @prepared.profile.with_size_stream?
          add_data_binding("#{path}.string_sizes", PhysicalStreamName.append_literal(prefix, ".size"))
        end
      when BinaryDataType::TAG_ARRAY
        add_data_binding("#{path}.sizes", PhysicalStreamName.append_literal(prefix, ".size#{array_level}"))
        append_bindings(type.child_at(0), child_path(path, ".elements"), prefix, add_size(array_level, 1_u64))
      when BinaryDataType::TAG_NULLABLE
        add_data_binding("#{path}.nulls", PhysicalStreamName.append_literal(prefix, ".null"))
        append_bindings(type.child_at(0), child_path(path, ".nested"), prefix, array_level)
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        append_bindings(type.child_at(0), path, prefix, array_level)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        if type.child_count == 0
          add_data_binding("#{path}.data", String.new(prefix.to_slice))
        else
          type.child_count.times do |index|
            field_name = type.named_tuple? ? type.field_name_at(index) : (index + 1).to_s
            field_prefix = PhysicalStreamName.append_escaped_field(prefix, field_name)
            append_bindings(type.child_at(index), field_path(path, index), field_prefix, array_level)
          end
        end
      when BinaryDataType::TAG_MAP
        add_data_binding("#{path}.sizes", PhysicalStreamName.append_literal(prefix, ".size#{array_level}"))
        keys_prefix = PhysicalStreamName.append_escaped_field(prefix, "keys")
        values_prefix = PhysicalStreamName.append_escaped_field(prefix, "values")
        append_bindings(type.child_at(0), child_path(path, ".elements.field.0"), keys_prefix, add_size(array_level, 1_u64))
        append_bindings(type.child_at(1), child_path(path, ".elements.field.1"), values_prefix, add_size(array_level, 1_u64))
      when BinaryDataType::TAG_LOW_CARDINALITY
        add_data_binding("#{path}.dictionary", PhysicalStreamName.append_literal(prefix, ".dict"))
        add_data_binding("#{path}.indexes", String.new(prefix.to_slice))
        @prefix_sizes[String.new("#{path}.dictionary".to_slice)] = 8
      when BinaryDataType::TAG_DYNAMIC
        add_structure_binding("#{path}.dynamic_structure", PhysicalStreamName.append_literal(prefix, ".dynamic_structure"))
        append_variant_bindings(type, path, prefix, array_level, true)
      when BinaryDataType::TAG_VARIANT
        append_variant_bindings(type, path, prefix, array_level, false)
      when BinaryDataType::TAG_NOTHING, BinaryDataType::TAG_BOOL
        add_data_binding("#{path}.data", String.new(prefix.to_slice))
      else
        unless type.fixed_width
          raise UnsupportedFormatError.new("unsupported binary Dynamic physical DataType")
        end
        add_data_binding("#{path}.data", String.new(prefix.to_slice))
      end
      nil
    end

    private def append_variant_bindings(
      type : BinaryDataType,
      path : String,
      prefix : String,
      array_level : UInt64,
      dynamic : Bool,
    ) : Nil
      role = "#{path}.discriminators"
      add_data_binding(role, PhysicalStreamName.append_literal(prefix, ".variant_discr"))
      @prefix_sizes[String.new(role.to_slice)] = 8

      site = @append_site_cursor
      if site >= @site_offsets.size
        raise UnsupportedFormatError.new("Dynamic physical binding lost its measured Variant site")
      end
      @append_site_cursor += 1
      offset = @site_offsets[site]?
      count = @site_counts[site]?
      unless offset && count
        raise UnsupportedFormatError.new("Dynamic physical binding lost its measured arm roster")
      end
      count.times do |index|
        sql_name = @arm_names[offset + index]
        arm_prefix = PhysicalStreamName.append_escaped_component(prefix, sql_name)
        arm = dynamic ? @prepared.arm_type(path, index) : type.child_at(index)
        append_bindings(arm, arm_path(path, index), arm_prefix, array_level)
      end
      nil
    end

    private def add_data_role(path : String, suffix : String, prefix_size : Int32? = nil) : Nil
      role_length = add_size(path.bytesize.to_u64, suffix.bytesize.to_u64)
      @data_role_count = add_size(@data_role_count, 1_u64)
      @role_bytes = add_size(@role_bytes, role_length)
      if prefix_size
        @prefix_role_count = add_size(@prefix_role_count, 1_u64)
        @prefix_role_bytes = add_size(@prefix_role_bytes, role_length)
      end
      nil
    end

    private def add_structure_role(path : String) : Nil
      @structure_role_count = add_size(@structure_role_count, 1_u64)
      @role_bytes = add_size(@role_bytes, add_size(path.bytesize.to_u64, ".dynamic_structure".bytesize.to_u64))
      nil
    end

    private def add_variant_site(arm_count : UInt64) : Nil
      @variant_site_count = add_size(@variant_site_count, 1_u64)
      @arm_occurrence_count = add_size(@arm_occurrence_count, arm_count)
      nil
    end

    private def add_data_binding(role : String, name : String) : Nil
      if @data_names.has_key?(role) || @structure_names.has_key?(role)
        raise UnsupportedFormatError.new("Dynamic physical roles collide across data and structure maps")
      end
      @data_names[role] = name
    end

    private def add_structure_binding(role : String, name : String) : Nil
      if @data_names.has_key?(role) || @structure_names.has_key?(role)
        raise UnsupportedFormatError.new("Dynamic physical roles collide across data and structure maps")
      end
      @structure_names[role] = name
    end

    private def validate_unique_physical_names! : Nil
      seen = Hash(String, Bool).new
      {@data_names, @structure_names}.each do |bindings|
        bindings.each_value do |name|
          if seen.has_key?(name)
            raise UnsupportedFormatError.new("Dynamic physical roles collide on a physical stream name")
          end
          seen[name] = true
        end
      end
      nil
    end

    private def validate_actual_byte_bound!(expected_retained_bytes : UInt64) : Nil
      actual = 0_u64
      {@data_names, @structure_names}.each do |bindings|
        bindings.each do |role, name|
          actual = add_size(actual, role.bytesize.to_u64)
          actual = add_size(actual, name.bytesize.to_u64)
        end
      end
      @prefix_sizes.each_key do |role|
        actual = add_size(actual, role.bytesize.to_u64)
      end
      unless actual <= expected_retained_bytes
        raise UnsupportedFormatError.new("Dynamic physical names exceeded their aggregate preflight bound")
      end
      nil
    end

    private def detached_copy(source : Hash(String, String)) : Hash(String, String)
      detached = Hash(String, String).new
      source.each do |role, name|
        detached[String.new(role.to_slice)] = String.new(name.to_slice)
      end
      detached
    end

    private def field_path(path : String, index : Int) : String
      indexed_child_path(path, ".field.", index)
    end

    private def arm_path(path : String, index : Int) : String
      indexed_child_path(path, ".arm.", index)
    end

    # Logical traversal paths are temporary work, distinct from retained role
    # keys/output names. Bound each path against the remaining operation byte
    # budget before constructing it; node/edge limits cap the number of paths.
    # This is logical-work accounting, not an aggregate allocator/RSS claim.
    private def child_path(path : String, suffix : String) : String
      length = add_size(path.bytesize.to_u64, suffix.bytesize.to_u64)
      @context.preflight_name_bytes(length) unless @name_preflight_complete
      String.build do |io|
        io << path
        io << suffix
      end
    end

    private def indexed_child_path(path : String, marker : String, index : Int) : String
      suffix_length = add_size(marker.bytesize.to_u64, digit_count(index.to_u64))
      length = add_size(path.bytesize.to_u64, suffix_length)
      @context.preflight_name_bytes(length) unless @name_preflight_complete
      String.build do |io|
        io << path
        io << marker
        io << index
      end
    end

    private def escaped_field_suffix_size(type : BinaryDataType, index : Int) : UInt64
      size = 3_u64
      type.field_name_byte_size(index).times do |byte_index|
        byte = type.field_name_byte_at(index, byte_index)
        size = add_size(size, escaped_word_byte?(byte) ? 1_u64 : 3_u64)
      end
      size
    end

    private def escaped_word_byte?(byte : UInt8) : Bool
      (byte >= 'A'.ord.to_u8 && byte <= 'Z'.ord.to_u8) ||
        (byte >= 'a'.ord.to_u8 && byte <= 'z'.ord.to_u8) ||
        (byte >= '0'.ord.to_u8 && byte <= '9'.ord.to_u8) || byte == '_'.ord.to_u8
    end

    private def add_physical_name(bytes : UInt64) : Nil
      @physical_name_bytes = add_size(@physical_name_bytes, bytes)
    end

    private def digit_count(value : UInt64) : UInt64
      digits = 1_u64
      remaining = value
      while remaining >= 10_u64
        remaining //= 10_u64
        digits += 1_u64
      end
      digits
    end

    private def ensure_memory_domain!(count : UInt64, label : String) : Nil
      if count > Int32::MAX.to_u64
        raise UnsupportedFormatError.new("#{label} exceeds the supported in-memory domain")
      end
      nil
    end

    private def same_limits?(left : BinaryCodecLimits, right : BinaryCodecLimits) : Bool
      left.max_depth == right.max_depth &&
        left.max_nodes == right.max_nodes &&
        left.max_elements == right.max_elements &&
        left.max_bytes == right.max_bytes
    end

    private def add_size(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("Dynamic physical roster size overflows UInt64")
      end
      left + right
    end

    private def multiply_size(left : UInt64, right : UInt64) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        raise UnsupportedFormatError.new("Dynamic physical roster size overflows UInt64")
      end
      left * right
    end
  end
end

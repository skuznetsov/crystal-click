module CrystalClick
  # Immutable schema-owned callback traversal for the bounded recursive
  # Compact JSON slice. Site IDs are structural Tuple/Array paths; physical
  # callback prefixes are independently rendered ClickHouse stream names.
  class CompactRecursiveJsonSchemaPlan
    struct JsonSite
      getter key : String
      getter physical_prefix : String
      getter callback_prefix : String
      getter descriptor : BinaryDataType
      getter descriptor_depth : Int32
      getter array_level : UInt64

      def initialize(
        key : String,
        physical_prefix : String,
        callback_prefix : String,
        @descriptor : BinaryDataType,
        @descriptor_depth : Int32,
        @array_level : UInt64,
      )
        @key = String.new(key.to_slice)
        @physical_prefix = String.new(physical_prefix.to_slice)
        @callback_prefix = String.new(callback_prefix.to_slice)
      end
    end

    struct ArraySite
      getter key : String
      getter physical_prefix : String
      getter callback_name : String
      getter array_level : UInt64

      def initialize(key : String, physical_prefix : String, callback_name : String, @array_level : UInt64)
        @key = String.new(key.to_slice)
        @physical_prefix = String.new(physical_prefix.to_slice)
        @callback_name = String.new(callback_name.to_slice)
      end
    end

    struct UInt8Site
      getter key : String
      getter callback_name : String
      getter type : BinaryDataType

      def initialize(key : String, callback_name : String, @type : BinaryDataType)
        @key = String.new(key.to_slice)
        @callback_name = String.new(callback_name.to_slice)
      end
    end

    struct SiteShape
      getter json_count : UInt64
      getter array_count : UInt64
      getter uint8_count : UInt64
      getter bulk_count : UInt64
      getter bulk_role_count : UInt64
      getter bulk_role_name_bytes : UInt64
      getter node_count : UInt64

      def initialize(
        @json_count : UInt64,
        @array_count : UInt64,
        @uint8_count : UInt64,
        @bulk_count : UInt64,
        @bulk_role_count : UInt64,
        @bulk_role_name_bytes : UInt64,
        @node_count : UInt64,
      )
      end
    end

    getter root_prefix : String

    @schema : StorageColumnSchema
    @limits : BinaryCodecLimits
    @profile : BinaryBulkProfile
    @json_sites : Array(JsonSite)
    @array_sites : Array(ArraySite)
    @uint8_sites : Array(UInt8Site)
    @bulk_sites : Array(CompactRecursiveJsonBulkSite)
    @budget : BinaryCodecBudget

    def self.admitted_schema?(
      schema : StorageColumnSchema,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
      depth : Int32 = 1_i32,
    ) : Bool
      return false unless schema.has_json?
      admitted_schema_node?(schema, limits, depth)
    rescue ex : ArgumentError | UnsupportedFormatError
      false
    end

    private def self.admitted_schema_node?(schema : StorageColumnSchema, limits : BinaryCodecLimits, depth : Int32) : Bool
      return false if depth <= 0 || depth > limits.max_depth
      return true if schema.object?
      return admitted_bulk_schema?(schema, limits, depth) if schema.bulk?
      if schema.array?
        admitted_schema_node?(schema.child_at(0), limits, depth + 1)
      elsif schema.tuple?
        return false if schema.child_count == 0
        schema.child_count.times do |index|
          return false unless admitted_schema_node?(schema.child_at(index), limits, depth + 1)
        end
        true
      else
        false
      end
    end

    private def self.admitted_bulk_schema?(schema : StorageColumnSchema, limits : BinaryCodecLimits, depth : Int32) : Bool
      return false unless schema.bulk?
      type = schema.bulk_type
      !type.contains_json? && !type.contains_dynamic? &&
        CompactRecursiveJsonBulkAdmission.admitted?(type, depth, limits)
    rescue ex : ArgumentError | UnsupportedFormatError
      false
    end

    def self.measure_shape(
      schema : StorageColumnSchema,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
    ) : SiteShape
      if schema.object?
        SiteShape.new(1_u64, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 1_u64)
      elsif schema.bulk?
        type = schema.bulk_type
        if type.tag == BinaryDataType::TAG_UINT8
          SiteShape.new(0_u64, 0_u64, 1_u64, 0_u64, 0_u64, 0_u64, 1_u64)
        else
          SiteShape.new(
            0_u64,
            0_u64,
            0_u64,
            1_u64,
            CompactRecursiveJsonStaticBulkGrammar.measure_role_count(type, profile),
            CompactRecursiveJsonStaticBulkGrammar.measure_role_name_bytes(type, profile, 4_u64),
            1_u64,
          )
        end
      elsif schema.array?
        child = measure_shape(schema.child_at(0), profile)
        SiteShape.new(
          child.json_count,
          checked_measure_add(child.array_count, 1_u64),
          child.uint8_count,
          child.bulk_count,
          child.bulk_role_count,
          child.bulk_role_name_bytes,
          checked_measure_add(child.node_count, 1_u64),
        )
      elsif schema.tuple?
        total = SiteShape.new(0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 0_u64, 1_u64)
        schema.child_count.times do |index|
          child = measure_shape(schema.child_at(index), profile)
          total = SiteShape.new(
            checked_measure_add(total.json_count, child.json_count),
            checked_measure_add(total.array_count, child.array_count),
            checked_measure_add(total.uint8_count, child.uint8_count),
            checked_measure_add(total.bulk_count, child.bulk_count),
            checked_measure_add(total.bulk_role_count, child.bulk_role_count),
            checked_measure_add(total.bulk_role_name_bytes, child.bulk_role_name_bytes),
            checked_measure_add(total.node_count, child.node_count),
          )
        end
        total
      else
        raise UnsupportedFormatError.new("recursive Compact schema shape contains an unsupported node")
      end
    end

    def self.preflight_shape!(
      schema : StorageColumnSchema,
      column_name : String,
      shape : SiteShape,
      budget : BinaryCodecBudget,
    ) : Nil
      site_count = checked_measure_add(
        checked_measure_add(shape.json_count, shape.array_count),
        checked_measure_add(shape.uint8_count, shape.bulk_count),
      )
      root_bytes = PhysicalStreamName.escaped_size(column_name)
      path_strings, path_bytes = measure_path_owners(schema, 4_u64, root_bytes, root_bytes, 0_u64)
      path_strings = checked_measure_add(path_strings, 1_u64)
      path_bytes = checked_measure_add(path_bytes, checked_measure_add(root_bytes, 1_u64))

      # Roster arrays, all site/role owners, and all retained path strings are
      # bounded before any proportional plan vectors or paths are allocated.
      roster_nodes = checked_measure_add(site_count, 4_u64)
      role_nodes = checked_measure_add(shape.bulk_role_count, shape.bulk_count)
      nodes = checked_measure_add(checked_measure_add(roster_nodes, role_nodes), path_strings)
      elements = checked_measure_add(site_count, checked_multiply_measure(shape.bulk_role_count, 2_u64))
      all_wire_bytes = checked_measure_add(path_bytes, shape.bulk_role_name_bytes)
      budget.ensure_future_nodes(nodes)
      budget.ensure_future_elements(elements)
      budget.ensure_wire_bytes(all_wire_bytes)
      charged_nodes = checked_measure_add(roster_nodes, path_strings)
      charged_nodes.times { budget.charge_node }
      budget.charge_elements(site_count) if site_count > 0_u64
      budget.charge_wire_bytes(path_bytes) if path_bytes > 0_u64
      nil
    end

    private def self.measure_path_owners(
      schema : StorageColumnSchema,
      key_bytes : UInt64,
      physical_bytes : UInt64,
      callback_bytes : UInt64,
      array_level : UInt64,
    ) : Tuple(UInt64, UInt64)
      strings = 0_u64
      bytes = 0_u64
      if schema.object?
        strings, bytes = add_path_owner(strings, bytes, key_bytes)
        strings, bytes = add_path_owner(strings, bytes, physical_bytes)
        strings, bytes = add_path_owner(strings, bytes, callback_bytes)
      elsif schema.bulk?
        strings, bytes = add_path_owner(strings, bytes, key_bytes)
        if schema.bulk_type.tag == BinaryDataType::TAG_UINT8
          strings, bytes = add_path_owner(strings, bytes, checked_measure_add(physical_bytes, 5_u64))
        else
          strings, bytes = add_path_owner(strings, bytes, physical_bytes)
        end
      elsif schema.array?
        suffix_bytes = checked_measure_add(5_u64, decimal_digits(array_level))
        strings, bytes = add_path_owner(strings, bytes, key_bytes)
        strings, bytes = add_path_owner(strings, bytes, physical_bytes)
        strings, bytes = add_path_owner(strings, bytes, checked_measure_add(callback_bytes, suffix_bytes))
        child = measure_path_owners(
          schema.child_at(0),
          checked_measure_add(key_bytes, 9_u64),
          physical_bytes,
          callback_bytes,
          checked_measure_add(array_level, 1_u64),
        )
        strings = checked_measure_add(strings, child[0])
        bytes = checked_measure_add(bytes, child[1])
      elsif schema.tuple?
        schema.child_count.times do |index|
          field = schema.named_tuple? ? schema.field_name_at(index) : (index + 1).to_s
          escaped_field = PhysicalStreamName.escaped_size(field)
          child = measure_path_owners(
            schema.child_at(index),
            checked_measure_add(key_bytes, 8_u64 + decimal_digits(index.to_u64)),
            checked_measure_add(physical_bytes, 3_u64 + escaped_field),
            checked_measure_add(callback_bytes, 3_u64 + escaped_field),
            array_level,
          )
          strings = checked_measure_add(strings, child[0])
          bytes = checked_measure_add(bytes, child[1])
        end
      end
      {strings, bytes}
    end

    private def self.add_path_owner(strings : UInt64, bytes : UInt64, string_bytes : UInt64) : Tuple(UInt64, UInt64)
      {
        checked_measure_add(strings, 1_u64),
        checked_measure_add(bytes, checked_measure_add(string_bytes, 1_u64)),
      }
    end

    private def self.decimal_digits(value : UInt64) : UInt64
      digits = 1_u64
      while value >= 10_u64
        value //= 10_u64
        digits += 1_u64
      end
      digits
    end

    private def self.checked_measure_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise UnsupportedFormatError.new("recursive Compact schema site roster exceeds UInt64")
      end
      left + right
    end

    private def self.checked_multiply_measure(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise UnsupportedFormatError.new("recursive Compact schema site roster exceeds UInt64")
      end
      left * right
    end

    def initialize(
      @schema : StorageColumnSchema,
      column_name : String,
      @limits : BinaryCodecLimits,
      @budget : BinaryCodecBudget,
      @profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
    )
      reader_schema = !@budget.writing? && (@schema.tuple? || @schema.array?) && @schema.has_json?
      unless self.class.admitted_schema?(@schema, @limits) && (@budget.writing? || reader_schema)
        raise UnsupportedFormatError.new("recursive Compact JSON schema is outside the bounded static-site subset")
      end
      shape = self.class.measure_shape(@schema, @profile)
      self.class.preflight_shape!(@schema, column_name, shape, @budget)
      context = PhysicalStreamPlanContext.new(@limits)
      @root_prefix = PhysicalStreamName.escape(column_name, context)
      @json_sites = Array(JsonSite).new(shape.json_count.to_i)
      @array_sites = Array(ArraySite).new(shape.array_count.to_i)
      @uint8_sites = Array(UInt8Site).new(shape.uint8_count.to_i)
      @bulk_sites = Array(CompactRecursiveJsonBulkSite).new(shape.bulk_count.to_i)
      append_sites(@schema, @root_prefix, column_name, "root", 1_i32, 0_u64, context)
      if @json_sites.empty?
        raise UnsupportedFormatError.new("recursive Compact JSON schema has no static Object site")
      end
    end

    def json_sites : Array(JsonSite)
      @json_sites.dup
    end

    def json_site_count : Int32
      @json_sites.size
    end

    def array_sites : Array(ArraySite)
      @array_sites.dup
    end

    def array_site_count : Int32
      @array_sites.size
    end

    def uint8_sites : Array(UInt8Site)
      @uint8_sites.dup
    end

    def uint8_site_count : Int32
      @uint8_sites.size
    end

    def bulk_sites : Array(CompactRecursiveJsonBulkSite)
      @bulk_sites.dup
    end

    def bulk_site_count : Int32
      @bulk_sites.size
    end

    def json_site(key : String) : JsonSite
      @json_sites.find { |site| site.key == key } ||
        raise(CorruptPartError.new("recursive Compact JSON schema plan has no such Object site"))
    end

    def array_site(key : String) : ArraySite
      @array_sites.find { |site| site.key == key } ||
        raise(CorruptPartError.new("recursive Compact JSON schema plan has no such Array site"))
    end

    def uint8_site(key : String) : UInt8Site
      @uint8_sites.find { |site| site.key == key } ||
        raise(CorruptPartError.new("recursive Compact JSON schema plan has no such UInt8 site"))
    end

    def bulk_site(key : String) : CompactRecursiveJsonBulkSite
      @bulk_sites.find { |site| site.key == key } ||
        raise(CorruptPartError.new("recursive Compact JSON schema plan has no such Bulk site"))
    end

    # Construct the complete mrk4 callback traversal from phase-owned pieces:
    # every Object prefix, then the serializer-DFS body schedule with each
    # Array size lane immediately before the body below it.
    # mrk3 has no callback labels and uses this only as a detached logical
    # schedule for per-site source validation.
    def expected_event_names(
      prefixes : Hash(String, Array(String)),
      schedules : Hash(String, CompactJsonObjectRoleSchedule),
    ) : Array(String)
      names = Array(String).new
      append_prefix_names(@schema, "root", names, prefixes)
      append_body_names(@schema, "root", names, schedules)
      names
    end

    # Writer counterpart: the inline Object encoder already returns canonical
    # to callback-name pairs, so writer planning need not fabricate reader
    # schedules. Keep the reader-owned overload above unchanged.
    def expected_event_names(
      prefixes : Hash(String, Array(String)),
      body_pairs : Hash(String, Array(ObjectDocumentInlineCallbackOrder::CallbackPair)),
    ) : Array(String)
      names = Array(String).new
      append_prefix_names(@schema, "root", names, prefixes)
      append_body_names(@schema, "root", names, body_pairs)
      names
    end

    # Logical occurrence rows for every schema node in one physical mark.
    # Previously captured Array lanes are consumed only for Array ancestors;
    # P remains the input grid and each child domain is the C sum of its own
    # parent-size lane.
    def mark_site_rows(
      physical_rows : UInt64,
      array_sizes : Hash(String, Array(UInt64)),
    ) : Hash(String, UInt64)
      rows = Hash(String, UInt64).new
      append_mark_rows(@schema, "root", physical_rows, array_sizes, rows)
      rows
    end

    def retained_workspace_bytes : UInt64
      bytes = instance_sizeof(CompactRecursiveJsonSchemaPlan).to_u64
      bytes = checked_add(bytes, string_owner_bytes(@root_prefix))
      bytes = checked_add(bytes, instance_sizeof(Array(JsonSite)).to_u64)
      bytes = checked_add(bytes, checked_multiply(@json_sites.size.to_u64, sizeof(JsonSite).to_u64))
      @json_sites.each do |site|
        bytes = checked_add(bytes, string_owner_bytes(site.key))
        bytes = checked_add(bytes, string_owner_bytes(site.physical_prefix))
        bytes = checked_add(bytes, string_owner_bytes(site.callback_prefix))
        bytes = checked_add(bytes, instance_sizeof(BinaryDataType).to_u64)
      end
      bytes = checked_add(bytes, instance_sizeof(Array(ArraySite)).to_u64)
      bytes = checked_add(bytes, checked_multiply(@array_sites.size.to_u64, sizeof(ArraySite).to_u64))
      @array_sites.each do |site|
        bytes = checked_add(bytes, string_owner_bytes(site.key))
        bytes = checked_add(bytes, string_owner_bytes(site.physical_prefix))
        bytes = checked_add(bytes, string_owner_bytes(site.callback_name))
      end
      bytes = checked_add(bytes, instance_sizeof(Array(UInt8Site)).to_u64)
      bytes = checked_add(bytes, checked_multiply(@uint8_sites.size.to_u64, sizeof(UInt8Site).to_u64))
      @uint8_sites.each do |site|
        bytes = checked_add(bytes, string_owner_bytes(site.key))
        bytes = checked_add(bytes, string_owner_bytes(site.callback_name))
        bytes = checked_add(bytes, instance_sizeof(BinaryDataType).to_u64)
      end
      bytes = checked_add(bytes, instance_sizeof(Array(CompactRecursiveJsonBulkSite)).to_u64)
      bytes = checked_add(bytes, checked_multiply(@bulk_sites.size.to_u64, sizeof(Pointer(CompactRecursiveJsonBulkSite)).to_u64))
      @bulk_sites.each { |site| bytes = checked_add(bytes, site.retained_workspace_bytes) }
      bytes
    end

    private def append_sites(
      schema : StorageColumnSchema,
      physical_prefix : String,
      callback_prefix : String,
      key : String,
      descriptor_depth : Int32,
      array_level : UInt64,
      context : PhysicalStreamPlanContext,
    ) : Nil
      if schema.object?
        descriptor = BinaryRecursiveDataTypeNameReader.parse_canonical_with_budget(
          schema.object_schema.declaration,
          @budget,
          descriptor_depth,
        ) || raise(UnsupportedFormatError.new("recursive Compact JSON Object descriptor is not canonical"))
        @json_sites << JsonSite.new(key, physical_prefix, callback_prefix, descriptor, descriptor_depth, array_level)
      elsif schema.bulk?
        type = schema.bulk_type
        unless !type.contains_json? && !type.contains_dynamic? &&
               CompactRecursiveJsonBulkAdmission.admitted?(type, descriptor_depth, @limits)
          raise UnsupportedFormatError.new("recursive Compact opaque Bulk subtree is outside the bounded static grammar")
        end
        bulk_plan = BinaryBulkPhysicalPlan.from_escaped_prefix(
          type,
          physical_prefix,
          @profile,
          @limits,
          context,
          array_level,
        )
        if type.tag == BinaryDataType::TAG_UINT8
          @uint8_sites << UInt8Site.new(key, bulk_plan.stream_name_for("root.data"), type)
        else
          site = CompactRecursiveJsonBulkSite.new(
            key,
            physical_prefix,
            descriptor_depth,
            array_level,
            type,
            bulk_plan,
            @limits,
            @budget,
          )
          @bulk_sites << site
        end
      elsif schema.array?
        array_name = PhysicalStreamName.append_literal(callback_prefix, ".size#{array_level}", context)
        @array_sites << ArraySite.new(key, physical_prefix, array_name, array_level)
        child_key = array_child_key(key)
        child_level = checked_level_add(array_level, 1_u64)
        append_sites(schema.child_at(0), physical_prefix, callback_prefix, child_key, checked_depth_add(descriptor_depth), child_level, context)
      elsif schema.tuple?
        schema.child_count.times do |index|
          field = schema.named_tuple? ? schema.field_name_at(index) : (index + 1).to_s
          child_prefix = PhysicalStreamName.append_escaped_field(physical_prefix, field, context)
          child_callback_prefix = PhysicalStreamName.append_escaped_field(callback_prefix, field, context)
          append_sites(
            schema.child_at(index),
            child_prefix,
            child_callback_prefix,
            tuple_child_key(key, index),
            checked_depth_add(descriptor_depth),
            array_level,
            context,
          )
        end
      else
        raise UnsupportedFormatError.new("recursive Compact JSON schema contains an unsupported node")
      end
      nil
    end

    private def append_mark_rows(
      schema : StorageColumnSchema,
      key : String,
      rows : UInt64,
      array_sizes : Hash(String, Array(UInt64)),
      output : Hash(String, UInt64),
    ) : Nil
      output[key] = rows
      if schema.tuple?
        schema.child_count.times do |index|
          append_mark_rows(schema.child_at(index), tuple_child_key(key, index), rows, array_sizes, output)
        end
      elsif schema.array?
        sizes = array_sizes[key]? ||
                raise(CorruptPartError.new("recursive Compact Array size lane was not captured before its child schedule"))
        unless sizes.size.to_u64 == rows
          raise CorruptPartError.new("recursive Compact Array size lane differs from its inherited parent rows")
        end
        children = 0_u64
        sizes.each do |size|
          if size > Int32::MAX.to_u64 || children > UInt64::MAX - size
            raise CorruptPartError.new("recursive Compact Array child occurrence count exceeds its domain")
          end
          children += size
        end
        if children > Int32::MAX.to_u64
          raise CorruptPartError.new("recursive Compact Array child occurrence count exceeds Int32")
        end
        append_mark_rows(schema.child_at(0), array_child_key(key), children, array_sizes, output)
      end
      nil
    end

    private def append_body_names(
      schema : StorageColumnSchema,
      key : String,
      output : Array(String),
      schedules : Hash(String, CompactJsonObjectRoleSchedule),
    ) : Nil
      if schema.object?
        schedule = schedules[key]? ||
                   raise(CorruptPartError.new("recursive Compact Object body schedule is missing"))
        schedule.body_events.each { |_owner, _canonical, callback| output << String.new(callback.to_slice) }
      elsif schema.bulk?
        type = schema.bulk_type
        if type.tag == BinaryDataType::TAG_UINT8
          output << String.new(uint8_site(key).callback_name.to_slice)
        else
          bulk_site(key).each_role do |role|
            output << String.new(bulk_site(key).callback_name_for(role.name).to_slice)
          end
        end
      elsif schema.array?
        output << String.new(array_site(key).callback_name.to_slice)
        append_body_names(schema.child_at(0), array_child_key(key), output, schedules)
      elsif schema.tuple?
        schema.child_count.times do |index|
          append_body_names(schema.child_at(index), tuple_child_key(key, index), output, schedules)
        end
      end
      nil
    end

    private def append_prefix_names(
      schema : StorageColumnSchema,
      key : String,
      output : Array(String),
      prefixes : Hash(String, Array(String)),
    ) : Nil
      if schema.object?
        callbacks = prefixes[key]? ||
                    raise(CorruptPartError.new("recursive Compact Object prefix schedule is missing"))
        callbacks.each { |name| output << String.new(name.to_slice) }
      elsif schema.bulk?
        unless schema.bulk_type.tag == BinaryDataType::TAG_UINT8
          site = bulk_site(key)
          site.prefix_role_count.times do |index|
            output << String.new(site.prefix_callback_name_at(index).to_slice)
          end
        end
      elsif schema.array?
        append_prefix_names(schema.child_at(0), array_child_key(key), output, prefixes)
      elsif schema.tuple?
        schema.child_count.times do |index|
          append_prefix_names(schema.child_at(index), tuple_child_key(key, index), output, prefixes)
        end
      end
      nil
    end

    private def append_body_names(
      schema : StorageColumnSchema,
      key : String,
      output : Array(String),
      body_pairs : Hash(String, Array(ObjectDocumentInlineCallbackOrder::CallbackPair)),
    ) : Nil
      if schema.object?
        pairs = body_pairs[key]? ||
                raise(CorruptPartError.new("recursive Compact Object body schedule is missing"))
        pairs.each { |_canonical, callback| output << String.new(callback.to_slice) }
      elsif schema.bulk?
        type = schema.bulk_type
        if type.tag == BinaryDataType::TAG_UINT8
          output << String.new(uint8_site(key).callback_name.to_slice)
        else
          bulk_site(key).each_role do |role|
            output << String.new(bulk_site(key).callback_name_for(role.name).to_slice)
          end
        end
      elsif schema.array?
        output << String.new(array_site(key).callback_name.to_slice)
        append_body_names(schema.child_at(0), array_child_key(key), output, body_pairs)
      elsif schema.tuple?
        schema.child_count.times do |index|
          append_body_names(schema.child_at(index), tuple_child_key(key, index), output, body_pairs)
        end
      end
      nil
    end

    private def tuple_child_key(parent : String, index : Int) : String
      String.build { |io| io << parent << "/tuple[" << index << ']' }
    end

    private def array_child_key(parent : String) : String
      String.build { |io| io << parent << "/array[0]" }
    end

    private def checked_depth_add(value : Int32) : Int32
      if value == Int32::MAX || value + 1 > @limits.max_depth
        raise UnsupportedFormatError.new("recursive Compact Object descriptor depth exceeds its configured limit")
      end
      value + 1
    end

    private def checked_level_add(value : UInt64, amount : UInt64) : UInt64
      if amount > UInt64::MAX - value || value + amount > Int32::MAX.to_u64
        raise UnsupportedFormatError.new("recursive Compact Array level exceeds its supported domain")
      end
      value + amount
    end

    private def string_owner_bytes(value : String) : UInt64
      checked_add(instance_sizeof(String).to_u64, value.bytesize.to_u64 + 1_u64)
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise UnsupportedFormatError.new("recursive Compact schema workspace exceeds UInt64")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise UnsupportedFormatError.new("recursive Compact schema workspace exceeds UInt64")
      end
      left * right
    end
  end
end

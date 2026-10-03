module CrystalClick
  # Binds the W125 Object metadata, typed paths, Dynamic alternatives, and
  # shared MAP lanes into one collision-checked physical filename roster.
  class ObjectDocumentPhysicalPlan
    @object_structure_stream : String
    @dynamic_structure_streams : Hash(String, String)
    @discriminator_streams : Hash(String, String)
    @typed_plans : Hash(String, BinaryBulkPhysicalPlan)
    @dynamic_arm_plans : Hash(String, Hash(String, BinaryBulkPhysicalPlan))
    @shared_plan : BinaryBulkPhysicalPlan
    @stream_count : Int32

    def initialize(
      column_name : String,
      plan : ObjectDocumentPlan,
      @profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      shared_profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
    )
      object = plan.structures.object
      unless object.version == 4_u64 && object.shared_data_version == 0_u64 && object.bucket_count == 1_u64
        raise UnsupportedFormatError.new("physical Object planning admits only V3 MAP with one shared-data bucket")
      end

      context = PhysicalStreamPlanContext.new(limits)
      total_records = add_size(plan.typed_path_count.to_u64, object.dynamic_path_count.to_u64)
      context.record_elements(total_records)

      context.preflight_name_bytes(PhysicalStreamName.escaped_size(column_name))
      column_prefix = PhysicalStreamName.escape(column_name)
      seen_names = Hash(String, Bool).new

      @object_structure_stream = PhysicalStreamName.append_literal(column_prefix, ".object_structure", context)
      context.charge_name_bytes(@object_structure_stream.bytesize.to_u64)
      reject_collision!(@object_structure_stream, seen_names)

      @dynamic_structure_streams = Hash(String, String).new
      @discriminator_streams = Hash(String, String).new
      @dynamic_arm_plans = Hash(String, Hash(String, BinaryBulkPhysicalPlan)).new
      object.dynamic_path_count.times do |index|
        preflight_object_path(object, index, column_prefix.bytesize.to_u64, context)
        raw_path = object.dynamic_path_at(index)
        path_prefix = PhysicalStreamName.append_escaped_component(column_prefix, raw_path, context)
        structure_name = PhysicalStreamName.append_literal(path_prefix, ".dynamic_structure", context)
        discriminator_name = PhysicalStreamName.append_literal(path_prefix, ".variant_discr", context)
        context.charge_name_bytes(add_size(structure_name.bytesize.to_u64, discriminator_name.bytesize.to_u64))
        reject_collision!(structure_name, seen_names)
        reject_collision!(discriminator_name, seen_names)
        @dynamic_structure_streams[String.new(raw_path.to_slice)] = structure_name
        @discriminator_streams[String.new(raw_path.to_slice)] = discriminator_name

        dynamic = plan.structures.dynamic_for(raw_path)
        context.record_elements(dynamic.canonical_variant_count.to_u64)
        arm_plans = Hash(String, BinaryBulkPhysicalPlan).new
        shared_string = BinaryDataType.primitive("String")
        shared_prefix = PhysicalStreamName.append_escaped_component(path_prefix, DynamicStructure::SHARED_VARIANT_NAME, context)
        shared_arm = BinaryBulkPhysicalPlan.from_escaped_prefix(shared_string, shared_prefix, @profile, limits, context)
        arm_plans[String.new(DynamicStructure::SHARED_VARIANT_NAME.to_slice)] = shared_arm
        collect_plan_names!(shared_arm, seen_names)

        dynamic.type_count.times do |type_index|
          type = dynamic.type_at(type_index)
          preflight_dynamic_type(type, limits.max_depth, 0, context, 0_u64, 0_u64)
          name_bound = display_name_bound(type, limits.max_depth, 0)
          escaped_name_bound = multiply_size(name_bound, 3_u64)
          context.preflight_name_bytes(escaped_name_bound)
          context.preflight_name_bytes(add_size(path_prefix.bytesize.to_u64, add_size(1_u64, escaped_name_bound)))

          arm_name = type.name
          unless arm_name.bytesize.to_u64 <= name_bound
            raise UnsupportedFormatError.new("Dynamic SQL display name exceeded its metadata preflight bound")
          end
          context.charge_name_bytes(arm_name.bytesize.to_u64)
          if arm_plans.has_key?(arm_name)
            raise UnsupportedFormatError.new("Dynamic alternatives collide on SQL display name")
          end
          arm_prefix = PhysicalStreamName.append_escaped_component(path_prefix, arm_name, context)
          arm_plan = BinaryBulkPhysicalPlan.from_escaped_prefix(type, arm_prefix, @profile, limits, context)
          arm_plans[String.new(arm_name.to_slice)] = arm_plan
          collect_plan_names!(arm_plan, seen_names)
        end
        @dynamic_arm_plans[String.new(raw_path.to_slice)] = arm_plans
      end

      @typed_plans = Hash(String, BinaryBulkPhysicalPlan).new
      plan.typed_path_count.times do |index|
        preflight_typed_path(plan, index, column_prefix.bytesize.to_u64, context)
        raw_path = plan.typed_path_at(index)
        path_prefix = PhysicalStreamName.append_escaped_component(column_prefix, raw_path, context)
        type = plan.typed_type_for(raw_path)
        typed_plan = BinaryBulkPhysicalPlan.from_escaped_prefix(type, path_prefix, @profile, limits, context)
        @typed_plans[String.new(raw_path.to_slice)] = typed_plan
        collect_plan_names!(typed_plan, seen_names)
      end

      shared_type = BinaryDataType.array(
        BinaryDataType.tuple(
          [BinaryDataType.primitive("String"), BinaryDataType.primitive("String")],
          ["paths", "values"]
        )
      )
      shared_prefix = PhysicalStreamName.append_literal(column_prefix, ".object_shared_data", context)
      @shared_plan = BinaryBulkPhysicalPlan.from_escaped_prefix(shared_type, shared_prefix, shared_profile, limits, context)
      collect_plan_names!(@shared_plan, seen_names)
      @stream_count = seen_names.size.to_i32
    end

    def object_structure_stream : String
      String.new(@object_structure_stream.to_slice)
    end

    def dynamic_structure_stream(path : String) : String
      name = @dynamic_structure_streams[path]? || raise(KeyError.new("Dynamic Object path not found: #{path.inspect}"))
      String.new(name.to_slice)
    end

    def discriminator_stream(path : String) : String
      name = @discriminator_streams[path]? || raise(KeyError.new("Dynamic Object path not found: #{path.inspect}"))
      String.new(name.to_slice)
    end

    def typed(path : String) : BinaryBulkPhysicalPlan
      @typed_plans[path]? || raise(KeyError.new("typed Object path not found: #{path.inspect}"))
    end

    def dynamic_arm(path : String, arm_name : String) : BinaryBulkPhysicalPlan
      arms = @dynamic_arm_plans[path]? || raise(KeyError.new("Dynamic Object path not found: #{path.inspect}"))
      arms[arm_name]? || raise(KeyError.new("Dynamic alternative not found: #{arm_name.inspect}"))
    end

    def shared : BinaryBulkPhysicalPlan
      @shared_plan
    end

    # Scalar count from the collision-checked construction roster. This lets
    # callers enforce entry caps before materializing the detached name list.
    def stream_count : Int32
      @stream_count
    end

    # The roster is detached and sorted; Object plans deliberately expose
    # basenames only, not guessed hashed aliases or extensions.
    def stream_names : Array(String)
      names = [] of String
      names << String.new(@object_structure_stream.to_slice)
      @dynamic_structure_streams.each_value { |name| names << String.new(name.to_slice) }
      @discriminator_streams.each_value { |name| names << String.new(name.to_slice) }
      @typed_plans.each_value do |physical|
        physical.stream_names.each_value { |name| names << String.new(name.to_slice) }
      end
      @dynamic_arm_plans.each_value do |arms|
        arms.each_value do |physical|
          physical.stream_names.each_value { |name| names << String.new(name.to_slice) }
        end
      end
      @shared_plan.stream_names.each_value { |name| names << String.new(name.to_slice) }
      names.sort!
      names
    end

    private def collect_plan_names!(plan : BinaryBulkPhysicalPlan, seen : Hash(String, Bool)) : Nil
      plan.stream_names.each_value do |name|
        reject_collision!(name, seen)
      end
      nil
    end

    private def reject_collision!(name : String, seen : Hash(String, Bool)) : Nil
      if seen.has_key?(name)
        raise UnsupportedFormatError.new("Object lanes collide on a physical stream name")
      end
      seen[name] = true
      nil
    end

    # Validate recursive descriptor work without consuming context counters.
    # The nested plan charges it once after this check and the SQL-name bound.
    private def preflight_dynamic_type(
      type : BinaryDataType,
      maximum_depth : Int,
      depth : Int,
      context : PhysicalStreamPlanContext,
      prior_nodes : UInt64,
      prior_elements : UInt64,
    ) : {UInt64, UInt64}
      if depth > maximum_depth
        raise UnsupportedFormatError.new("physical stream type depth exceeds configured limit")
      end
      # The physical Dynamic plan has no LowCardinality dictionary/index
      # roles. Refuse the descriptor during this bounded recursive walk,
      # before this planner's display-name bound and rendering step.
      if type.tag == BinaryDataType::TAG_LOW_CARDINALITY
        raise UnsupportedFormatError.new(
          "physical Object Dynamic LowCardinality alternatives are not admitted"
        )
      end
      metadata = type.metadata_entry_count
      children = type.child_count
      elements = metadata.to_u64 + children.to_u64
      nodes = 1_u64
      context.preflight_type_budget(add_size(prior_nodes, nodes), add_size(prior_elements, elements))
      children.times do |index|
        child_nodes, child_elements = preflight_dynamic_type(
          type.child_at(index), maximum_depth, depth + 1, context,
          add_size(prior_nodes, nodes), add_size(prior_elements, elements)
        )
        nodes = add_size(nodes, child_nodes)
        elements = add_size(elements, child_elements)
      end
      {nodes, elements}
    end

    # Conservative but metadata-aware SQL display length. In particular,
    # opaque Tuple field bytes, Enum labels/count, and timezone bytes are all
    # bounded before BinaryDataType#name recursively materializes anything.
    private def display_name_bound(type : BinaryDataType, maximum_depth : Int, depth : Int) : UInt64
      if depth > maximum_depth
        raise UnsupportedFormatError.new("Dynamic SQL display name exceeds configured type depth")
      end
      case type.tag
      when BinaryDataType::TAG_ARRAY
        add_size(7_u64, display_name_bound(type.child_at(0), maximum_depth, depth + 1))
      when BinaryDataType::TAG_NULLABLE
        add_size(10_u64, display_name_bound(type.child_at(0), maximum_depth, depth + 1))
      when BinaryDataType::TAG_MAP
        add_size(7_u64, add_size(display_name_bound(type.child_at(0), maximum_depth, depth + 1), display_name_bound(type.child_at(1), maximum_depth, depth + 1)))
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        total = 7_u64
        type.child_count.times do |index|
          total = add_size(total, display_name_bound(type.child_at(index), maximum_depth, depth + 1))
          total = add_size(total, 2_u64) if index > 0
          if type.named_tuple?
            total = add_size(total, add_size(multiply_size(type.field_name_byte_size(index).to_u64, 2_u64), 3_u64))
          end
        end
        total
      when BinaryDataType::TAG_ENUM8, BinaryDataType::TAG_ENUM16
        definition = type.enum_definition.not_nil!
        total = add_size(8_u64, multiply_size(definition.size.to_u64, 13_u64))
        definition.size.times do |index|
          total = add_size(total, multiply_size(definition.label_byte_size(index).to_u64, 2_u64))
        end
        total
      when BinaryDataType::TAG_DATETIME, BinaryDataType::TAG_DATETIME_ZONE,
           BinaryDataType::TAG_DATETIME64, BinaryDataType::TAG_DATETIME64_ZONE,
           BinaryDataType::TAG_TIME64
        zone_bytes = (type.temporal_type.not_nil!.time_zone?.try(&.name.bytesize) || 0).to_u64
        add_size(48_u64, zone_bytes)
      when BinaryDataType::TAG_DECIMAL32, BinaryDataType::TAG_DECIMAL64,
           BinaryDataType::TAG_DECIMAL128, BinaryDataType::TAG_DECIMAL256
        32_u64
      when BinaryDataType::TAG_FIXED_STRING
        13_u64 + digit_count(type.fixed_size.not_nil!.to_u64)
      else
        16_u64
      end
    end

    private def digit_count(value : UInt64) : UInt64
      digits = 1_u64
      while value >= 10_u64
        value //= 10_u64
        digits += 1_u64
      end
      digits
    end

    private def preflight_object_path(object : ObjectStructure, index : Int, column_length : UInt64, context : PhysicalStreamPlanContext) : Nil
      raw_size = object.dynamic_path_byte_size(index)
      escaped_size = PhysicalStreamName.escaped_size(raw_size) { |byte_index| object.dynamic_path_byte_at(index, byte_index) }
      context.preflight_name_bytes(add_size(column_length, add_size(1_u64, escaped_size)))
      nil
    end

    private def preflight_typed_path(plan : ObjectDocumentPlan, index : Int, column_length : UInt64, context : PhysicalStreamPlanContext) : Nil
      raw_size = plan.typed_path_byte_size_at(index)
      escaped_size = PhysicalStreamName.escaped_size(raw_size) { |byte_index| plan.typed_path_byte_at(index, byte_index) }
      context.preflight_name_bytes(add_size(column_length, add_size(1_u64, escaped_size)))
      nil
    end

    private def multiply_size(left : UInt64, right : UInt64) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        raise UnsupportedFormatError.new("physical Object plan size overflows UInt64")
      end
      left * right
    end

    private def add_size(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("physical Object plan size overflows UInt64")
      end
      left + right
    end
  end
end

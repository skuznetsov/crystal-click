module CrystalClick
  # Paired Compact Object per-path Data serializer. Dynamic structures, typed
  # discriminators, and ordinary recursive lanes share one caller budget and
  # are emitted in the source callback order rather than sorted role order.
  module ObjectSharedPathCodec
    COMPACT_PROFILE               = BinaryBulkProfile.with_size_stream
    LOW_CARDINALITY_VERSION_BYTES = OBJECT_SHARED_PATH_LOW_CARDINALITY_VERSION_BYTES

    private struct Emission
      getter name : String
      getter role : String?
      getter structure_path : String?
      getter start : Int32
      getter size : Int32

      def initialize(
        @name : String,
        @role : String?,
        @structure_path : String?,
        @start : Int32,
        @size : Int32,
      )
      end
    end

    def self.encode(
      type : BinaryDataType,
      structures : Hash(String, DynamicStructure),
      rows : Array(BinaryValue),
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
      profile : BinaryBulkProfile = COMPACT_PROFILE,
    ) : ObjectSharedPathStreams
      encode_with_budget(type, structures, rows, BinaryCodecBudget.new(limits, true), profile)
    end

    def self.encode_with_budget(
      type : BinaryDataType,
      structures : Hash(String, DynamicStructure),
      rows : Array(BinaryValue),
      budget : BinaryCodecBudget,
      profile : BinaryBulkProfile = COMPACT_PROFILE,
    ) : ObjectSharedPathStreams
      unless budget.writing?
        raise ArgumentError.new("Object shared path encode requires a write-direction budget")
      end
      unless type.contains_dynamic?
        raise ArgumentError.new("Object shared path codec requires a Dynamic root")
      end
      unless type.tag == BinaryDataType::TAG_DYNAMIC
        raise UnsupportedFormatError.new("Object shared path root must be a Dynamic descriptor")
      end
      if rows.size > Int32::MAX
        raise UnsupportedFormatError.new("Object shared path row count exceeds the supported domain")
      end

      plan = BinaryDynamicBulkPlan.new_with_prefix_without_statistics(type, structures, budget, profile)
      structure_streams = plan.encode_structure_prefix_streams_without_statistics(budget)
      data_streams = BinaryBulkEncoder.encode(
        type,
        [rows] of Array(BinaryValue),
        budget,
        profile,
        plan,
        low_cardinality_policy: BinaryLowCardinalityStoragePolicy::AdditionalKeysOnly,
      )
      role_names = planned_roles(plan, budget)
      compact_lanes = prepare_compact_lanes(role_names, data_streams, budget)
      physical_lanes = write_compact_lanes(compact_lanes, budget)

      emissions = [] of Emission
      emit_prefix_type(type, "root", "", 0, plan, structure_streams, data_streams, physical_lanes, emissions, budget)
      emit_type(type, "root", "", 0, plan, structure_streams, data_streams, physical_lanes, emissions, budget, profile)
      materialize(emissions, role_names, structure_streams, data_streams, physical_lanes, budget)
    end

    def self.decode(
      data : Bytes,
      events : Array(ObjectSharedPathSubstreamEvent),
      row_count : Int,
      type : BinaryDataType,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
      profile : BinaryBulkProfile = COMPACT_PROFILE,
    ) : Array(BinaryValue)
      decode_with_budget(data, events, row_count, type, BinaryCodecBudget.new(limits), profile)
    end

    def self.decode_with_budget(
      data : Bytes,
      events : Array(ObjectSharedPathSubstreamEvent),
      row_count : Int,
      type : BinaryDataType,
      budget : BinaryCodecBudget,
      profile : BinaryBulkProfile = COMPACT_PROFILE,
    ) : Array(BinaryValue)
      decode_with_structures_with_budget(data, events, row_count, type, budget, profile).rows
    end

    def self.decode_with_structures_with_budget(
      data : Bytes,
      events : Array(ObjectSharedPathSubstreamEvent),
      row_count : Int,
      type : BinaryDataType,
      budget : BinaryCodecBudget,
      profile : BinaryBulkProfile = COMPACT_PROFILE,
    ) : ObjectSharedPathDecodeResult
      if budget.writing?
        raise ArgumentError.new("Object shared path decode requires a read-direction budget")
      end
      unless type.contains_dynamic?
        raise ArgumentError.new("Object shared path codec requires a Dynamic root")
      end
      unless type.tag == BinaryDataType::TAG_DYNAMIC
        raise UnsupportedFormatError.new("Object shared path root must be a Dynamic descriptor")
      end
      unless row_count >= 0 && row_count <= Int32::MAX
        raise CorruptPartError.new("Object shared path row count is outside the supported domain")
      end

      count = row_count.to_u64
      budget.ensure_future_nodes(count)
      budget.ensure_future_elements(count)
      budget.ensure_wire_bytes(data.size.to_u64)
      budget.charge_wire_bytes(data.size.to_u64)

      reader = ObjectSharedPathTapeReader.new(data, events, budget)
      decode_prefix_type(type, "root", "", 0, 1, reader, budget)
      decode_type(type, "root", "", 0, reader, budget, profile)
      reader.finish!
      structure_streams = reader.build_structure_streams
      plan = BinaryDynamicBulkPlan.decode_structure_prefix_streams_without_statistics(
        type,
        structure_streams,
        budget,
        profile,
      )
      lanes = reader.bulk_streams
      rows_per_mark = [count] of UInt64
      decoded = BinaryBulkDecoder.decode(type, lanes, rows_per_mark, budget, 0, 1, profile, plan)
      unless decoded.size == 1 && decoded[0].size == row_count
        raise CorruptPartError.new("Object shared path root row count disagrees with the decoded value domain")
      end

      retained_path_work = 0_u64
      structures = reader.structures
      structures.each_key do |path|
        retained_path_work = checked_add(retained_path_work, path.bytesize.to_u64, false)
      end
      retained_result_work = checked_add(row_count.to_u64, retained_path_work, false)
      retained_result_work = checked_add(retained_result_work, structures.size.to_u64, false)
      budget.ensure_future_nodes(1_u64)
      budget.ensure_future_elements(retained_result_work)
      budget.charge_node
      budget.charge_elements(retained_result_work)
      ObjectSharedPathDecodeResult.new(decoded[0], structures)
    end

    private def self.planned_roles(
      plan : BinaryDynamicBulkPlan,
      budget : BinaryCodecBudget,
    ) : Array(String)
      count = plan.role_count
      budget.ensure_future_elements(count)
      budget.charge_elements(count)
      roles = plan.data_roles
      unless roles.size.to_u64 == count
        raise UnsupportedFormatError.new("Object shared path planned role count changed")
      end
      roles
    end

    private def self.prepare_compact_lanes(
      roles : Array(String),
      streams : BinaryBulkStreams,
      budget : BinaryCodecBudget,
    ) : Array(Tuple(String, BinaryBulkStream, UInt64))
      count = 0_u64
      roles.each { |role| count += 1_u64 if role.ends_with?(".discriminators") }
      budget.ensure_future_elements(count)
      budget.charge_elements(count)
      lanes = Array(Tuple(String, BinaryBulkStream, UInt64)).new(count.to_i)
      roles.each do |role|
        next unless role.ends_with?(".discriminators")
        lanes << {role, streams.stream(role), DynamicDiscriminatorBodyValidator::COMPACT_MODE}
      end
      lanes
    end

    private def self.write_compact_lanes(
      lanes : Array(Tuple(String, BinaryBulkStream, UInt64)),
      budget : BinaryCodecBudget,
    ) : Hash(String, Bytes)
      BinaryBulkDiscriminatorFramingAdapter.preflight_write(lanes, budget)
      result = Hash(String, Bytes).new
      lanes.each do |lane|
        physical, _offsets, _prefix_size = BinaryBulkDiscriminatorFramingAdapter.write_lane(lane[0], lane[1], lane[2])
        result[lane[0]] = physical
      end
      result
    end

    private def self.emit_type(
      type : BinaryDataType,
      path : String,
      physical_prefix : String,
      array_level : Int32,
      plan : BinaryDynamicBulkPlan,
      structures : BinaryDynamicStructureStreams,
      streams : BinaryBulkStreams,
      physical_lanes : Hash(String, Bytes),
      emissions : Array(Emission),
      budget : BinaryCodecBudget,
      profile : BinaryBulkProfile,
    ) : Nil
      case type.tag
      when BinaryDataType::TAG_DYNAMIC
        role = logical_name(path, ".discriminators", budget)
        body_name = append_name(physical_prefix, ".variant_discr", budget)
        add_discriminator_body_emission(emissions, role, body_name, physical_lanes, budget)
        plan.arm_count(path).times do |index|
          arm = plan.arm_type(path, index)
          child = indexed_path(path, ".arm.", index, budget)
          if index == plan.shared_index(path)
            arm_prefix = append_name(physical_prefix, ".SharedVariant", budget)
          else
            arm_prefix = append_type_component(physical_prefix, arm, budget)
          end
          emit_type(arm, child, arm_prefix, array_level, plan, structures, streams, physical_lanes, emissions, budget, profile)
        end
      when BinaryDataType::TAG_VARIANT
        role = logical_name(path, ".discriminators", budget)
        body_name = append_name(physical_prefix, ".variant_discr", budget)
        add_discriminator_body_emission(emissions, role, body_name, physical_lanes, budget)
        type.child_count.times do |index|
          arm = type.child_at(index)
          child = indexed_path(path, ".arm.", index, budget)
          arm_prefix = append_type_component(physical_prefix, arm, budget)
          emit_type(arm, child, arm_prefix, array_level, plan, structures, streams, physical_lanes, emissions, budget, profile)
        end
      when BinaryDataType::TAG_STRING
        if profile.with_size_stream?
          add_lane_emission(emissions, append_name(physical_prefix, ".size", budget), logical_name(path, ".string_sizes", budget), streams, 0, budget)
        end
        add_lane_emission(emissions, physical_prefix, logical_name(path, ".data", budget), streams, 0, budget)
      when BinaryDataType::TAG_ARRAY
        suffix = ".size#{array_level}"
        add_lane_emission(emissions, append_name(physical_prefix, suffix, budget), logical_name(path, ".sizes", budget), streams, 0, budget)
        child = logical_name(path, ".elements", budget)
        emit_type(type.child_at(0), child, physical_prefix, array_level + 1, plan, structures, streams, physical_lanes, emissions, budget, profile)
      when BinaryDataType::TAG_NULLABLE
        add_lane_emission(emissions, append_name(physical_prefix, ".null", budget), logical_name(path, ".nulls", budget), streams, 0, budget)
        emit_type(type.child_at(0), logical_name(path, ".nested", budget), physical_prefix, array_level, plan, structures, streams, physical_lanes, emissions, budget, profile)
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        emit_type(type.child_at(0), path, physical_prefix, array_level, plan, structures, streams, physical_lanes, emissions, budget, profile)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        if type.child_count == 0
          add_lane_emission(emissions, physical_prefix, logical_name(path, ".data", budget), streams, 0, budget)
        else
          type.child_count.times do |index|
            field_prefix = append_tuple_field(physical_prefix, type, index, budget)
            child = indexed_path(path, ".field.", index, budget)
            emit_type(type.child_at(index), child, field_prefix, array_level, plan, structures, streams, physical_lanes, emissions, budget, profile)
          end
        end
      when BinaryDataType::TAG_MAP
        suffix = ".size#{array_level}"
        add_lane_emission(emissions, append_name(physical_prefix, suffix, budget), logical_name(path, ".sizes", budget), streams, 0, budget)
        key_path = logical_name(path, ".elements.field.0", budget)
        key_prefix = append_escaped_field(physical_prefix, "keys", budget)
        emit_type(type.child_at(0), key_path, key_prefix, array_level + 1, plan, structures, streams, physical_lanes, emissions, budget, profile)
        value_path = logical_name(path, ".elements.field.1", budget)
        value_prefix = append_escaped_field(physical_prefix, "values", budget)
        emit_type(type.child_at(1), value_path, value_prefix, array_level + 1, plan, structures, streams, physical_lanes, emissions, budget, profile)
      when BinaryDataType::TAG_LOW_CARDINALITY
        dictionary_role = logical_name(path, ".dictionary", budget)
        indexes_role = logical_name(path, ".indexes", budget)
        dictionary_name = append_name(physical_prefix, ".dict", budget)
        add_lane_emission(emissions, dictionary_name, dictionary_role, streams, LOW_CARDINALITY_VERSION_BYTES, budget)
        add_lane_emission(emissions, physical_prefix, indexes_role, streams, 0, budget)
      when BinaryDataType::TAG_NESTED
        raise UnsupportedFormatError.new("Nested per-path physical substreams are not admitted")
      when BinaryDataType::TAG_QBIT
        raise UnsupportedFormatError.new("QBit per-path physical substreams are not admitted")
      when BinaryDataType::TAG_JSON
        raise UnsupportedFormatError.new("JSON per-path physical substreams are not admitted")
      else
        role = logical_name(path, ".data", budget)
        add_lane_emission(emissions, physical_prefix, role, streams, 0, budget)
      end
      nil
    end

    # CH invokes the recursively collected Dynamic/Variant prefix callbacks
    # before any discriminator or ordinary value body. Keep this as a distinct
    # pass: a nested Dynamic site can therefore precede its enclosing body.
    private def self.emit_prefix_type(
      type : BinaryDataType,
      path : String,
      physical_prefix : String,
      array_level : Int32,
      plan : BinaryDynamicBulkPlan,
      structures : BinaryDynamicStructureStreams,
      streams : BinaryBulkStreams,
      physical_lanes : Hash(String, Bytes),
      emissions : Array(Emission),
      budget : BinaryCodecBudget,
    ) : Nil
      case type.tag
      when BinaryDataType::TAG_DYNAMIC
        structure_name = append_name(physical_prefix, ".dynamic_structure", budget)
        add_structure_emission(emissions, structure_name, path, budget)
        role = logical_name(path, ".discriminators", budget)
        prefix_name = append_name(physical_prefix, ".variant_discr_prefix", budget)
        add_discriminator_prefix_emission(emissions, role, prefix_name, physical_lanes, budget)
        plan.arm_count(path).times do |index|
          arm = plan.arm_type(path, index)
          child = indexed_path(path, ".arm.", index, budget)
          arm_prefix = if index == plan.shared_index(path)
                         append_name(physical_prefix, ".SharedVariant", budget)
                       else
                         append_type_component(physical_prefix, arm, budget)
                       end
          emit_prefix_type(arm, child, arm_prefix, array_level, plan, structures, streams, physical_lanes, emissions, budget)
        end
      when BinaryDataType::TAG_VARIANT
        role = logical_name(path, ".discriminators", budget)
        prefix_name = append_name(physical_prefix, ".variant_discr_prefix", budget)
        add_discriminator_prefix_emission(emissions, role, prefix_name, physical_lanes, budget)
        type.child_count.times do |index|
          arm = type.child_at(index)
          child = indexed_path(path, ".arm.", index, budget)
          arm_prefix = append_type_component(physical_prefix, arm, budget)
          emit_prefix_type(arm, child, arm_prefix, array_level, plan, structures, streams, physical_lanes, emissions, budget)
        end
      when BinaryDataType::TAG_ARRAY
        emit_prefix_type(type.child_at(0), logical_name(path, ".elements", budget), physical_prefix, array_level + 1, plan, structures, streams, physical_lanes, emissions, budget)
      when BinaryDataType::TAG_NULLABLE
        emit_prefix_type(type.child_at(0), logical_name(path, ".nested", budget), physical_prefix, array_level, plan, structures, streams, physical_lanes, emissions, budget)
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        emit_prefix_type(type.child_at(0), path, physical_prefix, array_level, plan, structures, streams, physical_lanes, emissions, budget)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times do |index|
          field_prefix = append_tuple_field(physical_prefix, type, index, budget)
          child = indexed_path(path, ".field.", index, budget)
          emit_prefix_type(type.child_at(index), child, field_prefix, array_level, plan, structures, streams, physical_lanes, emissions, budget)
        end
      when BinaryDataType::TAG_MAP
        emit_prefix_type(type.child_at(0), logical_name(path, ".elements.field.0", budget), append_escaped_field(physical_prefix, "keys", budget), array_level + 1, plan, structures, streams, physical_lanes, emissions, budget)
        emit_prefix_type(type.child_at(1), logical_name(path, ".elements.field.1", budget), append_escaped_field(physical_prefix, "values", budget), array_level + 1, plan, structures, streams, physical_lanes, emissions, budget)
      when BinaryDataType::TAG_LOW_CARDINALITY
        role = logical_name(path, ".dictionary", budget)
        prefix_name = append_name(physical_prefix, ".dict_prefix", budget)
        add_low_cardinality_prefix_emission(emissions, prefix_name, role, streams, budget)
      end
      nil
    end

    private def self.decode_prefix_type(
      type : BinaryDataType,
      path : String,
      physical_prefix : String,
      array_level : Int32,
      depth : Int32,
      reader : ObjectSharedPathTapeReader,
      budget : BinaryCodecBudget,
    ) : Nil
      budget.ensure_depth(depth)
      case type.tag
      when BinaryDataType::TAG_DYNAMIC
        # A Dynamic site owns its descriptor at this depth and each implicit
        # SharedVariant/ordinary arm one level below it. Check that child level
        # before parsing the roster or allocating its canonical arm array.
        budget.ensure_depth(depth + 1)
        structure_name = append_name(physical_prefix, ".dynamic_structure", budget)
        structure_bytes = reader.take(structure_name)
        context = BinaryCodecContext.new(budget.limits, structure_bytes, false, budget, false, false)
        structure = DynamicStructureCodec.read_prefix_without_statistics(context, depth, depth + 1, true)
        context.ensure_consumed
        reader.add_structure(path, structure_bytes, structure)
        role = logical_name(path, ".discriminators", budget)
        prefix_name = append_name(physical_prefix, ".variant_discr_prefix", budget)
        reader.add_discriminator_prefix(role, prefix_name)
        canonical_arms(structure, budget).each_with_index do |arm, index|
          child = indexed_path(path, ".arm.", index, budget)
          arm_prefix = if index == structure.shared_index
                         append_name(physical_prefix, ".SharedVariant", budget)
                       else
                         append_type_component(physical_prefix, arm, budget)
                       end
          decode_prefix_type(arm, child, arm_prefix, array_level, depth + 1, reader, budget)
        end
      when BinaryDataType::TAG_VARIANT
        role = logical_name(path, ".discriminators", budget)
        prefix_name = append_name(physical_prefix, ".variant_discr_prefix", budget)
        reader.add_discriminator_prefix(role, prefix_name)
        type.child_count.times do |index|
          arm = type.child_at(index)
          child = indexed_path(path, ".arm.", index, budget)
          decode_prefix_type(arm, child, append_type_component(physical_prefix, arm, budget), array_level, depth + 1, reader, budget)
        end
      when BinaryDataType::TAG_ARRAY
        decode_prefix_type(type.child_at(0), logical_name(path, ".elements", budget), physical_prefix, array_level + 1, depth + 1, reader, budget)
      when BinaryDataType::TAG_NULLABLE
        decode_prefix_type(type.child_at(0), logical_name(path, ".nested", budget), physical_prefix, array_level, depth + 1, reader, budget)
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        decode_prefix_type(type.child_at(0), path, physical_prefix, array_level, depth + 1, reader, budget)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        type.child_count.times do |index|
          child = indexed_path(path, ".field.", index, budget)
          decode_prefix_type(type.child_at(index), child, append_tuple_field(physical_prefix, type, index, budget), array_level, depth + 1, reader, budget)
        end
      when BinaryDataType::TAG_MAP
        decode_prefix_type(type.child_at(0), logical_name(path, ".elements.field.0", budget), append_escaped_field(physical_prefix, "keys", budget), array_level + 1, depth + 1, reader, budget)
        decode_prefix_type(type.child_at(1), logical_name(path, ".elements.field.1", budget), append_escaped_field(physical_prefix, "values", budget), array_level + 1, depth + 1, reader, budget)
      when BinaryDataType::TAG_LOW_CARDINALITY
        role = logical_name(path, ".dictionary", budget)
        prefix_name = append_name(physical_prefix, ".dict_prefix", budget)
        reader.add_low_cardinality_dictionary_prefix(role, prefix_name)
      end
      nil
    end

    private def self.decode_type(
      type : BinaryDataType,
      path : String,
      physical_prefix : String,
      array_level : Int32,
      reader : ObjectSharedPathTapeReader,
      budget : BinaryCodecBudget,
      profile : BinaryBulkProfile,
    ) : Nil
      case type.tag
      when BinaryDataType::TAG_DYNAMIC
        structure = reader.structure_for(path)
        role = logical_name(path, ".discriminators", budget)
        body_name = append_name(physical_prefix, ".variant_discr", budget)
        reader.add_discriminator_body(role, body_name)
        arms = canonical_arms(structure, budget)
        arms.each_with_index do |arm, index|
          child = indexed_path(path, ".arm.", index, budget)
          if index == structure.shared_index
            arm_prefix = append_name(physical_prefix, ".SharedVariant", budget)
          else
            arm_prefix = append_type_component(physical_prefix, arm, budget)
          end
          decode_type(arm, child, arm_prefix, array_level, reader, budget, profile)
        end
      when BinaryDataType::TAG_VARIANT
        role = logical_name(path, ".discriminators", budget)
        body_name = append_name(physical_prefix, ".variant_discr", budget)
        reader.add_discriminator_body(role, body_name)
        type.child_count.times do |index|
          arm = type.child_at(index)
          child = indexed_path(path, ".arm.", index, budget)
          decode_type(arm, child, append_type_component(physical_prefix, arm, budget), array_level, reader, budget, profile)
        end
      when BinaryDataType::TAG_STRING
        if profile.with_size_stream?
          reader.add_lane(logical_name(path, ".string_sizes", budget), reader.take(append_name(physical_prefix, ".size", budget)))
        end
        reader.add_lane(logical_name(path, ".data", budget), reader.take(physical_prefix))
      when BinaryDataType::TAG_ARRAY
        reader.add_lane(logical_name(path, ".sizes", budget), reader.take(append_name(physical_prefix, ".size#{array_level}", budget)))
        decode_type(type.child_at(0), logical_name(path, ".elements", budget), physical_prefix, array_level + 1, reader, budget, profile)
      when BinaryDataType::TAG_NULLABLE
        reader.add_lane(logical_name(path, ".nulls", budget), reader.take(append_name(physical_prefix, ".null", budget)))
        decode_type(type.child_at(0), logical_name(path, ".nested", budget), physical_prefix, array_level, reader, budget, profile)
      when BinaryDataType::TAG_SIMPLE_AGGREGATE
        decode_type(type.child_at(0), path, physical_prefix, array_level, reader, budget, profile)
      when BinaryDataType::TAG_UNNAMED_TUPLE, BinaryDataType::TAG_NAMED_TUPLE
        if type.child_count == 0
          reader.add_lane(logical_name(path, ".data", budget), reader.take(physical_prefix))
        else
          type.child_count.times do |index|
            field_prefix = append_tuple_field(physical_prefix, type, index, budget)
            child = indexed_path(path, ".field.", index, budget)
            decode_type(type.child_at(index), child, field_prefix, array_level, reader, budget, profile)
          end
        end
      when BinaryDataType::TAG_MAP
        reader.add_lane(logical_name(path, ".sizes", budget), reader.take(append_name(physical_prefix, ".size#{array_level}", budget)))
        key_path = logical_name(path, ".elements.field.0", budget)
        decode_type(type.child_at(0), key_path, append_escaped_field(physical_prefix, "keys", budget), array_level + 1, reader, budget, profile)
        value_path = logical_name(path, ".elements.field.1", budget)
        decode_type(type.child_at(1), value_path, append_escaped_field(physical_prefix, "values", budget), array_level + 1, reader, budget, profile)
      when BinaryDataType::TAG_LOW_CARDINALITY
        dictionary_role = logical_name(path, ".dictionary", budget)
        dictionary_name = append_name(physical_prefix, ".dict", budget)
        reader.add_low_cardinality_dictionary_body(dictionary_role, dictionary_name)
        indexes_role = logical_name(path, ".indexes", budget)
        reader.add_lane(indexes_role, reader.take(physical_prefix))
      when BinaryDataType::TAG_NESTED
        raise UnsupportedFormatError.new("Nested per-path physical substreams are not admitted")
      when BinaryDataType::TAG_QBIT
        raise UnsupportedFormatError.new("QBit per-path physical substreams are not admitted")
      when BinaryDataType::TAG_JSON
        raise UnsupportedFormatError.new("JSON per-path physical substreams are not admitted")
      else
        reader.add_lane(logical_name(path, ".data", budget), reader.take(physical_prefix))
      end
      nil
    end

    private def self.canonical_arms(structure : DynamicStructure, budget : BinaryCodecBudget) : Array(BinaryDataType)
      count = structure.canonical_variant_count
      budget.ensure_future_elements(count.to_u64)
      budget.charge_elements(count.to_u64)
      arms = Array(BinaryDataType?).new(count, nil)
      arms[structure.shared_index] = BinaryDataType.primitive("String")
      structure.type_count.times do |index|
        arm = structure.type_at(index)
        canonical = structure.canonical_index_for(arm)
        if arms[canonical]?
          raise CorruptPartError.new("Dynamic canonical arm roster is duplicated")
        end
        arms[canonical] = arm
      end
      Array(BinaryDataType).new(count) do |index|
        arms[index] || raise(CorruptPartError.new("Dynamic canonical arm roster is incomplete"))
      end
    rescue ex : ArgumentError
      raise CorruptPartError.new("Dynamic canonical arm roster is invalid: #{ex.message}")
    end

    private def self.add_structure_emission(
      emissions : Array(Emission),
      name : String,
      path : String,
      budget : BinaryCodecBudget,
    ) : Nil
      reserve_emission(emissions, name, budget)
      emissions << Emission.new(name, nil, path, 0, 0)
    end

    private def self.add_lane_emission(
      emissions : Array(Emission),
      name : String,
      role : String,
      streams : BinaryBulkStreams,
      start : Int32,
      budget : BinaryCodecBudget,
    ) : Nil
      stream = streams.stream(role)
      unless start >= 0 && start <= stream.byte_size
        raise UnsupportedFormatError.new("Object shared path lane start is outside its logical stream")
      end
      reserve_emission(emissions, name, budget)
      emissions << Emission.new(name, role, nil, start, stream.byte_size - start)
    end

    private def self.add_discriminator_prefix_emission(
      emissions : Array(Emission),
      role : String,
      prefix_name : String,
      physical_lanes : Hash(String, Bytes),
      budget : BinaryCodecBudget,
    ) : Nil
      bytes = physical_lanes[role]? || raise(UnsupportedFormatError.new("Object shared path discriminator lane was not framed"))
      if bytes.size < BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES
        raise UnsupportedFormatError.new("Object shared path compact lane is shorter than its mode prefix")
      end
      reserve_emission(emissions, prefix_name, budget)
      emissions << Emission.new(prefix_name, role, nil, 0, BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES)
      nil
    end

    private def self.add_low_cardinality_prefix_emission(
      emissions : Array(Emission),
      prefix_name : String,
      role : String,
      streams : BinaryBulkStreams,
      budget : BinaryCodecBudget,
    ) : Nil
      stream = streams.stream(role)
      if stream.byte_size < LOW_CARDINALITY_VERSION_BYTES
        raise UnsupportedFormatError.new("LowCardinality dictionary lane is shorter than its version prefix")
      end
      reserve_emission(emissions, prefix_name, budget)
      emissions << Emission.new(prefix_name, role, nil, 0, LOW_CARDINALITY_VERSION_BYTES)
      nil
    end

    private def self.add_discriminator_body_emission(
      emissions : Array(Emission),
      role : String,
      body_name : String,
      physical_lanes : Hash(String, Bytes),
      budget : BinaryCodecBudget,
    ) : Nil
      bytes = physical_lanes[role]? || raise(UnsupportedFormatError.new("Object shared path discriminator lane was not framed"))
      if bytes.size < BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES
        raise UnsupportedFormatError.new("Object shared path compact lane is shorter than its mode prefix")
      end
      reserve_emission(emissions, body_name, budget)
      emissions << Emission.new(body_name, role, nil, BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES, bytes.size - BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES)
      nil
    end

    private def self.reserve_emission(emissions : Array(Emission), name : String, budget : BinaryCodecBudget) : Nil
      budget.ensure_future_nodes(1_u64)
      budget.ensure_future_elements(name.bytesize.to_u64 + 1_u64)
      budget.charge_node
      budget.charge_elements(name.bytesize.to_u64 + 1_u64)
      nil
    end

    private def self.materialize(
      emissions : Array(Emission),
      roles : Array(String),
      structures : BinaryDynamicStructureStreams,
      streams : BinaryBulkStreams,
      physical_lanes : Hash(String, Bytes),
      budget : BinaryCodecBudget,
    ) : ObjectSharedPathStreams
      total = structures.total_input_byte_size
      roles.each do |role|
        stream = streams.stream(role)
        lane_size = if role.ends_with?(".discriminators")
                      BinaryBulkDiscriminatorFramingAdapter.physical_size(stream, DynamicDiscriminatorBodyValidator::COMPACT_MODE).to_u64
                    else
                      stream.byte_size.to_u64
                    end
        total = checked_add(total, lane_size, true)
      end
      if total > Int32::MAX.to_u64
        raise UnsupportedFormatError.new("Object shared path Data slice exceeds the supported byte domain")
      end

      event_name_work = 0_u64
      emissions.each do |emission|
        event_name_work = checked_add(event_name_work, emission.name.bytesize.to_u64, true)
      end
      event_count = emissions.size.to_u64
      budget.ensure_future_nodes(event_count)
      retained_event_work = checked_add(event_name_work, event_count, true)
      retained_event_work = checked_add(retained_event_work, event_count, true)
      budget.ensure_future_elements(retained_event_work)
      # One output buffer, one detached public stream buffer, and temporary
      # copies returned for structure blobs are all bounded before allocation.
      copy_work = checked_add(checked_add(total, total, true), structures.total_input_byte_size, true)
      budget.ensure_wire_bytes(copy_work)
      event_count.times { budget.charge_node }
      budget.charge_elements(retained_event_work)
      budget.charge_wire_bytes(copy_work)

      output = Bytes.new(total.to_i32)
      events = Array(ObjectSharedPathSubstreamEvent).new(emissions.size)
      cursor = 0_i32
      emissions.each do |emission|
        events << ObjectSharedPathSubstreamEvent.new(emission.name, cursor.to_u64)
        if path = emission.structure_path
          bytes = structures.structure_bytes_for(path)
          if bytes.size != 0
            output[cursor, bytes.size].copy_from(bytes)
          end
          cursor += bytes.size
        elsif role = emission.role
          if role.ends_with?(".discriminators")
            bytes = physical_lanes[role]
            emission.size.times do |offset|
              output[cursor + offset] = bytes[emission.start + offset]
            end
          else
            stream = streams.stream(role)
            emission.size.times do |offset|
              output[cursor + offset] = stream.byte_at(emission.start + offset)
            end
          end
          cursor += emission.size
        else
          raise UnsupportedFormatError.new("Object shared path output emission has no source")
        end
      end
      unless cursor == output.size
        raise UnsupportedFormatError.new("Object shared path output schedule disagrees with its measured size")
      end
      ObjectSharedPathStreams.new(output, events)
    end

    private def self.append_name(prefix : String, suffix : String, budget : BinaryCodecBudget) : String
      size = checked_add(prefix.bytesize.to_u64, suffix.bytesize.to_u64, true)
      budget.ensure_future_elements(size)
      budget.charge_elements(size)
      PhysicalStreamName.append_literal(prefix, suffix)
    end

    private def self.append_type_component(prefix : String, type : BinaryDataType, budget : BinaryCodecBudget) : String
      bounds = BinaryTypeNameBudget.measure(type, budget)
      work = checked_add(prefix.bytesize.to_u64, checked_add(bounds[1], 1_u64, true), true)
      budget.ensure_future_elements(work)
      budget.charge_elements(work)
      name = type.name
      PhysicalStreamName.append_literal(prefix, ".#{name}")
    end

    private def self.append_tuple_field(prefix : String, type : BinaryDataType, index : Int32, budget : BinaryCodecBudget) : String
      raw_size = if type.named_tuple?
                   type.field_name_byte_size(index).to_u64
                 else
                   decimal_digits(index.to_u64).to_u64
                 end
      escaped_bound = raw_size * 3_u64 + 3_u64
      work = checked_add(prefix.bytesize.to_u64, escaped_bound, true)
      budget.ensure_future_elements(work)
      budget.charge_elements(work)
      raw = type.named_tuple? ? type.field_name_at(index) : (index + 1).to_s
      PhysicalStreamName.append_escaped_field(prefix, raw)
    end

    private def self.append_escaped_field(prefix : String, raw : String, budget : BinaryCodecBudget) : String
      raw_size = raw.bytesize.to_u64
      escaped_bound = raw_size * 3_u64 + 3_u64
      work = checked_add(prefix.bytesize.to_u64, escaped_bound, true)
      budget.ensure_future_elements(work)
      budget.charge_elements(work)
      PhysicalStreamName.append_escaped_field(prefix, raw)
    end

    private def self.logical_name(path : String, suffix : String, budget : BinaryCodecBudget) : String
      size = checked_add(path.bytesize.to_u64, suffix.bytesize.to_u64, true)
      budget.ensure_future_elements(size)
      budget.charge_elements(size)
      String.build(size.to_i) { |io| io << path << suffix }
    end

    private def self.indexed_path(path : String, suffix : String, index : Int32, budget : BinaryCodecBudget) : String
      digits = decimal_digits(index.to_u64).to_u64
      size = checked_add(checked_add(path.bytesize.to_u64, suffix.bytesize.to_u64, true), digits, true)
      budget.ensure_future_elements(size)
      budget.charge_elements(size)
      String.build(size.to_i) { |io| io << path << suffix << index }
    end

    private def self.decimal_digits(value : UInt64) : Int32
      digits = 1_i32
      current = value
      while current >= 10_u64
        current //= 10_u64
        digits += 1
      end
      digits
    end

    private def self.checked_add(left : UInt64, right : UInt64, writing : Bool) : UInt64
      if right > UInt64::MAX - left
        if writing
          raise UnsupportedFormatError.new("Object shared path size arithmetic overflows UInt64")
        else
          raise CorruptPartError.new("Object shared path size arithmetic overflows UInt64")
        end
      end
      left + right
    end
  end
end

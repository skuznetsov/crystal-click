module CrystalClick
  # Paired exact full-stream codec. Object and every Dynamic child consume one
  # aggregate node/element/wire-byte budget, without a synthetic set-root node.
  module ObjectDynamicStructureCodec
    def self.encode(
      structure_set : ObjectDynamicStructureSet,
      limits : BinaryCodecLimits = BinaryCodecLimits.default,
      inferred_actual_root_depth : Int32? = nil,
    ) : ObjectDynamicStructureStreams
      budget = BinaryCodecBudget.new(limits, true)
      encode_with_budget(structure_set, budget, inferred_actual_root_depth: inferred_actual_root_depth)
    end

    # Borrowed-budget entry point for a wider Object document operation. The
    # Object and every Dynamic metadata stream share the caller's budget.
    def self.encode_with_budget(
      structure_set : ObjectDynamicStructureSet,
      budget : BinaryCodecBudget,
      inferred_actual_root_depth : Int32? = nil,
    ) : ObjectDynamicStructureStreams
      unless budget.writing?
        raise ArgumentError.new("Object/Dynamic structure encode requires a writing budget")
      end

      limits = budget.limits
      object = structure_set.object
      dynamic_type_depth = dynamic_structure_type_depth(budget, inferred_actual_root_depth)
      object_context = BinaryCodecContext.new(limits, nil, true, budget)
      object_statistics_offset = ObjectStructureCodec.write_with_statistics_offset(structure_set.object, object_context)
      object_bytes = object_context.finish_bytes

      dynamic_bytes = Hash(String, Bytes).new
      dynamic_statistics_offsets = Hash(String, Int32).new
      object.dynamic_path_count.times do |index|
        path = object.dynamic_path_at(index)
        context = BinaryCodecContext.new(limits, nil, true, budget)
        dynamic_statistics_offsets[path] = DynamicStructureCodec.write_with_statistics_offset(
          structure_set.dynamic_for(path),
          context,
          type_depth: dynamic_type_depth,
        )
        dynamic_bytes[path] = context.finish_bytes
      end

      ObjectDynamicStructureStreams.new(object_bytes, dynamic_bytes, object_statistics_offset, dynamic_statistics_offsets)
    end

    def self.decode(
      streams : ObjectDynamicStructureStreams,
      limits : BinaryCodecLimits = BinaryCodecLimits.default,
      inferred_actual_root_depth : Int32? = nil,
    ) : ObjectDynamicStructureSet
      budget = BinaryCodecBudget.new(limits)
      decode_with_budget(streams, budget, inferred_actual_root_depth: inferred_actual_root_depth)
    end

    # Borrowed-budget entry point for a wider Object document operation. It
    # charges all metadata stream bytes once before any byte-copying getter,
    # then shares recursive descriptor work with the parent operation.
    def self.decode_with_budget(
      streams : ObjectDynamicStructureStreams,
      budget : BinaryCodecBudget,
      inferred_actual_root_depth : Int32? = nil,
    ) : ObjectDynamicStructureSet
      if budget.writing?
        raise ArgumentError.new("Object/Dynamic structure decode requires a reading budget")
      end

      limits = budget.limits
      if origin = inferred_actual_root_depth
        budget.ensure_depth(origin)
      end
      # Do not call the byte-copying getters until the complete aggregate input
      # byte count has passed and been charged.
      total_input_bytes = streams.total_input_byte_size
      budget.charge_wire_bytes(total_input_bytes)

      object_bytes = streams.object
      object_context = BinaryCodecContext.new(limits, object_bytes, false, budget, false)
      object = ObjectStructureCodec.read_from(object_context)
      object_context.ensure_consumed

      if streams.dynamic_count != object.dynamic_path_count
        raise CorruptPartError.new("Dynamic stream keys do not exactly match the Object path roster")
      end
      object.dynamic_path_count.times do |index|
        path = object.dynamic_path_at(index)
        unless streams.has_dynamic_path?(path)
          raise CorruptPartError.new("Dynamic stream is missing Object path #{path.inspect}")
        end
      end
      dynamic_type_depth = dynamic_structure_type_depth(budget, inferred_actual_root_depth)

      # The exact key set has been proven without copying any Dynamic bytes or
      # key strings. Only now create the detached map used for traversal.
      dynamic_bytes = streams.dynamics
      decoded_dynamics = Hash(String, DynamicStructure).new
      object.dynamic_path_count.times do |index|
        path = object.dynamic_path_at(index)
        bytes = dynamic_bytes[path]
        context = BinaryCodecContext.new(limits, bytes, false, budget, false)
        decoded_dynamics[path] = DynamicStructureCodec.read_from(context, type_depth: dynamic_type_depth)
        context.ensure_consumed
      end

      begin
        ObjectDynamicStructureSet.new(object, decoded_dynamics)
      rescue ex : ArgumentError
        raise CorruptPartError.new("invalid paired Object/Dynamic structure set: #{ex.message}")
      end
    end

    # Standalone metadata retains its historical depth-one entry point. An
    # Object operation supplies the absolute inferred root origin directly;
    # there is no synthetic Dynamic descriptor edge at this metadata boundary.
    private def self.dynamic_structure_type_depth(
      budget : BinaryCodecBudget,
      inferred_actual_root_depth : Int32?,
    ) : Int32
      origin = inferred_actual_root_depth
      return 1_i32 unless origin

      budget.ensure_depth(origin)
      origin
    end
  end
end

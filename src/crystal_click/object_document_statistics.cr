module CrystalClick
  # Rebuilds Object/Dynamic statistics from the explicit column plan and its
  # logical rows. This derives counts only; it does not infer any path or type
  # roster from the documents.
  module ObjectDocumentStatistics
    MAX_DYNAMIC_SPILLED_NAMES =    256
    MAX_OBJECT_SHARED_PATHS   = 10_000

    alias DynamicRoute = Tuple(BinaryDataType, UInt8)
    alias Routes = Hash(String, DynamicRoute)
    alias NameCounts = Hash(String, UInt64)
    alias DynamicRouting = Tuple(
      DynamicStructure,
      Array(String),
      Array(BinaryTypeNameBudget::Bounds),
      Routes,
      UInt8,
    )

    def self.recompute(
      plan : ObjectDocumentPlan,
      granules : Array(Array(ObjectDocument)),
      limits : BinaryCodecLimits = ObjectDocumentCodec::DEFAULT_LIMITS,
    ) : ObjectDocumentPlan
      budget = BinaryCodecBudget.new(limits, true)
      recompute_with_budget(plan, granules, budget)
    end

    # Borrowed-budget entry point for a parent writer. The caller may continue
    # directly into ObjectDocumentCodec with this same consumptive budget.
    def self.recompute_with_budget(
      plan : ObjectDocumentPlan,
      granules : Array(Array(ObjectDocument)),
      budget : BinaryCodecBudget,
    ) : ObjectDocumentPlan
      unless budget.writing?
        raise ArgumentError.new("Object statistics recomputation requires a writing budget")
      end

      object = plan.structures.object
      unless object.version == 4_u64 && object.shared_data_version == 0_u64 && object.bucket_count == 1_u64
        raise UnsupportedFormatError.new("Object statistics support only Object V3 with one MAP bucket")
      end

      # Admit the complete name-copy set before either immutable plan roster is
      # exposed through its detached String getters. Object paths are read once,
      # copied into ObjectStructure, copied into ObjectDynamicStructureSet,
      # then read once by that set's roster check. Typed paths are read once
      # and copied into the returned ObjectDocumentPlan.
      dynamic_paths, typed_paths, typed_types = copy_rosters(plan, budget)
      typed_by_path = Hash(String, BinaryDataType).new
      typed_paths.each_with_index do |path, index|
        typed_by_path[path] = typed_types[index]
      end

      # Dynamic SQL names can contain substantial escaped metadata (notably
      # named Tuple fields and Enum labels). Bound every canonical name and
      # recursive descriptor before requesting a detached canonical roster or
      # invoking BinaryDataType#name.
      routings = build_routings(plan, dynamic_paths, budget)

      total_rows, total_paths, document_path_bytes = inspect_grid(granules, budget)
      base_nodes = checked_add(granules.size.to_u64, total_rows)
      base_nodes = checked_add(base_nodes, total_paths)
      base_elements = checked_add(granules.size.to_u64, total_paths)
      budget.ensure_future_nodes(base_nodes)
      budget.ensure_future_elements(base_elements)
      budget.ensure_wire_bytes(document_path_bytes)
      budget.charge_wire_bytes(document_path_bytes)

      dynamic_slot_count = dynamic_paths.size.to_u64
      routings.each { |routing| dynamic_slot_count = checked_add(dynamic_slot_count, routing[1].size.to_u64) }
      budget.preflight_children(dynamic_slot_count)
      dynamic_slot_count.times { budget.charge_node }

      object_counts = Array(UInt64).new(dynamic_paths.size, 0_u64)
      dynamic_counts = Array(Array(UInt64)).new(routings.size)
      dynamic_shared_counts = Array(NameCounts).new(routings.size)
      dynamic_shared_names = Array(Array(String)).new(routings.size)
      dynamic_by_path = Hash(String, Int32).new
      routings.each_with_index do |routing, index|
        dynamic_counts << Array(UInt64).new(routing[1].size, 0_u64)
        dynamic_shared_counts << NameCounts.new
        dynamic_shared_names << Array(String).new
        dynamic_by_path[dynamic_paths[index]] = index.to_i32
      end

      object_shared_counts = NameCounts.new
      object_shared_names = Array(String).new
      context = BinaryCodecContext.new(budget.limits, nil, true, budget, false, false)

      granules.each do |mark_rows|
        budget.charge_node
        budget.charge_elements(1_u64)
        mark_rows.each do |document|
          budget.charge_node
          path_count = document.path_count
          budget.preflight_children(path_count.to_u64) if path_count > 0

          # A typed field is required in every row and is validated against the
          # caller's explicit schema. Its type is not included in Object/Dynamic
          # statistics.
          typed_paths.each_with_index do |path, index|
            unless document.has_path?(path)
              raise UnsupportedFormatError.new("typed Object field is missing: #{path.inspect}")
            end
            value = document.value_for(path)
            context.validate_type_tree(value.type)
            unless value.type == typed_types[index]
              raise UnsupportedFormatError.new("typed Object field has a descriptor that differs from its schema")
            end
          end

          path_count.times do |path_index|
            budget.charge_node
            path = document.path_at(path_index)

            next if typed_by_path.has_key?(path)

            if dynamic_index = dynamic_by_path[path]?
              value = document.value_for(path)
              if value.type.tag == BinaryDataType::TAG_NOTHING
                unless value.is_null?
                  raise UnsupportedFormatError.new("top-level Nothing is admitted only as Dynamic NULL")
                end
                next
              end
              if value.type.tag == BinaryDataType::TAG_NULLABLE
                raise UnsupportedFormatError.new("top-level Nullable is outside the Dynamic V3 canonical profile")
              end

              routing = routings[dynamic_index]
              name_bounds = BinaryTypeNameBudget.measure(value.type, budget)
              name = BinaryTypeNameBudget.materialize(value.type, budget, name_bounds)
              arm_index = DynamicValueCodec.route_index(value.type, name, routing[3], routing[4]).to_i
              increment!(object_counts, dynamic_index)
              increment!(dynamic_counts[dynamic_index], arm_index)

              if arm_index == routing[4].to_i
                retain_name_count!(
                  dynamic_shared_counts[dynamic_index],
                  dynamic_shared_names[dynamic_index],
                  name,
                  MAX_DYNAMIC_SPILLED_NAMES,
                  budget
                )
              end
            else
              value = document.value_for(path)
              if value.type.tag == BinaryDataType::TAG_NOTHING
                unless value.is_null?
                  raise UnsupportedFormatError.new("non-typed Nothing values must use the NULL sentinel")
                end
                next
              end
              if value.type.tag == BinaryDataType::TAG_NULLABLE
                raise UnsupportedFormatError.new("non-typed top-level Nullable values are outside the canonical profile")
              end

              name_bounds = BinaryTypeNameBudget.measure(value.type, budget)
              BinaryTypeNameBudget.materialize(value.type, budget, name_bounds)
              retain_name_count!(object_shared_counts, object_shared_names, path, MAX_OBJECT_SHARED_PATHS, budget)
            end
          end
        end
      end

      # Statistics constructors clone their positional arrays and each retained
      # name. Reserve those copies before creating the first output record.
      stats_record_count = object_shared_names.size.to_u64
      dynamic_shared_names.each { |names| stats_record_count = checked_add(stats_record_count, names.size.to_u64) }
      stats_counter_count = object_counts.size.to_u64
      dynamic_counts.each { |counts| stats_counter_count = checked_add(stats_counter_count, counts.size.to_u64) }
      budget.preflight_children(checked_add(stats_record_count, stats_counter_count))

      object_stats = statistics(object_counts, object_shared_counts, object_shared_names, budget)
      fresh_dynamics = Hash(String, DynamicStructure).new
      routings.each_with_index do |routing, index|
        stats = statistics(dynamic_counts[index], dynamic_shared_counts[index], dynamic_shared_names[index], budget)
        fresh_dynamics[dynamic_paths[index]] = rebuild_dynamic(routing, stats, budget)
      end

      fresh_object = ObjectStructure.new(dynamic_paths, 4_u64, 0_u64, 1_u64, statistics: object_stats)
      fresh_set = ObjectDynamicStructureSet.new(fresh_object, fresh_dynamics)
      typed_schema = Hash(String, BinaryDataType).new
      typed_paths.each_with_index do |path, index|
        typed_schema[path] = typed_types[index]
      end
      ObjectDocumentPlan.new(fresh_set, typed_schema)
    end

    private def self.copy_rosters(
      plan : ObjectDocumentPlan,
      budget : BinaryCodecBudget,
    ) : Tuple(Array(String), Array(String), Array(BinaryDataType))
      object = plan.structures.object
      dynamic_count = object.dynamic_path_count
      typed_count = plan.typed_path_count
      roster_count = checked_add(dynamic_count.to_u64, typed_count.to_u64)
      # The byte-size walk is itself logical work. Admit its complete node and
      # edge lower bound before reading any per-path metadata; the later
      # detached-copy pass is admitted and charged separately below.
      budget.ensure_future_nodes(roster_count)
      budget.preflight_children(roster_count)

      dynamic_bytes = 0_u64
      dynamic_count.times do |index|
        budget.charge_node
        dynamic_bytes = checked_add(dynamic_bytes, object.dynamic_path_byte_size(index).to_u64)
      end
      typed_bytes = 0_u64
      typed_count.times do |index|
        budget.charge_node
        typed_bytes = checked_add(typed_bytes, plan.typed_path_byte_size_at(index).to_u64)
      end

      dynamic_copy_bytes = checked_multiply(dynamic_bytes, 4_u64)
      typed_copy_bytes = checked_multiply(typed_bytes, 2_u64)
      budget.ensure_wire_bytes(checked_add(dynamic_copy_bytes, typed_copy_bytes))
      budget.charge_wire_bytes(checked_add(dynamic_copy_bytes, typed_copy_bytes))
      budget.preflight_children(roster_count)

      dynamic_paths = Array(String).new(dynamic_count)
      dynamic_count.times do |index|
        budget.charge_node
        dynamic_paths << object.dynamic_path_at(index)
      end

      typed_paths = Array(String).new(typed_count)
      typed_types = Array(BinaryDataType).new(typed_count)
      type_context = BinaryCodecContext.new(budget.limits, nil, true, budget, false, false)
      typed_count.times do |index|
        budget.charge_node
        path = plan.typed_path_at(index)
        type = plan.typed_type_for(path)
        type_context.validate_type_tree(type)
        typed_paths << path
        typed_types << type
      end
      {dynamic_paths, typed_paths, typed_types}
    end

    private def self.build_routings(
      plan : ObjectDocumentPlan,
      dynamic_paths : Array(String),
      budget : BinaryCodecBudget,
    ) : Array(DynamicRouting)
      result = Array(DynamicRouting).new(dynamic_paths.size)
      dynamic_paths.each do |path|
        budget.charge_node
        structure = plan.structures.dynamic_for(path)
        type_count = structure.type_count
        variant_count = structure.canonical_variant_count
        budget.preflight_children(checked_add(type_count.to_u64, variant_count.to_u64))

        bounds = Array(BinaryTypeNameBudget::Bounds).new(type_count)
        aggregate_roster_bound = DynamicStructure::SHARED_VARIANT_NAME.bytesize.to_u64
        type_count.times do |index|
          bound = BinaryTypeNameBudget.measure(structure.type_at(index), budget)
          bounds << bound
          aggregate_roster_bound = checked_add(aggregate_roster_bound, bound[0])
        end

        # The canonical-name getter duplicates every roster String. Its whole
        # maximum copy set is admitted before invoking that getter.
        budget.ensure_wire_bytes(aggregate_roster_bound)
        variant_count.times { budget.charge_node }
        variant_names = structure.canonical_variant_names
        copied_name_bytes = 0_u64
        variant_names.each do |name|
          copied_name_bytes = checked_add(copied_name_bytes, name.bytesize.to_u64)
        end
        budget.charge_wire_bytes(copied_name_bytes)

        routes = Routes.new
        type_count.times do |index|
          budget.charge_node
          type = structure.type_at(index)
          name = BinaryTypeNameBudget.materialize(type, budget, bounds[index])
          canonical_index = variant_names.index(name) || raise UnsupportedFormatError.new("Dynamic type is absent from its canonical roster")
          routes[name] = {type, canonical_index.to_u8}
        end
        result << {structure, variant_names, bounds, routes, structure.shared_index.to_u8}
      end
      result
    end

    private def self.inspect_grid(
      granules : Array(Array(ObjectDocument)),
      budget : BinaryCodecBudget,
    ) : Tuple(UInt64, UInt64, UInt64)
      if granules.size >= Int32::MAX
        raise UnsupportedFormatError.new("Object document mark grid exceeds the supported domain")
      end
      mark_count = granules.size.to_u64
      # Admit both the known outer work and its minimum node count before
      # touching a descendant granule or document.
      budget.ensure_future_nodes(mark_count)
      budget.preflight_children(mark_count)

      rows = 0_u64
      paths = 0_u64
      path_bytes = 0_u64
      granules.each do |mark_rows|
        if mark_rows.empty?
          raise ArgumentError.new("Object document real marks must contain at least one row")
        end
        if mark_rows.size > Int32::MAX
          raise UnsupportedFormatError.new("Object document mark row count exceeds the supported domain")
        end
        budget.charge_node
        budget.ensure_future_nodes(mark_rows.size.to_u64)
        rows = checked_add(rows, mark_rows.size.to_u64)
        mark_rows.each do |document|
          budget.charge_node
          path_count = document.path_count
          budget.ensure_future_nodes(path_count.to_u64)
          budget.preflight_children(path_count.to_u64) if path_count > 0
          paths = checked_add(paths, path_count.to_u64)
          path_count.times do |index|
            budget.charge_node
            byte_size = document.path_byte_size_at(index).to_u64
            path_bytes = checked_add(path_bytes, byte_size)
            budget.charge_wire_bytes(byte_size)
          end
        end
      end
      {rows, paths, path_bytes}
    end

    private def self.retain_name_count!(
      counts : NameCounts,
      retained : Array(String),
      name : String,
      cap : Int32,
      budget : BinaryCodecBudget,
    ) : Nil
      if count = counts[name]?
        counts[name] = checked_add(count, 1_u64)
      elsif retained.size < cap
        budget.preflight_children(1_u64)
        budget.charge_node
        counts[name] = 1_u64
        retained << name
      end
      nil
    end

    private def self.statistics(
      counts : Array(UInt64),
      shared_counts : NameCounts,
      retained_names : Array(String),
      budget : BinaryCodecBudget,
    ) : StructureStatistics
      shared = Array(StructureStatistic).new(retained_names.size)
      retained_names.each do |name|
        budget.ensure_wire_bytes(name.bytesize.to_u64)
        budget.charge_wire_bytes(name.bytesize.to_u64)
        budget.charge_node
        shared << StructureStatistic.new(name, shared_counts[name])
      end
      StructureStatistics.new(counts, shared)
    end

    private def self.rebuild_dynamic(
      routing : DynamicRouting,
      stats : StructureStatistics,
      budget : BinaryCodecBudget,
    ) : DynamicStructure
      source = routing[0]
      type_count = source.type_count
      type_copy_nodes = checked_multiply(type_count.to_u64, 2_u64)
      budget.preflight_children(type_copy_nodes)

      constructor_name_bytes = 0_u64
      type_count.times do |index|
        bounds = routing[2][index]
        constructor_name_bytes = checked_add(constructor_name_bytes, checked_add(bounds[0], bounds[1]))
      end
      budget.ensure_wire_bytes(constructor_name_bytes)

      types = Array(BinaryDataType).new(type_count)
      type_count.times do |index|
        budget.charge_node
        types << source.type_at(index)
      end
      # DynamicStructure's constructor renders every ordinary type again and
      # copies those names into its canonical roster. Charge the conservative
      # metadata-aware bounds before that constructor can allocate them.
      result = DynamicStructure.new(types, stats)
      budget.charge_wire_bytes(constructor_name_bytes)
      result
    end

    private def self.increment!(counts : Array(UInt64), index : Int) : Nil
      counts[index] = checked_add(counts[index], 1_u64)
    end

    private def self.checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise UnsupportedFormatError.new("Object statistics count overflows UInt64")
      end
      left + right
    end

    private def self.checked_multiply(left : UInt64, right : UInt64) : UInt64
      if right != 0_u64 && left > UInt64::MAX // right
        raise UnsupportedFormatError.new("Object statistics size overflows UInt64")
      end
      left * right
    end
  end
end

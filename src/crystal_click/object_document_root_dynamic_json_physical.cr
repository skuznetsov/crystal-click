module CrystalClick
  # Composes inferred-root Dynamic JSON children onto the existing Object
  # physical owner. The parent supplies physical P rows; each normalized child
  # Object supplies its own logical Q census for StorageOccurrenceGrid.
  module ObjectDocumentRootDynamicJsonPhysical
    def self.append_pairs!(
      pairs : Hash(String, CompressedMarkFiles),
      physical_plan : ObjectDocumentPhysicalPlan,
      plan : ObjectDocumentPlan,
      streams : ObjectDocumentStreams,
      physical_rows : Array(UInt64),
      codec_budget : BinaryCodecBudget,
      transport_budget : CompressedStreamBudget,
      frame_bytes : Int,
      profile : BinaryBulkProfile,
    ) : Nil
      unless physical_rows.size == streams.mark_count
        raise UnsupportedFormatError.new("root Dynamic JSON physical rows differ from the parent mark grid")
      end

      object = plan.structures.object
      unless streams.dynamic_path_count == object.dynamic_path_count
        raise UnsupportedFormatError.new("root Dynamic JSON paths differ from the Object declaration")
      end
      operation_origin = physical_plan.inferred_actual_root_depth
      codec_budget.ensure_depth(operation_origin)
      object.dynamic_path_count.times do |index|
        path = object.dynamic_path_at(index)
        unless streams.has_dynamic_path?(path)
          raise UnsupportedFormatError.new("root Dynamic JSON paths differ from the Object declaration")
        end
      end

      object.dynamic_path_count.times do |index|
        path = object.dynamic_path_at(index)
        structure = plan.structures.dynamic_for(path)
        dynamic_streams = streams.dynamic_for(path)
        leaf_plans = plan.root_dynamic_json_object_leaf_plans_for(path, codec_budget)
        roster = DynamicJsonObjectBindingRoster.for_root_if_json(
          structure,
          leaf_plans,
          codec_budget,
          operation_origin,
        )
        stream_keys = dynamic_streams.json_object_leaf_keys(codec_budget)

        unless selected_roster = roster
          unless leaf_plans.empty? && stream_keys.empty? && !physical_plan.has_root_dynamic_json?(path)
            raise UnsupportedFormatError.new("no-JSON root Dynamic path acquired JSON bindings or physical sites")
          end
          next
        end

        unless physical_plan.has_root_dynamic_json?(path)
          raise UnsupportedFormatError.new("root Dynamic JSON physical roster omits a JSON-bearing path")
        end
        dynamic_physical = physical_plan.root_dynamic_json(path)
        binding_keys = selected_roster.json_object_leaf_keys(codec_budget)
        site_count = dynamic_physical.json_object_site_count
        unless binding_keys.size == leaf_plans.size && binding_keys.size == stream_keys.size &&
               binding_keys.size == site_count
          raise UnsupportedFormatError.new("root Dynamic JSON child plans, streams, and physical sites differ")
        end

        expected_plans = Hash(BinaryDynamicJsonLeafKey, ObjectDocumentPlan).new(initial_capacity: leaf_plans.size)
        leaf_plans.each do |entry|
          if expected_plans.has_key?(entry[0])
            raise UnsupportedFormatError.new("root Dynamic JSON declaration contains a duplicate leaf")
          end
          expected_plans[entry[0]] = entry[1]
        end
        unless expected_plans.size == binding_keys.size
          raise UnsupportedFormatError.new("root Dynamic JSON declaration does not exactly cover its binding roster")
        end
        binding_keys.each do |key|
          unless expected_plans.has_key?(key)
            raise UnsupportedFormatError.new("root Dynamic JSON binding has no declared child plan")
          end
        end

        seen_streams = Hash(BinaryDynamicJsonLeafKey, Bool).new(initial_capacity: stream_keys.size)
        stream_keys.each do |key|
          if seen_streams.has_key?(key) || !expected_plans.has_key?(key)
            raise UnsupportedFormatError.new("root Dynamic JSON stream roster differs from its declared leaves")
          end
          seen_streams[key] = true
        end

        seen_sites = Hash(BinaryDynamicJsonLeafKey, Bool).new(initial_capacity: site_count)
        stream_keys.each do |key|
          site = dynamic_physical.json_object_site(key)
          child_plan = expected_plans[key]? ||
                       raise(UnsupportedFormatError.new("root Dynamic JSON physical site has no declared child plan"))
          if seen_sites.has_key?(key)
            raise UnsupportedFormatError.new("root Dynamic JSON physical site is duplicated")
          end
          seen_sites[key] = true
          unless site.leaf_key == key && site.binding.leaf_key == key &&
                 site.binding.plan.same?(child_plan) && dynamic_streams.has_json_object_leaf?(key)
            raise UnsupportedFormatError.new("root Dynamic JSON binding changed before physical composition")
          end

          json_depth = selected_roster.json_object_leaf_depth(key)
          child_root_depth64 = json_depth.to_i64 + 1_i64
          codec_budget.ensure_depth(child_root_depth64)
          unless site.json_depth == json_depth &&
                 site.physical_plan.typed_descriptor_root_depth == child_root_depth64.to_i32 &&
                 site.physical_plan.inferred_actual_root_depth == child_root_depth64.to_i32 &&
                 site.physical_plan.shared_profile == physical_plan.shared_profile
            raise UnsupportedFormatError.new("root Dynamic JSON child physical plan lost its inherited depth or profile")
          end
          begin
            site.binding.validate_for!(
              key,
              structure,
              codec_budget,
              json_depth,
              operation_origin,
            )
          rescue ex : ArgumentError
            raise UnsupportedFormatError.new(ex.message || "root Dynamic JSON binding no longer matches its actual roster")
          end

          child_streams = dynamic_streams.json_object_leaf_for(key)
          unless child_streams.mark_count == streams.mark_count
            raise UnsupportedFormatError.new("root Dynamic JSON child stream differs from the parent mark count")
          end
          grid = child_grid(physical_rows, child_streams, codec_budget)
          child_physical = site.physical_plan

          ObjectDocumentColumnWriter.preflight_child_site_variant_prefixes!(
            child_physical, child_plan, child_streams, codec_budget
          )
          lanes = ObjectDocumentColumnWriter.bind_child_site_lanes(
            child_physical, child_plan, child_streams, codec_budget
          )
          mark_records = grid.mark_count + 1
          lane_count = lanes.size.to_u64
          codec_budget.preflight_children(lane_count)
          lane_count.times { codec_budget.charge_node }
          raw_sizes = Array(Int32).new(lanes.size) { |lane_index| lanes[lane_index].byte_size }
          CompressedMarkWriter.preflight_batch(raw_sizes, mark_records, frame_bytes, transport_budget)

          child_pair_bound = child_physical.stream_count.to_u64
          codec_budget.preflight_children(child_pair_bound)
          child_pair_bound.times { codec_budget.charge_node }
          child_pairs = Hash(String, CompressedMarkFiles).new(initial_capacity: child_physical.stream_count)
          lanes.each do |lane|
            child_pairs[lane.name] = lane.encode_child_site(grid, frame_bytes, transport_budget)
          end
          ObjectDocumentColumnWriter.append_child_site_advanced_pairs!(
            child_pairs,
            child_physical,
            child_plan,
            child_streams,
            physical_rows,
            codec_budget,
            transport_budget,
            frame_bytes,
            profile,
          )

          ObjectDocumentTypedDynamicJsonPhysical.append_pairs!(
            child_pairs,
            child_physical,
            child_plan,
            child_streams,
            physical_rows,
            codec_budget,
            transport_budget,
            frame_bytes,
            profile,
          )
          ObjectDocumentRootDynamicJsonPhysical.append_pairs!(
            child_pairs,
            child_physical,
            child_plan,
            child_streams,
            physical_rows,
            codec_budget,
            transport_budget,
            frame_bytes,
            profile,
          )

          expected_name_count = child_physical.stream_count.to_u64
          codec_budget.preflight_children(expected_name_count)
          expected_name_count.times { codec_budget.charge_node }
          expected_names = child_physical.stream_names
          unless expected_names.size == child_pairs.size && expected_names.all? { |name| child_pairs.has_key?(name) }
            raise UnsupportedFormatError.new("root Dynamic JSON child pairs do not exactly cover its physical roster")
          end
          parent_pair_count = child_pairs.size.to_u64
          codec_budget.preflight_children(parent_pair_count)
          parent_pair_count.times { codec_budget.charge_node }
          child_pairs.each do |name, pair|
            if pairs.has_key?(name)
              raise UnsupportedFormatError.new("root Dynamic JSON physical stream is duplicated")
            end
            pairs[name] = pair
          end
        end
        unless seen_sites.size == expected_plans.size
          raise UnsupportedFormatError.new("root Dynamic JSON physical roster omitted a bound leaf")
        end
      end
      nil
    end

    private def self.child_grid(
      physical_rows : Array(UInt64),
      streams : ObjectDocumentStreams,
      budget : BinaryCodecBudget,
    ) : StorageOccurrenceGrid
      count = streams.mark_count.to_u64
      records = count * 3_u64
      budget.ensure_future_nodes(records)
      budget.ensure_future_elements(records)
      count.times { budget.charge_node }
      budget.charge_elements(count) if count > 0_u64
      logical_rows = Array(UInt64).new(streams.mark_count)
      streams.mark_count.times do |mark|
        logical_rows << streams.row_count_at(mark)
      end
      StorageOccurrenceGrid.new(physical_rows, logical_rows, budget)
    end
  end
end

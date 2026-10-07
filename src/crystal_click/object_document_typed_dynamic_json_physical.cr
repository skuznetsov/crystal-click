module CrystalClick
  # Recursively composes the physical Object children attached to typed
  # Dynamic JSON leaves. The parent owns physical P; each child's normalized
  # Object streams retain logical Q. Descendants keep the original P while
  # their own JSON census supplies the next logical grid.
  module ObjectDocumentTypedDynamicJsonPhysical
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
        raise UnsupportedFormatError.new("typed Dynamic JSON physical rows differ from the parent mark grid")
      end

      typed_path_count = plan.typed_dynamic_count.to_u64
      typed_path_owner_records = typed_path_count + 1_u64
      codec_budget.preflight_children(typed_path_count) if typed_path_count > 0_u64
      codec_budget.ensure_future_nodes(typed_path_owner_records)
      typed_path_bytes = 0_u64
      plan.typed_dynamic_count.times do |index|
        typed_path_bytes = checked_add_u64(
          typed_path_bytes,
          plan.typed_dynamic_path_byte_size_at(index).to_u64
        )
      end
      codec_budget.charge_wire_bytes(typed_path_bytes) if typed_path_bytes > 0_u64
      codec_budget.charge_node
      typed_path_count.times { codec_budget.charge_node }
      typed_dynamic_paths = Array(String).new(plan.typed_dynamic_count)
      plan.typed_dynamic_count.times do |index|
        typed_dynamic_paths << plan.typed_dynamic_path_at(index)
      end
      unless streams.typed_dynamic_path_count == typed_dynamic_paths.size
        raise UnsupportedFormatError.new("typed Dynamic JSON paths differ from the Object declaration")
      end
      typed_dynamic_paths.each do |path|
        unless streams.has_typed_dynamic_path?(path)
          raise UnsupportedFormatError.new("typed Dynamic JSON paths differ from the Object declaration")
        end
      end

      plan.typed_dynamic_count.times do |index|
        path = typed_dynamic_paths[index]
        dynamic_streams = streams.typed_dynamic_for(path)
        dynamic_physical = physical_plan.typed_dynamic(path)
        declared_bindings = plan.typed_dynamic_json_object_leaf_plans_for(path, codec_budget)
        stream_keys = dynamic_streams.json_object_leaf_keys(codec_budget)
        site_count = dynamic_physical.json_object_site_count
        unless declared_bindings.size == stream_keys.size && declared_bindings.size == site_count
          raise UnsupportedFormatError.new("typed Dynamic JSON child plans, streams, and physical sites differ")
        end
        retained_entries = declared_bindings.size.to_u64 + site_count.to_u64
        retained_records = retained_entries + 2_u64
        codec_budget.preflight_children(retained_entries) if retained_entries > 0_u64
        codec_budget.ensure_future_nodes(retained_records)
        retained_records.times { codec_budget.charge_node }

        expected_keys = Hash(BinaryDynamicJsonLeafKey, ObjectDocumentPlan).new(initial_capacity: declared_bindings.size)
        declared_bindings.each do |entry|
          if expected_keys.has_key?(entry[0])
            raise UnsupportedFormatError.new("typed Dynamic JSON declaration contains a duplicate leaf")
          end
          expected_keys[entry[0]] = entry[1]
        end
        unless expected_keys.size == stream_keys.size && expected_keys.size == site_count
          raise UnsupportedFormatError.new("typed Dynamic JSON child plans, streams, and physical sites differ")
        end
        stream_keys.each do |key|
          unless expected_keys.has_key?(key)
            raise UnsupportedFormatError.new("typed Dynamic JSON stream has no declared child plan")
          end
        end

        seen_sites = Hash(BinaryDynamicJsonLeafKey, Bool).new(initial_capacity: site_count)
        stream_keys.each do |key|
          site = dynamic_physical.json_object_site(key)
          child_plan = expected_keys[key]? ||
                       raise(UnsupportedFormatError.new("typed Dynamic JSON physical site has no declared child plan"))
          unless seen_sites[key]?
            seen_sites[key] = true
          else
            raise UnsupportedFormatError.new("typed Dynamic JSON physical site is duplicated")
          end
          unless site.binding.leaf_key == key && site.binding.plan.same?(child_plan) &&
                 dynamic_streams.has_json_object_leaf?(key)
            raise UnsupportedFormatError.new("typed Dynamic JSON binding changed before physical composition")
          end

          child_streams = dynamic_streams.json_object_leaf_for(key)
          unless child_streams.mark_count == streams.mark_count
            raise UnsupportedFormatError.new("typed Dynamic JSON child stream differs from the parent mark count")
          end
          grid = child_grid(physical_rows, child_streams, codec_budget)
          child_physical = site.physical_plan
          json_depth = dynamic_physical.json_object_leaf_depth(key)
          expected_root_depth64 = json_depth.to_i64 + 1_i64
          codec_budget.ensure_depth(expected_root_depth64)
          unless child_physical.typed_descriptor_root_depth == expected_root_depth64.to_i32
            raise UnsupportedFormatError.new("typed Dynamic JSON child physical plan lost its inherited descriptor depth")
          end

          begin
            site.binding.validate_for!(
              key,
              plan.typed_dynamic_site_structure_for(path, key.dynamic_site),
              codec_budget,
              json_depth,
            )
          rescue ex : ArgumentError
            raise UnsupportedFormatError.new(ex.message || "typed Dynamic JSON binding no longer matches its actual roster")
          end

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

          # The descendant Object uses the same physical P rows. Its own
          # normalized streams supply Q, and this call repeats that rule for
          # every deeper typed Dynamic JSON leaf.
          append_pairs!(
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
            raise UnsupportedFormatError.new("typed Dynamic JSON child pairs do not exactly cover its physical roster")
          end
          parent_pair_count = child_pairs.size.to_u64
          codec_budget.preflight_children(parent_pair_count)
          parent_pair_count.times { codec_budget.charge_node }
          child_pairs.each do |name, pair|
            if pairs.has_key?(name)
              raise UnsupportedFormatError.new("typed Dynamic JSON physical stream is duplicated")
            end
            pairs[name] = pair
          end
        end
        unless seen_sites.size == expected_keys.size
          raise UnsupportedFormatError.new("typed Dynamic JSON physical roster omitted a bound leaf")
        end
      end
      nil
    end

    private def self.checked_add_u64(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("typed Dynamic path byte count overflows UInt64")
      end
      left + right
    end

    private def self.child_grid(
      physical_rows : Array(UInt64),
      streams : ObjectDocumentStreams,
      budget : BinaryCodecBudget,
    ) : StorageOccurrenceGrid
      count = streams.mark_count.to_u64
      # Admit the temporary logical-Q vector and both detached P/Q vectors
      # retained by StorageOccurrenceGrid before the first proportional array.
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

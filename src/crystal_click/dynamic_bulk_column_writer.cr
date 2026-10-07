module CrystalClick
  # Encodes one prepared Dynamic value column into its bounded physical lanes.
  # Part envelope construction and publication remain with WidePartWriter.
  class DynamicBulkColumnWriter
    def self.encode(
      plan : BinaryDynamicBulkPlan,
      physical : BinaryDynamicBulkPhysicalPlan,
      granules : Array(Array(BinaryValue)),
      rows_per_mark : Array(UInt64),
      frame_bytes : Int,
      limits : BinaryCodecLimits,
      transport_limits : CompressedStreamLimits,
      codec_budget : BinaryCodecBudget? = nil,
      transport_budget : CompressedStreamBudget? = nil,
    ) : Hash(String, CompressedMarkFiles)
      unless physical.same_prepared_plan?(plan)
        raise ArgumentError.new("Dynamic physical plan does not retain the supplied prepared plan")
      end
      validate_parent_grid!(granules, rows_per_mark)
      validate_frame_bytes!(frame_bytes, transport_limits, plan, physical)

      # Structures and ordinary Dynamic data consume one operation-local codec
      # budget. The retained plan is passed through; no second roster is built.
      write_codec_budget = codec_budget || BinaryCodecBudget.new(limits, true)
      validate_codec_budget!(write_codec_budget, limits)
      write_transport_budget = transport_budget || CompressedStreamBudget.new(transport_limits, true)
      validate_transport_budget!(write_transport_budget, transport_limits)
      structures = plan.encode_structure_streams(write_codec_budget)
      data = BinaryBulkEncoder.encode(
        plan.type, granules, write_codec_budget, plan.profile, plan
      )

      lane_count = data.role_count.to_i64 + structures.site_count.to_i64
      if lane_count <= 0 || lane_count > Int32::MAX
        raise UnsupportedFormatError.new("Dynamic physical lane count exceeds the supported domain")
      end
      write_codec_budget.charge_elements(lane_count.to_u64)

      data_roles = data.roles
      site_paths = structures.site_paths
      unless data.mark_count == granules.size && site_paths == plan.site_paths
        raise UnsupportedFormatError.new("Dynamic encoded sites or outer mark grid differ from the retained plan")
      end
      structure_roles = Array(String).new(site_paths.size)
      site_paths.each { |path| structure_roles << "#{path}.dynamic_structure" }
      structure_roles.sort!

      physical_names = physical.stream_names
      expected_roles = Array(String).new(lane_count.to_i)
      expected_roles.concat(data_roles)
      expected_roles.concat(structure_roles)
      expected_roles.sort!
      unless data_roles == data_roles.sort && structure_roles == structure_roles.uniq &&
             physical_names.size == lane_count && physical_names.keys.sort == expected_roles
        raise UnsupportedFormatError.new("Dynamic physical roles differ from the retained plan and encoded lanes")
      end

      prefix_lanes = Array(Tuple(String, BinaryBulkStream, Int32)).new(data_roles.size)
      raw_sizes = Array(Int32).new(lane_count.to_i)
      data_roles.each do |role|
        stream = data.stream(role)
        unless stream.offset_count == rows_per_mark.size + 1
          raise UnsupportedFormatError.new("Dynamic value lane lacks the complete outer mark grid")
        end
        prefix = physical.prefix_size_for(role)
        prefix_lanes << {role, stream, prefix}

        raw_size = stream.byte_size
        if role.ends_with?(".discriminators")
          if raw_size > Int32::MAX - BinaryBulkPhysicalPrefixAdapter::PREFIX_BYTES
            raise UnsupportedFormatError.new("Dynamic discriminator lane exceeds the supported byte domain")
          end
          raw_size += BinaryBulkPhysicalPrefixAdapter::PREFIX_BYTES
        end
        raw_sizes << raw_size
      end

      structure_lanes = Array(Tuple(String, Bytes, Int32)).new(site_paths.size)
      site_paths.each do |path|
        bytes = structures.structure_bytes_for(path)
        statistics_offset = plan.statistics_offset_for(path)
        unless bytes.size > 0 && bytes.size <= Int32::MAX &&
               statistics_offset >= 0 && statistics_offset < bytes.size
          raise UnsupportedFormatError.new("Dynamic structure statistics offset is outside its physical lane")
        end
        role = "#{path}.dynamic_structure"
        physical_name = physical_names[role]? ||
                        raise(UnsupportedFormatError.new("Dynamic structure role is missing from its physical plan"))
        structure_lanes << {physical_name, bytes, statistics_offset}
        raw_sizes << bytes.size.to_i32
      end

      # Validate every data prefix and reserve all coordinate/header work before
      # materializing transformed data lanes. The transport preflight covers
      # all value and structure files before any compressed output is emitted.
      BinaryBulkPhysicalPrefixAdapter.preflight_write(prefix_lanes, write_codec_budget)
      CompressedMarkWriter.preflight_batch(
        raw_sizes, rows_per_mark.size + 1, frame_bytes, write_transport_budget
      )

      pairs = Hash(String, CompressedMarkFiles).new(initial_capacity: lane_count.to_i)
      prefix_lanes.each do |role, stream, prefix|
        bytes, offsets, physical_prefix = BinaryBulkPhysicalPrefixAdapter.write_lane(
          role, stream, prefix
        )
        physical_name = physical_names[role]? ||
                        raise(UnsupportedFormatError.new("Dynamic data role is missing from its physical plan"))
        add_lane!(pairs, physical_name, CompressedMarkWriter.encode(
          bytes, offsets, rows_per_mark,
          prefix_size: physical_prefix,
          frame_bytes: frame_bytes,
          budget: write_transport_budget
        ))
      end

      structure_lanes.each do |physical_name, bytes, statistics_offset|
        add_lane!(pairs, physical_name, CompressedMarkWriter.encode_metadata(
          bytes, statistics_offset, rows_per_mark,
          frame_bytes: frame_bytes,
          budget: write_transport_budget
        ))
      end

      expected_names = physical_names.values.sort
      unless pairs.size == lane_count && pairs.keys.sort == expected_names
        raise UnsupportedFormatError.new("Dynamic encoded physical roster differs from its plan")
      end
      pairs
    end

    private def self.validate_frame_bytes!(
      frame_bytes : Int,
      limits : CompressedStreamLimits,
      plan : BinaryDynamicBulkPlan,
      physical : BinaryDynamicBulkPhysicalPlan,
    ) : Nil
      if frame_bytes <= 0 || frame_bytes > Int32::MAX
        raise ArgumentError.new("frame size must be a positive Int32 value")
      end
      if frame_bytes.to_i64 > limits.max_frame_decompressed_bytes
        raise ArgumentError.new("Dynamic frame size is outside the compressed transport limit")
      end
      plan.data_roles.each do |role|
        if physical.prefix_size_for(role) > frame_bytes
          raise ArgumentError.new("frame zero cannot contain the complete prefix")
        end
      end
      nil
    end

    private def self.validate_parent_grid!(
      granules : Array(Array(BinaryValue)),
      rows_per_mark : Array(UInt64),
    ) : Nil
      if granules.empty? || granules.size > WidePartWriter::MAX_MARKS
        raise ArgumentError.new("Dynamic physical output requires a bounded nonempty parent grid")
      end
      unless rows_per_mark.size == granules.size
        raise ArgumentError.new("Dynamic parent row counts differ from the value granule count")
      end
      granules.each_with_index do |rows, mark|
        if rows.empty? || rows.size > WidePartWriter::MAX_ROWS_PER_MARK
          raise ArgumentError.new("Dynamic parent granule size is outside the writer limit")
        end
        unless rows_per_mark[mark] == rows.size.to_u64
          raise ArgumentError.new("Dynamic parent row counts differ from the value granules")
        end
      end
      nil
    end

    private def self.validate_codec_budget!(budget : BinaryCodecBudget, limits : BinaryCodecLimits) : Nil
      unless budget.writing? && budget.limits.max_depth == limits.max_depth &&
             budget.limits.max_nodes == limits.max_nodes &&
             budget.limits.max_elements == limits.max_elements &&
             budget.limits.max_bytes == limits.max_bytes
        raise ArgumentError.new("Dynamic writer requires a compatible writing codec budget")
      end
      nil
    end

    private def self.validate_transport_budget!(budget : CompressedStreamBudget, limits : CompressedStreamLimits) : Nil
      budget.ensure_direction(true)
      unless budget.limits.max_file_bytes == limits.max_file_bytes &&
             budget.limits.max_mark_bytes == limits.max_mark_bytes &&
             budget.limits.max_frame_compressed_bytes == limits.max_frame_compressed_bytes &&
             budget.limits.max_frame_decompressed_bytes == limits.max_frame_decompressed_bytes &&
             budget.limits.max_records == limits.max_records &&
             budget.limits.max_decoded_bytes == limits.max_decoded_bytes &&
             budget.limits.max_result_bytes == limits.max_result_bytes
        raise ArgumentError.new("Dynamic writer requires a compatible writing transport budget")
      end
      nil
    end

    private def self.add_lane!(
      pairs : Hash(String, CompressedMarkFiles),
      physical_name : String,
      lane : CompressedMarkFiles,
    ) : Nil
      if pairs.has_key?(physical_name)
        raise UnsupportedFormatError.new("Dynamic physical filenames collide")
      end
      pairs[physical_name] = lane
      nil
    end
  end
end

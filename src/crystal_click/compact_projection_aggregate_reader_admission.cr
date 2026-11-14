module CrystalClick
  # Projection-only admission for Compact aggregate states. It binds the
  # hidden UInt64 key through the Compact context so declaration, callback
  # identity, checksums, and global row/mark axes share one physical owner.
  private class CompactProjectionAggregateReaderAdmission
    FIXED_CHECKSUM_MANIFEST = Set{
      "count.txt",
      "data.bin",
      "primary.idx",
      "serialization.json",
    }

    def self.validate_projection_aggregate!(
      part_path : String,
      column_name : String,
      descriptor : WidePartProjectionAggregateDescriptor,
      reader : CompactBinaryBulkColumnReader,
      transport_budget : CompressedStreamBudget,
    ) : Array(String)
      path = File.expand_path(part_path)
      transport_budget.ensure_direction(false)

      unless descriptor.column_name == column_name && descriptor.type_name == reader.schema_declaration &&
             reader.source_declaration == descriptor.type_name && reader.row_count > 0_u64
        raise CorruptPartError.new("Compact projection aggregate reader differs from its exact child declaration or row count")
      end
      if descriptor.count?
        count_plan = WideAggregateCountStoragePlan.for_type(descriptor.type) ||
                     raise(UnsupportedFormatError.new("Compact projection child has no admitted Count descriptor"))
        unless count_plan.type_name == WideAggregateCountStoragePlan::NO_ARGUMENT_TYPE_NAME &&
               descriptor.type_name == WideAggregateCountStoragePlan::NO_ARGUMENT_TYPE_NAME
          raise UnsupportedFormatError.new("Compact projection Count reader admits only the literal count() state")
        end
      elsif !(descriptor.sum? || descriptor.minmax?)
        raise UnsupportedFormatError.new("Compact projection reader admits only UInt64 sum/min/max states")
      end

      key_names = validate_projection_roster!(
        reader.projection_aggregate_physical_context,
        descriptor,
        reader.projection_aggregate_limits,
      )
      selected_checksum_names = reader.selected_checksum_names
      mark_name = selected_checksum_names[1]?
      unless mark_name && (mark_name == "data.mrk4" || mark_name == "data.cmrk4")
        raise UnsupportedFormatError.new("Compact projection aggregates require one MRK4 mark sidecar")
      end
      validate_projection_manifest!(path, reader, PartChecksums.parse(
        PartMetadataFileReader.new(path, transport_budget)
          .read("checksums.txt", PartChecksums::MAX_CHECKSUM_FILE_BYTES).to_slice,
      ), selected_checksum_names, mark_name)

      key_names.map { |name| String.new(name.to_slice) }
    end

    def self.validate_projection_roster!(
      context : CompactPartPhysicalContext,
      selected_descriptor : WidePartProjectionAggregateDescriptor,
      limits : BinaryCodecLimits,
    ) : Array(String)
      unless context.mode == CompactMarkFormat::Mrk4
        raise UnsupportedFormatError.new("Compact projection aggregate requires MRK4 child marks")
      end
      columns = context.columns
      key_count = 0
      while key_count < columns.size && columns[key_count][1] == "UInt64"
        key_count += 1
      end
      unless key_count == 1 && columns.size > key_count && columns.size <= key_count + 4
        raise UnsupportedFormatError.new("Compact projection aggregate requires one leading UInt64 key and one to four states")
      end
      unless columns.map(&.[0]).to_set.size == columns.size
        raise CorruptPartError.new("Compact projection aggregate column names are not unique")
      end

      key_name = columns[0][0]
      key_stream_name = PhysicalStreamName.escape(key_name)
      key_slots = context.physical_roster.select { |slot| slot.column_name == key_name }
      observed_key_callbacks = key_slots.map do |slot|
        slot.stream_name || raise(CorruptPartError.new("Compact projection UInt64 key callback has no stream name"))
      end
      unless observed_key_callbacks == [key_stream_name]
        raise CorruptPartError.new("Compact projection UInt64 key callback differs from its exact physical plan")
      end
      context.validate_uint64_single_callback_spans!(key_name, key_stream_name)

      seen_functions = Set(WidePartProjectionAggregateDescriptor::Function).new
      count_seen = false
      state_columns = columns[key_count..]
      state_columns.each do |name, type_name|
        descriptor = WidePartProjectionAggregateDescriptor.for_column(name, type_name) ||
                     raise(UnsupportedFormatError.new("Compact projection aggregate roster contains a noncanonical state"))
        unless seen_functions.add?(descriptor.function)
          raise UnsupportedFormatError.new("Compact projection aggregate roster repeats a function")
        end
        count_seen ||= descriptor.count?

        normalizer = CompactBinaryBulkNormalizer.new(
          descriptor.type,
          name,
          BinaryBulkProfile.single_stream,
          limits,
        )
        expected_callbacks = normalizer.expected_physical_callback_roster
        unless expected_callbacks.size == 1
          raise CorruptPartError.new("Compact projection aggregate state does not have one exact callback")
        end
        state_slots = context.physical_roster.select { |slot| slot.column_name == name }
        observed_callbacks = state_slots.map do |slot|
          slot.stream_name || raise(CorruptPartError.new("Compact projection aggregate callback has no stream name"))
        end
        unless observed_callbacks == expected_callbacks
          raise CorruptPartError.new("Compact projection aggregate callback differs from its exact physical plan")
        end

        if descriptor.sum? || descriptor.minmax?
          state_width = descriptor.sum? ? 8_u64 : 9_u64
          lane_label = descriptor.sum? ? "AggregateFunction(sum(UInt64)) state" : "AggregateFunction(#{descriptor.function_name}(UInt64)) state"
          context.validate_fixed_width_single_callback_spans!(
            name,
            expected_callbacks[0],
            state_width,
            lane_label,
          )
        end
      end

      if selected_descriptor.count? && !count_seen
        raise UnsupportedFormatError.new("Compact projection Count child roster omits count()")
      end
      unless state_columns.any? { |name, type_name| name == selected_descriptor.column_name && type_name == selected_descriptor.type_name }
        raise CorruptPartError.new("Compact selected aggregate differs from its persisted state roster")
      end
      [String.new(key_name.to_slice)] of String
    end

    private def self.validate_projection_manifest!(
      path : String,
      reader : CompactBinaryBulkColumnReader,
      checksums : PartChecksums,
      selected_checksum_names : Array(String),
      mark_name : String,
    ) : Nil
      unless selected_checksum_names == ["data.bin", mark_name]
        raise CorruptPartError.new("Compact projection checksum selection differs from its physical data and mark files")
      end
      expected_manifest = FIXED_CHECKSUM_MANIFEST.dup
      expected_manifest << mark_name
      unless checksums.entries.keys.to_set == expected_manifest
        raise UnsupportedFormatError.new("Compact projection physical manifest is outside the admitted MRK4 child profile")
      end
      checksums.entries.each_key do |name|
        checksums.validate_selected_entries(path, name)
      end

      mark_count = reader.mark_count.to_u64
      if mark_count + 1_u64 > PrimaryKeyIndex::MAX_INDEX_ENTRIES.to_u64
        raise CorruptPartError.new("Compact projection UInt64 primary index exceeds its entry bound")
      end
      expected_index_bytes = (mark_count + 1_u64) * 8_u64
      index_path = File.join(path, "primary.idx")
      unless File.size(index_path).to_u64 == expected_index_bytes
        raise CorruptPartError.new("Compact projection primary.idx is not an exact uncompressed UInt64 mark grid")
      end
      nil
    rescue ex : IO::Error
      raise CorruptPartError.new("Compact projection primary index is unavailable")
    end
  end
end

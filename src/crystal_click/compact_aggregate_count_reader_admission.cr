module CrystalClick
  # Projection-only admission for Compact count() states. It binds the hidden
  # UInt64 key through the existing Compact context so key declaration,
  # mrk4 callback identity, and global row/mark axes share one physical owner
  # with the selected state column.
  private class CompactAggregateCountReaderAdmission
    FIXED_CHECKSUM_MANIFEST = Set{
      "count.txt",
      "data.bin",
      "primary.idx",
      "serialization.json",
    }

    def self.validate_projection_count!(
      part_path : String,
      count_reader : CompactBinaryBulkColumnReader,
      transport_budget : CompressedStreamBudget,
    ) : Array(String)
      path = File.expand_path(part_path)
      transport_budget.ensure_direction(false)

      metadata = PartMetadataFileReader.new(path, transport_budget)
      checksums = PartChecksums.parse(
        metadata.read("checksums.txt", PartChecksums::MAX_CHECKSUM_FILE_BYTES).to_slice,
      )
      count_plan = WideAggregateCountStoragePlan.for_type_name(count_reader.schema_declaration) ||
                   raise(UnsupportedFormatError.new("Compact projection child has no admitted Count descriptor"))

      unless count_plan.type_name == WideAggregateCountStoragePlan::NO_ARGUMENT_TYPE_NAME &&
             count_reader.schema_declaration == count_plan.type_name &&
             count_reader.source_declaration == count_plan.type_name &&
             count_reader.row_count > 0_u64
        raise CorruptPartError.new("Compact projection Count reader differs from its exact child declaration or row count")
      end

      key_names = count_reader.projection_count_sibling_key_names!

      selected_checksum_names = count_reader.selected_checksum_names
      mark_name = selected_checksum_names[1]?
      unless mark_name && (mark_name == "data.mrk4" || mark_name == "data.cmrk4")
        raise UnsupportedFormatError.new("Compact projection Count requires one MRK4 mark sidecar")
      end
      unless selected_checksum_names == ["data.bin", mark_name]
        raise CorruptPartError.new("Compact projection Count checksum selection differs from its physical data and mark files")
      end
      expected_manifest = FIXED_CHECKSUM_MANIFEST.dup
      expected_manifest << mark_name
      unless checksums.entries.keys.to_set == expected_manifest
        raise UnsupportedFormatError.new("Compact projection Count physical manifest is outside the admitted MRK4 child profile")
      end
      checksums.entries.each_key do |name|
        checksums.validate_selected_entries(path, name)
      end

      expected_count_streams = [PhysicalStreamName.escape("count()")]
      unless count_reader.physical_stream_names == expected_count_streams
        raise CorruptPartError.new("Compact projection Count state callback roster differs from its exact physical plan")
      end

      key_names.map { |name| String.new(name.to_slice) }
    end
  end
end

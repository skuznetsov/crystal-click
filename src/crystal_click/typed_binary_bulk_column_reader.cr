module CrystalClick
  # Format-neutral entry point for a selected static BinaryBulk column.
  # Wide and Compact parts retain their own physical reader and workspace
  # accounting; this wrapper only selects the backend and forwards the shared
  # logical-column API.
  class TypedBinaryBulkColumnReader
    getter row_count : UInt64
    getter mark_count : Int32
    getter ordinary_profile : BinaryBulkProfile
    getter logical_read_bytes : UInt64

    @reader : BinaryBulkColumnReader | CompactBinaryBulkColumnReader

    def self.open(
      part_path : String,
      column_name : String,
      expected_type : BinaryDataType,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
      transport_limits : CompressedStreamLimits = CompressedStreamLimits.new,
      codec_budget : BinaryCodecBudget? = nil,
      transport_budget : CompressedStreamBudget? = nil,
    ) : TypedBinaryBulkColumnReader
      StorageReadBudgetValidator.validate!(
        codec_budget,
        transport_budget,
        limits,
        transport_limits,
        "typed BinaryBulk reader codec budget differs from its read limits",
        "typed BinaryBulk reader transport budget differs from its read limits",
      )
      dispatch_budget = transport_budget || CompressedStreamBudget.new(transport_limits)
      path = File.expand_path(part_path)
      metadata = PartMetadataFileReader.new(path, dispatch_budget)
      checksums = PartChecksums.parse(
        metadata.read("checksums.txt", PartChecksums::MAX_CHECKSUM_FILE_BYTES).to_slice
      )
      if CompactMarkFileAdapter.routing_candidate?(path, checksums)
        effective_transport_budget = transport_budget || dispatch_budget
        reader = CompactBinaryBulkColumnReader.open(
          part_path,
          column_name,
          expected_type,
          limits,
          transport_limits,
          codec_budget,
          effective_transport_budget,
        )
        new(reader)
      else
        reader = BinaryBulkColumnReader.open(
          part_path,
          column_name,
          expected_type,
          limits,
          transport_limits,
          codec_budget,
          transport_budget,
        )
        new(reader)
      end
    end

    private def initialize(reader : BinaryBulkColumnReader | CompactBinaryBulkColumnReader)
      @reader = reader
      @row_count = reader.row_count
      @mark_count = reader.mark_count
      @ordinary_profile = reader.ordinary_profile
      @logical_read_bytes = reader.logical_read_bytes
    end

    def schema_declaration : String
      @reader.schema_declaration
    end

    def source_declaration : String
      @reader.source_declaration
    end

    def mark_row_counts : Array(UInt64)
      @reader.mark_row_counts
    end

    def physical_stream_names : Array(String)
      @reader.physical_stream_names
    end

    def selected_checksum_names : Array(String)
      @reader.selected_checksum_names
    end

    def retained_grid_workspace_bytes : UInt64
      @reader.retained_grid_workspace_bytes
    end

    # Backend-owned live reader structures, not a guessed physical format.
    # Compact supplies its context/profile accounting directly; the established
    # Wide estimate retains only objects that BinaryBulkColumnReader actually
    # owns. Shared result/window containers are charged by the caller.
    def retained_workspace_bytes : UInt64
      bytes = instance_sizeof(TypedBinaryBulkColumnReader).to_u64
      case reader = @reader
      when CompactBinaryBulkColumnReader
        checked_add(bytes, reader.retained_workspace_bytes)
      when BinaryBulkColumnReader
        bytes = checked_add(bytes, instance_sizeof(BinaryBulkColumnReader).to_u64)
        bytes = checked_add(bytes, instance_sizeof(BinaryBulkPhysicalPlan).to_u64)
        bytes = checked_add(bytes, instance_sizeof(PartStreamSource).to_u64)
        checked_add(bytes, reader.retained_grid_workspace_bytes)
      else
        raise UnsupportedFormatError.new("typed BinaryBulk reader backend is unsupported")
      end
    end

    def read_marks(first_mark : Int, mark_count : Int) : Array(Array(BinaryValue))
      @reader.read_marks(first_mark, mark_count)
    end

    # Reports Compact's live normalization workspace before an allocation
    # phase. Wide keeps its established reader path and does not use this
    # Compact-specific accounting hook.
    def read_marks(
      first_mark : Int,
      mark_count : Int,
      workspace_observer : Proc(UInt64, Nil),
    ) : Array(Array(BinaryValue))
      case reader = @reader
      when CompactBinaryBulkColumnReader
        reader.read_marks(first_mark, mark_count, workspace_observer)
      when BinaryBulkColumnReader
        reader.read_marks(first_mark, mark_count)
      else
        raise UnsupportedFormatError.new("typed BinaryBulk reader backend is unsupported")
      end
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      raise BoundsError.new("typed BinaryBulk workspace charge overflows UInt64") if right > UInt64::MAX - left
      left + right
    end
  end
end

module CrystalClick
  # Nominal Nested guard over the shared static BinaryBulk part reader.
  # Keeping this facade preserves the older API's admission boundary while
  # the implementation is shared with other statically planned descriptors.
  class NestedBulkColumnReader
    @reader : BinaryBulkColumnReader

    def self.open(
      part_path : String,
      column_name : String,
      expected_type : BinaryDataType,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
      transport_limits : CompressedStreamLimits = CompressedStreamLimits.new,
    ) : NestedBulkColumnReader
      new(part_path, column_name, expected_type, limits, transport_limits)
    end

    private def initialize(
      part_path : String,
      column_name : String,
      expected_type : BinaryDataType,
      limits : BinaryCodecLimits,
      transport_limits : CompressedStreamLimits,
    )
      unless expected_type.tag == BinaryDataType::TAG_NESTED
        raise UnsupportedFormatError.new("Nested bulk reader requires a nominal Nested descriptor")
      end
      @reader = BinaryBulkColumnReader.open(
        part_path, column_name, expected_type, limits, transport_limits
      )
    end

    def row_count : UInt64
      @reader.row_count
    end

    def mark_count : Int32
      @reader.mark_count
    end

    def ordinary_profile : BinaryBulkProfile
      @reader.ordinary_profile
    end

    def logical_read_bytes : UInt64
      @reader.logical_read_bytes
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

    def read_marks(first_mark : Int, mark_count : Int) : Array(Array(BinaryValue))
      @reader.read_marks(first_mark, mark_count)
    end
  end
end

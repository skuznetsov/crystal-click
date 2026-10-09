require "json"

module CrystalClick
  # Binds one literal Object column in a normalized Wide part to the bounded
  # Object document file reader. Part metadata chooses the ordinary String
  # profile; the Object shared-MAP String profile remains the stock single
  # stream profile.
  class ObjectColumnReader
    MAX_METADATA_FILE_BYTES = ObjectColumnPartMetadata::MAX_METADATA_FILE_BYTES
    MAX_METADATA_LINE_BYTES = ObjectColumnPartMetadata::MAX_METADATA_LINE_BYTES
    MAX_METADATA_COLUMNS    = ObjectColumnPartMetadata::MAX_METADATA_COLUMNS
    MAX_METADATA_SUBSTREAMS = ObjectColumnPartMetadata::MAX_METADATA_SUBSTREAMS
    MAX_CODEC_FILE_BYTES    = ObjectColumnPartMetadata::MAX_CODEC_FILE_BYTES
    MAX_ROWS                = ObjectColumnPartMetadata::MAX_ROWS
    CODEC_LZ4               = ObjectColumnPartMetadata::CODEC_LZ4

    getter row_count : UInt64
    getter ordinary_profile : BinaryBulkProfile
    getter logical_read_bytes : UInt64

    @part_path : String
    @column_name : String
    @typed_schema : Hash(String, BinaryDataType)
    @limits : BinaryCodecLimits
    @transport_limits : CompressedStreamLimits
    @descriptor : ObjectDocumentFileDescriptor
    @schema_declaration : String
    @source_declaration : String

    def self.open(
      part_path : String,
      column_name : String,
      expected_schema : ObjectDocumentSchema,
    ) : ObjectColumnReader
      new(part_path, column_name, expected_schema)
    end

    private def initialize(
      part_path : String,
      column_name : String,
      expected_schema : ObjectDocumentSchema,
    )
      @limits = expected_schema.limits
      metadata = ObjectColumnPartMetadata.open(
        part_path,
        column_name,
        ->(declaration : String) {
          source_schema = ObjectDocumentSchema.parse_declaration(declaration, @limits)
          unless source_schema.declaration == expected_schema.declaration
            raise CorruptPartError.new("part Object declaration differs from the expected schema")
          end
          nil
        },
      )
      @part_path = File.expand_path(part_path)
      @column_name = String.new(column_name.to_slice)
      @transport_limits = CompressedStreamLimits.new
      @typed_schema = expected_schema.typed_paths
      @schema_declaration = expected_schema.declaration
      @source_declaration = metadata.source_declaration

      # The callback parsed the source declaration before the helper examined
      # count, substream, codec, and serialization metadata. Exact canonical
      # equality means the expected schema is the same plan contract.
      source_schema = expected_schema

      row_count = metadata.row_count
      selected_stream_names = metadata.selected_stream_names
      @ordinary_profile = metadata.ordinary_profile
      @descriptor = ObjectDocumentFileReader.inspect(
        @part_path,
        @column_name,
        @typed_schema,
        @ordinary_profile,
        BinaryBulkProfile.single_stream,
        true,
        @limits,
        @transport_limits,
      )
      begin
        expected_schema.validate_plan(@descriptor.plan)
        source_schema.validate_plan(@descriptor.plan)
      rescue ex : ArgumentError
        raise CorruptPartError.new(ex.message || "Object schema does not match its physical plan")
      end
      unless @descriptor.row_count == row_count
        raise CorruptPartError.new("count.txt disagrees with the Object outer mark grid")
      end

      expected_stream_names = @descriptor.physical_stream_names
      expected_stream_names.sort!
      selected_stream_names.sort!
      unless selected_stream_names == expected_stream_names
        raise CorruptPartError.new("selected columns_substreams roster differs from the Object physical plan")
      end

      @row_count = row_count
      @logical_read_bytes = @descriptor.logical_read_bytes
    end

    def mark_row_counts : Array(UInt64)
      @descriptor.mark_row_counts
    end

    # Logical names from the selected Object column's exact substream roster.
    def physical_stream_names : Array(String)
      @descriptor.physical_stream_names
    end

    # Actual checksummed basenames selected by hashed normalized Object layout.
    def selected_checksum_names : Array(String)
      @descriptor.selected_checksum_names
    end

    def schema_declaration : String
      String.new(@schema_declaration.to_slice)
    end

    # The literal type text as stored in columns.txt, detached from its read
    # buffer. schema_declaration is the canonical expected declaration.
    def source_declaration : String
      String.new(@source_declaration.to_slice)
    end

    def read_marks(first_mark : Int, mark_count : Int) : Array(Array(ObjectDocument))
      if first_mark < 0 || mark_count < 0
        raise ArgumentError.new("mark selection must be nonnegative")
      end
      row_counts = @descriptor.mark_row_counts
      if first_mark > row_counts.size || mark_count > row_counts.size - first_mark
        raise ArgumentError.new("mark selection is outside the Object grid")
      end

      selected = ObjectDocumentFileReader.read(
        @part_path,
        @column_name,
        @typed_schema,
        first_mark,
        mark_count,
        @ordinary_profile,
        BinaryBulkProfile.single_stream,
        true,
        @limits,
        @transport_limits,
      )
      unless selected.size == mark_count
        raise CorruptPartError.new("bounded Object read returned the wrong number of marks")
      end
      mark_count.times do |index|
        unless selected[index].size.to_u64 == row_counts[first_mark + index]
          raise CorruptPartError.new("bounded Object rows disagree with the inspected outer grid")
        end
      end
      selected
    end

    # Reads one shared Object path as dense values per physical mark.
    # Advanced layouts avoid root Copy lanes and reconstructing unrelated
    # fields; MAP layouts decode their ordinary shared lane(s) instead.
    def read_shared_path_marks(
      path : String,
      first_mark : Int,
      mark_count : Int,
    ) : Array(Array(BinaryValue))
      if first_mark < 0 || mark_count < 0
        raise ArgumentError.new("mark selection must be nonnegative")
      end
      row_counts = @descriptor.mark_row_counts
      if first_mark > row_counts.size || mark_count > row_counts.size - first_mark
        raise ArgumentError.new("mark selection is outside the Object grid")
      end
      selected = ObjectDocumentFileReader.read_shared_path_marks(
        @part_path,
        @column_name,
        @descriptor,
        path,
        first_mark,
        mark_count,
        @ordinary_profile,
        true,
        @limits,
        @transport_limits,
      )
      unless selected.size == mark_count
        raise CorruptPartError.new("bounded Object shared-path read returned the wrong number of marks")
      end
      mark_count.times do |index|
        unless selected[index].size.to_u64 == row_counts[first_mark + index]
          raise CorruptPartError.new("bounded Object shared-path rows disagree with the inspected outer grid")
        end
      end
      selected
    end
  end
end

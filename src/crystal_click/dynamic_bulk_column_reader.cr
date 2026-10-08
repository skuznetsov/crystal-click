module CrystalClick
  # Reads one complete Dynamic-bearing BinaryBulk column from a normalized
  # Object part. Metadata remains schema-bound here; Dynamic structure, lane,
  # and P/Q scheduling behavior is shared with recursive Dynamic sites.
  class DynamicBulkColumnReader
    getter row_count : UInt64
    getter mark_count : Int32
    getter ordinary_profile : BinaryBulkProfile
    getter logical_read_bytes : UInt64

    @part_path : String
    @column_name : String
    @type : BinaryDataType
    @limits : BinaryCodecLimits
    @transport_limits : CompressedStreamLimits
    @site_reader : DynamicBulkSiteReader
    @schema_declaration : String
    @source_declaration : String

    def self.open(
      part_path : String,
      column_name : String,
      expected_type : BinaryDataType,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
      transport_limits : CompressedStreamLimits = CompressedStreamLimits.new,
    ) : DynamicBulkColumnReader
      new(part_path, column_name, expected_type, limits, transport_limits)
    end

    private def initialize(
      part_path : String,
      column_name : String,
      @type : BinaryDataType,
      @limits : BinaryCodecLimits,
      @transport_limits : CompressedStreamLimits,
    )
      # Bound descriptor/name work before summary predicates, metadata
      # callbacks, or structure discovery can traverse the caller's type.
      name_budget = BinaryCodecBudget.new(@limits)
      name_bounds = BinaryTypeNameBudget.measure(@type, name_budget)
      canonical = BinaryTypeNameBudget.materialize(@type, name_budget, name_bounds)
      name_budget.ensure_wire_bytes(canonical.bytesize.to_u64)
      name_budget.charge_wire_bytes(canonical.bytesize.to_u64)
      @schema_declaration = String.new(canonical.to_slice)

      unless @type.contains_dynamic?
        raise UnsupportedFormatError.new("Dynamic bulk reader requires a Dynamic-bearing descriptor")
      end
      if @type.contains_json?
        raise UnsupportedFormatError.new("JSON is outside the admitted Dynamic bulk profile")
      end
      unless column_name.bytesize > 0 && column_name.bytesize <= WidePartWriter::MAX_COLUMN_NAME_BYTES
        raise ArgumentError.new("Dynamic bulk column name is outside the admitted range")
      end
      @part_path = File.expand_path(part_path)
      @column_name = String.new(column_name.to_slice)

      metadata = ObjectColumnPartMetadata.open(
        @part_path,
        @column_name,
        ->(declaration : String) {
          unless declaration == canonical
            raise CorruptPartError.new("Dynamic source declaration differs from the expected nominal descriptor")
          end
          nil
        },
        subcolumns_validator: ->(subcolumns : Array(JSON::Any), row_count : UInt64) {
          DynamicTupleSerializationMetadataValidator.validate_subcolumns!(
            subcolumns, @type, row_count, @limits
          )
        },
        require_selected_subcolumns: @type.tag == BinaryDataType::TAG_NAMED_TUPLE ||
                                     @type.tag == BinaryDataType::TAG_UNNAMED_TUPLE,
      )
      @source_declaration = metadata.source_declaration
      @ordinary_profile = metadata.ordinary_profile
      if metadata.row_count == 0_u64
        raise CorruptPartError.new("Dynamic bulk part must contain at least one parent row")
      end

      source = PartStreamSource.new(@part_path)
      root_prefix = PhysicalStreamName.escape(@column_name)
      @site_reader = DynamicBulkSiteReader.open(
        source,
        @type,
        root_prefix,
        0_u64,
        @ordinary_profile,
        @limits,
        @transport_limits,
        BinaryCodecBudget.new(@limits),
        CompressedStreamBudget.new(@transport_limits),
        nil,
        nil,
        metadata.row_count,
      )
      expected_stream_names = @site_reader.physical_stream_names.sort!
      actual_stream_names = metadata.selected_stream_names.sort!
      unless actual_stream_names == expected_stream_names
        raise CorruptPartError.new("Dynamic selected columns_substreams roster differs from the physical site plan")
      end

      @row_count = @site_reader.row_count
      @mark_count = @site_reader.mark_count
      @logical_read_bytes = @site_reader.logical_read_bytes
    end

    def schema_declaration : String
      String.new(@schema_declaration.to_slice)
    end

    def source_declaration : String
      String.new(@source_declaration.to_slice)
    end

    def mark_row_counts : Array(UInt64)
      @site_reader.mark_row_counts
    end

    def physical_stream_names : Array(String)
      @site_reader.physical_stream_names
    end

    def selected_checksum_names : Array(String)
      @site_reader.selected_checksum_names
    end

    def retained_grid_workspace_bytes : UInt64
      @site_reader.retained_grid_workspace_bytes
    end

    # Validate the complete parent schedule without selecting a mark. The
    # site reader performs any required full-domain replay for bound JSON or
    # LowCardinality state; table consumers must call this even for empty
    # candidate/window selections.
    def validate_complete_schedule : Nil
      @site_reader.read_marks(0, 0)
      nil
    end

    # Returns selected parent marks as recursive BinaryValues. Dynamic actual
    # arms containing LowCardinality replay the complete state before a
    # middle/end-empty selection. A zero mark count still validates the full
    # schedule and any bound-child replay required by the site plan.
    def read_marks(first_mark : Int, mark_count : Int) : Array(Array(BinaryValue))
      @site_reader.read_marks(first_mark, mark_count)
    end
  end
end

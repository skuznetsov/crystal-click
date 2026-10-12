module CrystalClick
  # Detached Compact metadata for one fixed String-v0/BASIC-MAP schema.
  # Unlike Wide metadata, the roster has no columns_substreams.txt: plain
  # MRK3 carries one whole-column slot per declaration.
  class CompactPartMetadata
    CODEC         = CompactSerializationProfile::CODEC_LZ4
    SERIALIZATION = "{\"columns\":[],\"propagate_types_serialization_versions_to_nested_types\":true,\"types_serialization_versions\":{\"string\":0},\"version\":1}"

    getter columns_text : String
    getter count_text : String
    getter serialization_text : String
    getter codec_text : String
    getter metadata_version_text : String
    getter schema_columns : Array({String, String})
    getter expected_files : Array(String)
    getter row_count : UInt64

    def initialize(
      key_name : String,
      columns : Array(CompactStaticColumnInput),
      @row_count : UInt64,
      limits : BinaryCodecLimits,
      codec_budget : BinaryCodecBudget,
      transport_budget : CompressedStreamBudget,
    )
      unless codec_budget.writing? && same_limits?(codec_budget.limits, limits)
        raise ArgumentError.new("Compact metadata codec budget differs from its write limits")
      end
      transport_budget.ensure_direction(true)
      if columns.empty? || columns.size + 1 > WidePartTable::MAX_COLUMNS
        raise UnsupportedFormatError.new("Compact column count is outside the reader limit")
      end

      @schema_columns = Array({String, String}).new(columns.size + 1)
      key_copy = String.new(key_name.to_slice)
      @schema_columns << {key_copy, "UInt64"}
      declarations = Array(String).new(columns.size)
      column_names = Array(String).new(columns.size)
      declarations_size = line_size(key_name.bytesize.to_u64, "UInt64".bytesize.to_u64)

      columns.each do |column|
        name = String.new(column.name.to_slice)
        bounds = BinaryTypeNameBudget.measure(column.type, codec_budget)
        codec_budget.ensure_wire_bytes(bounds[1])
        declaration = BinaryTypeNameBudget.materialize(column.type, codec_budget, bounds)
        if declaration.empty? || declaration.bytesize > WidePart::MAX_METADATA_LINE_BYTES
          raise UnsupportedFormatError.new("Compact declaration exceeds the metadata line limit")
        end
        declarations << declaration
        column_names << name
        @schema_columns << {String.new(name.to_slice), String.new(declaration.to_slice)}
        declarations_size = checked_add(
          declarations_size,
          line_size(name.bytesize.to_u64, declaration.bytesize.to_u64),
        )
      end

      columns_header = "columns format version: 1\n#{columns.size + 1} columns:\n"
      columns_size = checked_add(columns_header.bytesize.to_u64, declarations_size)
      @count_text = @row_count.to_s
      @serialization_text = String.new(SERIALIZATION.to_slice)
      @codec_text = String.new(CODEC.to_slice)
      @metadata_version_text = "0"
      output_bytes = checked_add(
        columns_size,
        checked_add(
          @count_text.bytesize.to_u64,
          checked_add(
            @serialization_text.bytesize.to_u64,
            checked_add(@codec_text.bytesize.to_u64, @metadata_version_text.bytesize.to_u64),
          ),
        ),
      )
      if columns_size > WidePart::MAX_METADATA_FILE_BYTES.to_u64 ||
         @count_text.bytesize > WidePart::MAX_METADATA_FILE_BYTES ||
         @serialization_text.bytesize > WidePart::MAX_METADATA_FILE_BYTES
        raise UnsupportedFormatError.new("Compact metadata exceeds the reader file limit")
      end
      if @codec_text.bytesize > WidePart::MAX_CODEC_FILE_BYTES
        raise UnsupportedFormatError.new("Compact codec metadata exceeds its reader limit")
      end

      # Type-name measurement/materialization above is charged by
      # BinaryTypeNameBudget. Once the exact file sizes are known, reserve
      # those files and a conservative metadata-copy workspace before building
      # the final columns text or staging any files. Small bounded declaration
      # and fixed metadata strings already exist at this point.
      if output_bytes > UInt64::MAX // 2_u64
        raise UnsupportedFormatError.new("Compact metadata workspace overflows")
      end
      metadata_workspace = output_bytes * 2_u64
      codec_budget.ensure_wire_bytes(output_bytes)
      codec_budget.charge_wire_bytes(output_bytes)
      transport_budget.reserve_file_bytes(to_i64(output_bytes))
      transport_budget.reserve_result_bytes(to_i64(metadata_workspace))

      @columns_text = String.build do |io|
        io << columns_header
        io << '`' << key_copy << "` UInt64\n"
        columns.size.times do |index|
          io << '`' << column_names[index] << "` " << declarations[index] << '\n'
        end
      end
      unless @columns_text.bytesize.to_u64 == columns_size
        raise UnsupportedFormatError.new("Compact columns metadata differed from its preflight")
      end

      @expected_files = [
        "columns.txt",
        "count.txt",
        "data.bin",
        "data.mrk3",
        "default_compression_codec.txt",
        "metadata_version.txt",
        "primary.idx",
        "serialization.json",
        "checksums.txt",
      ]
    end

    private def same_limits?(left : BinaryCodecLimits, right : BinaryCodecLimits) : Bool
      left.max_depth == right.max_depth && left.max_nodes == right.max_nodes &&
        left.max_elements == right.max_elements && left.max_bytes == right.max_bytes
    end

    private def line_size(name_bytes : UInt64, type_bytes : UInt64) : UInt64
      checked_add(checked_add(name_bytes, type_bytes), 4_u64)
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if left > UInt64::MAX - right
        raise UnsupportedFormatError.new("Compact metadata size overflows UInt64")
      end
      left + right
    end

    private def to_i64(value : UInt64) : Int64
      if value > Int64::MAX.to_u64
        raise UnsupportedFormatError.new("Compact metadata size exceeds the supported domain")
      end
      value.to_i64
    end
  end
end

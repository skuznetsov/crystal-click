module CrystalClick
  # Detached Compact metadata for one fixed String-v0/BASIC-MAP schema.
  # MRK3 carries one whole-column slot per declaration; MRK4 records the exact
  # serializer callback roster in columns_substreams.txt.
  class CompactPartMetadata
    CODEC         = CompactSerializationProfile::CODEC_LZ4
    SERIALIZATION = "{\"columns\":[],\"propagate_types_serialization_versions_to_nested_types\":true,\"types_serialization_versions\":{\"string\":0},\"version\":1}"

    getter columns_text : String
    getter count_text : String
    getter serialization_text : String
    getter codec_text : String
    getter metadata_version_text : String
    getter columns_substreams_text : String
    getter schema_columns : Array({String, String})
    getter expected_files : Array(String)
    getter row_count : UInt64
    getter mark_format : CompactMarkFormat
    getter slot_count : Int32
    getter physical_roster_snapshot_workspace_bytes : UInt64

    @substreams : Array({String, Array(String)})

    def initialize(
      key_name : String,
      columns : Array(T),
      @row_count : UInt64,
      limits : BinaryCodecLimits,
      codec_budget : BinaryCodecBudget,
      transport_budget : CompressedStreamBudget,
      write_plan : W,
    ) forall T, W
      unless codec_budget.writing? && same_limits?(codec_budget.limits, limits)
        raise ArgumentError.new("Compact metadata codec budget differs from its write limits")
      end
      transport_budget.ensure_direction(true)
      if columns.empty? || columns.size + 1 > WidePartTable::MAX_COLUMNS
        raise UnsupportedFormatError.new("Compact column count is outside the reader limit")
      end
      unless write_plan.column_count == columns.size + 1 && write_plan.slot_count > 0
        raise UnsupportedFormatError.new("Compact write plan differs from the metadata columns")
      end
      @mark_format = write_plan.mark_format
      @slot_count = write_plan.slot_count

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
      @substreams = if @mark_format.mrk4?
                      transport_budget.reserve_result_bytes(to_i64(write_plan.substreams_workspace_bytes))
                      write_plan.substreams
                    elsif @mark_format.mrk3?
                      [] of {String, Array(String)}
                    else
                      raise UnsupportedFormatError.new("unsupported Compact mark format")
                    end
      substreams_size = if @mark_format.mrk4?
                          measure_substreams_size(@substreams, @schema_columns)
                        else
                          0_u64
                        end
      @physical_roster_snapshot_workspace_bytes = if @mark_format.mrk4?
                                                    physical_roster_snapshot_workspace(@substreams)
                                                  else
                                                    0_u64
                                                  end
      @count_text = @row_count.to_s
      @serialization_text = String.new(SERIALIZATION.to_slice)
      @codec_text = String.new(CODEC.to_slice)
      @metadata_version_text = "0"
      if substreams_size > WidePart::MAX_METADATA_FILE_BYTES.to_u64
        raise UnsupportedFormatError.new("Compact columns_substreams.txt exceeds the reader file limit")
      end
      output_bytes = checked_add(
        columns_size,
        checked_add(
          @count_text.bytesize.to_u64,
          checked_add(
            @serialization_text.bytesize.to_u64,
            checked_add(
              @codec_text.bytesize.to_u64,
              checked_add(@metadata_version_text.bytesize.to_u64, substreams_size),
            ),
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
      @columns_substreams_text = if @mark_format.mrk4?
                                   build_substreams_text(@substreams)
                                 else
                                   ""
                                 end
      unless @columns_substreams_text.bytesize.to_u64 == substreams_size
        raise UnsupportedFormatError.new("Compact substream metadata differed from its preflight")
      end

      @expected_files = [
        "columns.txt",
        "count.txt",
        "data.bin",
        mark_file_name,
        "default_compression_codec.txt",
        "metadata_version.txt",
        "primary.idx",
        "serialization.json",
        "checksums.txt",
      ]
      @expected_files << "columns_substreams.txt" if @mark_format.mrk4?
    end

    # Compares the staged reader's detached physical roster against the exact
    # callback snapshot used to build columns_substreams.txt. This does not
    # ask the write plan to regenerate its public roster copy.
    def physical_roster_matches?(roster : Array(CompactPhysicalSlot)) : Bool
      return false unless roster.size == @slot_count

      slot_index = 0
      if @mark_format.mrk3?
        return false unless roster.size == @schema_columns.size
        @schema_columns.each_with_index do |(column_name, _type), index|
          slot = roster[index]?
          return false unless slot && slot.index == index && slot.column_name == column_name && slot.stream_name.nil?
        end
        return true
      end

      return false unless @mark_format.mrk4?
      @substreams.each do |column_name, streams|
        streams.each do |stream_name|
          slot = roster[slot_index]?
          return false unless slot && slot.index == slot_index && slot.column_name == column_name &&
                              slot.stream_name == stream_name
          slot_index += 1
        end
      end
      slot_index == roster.size
    end

    private def same_limits?(left : BinaryCodecLimits, right : BinaryCodecLimits) : Bool
      left.max_depth == right.max_depth && left.max_nodes == right.max_nodes &&
        left.max_elements == right.max_elements && left.max_bytes == right.max_bytes
    end

    private def line_size(name_bytes : UInt64, type_bytes : UInt64) : UInt64
      checked_add(checked_add(name_bytes, type_bytes), 4_u64)
    end

    private def measure_substreams_size(
      substreams : Array({String, Array(String)}),
      schema_columns : Array({String, String}),
    ) : UInt64
      unless substreams.size == schema_columns.size && substreams.size <= WidePartTable::MAX_COLUMNS
        raise UnsupportedFormatError.new("Compact substream roster differs from the schema columns")
      end

      total_streams = 0
      bytes = "columns substreams version: 1\n".bytesize.to_u64
      bytes = checked_add(bytes, "#{schema_columns.size} columns:\n".bytesize.to_u64)
      substreams.each_with_index do |(column_name, streams), index|
        unless column_name == schema_columns[index][0] && !streams.empty?
          raise UnsupportedFormatError.new("Compact substream roster order differs from the schema")
        end
        if streams.size > WidePart::MAX_METADATA_SUBSTREAMS - total_streams
          raise UnsupportedFormatError.new("Compact substream roster exceeds the reader limit")
        end
        total_streams += streams.size
        bytes = checked_add(
          bytes,
          "#{streams.size} substreams for column `#{column_name}`:\n".bytesize.to_u64,
        )
        streams.each do |stream_name|
          if stream_name.empty? || stream_name.bytesize > WidePart::MAX_METADATA_LINE_BYTES
            raise UnsupportedFormatError.new("Compact physical stream name exceeds the metadata line limit")
          end
          bytes = checked_add(bytes, stream_name.bytesize.to_u64 + 2_u64)
        end
      end
      unless total_streams == @slot_count
        raise UnsupportedFormatError.new("Compact substream roster differs from the mark slot count")
      end
      bytes
    end

    private def build_substreams_text(substreams : Array({String, Array(String)})) : String
      String.build do |io|
        io << "columns substreams version: 1\n"
        io << substreams.size << " columns:\n"
        substreams.each do |column_name, streams|
          io << streams.size << " substreams for column `" << column_name << "`:\n"
          streams.each { |stream_name| io << '\t' << stream_name << '\n' }
        end
      end
    end

    private def physical_roster_snapshot_workspace(
      substreams : Array({String, Array(String)}),
    ) : UInt64
      slot_count = @slot_count.to_u64
      bytes = instance_sizeof(Array(CompactPhysicalSlot)).to_u64
      bytes = checked_add(bytes, checked_multiply(slot_count, sizeof(Pointer(CompactPhysicalSlot)).to_u64))
      substreams.each do |column_name, streams|
        streams.each do |stream_name|
          bytes = checked_add(bytes, instance_sizeof(CompactPhysicalSlot).to_u64)
          bytes = checked_add(bytes, string_owner_bytes(column_name))
          bytes = checked_add(bytes, string_owner_bytes(stream_name))
        end
      end
      bytes
    end

    private def string_owner_bytes(value : String) : UInt64
      checked_add(instance_sizeof(String).to_u64, value.bytesize.to_u64 + 1_u64)
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise UnsupportedFormatError.new("Compact physical roster workspace overflows")
      end
      left * right
    end

    private def mark_file_name : String
      case @mark_format
      when CompactMarkFormat::Mrk3
        "data.mrk3"
      when CompactMarkFormat::Mrk4
        "data.mrk4"
      else
        raise UnsupportedFormatError.new("unsupported Compact mark format")
      end
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

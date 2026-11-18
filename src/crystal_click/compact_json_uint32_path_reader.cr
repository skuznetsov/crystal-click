module CrystalClick
  # :nodoc:
  # Bounded reader for one declared top-level UInt32 field in a root Compact
  # JSON Object column. It retains only the selected MRK4 stream identity.
  class CompactJsonUInt32PathReader
    UINT32_BYTES = 4_u64

    getter column_name : String

    @source_column_name : String
    @slot_index : Int32
    @context : CompactPartPhysicalContext
    @mark_rows : Array(UInt64)

    def self.open(
      part_path : String,
      physical_columns : Array({String, String}),
      column_name : String,
      source_column_name : String,
      source_declaration : String,
      field_name : String,
      transport_budget : CompressedStreamBudget,
      limits : BinaryCodecLimits = BinaryBulkCodec::DEFAULT_LIMITS,
    ) : CompactJsonUInt32PathReader
      unless !source_column_name.empty? && !field_name.empty? && !field_name.includes?('.') &&
             column_name == "#{source_column_name}.#{field_name}"
        raise UnsupportedFormatError.new("selected Compact JSON path is not a simple top-level field")
      end
      if column_name.bytesize > WidePartTable::MAX_COLUMN_NAME_BYTES
        raise BoundsError.new("selected Compact JSON path exceeds the column-name limit")
      end
      unless physical_columns.any? { |name, type| name == source_column_name && type == source_declaration }
        raise CorruptPartError.new("selected Compact JSON path source differs from columns.txt")
      end

      descriptor = BinaryRecursiveDataTypeNameReader.parse_canonical(source_declaration, limits) ||
                   raise(UnsupportedFormatError.new("selected Compact JSON path requires a canonical JSON declaration"))
      unless descriptor.tag == BinaryDataType::TAG_JSON
        raise UnsupportedFormatError.new("selected Compact JSON path requires a root JSON declaration")
      end
      schema = ObjectDocumentSchema.parse_declaration(source_declaration, limits)
      unless schema.declaration == source_declaration
        raise UnsupportedFormatError.new("selected Compact JSON path requires a canonical Object declaration")
      end
      field_type = schema.typed_type_for(field_name) ||
                   raise(UnsupportedFormatError.new("selected Compact JSON path is not declared as a typed field"))
      unless field_type.tag == BinaryDataType::TAG_UINT32 && field_type.child_count == 0
        raise(UnsupportedFormatError.new("selected Compact JSON path is not a declared simple UInt32 field"))
      end

      context = CompactPartPhysicalContext.open(part_path, transport_budget)
      unless context.mode.mrk4?
        raise UnsupportedFormatError.new("selected Compact JSON UInt32 paths require MRK4")
      end
      unless context.physical_column_type_matches?(source_column_name, source_declaration)
        raise CorruptPartError.new("selected Compact JSON path source changed during admission")
      end

      CompactSerializationProfile.open(
        part_path,
        physical_columns,
        source_column_name,
        descriptor,
        context.row_count,
        transport_budget,
      )
      slot_index = context.validate_fixed_width_stream_spans!(
        source_column_name,
        column_name,
        UINT32_BYTES,
        "JSON UInt32 path",
      )
      mark_rows = context.mark_row_counts
      mark_total = 0_u64
      mark_rows.each do |mark_rows_count|
        if mark_rows_count > UInt64::MAX - mark_total
          raise CorruptPartError.new("selected Compact JSON path mark row count overflows")
        end
        mark_total += mark_rows_count
      end
      unless mark_total == context.row_count && mark_rows.size == context.granule_count
        raise CorruptPartError.new("selected Compact JSON path mark grid differs from its parent row count")
      end
      new(column_name, source_column_name, slot_index, context, mark_rows)
    end

    private def initialize(
      column_name : String,
      source_column_name : String,
      @slot_index : Int32,
      @context : CompactPartPhysicalContext,
      @mark_rows : Array(UInt64),
    )
      @column_name = String.new(column_name.to_slice)
      @source_column_name = String.new(source_column_name.to_slice)
    end

    def row_count : UInt64
      @context.row_count
    end

    def mark_row_counts : Array(UInt64)
      @mark_rows.dup
    end

    def schema_declaration : String
      "UInt32"
    end

    def retained_workspace_bytes : UInt64
      bytes = instance_sizeof(CompactJsonUInt32PathReader).to_u64
      bytes = checked_add(bytes, @context.retained_workspace_bytes)
      bytes = checked_add(bytes, @context.retained_grid_workspace_bytes)
      bytes = checked_add(bytes, string_owner_bytes(@column_name))
      bytes = checked_add(bytes, string_owner_bytes(@source_column_name))
      bytes = checked_add(bytes, instance_sizeof(Array(UInt64)).to_u64)
      checked_add(bytes, @mark_rows.size.to_u64 * sizeof(UInt64).to_u64)
    end

    def workspace_bytes_for_mark(mark_index : Int) : UInt64
      @context.fixed_width_stream_workspace_bytes(
        @source_column_name,
        @slot_index,
        mark_index,
        @column_name,
        UINT32_BYTES,
        "JSON UInt32 path",
      )
    end

    def read_mark_into(
      mark_index : Int,
      destination : Bytes,
      workspace : CompressedBlock::DecodeWorkspace,
    ) : Nil
      @context.read_fixed_width_stream_mark_into(
        @source_column_name,
        @slot_index,
        mark_index,
        @column_name,
        UINT32_BYTES,
        "JSON UInt32 path",
        destination,
        workspace,
      )
      {% if IO::ByteFormat::SystemEndian == IO::ByteFormat::BigEndian %}
        rows = @mark_rows[mark_index]
        rows.to_i.times do |index|
          bytes = destination[index * sizeof(UInt32), sizeof(UInt32)]
          IO::ByteFormat::BigEndian.encode(IO::ByteFormat::LittleEndian.decode(UInt32, bytes), bytes)
        end
      {% end %}
      nil
    end

    private def string_owner_bytes(value : String) : UInt64
      checked_add(instance_sizeof(String).to_u64, value.bytesize.to_u64)
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise CorruptPartError.new("Compact JSON UInt32 path workspace estimate overflows")
      end
      left + right
    end
  end
end

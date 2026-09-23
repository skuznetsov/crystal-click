module CrystalClick
  alias WidePartNumericArray = Array(UInt8) | Array(UInt16) | Array(UInt32) | Array(UInt64) |
                               Array(Int8) | Array(Int16) | Array(Int32) | Array(Int64) |
                               Array(Float32) | Array(Float64)
  alias WidePartNumericSlice = Slice(UInt8) | Slice(UInt16) | Slice(UInt32) | Slice(UInt64) |
                               Slice(Int8) | Slice(Int16) | Slice(Int32) | Slice(Int64) |
                               Slice(Float32) | Slice(Float64)
  alias WidePartNullableArray = Array(UInt8?) | Array(UInt16?) | Array(UInt32?) | Array(UInt64?) |
                                Array(Int8?) | Array(Int16?) | Array(Int32?) | Array(Int64?) |
                                Array(Float32?) | Array(Float64?)
  alias WidePartNullableSlice = Slice(UInt8?) | Slice(UInt16?) | Slice(UInt32?) | Slice(UInt64?) |
                                Slice(Int8?) | Slice(Int16?) | Slice(Int32?) | Slice(Int64?) |
                                Slice(Float32?) | Slice(Float64?)
  alias WidePartNullableStringArray = Array(String?)
  alias WidePartNullableStringSlice = Slice(String?)

  # A callback view over aligned selected columns from one bounded table batch.
  # Column slices alias per-mark arrays and are valid only until the callback
  # returns; callers that need to retain values must copy them.
  struct WidePartTableBatch
    getter part_index : Int32
    getter part_name : String
    getter part_path : String
    getter mark_index : Int32
    getter mark_row_offset : UInt64
    getter part_row_offset : UInt64
    getter source_row_offset : UInt64

    @column_names : Array(String)
    @column_types : Array(String)
    @column_values : Array(WidePartNumericSlice)
    @typed_numeric_values : Hash(String, WidePartNumericSlice)
    @string_values : Hash(String, Slice(String))
    @nullable_values : Hash(String, WidePartNullableSlice)
    @nullable_string_values : Hash(String, WidePartNullableStringSlice)

    def initialize(
      @part_index : Int32,
      @part_name : String,
      @part_path : String,
      @mark_index : Int32,
      @mark_row_offset : UInt64,
      @part_row_offset : UInt64,
      @source_row_offset : UInt64,
      @column_names : Array(String),
      column_types : Array(String),
      @column_values : Array(WidePartNumericSlice),
    )
      @column_types = column_types
      @typed_numeric_values = Hash(String, WidePartNumericSlice).new
      @string_values = Hash(String, Slice(String)).new
      @nullable_values = Hash(String, WidePartNullableSlice).new
      @nullable_string_values = Hash(String, WidePartNullableStringSlice).new
    end

    # Preserve the original UInt64 batch construction contract.
    def initialize(
      @part_index : Int32,
      @part_name : String,
      @part_path : String,
      @mark_index : Int32,
      @mark_row_offset : UInt64,
      @part_row_offset : UInt64,
      @source_row_offset : UInt64,
      @column_names : Array(String),
      column_values : Array(Slice(UInt64)),
    )
      @column_types = Array(String).new(column_values.size, "UInt64")
      @column_values = column_values.map { |values| values.as(WidePartNumericSlice) }
      @typed_numeric_values = Hash(String, WidePartNumericSlice).new
      @string_values = Hash(String, Slice(String)).new
      @nullable_values = Hash(String, WidePartNullableSlice).new
      @nullable_string_values = Hash(String, WidePartNullableStringSlice).new
    end

    # Preserve the existing typed/hash construction contract. Batches created
    # through this overload simply have no materialized Nullable(String) data.
    def initialize(
      @part_index : Int32,
      @part_name : String,
      @part_path : String,
      @mark_index : Int32,
      @mark_row_offset : UInt64,
      @part_row_offset : UInt64,
      @source_row_offset : UInt64,
      @column_names : Array(String),
      @column_types : Array(String),
      @typed_numeric_values : Hash(String, WidePartNumericSlice),
      @string_values : Hash(String, Slice(String)),
      @nullable_values : Hash(String, WidePartNullableSlice),
    )
      @column_values = [] of WidePartNumericSlice
      @nullable_string_values = Hash(String, WidePartNullableStringSlice).new
    end

    def initialize(
      @part_index : Int32,
      @part_name : String,
      @part_path : String,
      @mark_index : Int32,
      @mark_row_offset : UInt64,
      @part_row_offset : UInt64,
      @source_row_offset : UInt64,
      @column_names : Array(String),
      @column_types : Array(String),
      @typed_numeric_values : Hash(String, WidePartNumericSlice),
      @string_values : Hash(String, Slice(String)),
      @nullable_values : Hash(String, WidePartNullableSlice),
      @nullable_string_values : Hash(String, WidePartNullableStringSlice),
    )
      @column_values = [] of WidePartNumericSlice
    end

    def column_names : Array(String)
      @column_names.dup
    end

    def values_for(column : String) : Slice(UInt64)
      index = column_index(column)
      raise UnsupportedFormatError.new("UInt64 accessor requires an exact UInt64 column") unless @column_types[index] == "UInt64"
      return @typed_numeric_values[column].as(Slice(UInt64)) if @typed_numeric_values.has_key?(column)
      @column_values[index].as(Slice(UInt64))
    end

    # Return a typed view only when the caller's exact type matches the on-disk
    # declaration; equal-width signed/unsigned or float/integer reinterpretation
    # is not permitted.
    def values_for(column : String, type : T.class) : Slice(T) forall T
      index = column_index(column)
      type_name = WidePart.numeric_type_name(type)
      unless WidePart.supports_numeric_type?(type_name) && @column_types[index] == type_name
        raise UnsupportedFormatError.new("typed accessor does not match selected column type")
      end
      return @typed_numeric_values[column].as(Slice(T)) if @typed_numeric_values.has_key?(column)
      @column_values[index].as(Slice(T))
    end

    def strings_for(column : String) : Slice(String)
      index = column_index(column)
      raise UnsupportedFormatError.new("String accessor requires an exact String column") unless @column_types[index] == "String"
      @string_values[column]? || raise(UnsupportedFormatError.new("String column was not materialized in this batch"))
    end

    def nullable_values_for(column : String, type : T.class) : Slice(T?) forall T
      index = column_index(column)
      type_name = "Nullable(#{WidePart.numeric_type_name(type)})"
      raise UnsupportedFormatError.new("typed accessor does not match selected Nullable column type") unless @column_types[index] == type_name
      (@nullable_values[column]? || raise(UnsupportedFormatError.new("Nullable column was not materialized in this batch"))).as(Slice(T?))
    end

    def nullable_strings_for(column : String) : Slice(String?)
      index = column_index(column)
      raise UnsupportedFormatError.new("Nullable(String) accessor requires an exact Nullable(String) column") unless @column_types[index] == "Nullable(String)"
      @nullable_string_values[column]? || raise(UnsupportedFormatError.new("Nullable(String) column was not materialized in this batch"))
    end

    private def column_index(column : String) : Int
      index = @column_names.index(column)
      raise UnsupportedFormatError.new("column is not selected") unless index
      index
    end
  end

  # A correctness-first reader over caller-selected immutable Wide-part paths.
  # It does not discover active parts or execute a query language. Each mark is
  # materialized for selected columns, checked for row alignment, then exposed
  # in bounded callback slices.
  class WidePartTable
    MAX_PARTS             = 1_024
    MAX_COLUMNS           =    16
    MAX_PART_NAME_BYTES   = MergeTreePartInfo::MAX_NAME_BYTES
    MAX_PART_PATH_BYTES   =         4_096
    MAX_COLUMN_NAME_BYTES =         4_096
    MAX_MARKS_PER_READER  =        65_536
    MAX_TOTAL_MARKS       = 1_000_000_u64
    # At the 16-column limit a full mark is capped at 8 MiB for the widest types.
    MAX_MARK_ROWS = 65_536_u64
    # Variable-width selected String data is preflighted and then rechecked
    # after materialization; one mark is capped independently of batch_rows.
    MAX_MARK_MATERIALIZED_BYTES = 64 * 1024 * 1024
    MAX_TOTAL_ROWS              = 100_000_000_000_u64
    DEFAULT_BATCH_ROWS          =               4_096
    MAX_BATCH_ROWS              =               4_096

    getter part_count : Int32
    getter total_row_count : UInt64
    getter checksum_verification : ChecksumVerification

    private struct ColumnReader
      getter name : String
      getter reader : WidePart

      def column_type : String
        @reader.column_type
      end

      def initialize(@name : String, @reader : WidePart)
      end
    end

    private struct PartEntry
      getter name : String
      getter path : String
      getter row_count : UInt64
      getter mark_row_counts : Array(UInt64)
      getter readers : Array(ColumnReader)
      getter column_types : Array(String)
      getter column_sources : Array({String, String, String})

      def initialize(
        @name : String,
        @path : String,
        @row_count : UInt64,
        @mark_row_counts : Array(UInt64),
        @readers : Array(ColumnReader),
        @column_types : Array(String),
        @column_sources : Array({String, String, String}),
      )
      end
    end

    @columns : Array(String)
    @entries : Array(PartEntry)
    @numeric_mode : Bool
    @typed_mode : Bool

    def self.open_selected(parts : Array(String), columns : Array(String)) : WidePartTable
      new(parts, columns, false, false)
    end

    def self.open_selected_numeric(parts : Array(String), columns : Array(String)) : WidePartTable
      new(parts, columns, true, false)
    end

    def self.open_selected_typed(parts : Array(String), columns : Array(String)) : WidePartTable
      new(parts, columns, false, true)
    end

    def columns : Array(String)
      @columns.dup
    end

    def column_types : Array({String, String})
      return [] of {String, String} if @entries.empty?
      @entries.first.readers.map { |selected| {selected.name, selected.column_type} }
    end

    # Retain the physical source identity for virtual JSON typed paths so the
    # offline table can compare full JSON schemas before exposing callbacks.
    def column_sources : Array({String, String, String})
      return [] of {String, String, String} if @entries.empty?
      @entries.first.readers.map do |selected|
        {selected.name, selected.reader.source_column_name, selected.reader.source_column_type}
      end
    end

    # The callback receives one row-aligned slice per selected column. Slices
    # alias the current mark arrays and must not be retained past the callback.
    def scan(batch_rows : Int = DEFAULT_BATCH_ROWS, & : WidePartTableBatch -> Nil) : Nil
      raise BoundsError.new("batch row count is out of range") if batch_rows <= 0 || batch_rows > MAX_BATCH_ROWS
      unless @entries.all? { |part| part.readers.all? { |selected| selected.column_type == "UInt64" } }
        raise UnsupportedFormatError.new("UInt64 scan requires exact UInt64 columns")
      end

      scan_rows(batch_rows) { |batch| yield batch }
    end

    # Scan mixed fixed-width primitive numeric columns. Typed values are
    # retrieved from each batch with values_for(column, CrystalType).
    def scan_numeric(batch_rows : Int = DEFAULT_BATCH_ROWS, & : WidePartTableBatch -> Nil) : Nil
      raise BoundsError.new("batch row count is out of range") if batch_rows <= 0 || batch_rows > MAX_BATCH_ROWS
      unless @entries.all? { |part| part.readers.all? { |selected| WidePart.supports_numeric_type?(selected.column_type) } }
        raise UnsupportedFormatError.new("numeric scan requires exact primitive numeric columns")
      end

      scan_rows(batch_rows) { |batch| yield batch }
    end

    # Scan exact String, Nullable(String), fixed-width primitive numeric, and
    # Nullable(primitive numeric) columns. Each selected column's declared
    # type is retained in the callback; no equal-width reinterpretation is
    # permitted.
    def scan_typed(batch_rows : Int = DEFAULT_BATCH_ROWS, & : WidePartTableBatch -> Nil) : Nil
      raise BoundsError.new("batch row count is out of range") if batch_rows <= 0 || batch_rows > MAX_BATCH_ROWS
      scan_typed_rows(batch_rows) { |batch| yield batch }
    end

    private def scan_typed_rows(batch_rows : Int, & : WidePartTableBatch -> Nil) : Nil
      source_row_offset = 0_u64
      @entries.each_with_index do |part, part_index|
        part_row_offset = 0_u64
        part.mark_row_counts.each_with_index do |mark_rows, mark_index|
          # Selected String and Nullable(String) size streams are read first.
          # This preflight bounds raw variable-width materialization before any
          # String array is allocated. The immutable-parts contract is not
          # transactional; the actual aggregate is checked again before
          # callback exposure.
          preflight_string_bytes = 0_u64
          part.readers.each do |selected|
            if selected.column_type == "String" || WidePart.supports_nullable_string_type?(selected.column_type)
              bytes = if selected.column_type == "String"
                        selected.reader.string_mark_range_raw_bytes(selected.name, mark_index, 1)
                      else
                        selected.reader.nullable_string_mark_range_raw_bytes(selected.name, mark_index, 1)
                      end
              if bytes > (MAX_MARK_MATERIALIZED_BYTES.to_u64 - preflight_string_bytes)
                raise CorruptPartError.new("selected String mark exceeds aggregate materialization limit")
              end
              preflight_string_bytes += bytes
            end
          end

          numeric_values = Hash(String, WidePartNumericArray).new
          string_values = Hash(String, Array(String)).new
          nullable_values = Hash(String, WidePartNullableArray).new
          nullable_string_values = Hash(String, WidePartNullableStringArray).new
          actual_string_bytes = 0_u64
          part.readers.each do |selected|
            case selected.column_type
            when "String"
              values = selected.reader.read_string_mark_range(selected.name, mark_index, 1)
              raise CorruptPartError.new("selected String mark row count changed") unless values.size.to_u64 == mark_rows
              values.each do |value|
                bytes = value.bytesize.to_u64
                raise CorruptPartError.new("selected String mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
                actual_string_bytes += bytes
              end
              string_values[selected.name] = values
            when "Nullable(String)"
              values, bytes = selected.reader.read_nullable_string_mark_range_with_raw_bytes(selected.name, mark_index, 1)
              raise CorruptPartError.new("selected Nullable(String) mark row count changed") unless values.size.to_u64 == mark_rows
              raise CorruptPartError.new("selected Nullable(String) mark exceeds aggregate materialization limit") if bytes > MAX_MARK_MATERIALIZED_BYTES.to_u64 - actual_string_bytes
              actual_string_bytes += bytes
              nullable_string_values[selected.name] = values
            when .starts_with?("Nullable(")
              values = read_nullable_values(selected, mark_index)
              raise CorruptPartError.new("selected Nullable mark row count changed") unless nullable_array_size(values).to_u64 == mark_rows
              nullable_values[selected.name] = values
            else
              values = read_numeric_values(selected, mark_index)
              raise CorruptPartError.new("selected column mark row count changed") unless values.size.to_u64 == mark_rows
              numeric_values[selected.name] = values
            end
          end

          mark_row_offset = 0_u64
          while mark_row_offset < mark_rows
            remaining = mark_rows - mark_row_offset
            size = remaining < batch_rows.to_u64 ? remaining.to_i : batch_rows
            numeric_slices = Hash(String, WidePartNumericSlice).new
            string_slices = Hash(String, Slice(String)).new
            nullable_slices = Hash(String, WidePartNullableSlice).new
            nullable_string_slices = Hash(String, WidePartNullableStringSlice).new
            part.readers.each do |selected|
              if values = numeric_values[selected.name]?
                numeric_slices[selected.name] = slice_numeric_values(values, mark_row_offset.to_i, size)
              elsif values = string_values[selected.name]?
                string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
              elsif values = nullable_values[selected.name]?
                nullable_slices[selected.name] = slice_nullable_values(values, mark_row_offset.to_i, size)
              elsif values = nullable_string_values[selected.name]?
                nullable_string_slices[selected.name] = values.to_unsafe.to_slice(values.size)[mark_row_offset.to_i, size]
              else
                raise CorruptPartError.new("selected typed column was not materialized")
              end
            end
            batch = WidePartTableBatch.new(
              part_index.to_i32,
              part.name,
              part.path,
              mark_index.to_i32,
              mark_row_offset,
              part_row_offset &+ mark_row_offset,
              source_row_offset &+ part_row_offset &+ mark_row_offset,
              @columns,
              part.column_types,
              numeric_slices,
              string_slices,
              nullable_slices,
              nullable_string_slices
            )
            yield batch
            mark_row_offset &+= size.to_u64
          end

          part_row_offset &+= mark_rows
        end

        raise CorruptPartError.new("part row count changed during scan") unless part_row_offset == part.row_count
        source_row_offset &+= part.row_count
      end

      raise CorruptPartError.new("source row count mismatch") unless source_row_offset == @total_row_count
      nil
    end

    private def scan_rows(batch_rows : Int, & : WidePartTableBatch -> Nil) : Nil
      source_row_offset = 0_u64
      @entries.each_with_index do |part, part_index|
        part_row_offset = 0_u64
        part.mark_row_counts.each_with_index do |mark_rows, mark_index|
          column_values = Array(WidePartNumericArray).new(@columns.size)
          part.readers.each do |selected|
            values = read_numeric_values(selected, mark_index)
            raise CorruptPartError.new("selected column mark row count changed") unless values.size.to_u64 == mark_rows
            column_values << values
          end

          mark_row_offset = 0_u64
          while mark_row_offset < mark_rows
            remaining = mark_rows - mark_row_offset
            size = remaining < batch_rows.to_u64 ? remaining.to_i : batch_rows
            slices = Array(WidePartNumericSlice).new(column_values.size)
            column_values.each do |values|
              slices << slice_numeric_values(values, mark_row_offset.to_i, size)
            end
            batch = WidePartTableBatch.new(
              part_index.to_i32,
              part.name,
              part.path,
              mark_index.to_i32,
              mark_row_offset,
              # Preflight bounds each part and the concatenated source before
              # these additions; WidePart also proves marks sum to row_count.
              part_row_offset &+ mark_row_offset,
              source_row_offset &+ part_row_offset &+ mark_row_offset,
              @columns,
              part.column_types,
              slices
            )
            yield batch
            mark_row_offset &+= size.to_u64
          end

          part_row_offset &+= mark_rows
        end

        raise CorruptPartError.new("part row count changed during scan") unless part_row_offset == part.row_count
        source_row_offset &+= part.row_count
      end

      raise CorruptPartError.new("source row count mismatch") unless source_row_offset == @total_row_count
      nil
    end

    private def read_numeric_values(selected : ColumnReader, mark_index : Int) : WidePartNumericArray
      reader = selected.reader
      case selected.column_type
      when "UInt8"
        reader.read_numeric_mark_range(selected.name, mark_index, 1, UInt8)
      when "UInt16"
        reader.read_numeric_mark_range(selected.name, mark_index, 1, UInt16)
      when "UInt32"
        reader.read_numeric_mark_range(selected.name, mark_index, 1, UInt32)
      when "UInt64"
        reader.read_numeric_mark_range(selected.name, mark_index, 1, UInt64)
      when "Int8"
        reader.read_numeric_mark_range(selected.name, mark_index, 1, Int8)
      when "Int16"
        reader.read_numeric_mark_range(selected.name, mark_index, 1, Int16)
      when "Int32"
        reader.read_numeric_mark_range(selected.name, mark_index, 1, Int32)
      when "Int64"
        reader.read_numeric_mark_range(selected.name, mark_index, 1, Int64)
      when "Float32"
        reader.read_numeric_mark_range(selected.name, mark_index, 1, Float32)
      when "Float64"
        reader.read_numeric_mark_range(selected.name, mark_index, 1, Float64)
      else
        raise UnsupportedFormatError.new("unsupported numeric column type")
      end
    end

    private def slice_numeric_values(values : WidePartNumericArray, offset : Int, size : Int) : WidePartNumericSlice
      case values
      when Array(UInt8)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(UInt16)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(UInt32)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(UInt64)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Int8)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Int16)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Int32)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Int64)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Float32)
        values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Float64)
        values.to_unsafe.to_slice(values.size)[offset, size]
      else
        raise UnsupportedFormatError.new("unsupported numeric column type")
      end
    end

    private def read_nullable_values(selected : ColumnReader, mark_index : Int) : WidePartNullableArray
      reader = selected.reader
      case selected.column_type
      when "Nullable(UInt8)"   then reader.read_nullable_numeric_mark_range(selected.name, mark_index, 1, UInt8)
      when "Nullable(UInt16)"  then reader.read_nullable_numeric_mark_range(selected.name, mark_index, 1, UInt16)
      when "Nullable(UInt32)"  then reader.read_nullable_numeric_mark_range(selected.name, mark_index, 1, UInt32)
      when "Nullable(UInt64)"  then reader.read_nullable_numeric_mark_range(selected.name, mark_index, 1, UInt64)
      when "Nullable(Int8)"    then reader.read_nullable_numeric_mark_range(selected.name, mark_index, 1, Int8)
      when "Nullable(Int16)"   then reader.read_nullable_numeric_mark_range(selected.name, mark_index, 1, Int16)
      when "Nullable(Int32)"   then reader.read_nullable_numeric_mark_range(selected.name, mark_index, 1, Int32)
      when "Nullable(Int64)"   then reader.read_nullable_numeric_mark_range(selected.name, mark_index, 1, Int64)
      when "Nullable(Float32)" then reader.read_nullable_numeric_mark_range(selected.name, mark_index, 1, Float32)
      when "Nullable(Float64)" then reader.read_nullable_numeric_mark_range(selected.name, mark_index, 1, Float64)
      else
        raise UnsupportedFormatError.new("unsupported Nullable numeric column type")
      end
    end

    private def nullable_array_size(values : WidePartNullableArray) : Int
      case values
      when Array(UInt8?)   then values.size
      when Array(UInt16?)  then values.size
      when Array(UInt32?)  then values.size
      when Array(UInt64?)  then values.size
      when Array(Int8?)    then values.size
      when Array(Int16?)   then values.size
      when Array(Int32?)   then values.size
      when Array(Int64?)   then values.size
      when Array(Float32?) then values.size
      when Array(Float64?) then values.size
      else
        raise UnsupportedFormatError.new("unsupported Nullable numeric column type")
      end
    end

    private def slice_nullable_values(values : WidePartNullableArray, offset : Int, size : Int) : WidePartNullableSlice
      case values
      when Array(UInt8?)   then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(UInt16?)  then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(UInt32?)  then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(UInt64?)  then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Int8?)    then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Int16?)   then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Int32?)   then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Int64?)   then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Float32?) then values.to_unsafe.to_slice(values.size)[offset, size]
      when Array(Float64?) then values.to_unsafe.to_slice(values.size)[offset, size]
      else
        raise UnsupportedFormatError.new("unsupported Nullable numeric column type")
      end
    end

    private def initialize(parts : Array(String), columns : Array(String), @numeric_mode : Bool, @typed_mode : Bool)
      raise BoundsError.new("no parts selected") if parts.empty?
      raise BoundsError.new("part count exceeds limit") if parts.size > MAX_PARTS
      raise BoundsError.new("no columns selected") if columns.empty?
      raise BoundsError.new("column count exceeds limit") if columns.size > MAX_COLUMNS

      @columns = Array(String).new(columns.size)
      seen_columns = Set(String).new
      columns.each do |column|
        raise BoundsError.new("column name is empty or exceeds limit") if column.empty? || column.bytesize > MAX_COLUMN_NAME_BYTES
        raise BoundsError.new("duplicate selected column") if seen_columns.includes?(column)
        seen_columns << column
        @columns << column.dup
      end

      @entries = Array(PartEntry).new(parts.size)
      seen_paths = Set(String).new
      selected_parts = Array({String, String, MergeTreePartInfo}).new(parts.size)
      parts.each do |requested_path|
        path, name, info = validate_selected_part(requested_path)
        raise BoundsError.new("duplicate selected part path") if seen_paths.includes?(path)
        seen_paths << path
        selected_parts << {path, name, info}
      end
      reject_overlapping_parts(selected_parts)

      total_rows = 0_u64
      total_marks = 0_u64
      expected_column_types = nil.as(Array(String)?)
      expected_column_sources = nil.as(Array({String, String, String})?)

      # selected_parts remains in caller order. The parsed identities above
      # are used only for the overlap guard; they do not imply Active status.
      selected_parts.each do |selected_part|
        path = selected_part[0]
        name = selected_part[1]
        readers = Array(ColumnReader).new(@columns.size)
        expected_mark_rows = nil.as(Array(UInt64)?)
        expected_row_count = nil.as(UInt64?)
        checksums = PartChecksums.open(path)

        @columns.each do |column|
          reader = if @numeric_mode
                     WidePart.open_numeric(path, column)
                   elsif @typed_mode
                     WidePart.open_typed(path, column)
                   else
                     WidePart.open(path, column)
                   end
          raise BoundsError.new("mark count exceeds per-reader limit") if reader.mark_count > MAX_MARKS_PER_READER
          mark_rows = reader.mark_row_counts
          mark_rows.each do |rows|
            raise BoundsError.new("mark row count exceeds limit") if rows > MAX_MARK_ROWS
          end

          if current_rows = expected_row_count
            raise CorruptPartError.new("selected columns have different row counts") unless reader.row_count == current_rows
          else
            expected_row_count = reader.row_count
          end

          if current_marks = expected_mark_rows
            raise CorruptPartError.new("selected columns have different mark row counts") unless mark_rows == current_marks
          else
            expected_mark_rows = mark_rows
          end

          reader.selected_checksum_names.each do |checksum_name|
            checksums.validate_selected_entries(path, checksum_name)
          end
          readers << ColumnReader.new(column, reader)
          total_marks = checked_total_marks(total_marks, reader.mark_count.to_u64)
        end

        current_column_types = readers.map(&.column_type)
        current_column_sources = readers.map do |selected|
          {selected.name, selected.reader.source_column_name, selected.reader.source_column_type}
        end
        if current_types = expected_column_types
          raise CorruptPartError.new("selected columns have different types across parts") unless current_column_types == current_types
        else
          expected_column_types = current_column_types
        end
        if current_sources = expected_column_sources
          raise CorruptPartError.new("selected columns have different source schemas across parts") unless current_column_sources == current_sources
        else
          expected_column_sources = current_column_sources
        end

        row_count = expected_row_count || raise(CorruptPartError.new("selected part has no readers"))
        mark_row_counts = expected_mark_rows || raise(CorruptPartError.new("selected part has no mark rows"))
        total_rows = checked_total_rows(total_rows, row_count)
        @entries << PartEntry.new(name, path, row_count, mark_row_counts, readers, current_column_types, current_column_sources)
      end

      @part_count = @entries.size.to_i32
      @total_row_count = total_rows
      @checksum_verification = ChecksumVerification::SizeChecked
    end

    private def validate_selected_part(requested_path : String) : {String, String, MergeTreePartInfo}
      raise BoundsError.new("part path is empty or exceeds limit") if requested_path.empty? || requested_path.bytesize > MAX_PART_PATH_BYTES
      path = File.expand_path(requested_path)
      name = File.basename(path)
      raise BoundsError.new("part name exceeds limit") if name.bytesize > MAX_PART_NAME_BYTES
      info = MergeTreePartInfo.parse(name) || raise(InvalidPartError.new("invalid selected part name: #{name}"))
      raise UnsupportedFormatError.new("patch parts are not supported") if info.patch?
      raise InvalidPartError.new("selected part is a symbolic link: #{name}") if File.symlink?(path)
      raise InvalidPartError.new("selected part is not a directory: #{name}") unless Dir.exists?(path)
      {path, name, info}
    rescue ex : IO::Error
      raise InvalidPartError.new(ex.message || "cannot read selected part")
    end

    private def reject_overlapping_parts(parts : Array({String, String, MergeTreePartInfo})) : Nil
      parts.each_with_index do |left, left_index|
        (left_index + 1...parts.size).each do |right_index|
          right = parts[right_index]
          if left[2].overlaps?(right[2])
            raise InvalidPartError.new("selected parts overlap: #{left[1]} and #{right[1]}")
          end
        end
      end
    end

    private def checked_total_rows(total : UInt64, rows : UInt64) : UInt64
      raise BoundsError.new("total row count exceeds limit") if rows > MAX_TOTAL_ROWS - total
      total + rows
    end

    private def checked_total_marks(total : UInt64, marks : UInt64) : UInt64
      raise BoundsError.new("total mark count exceeds limit") if marks > MAX_TOTAL_MARKS - total
      total + marks
    end
  end
end

module CrystalClick
  alias WidePartNumericArray = Array(UInt8) | Array(UInt16) | Array(UInt32) | Array(UInt64) |
                               Array(Int8) | Array(Int16) | Array(Int32) | Array(Int64) |
                               Array(Float32) | Array(Float64)
  alias WidePartNumericSlice = Slice(UInt8) | Slice(UInt16) | Slice(UInt32) | Slice(UInt64) |
                               Slice(Int8) | Slice(Int16) | Slice(Int32) | Slice(Int64) |
                               Slice(Float32) | Slice(Float64)

  # A callback view over aligned numeric columns from one bounded table batch.
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
    end

    def column_names : Array(String)
      @column_names.dup
    end

    def values_for(column : String) : Slice(UInt64)
      index = column_index(column)
      raise UnsupportedFormatError.new("UInt64 accessor requires an exact UInt64 column") unless @column_types[index] == "UInt64"
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
      @column_values[index].as(Slice(T))
    end

    private def column_index(column : String) : Int
      index = @column_names.index(column)
      raise UnsupportedFormatError.new("column is not selected") unless index
      index
    end
  end

  # A correctness-first reader over caller-selected immutable Wide-part paths.
  # It does not discover active parts or execute a query language. Each mark is
  # materialized for selected numeric columns, checked for row alignment, then
  # exposed in bounded callback slices.
  class WidePartTable
    MAX_PARTS             = 1_024
    MAX_COLUMNS           =    16
    MAX_PART_NAME_BYTES   = MergeTreePartInfo::MAX_NAME_BYTES
    MAX_PART_PATH_BYTES   =         4_096
    MAX_COLUMN_NAME_BYTES =         4_096
    MAX_MARKS_PER_READER  =        65_536
    MAX_TOTAL_MARKS       = 1_000_000_u64
    # At the 16-column limit a full mark is capped at 8 MiB for the widest types.
    MAX_MARK_ROWS      =          65_536_u64
    MAX_TOTAL_ROWS     = 100_000_000_000_u64
    DEFAULT_BATCH_ROWS =               4_096
    MAX_BATCH_ROWS     =               4_096

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

      def initialize(
        @name : String,
        @path : String,
        @row_count : UInt64,
        @mark_row_counts : Array(UInt64),
        @readers : Array(ColumnReader),
        @column_types : Array(String),
      )
      end
    end

    @columns : Array(String)
    @entries : Array(PartEntry)
    @numeric_mode : Bool

    def self.open_selected(parts : Array(String), columns : Array(String)) : WidePartTable
      new(parts, columns, false)
    end

    def self.open_selected_numeric(parts : Array(String), columns : Array(String)) : WidePartTable
      new(parts, columns, true)
    end

    def columns : Array(String)
      @columns.dup
    end

    def column_types : Array({String, String})
      return [] of {String, String} if @entries.empty?
      @entries.first.readers.map { |selected| {selected.name, selected.column_type} }
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

      scan_rows(batch_rows) { |batch| yield batch }
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

    private def initialize(parts : Array(String), columns : Array(String), @numeric_mode : Bool)
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

          checksums.validate_selected_entries(
            path,
            File.basename(reader.data_path),
            File.basename(reader.mark_path)
          )
          readers << ColumnReader.new(column, reader)
          total_marks = checked_total_marks(total_marks, reader.mark_count.to_u64)
        end

        current_column_types = readers.map(&.column_type)
        if current_types = expected_column_types
          raise CorruptPartError.new("selected columns have different types across parts") unless current_column_types == current_types
        else
          expected_column_types = current_column_types
        end

        row_count = expected_row_count || raise(CorruptPartError.new("selected part has no readers"))
        mark_row_counts = expected_mark_rows || raise(CorruptPartError.new("selected part has no mark rows"))
        total_rows = checked_total_rows(total_rows, row_count)
        @entries << PartEntry.new(name, path, row_count, mark_row_counts, readers, current_column_types)
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

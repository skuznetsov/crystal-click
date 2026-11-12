require "json"
require "../spec/support/compact_part_writer_w281_fixture"

module CompactStaticBulkW281Helper
  extend self

  alias RecursiveWindow = NamedTuple(signatures: Array(String), first_mark: Int32, mark_count: Int32)
  alias TypedWindow = NamedTuple(signatures: Array(String), start_row: Int32, row_count: Int32)
  alias WindowSpec = NamedTuple(first_mark: Int32, mark_count: Int32, start_row: Int32, max_rows: Int32)

  FORMAT          = "compact_static_bulk_w281_helper_v1"
  ROW_COUNT       = CompactPartWriterW281Fixture::ROW_COUNT
  ROWS_PER_MARK   = CompactPartWriterW281Fixture::ROWS_PER_MARK
  DATA_MARK_COUNT = CompactPartWriterW281Fixture::MARK_COUNT
  DATA_MARK_ROWS  = [2_u64, 2_u64, 2_u64, 2_u64]
  WINDOW_SPECS    = {
    "full"   => {first_mark: 0, mark_count: 4, start_row: 0, max_rows: 8},
    "middle" => {first_mark: 1, mark_count: 2, start_row: 2, max_rows: 4},
    "last"   => {first_mark: 3, mark_count: 1, start_row: 6, max_rows: 2},
    "eof"    => {first_mark: 4, mark_count: 0, start_row: 8, max_rows: 1},
  } of String => WindowSpec

  def main(args : Array(String)) : Nil
    unless args.size == 5 && {"read", "write"}.includes?(args[0])
      raise ArgumentError.new("usage: helper read|write static_bulk|stock_bulk mrk3|mrk4 s0|s1 PART")
    end

    action = args[0]
    case_name = args[1]
    mark_format_name = args[2]
    profile_name = args[3]
    part_path = args[4]
    case_symbol = fixture_case(case_name)
    mark_format = case mark_format_name
                  when "mrk3" then CrystalClick::CompactMarkFormat::Mrk3
                  when "mrk4" then CrystalClick::CompactMarkFormat::Mrk4
                  else             raise ArgumentError.new("unsupported mark format: #{mark_format_name}")
                  end
    profile = case profile_name
              when "s0" then CrystalClick::BinaryBulkProfile.single_stream
              when "s1" then CrystalClick::BinaryBulkProfile.with_size_stream
              else           raise ArgumentError.new("unsupported String profile: #{profile_name}")
              end

    schema = schema_for(case_symbol)
    if action == "write"
      CrystalClick::CompactPartWriter.write_uint64_columns(
        part_path,
        CompactPartWriterW281Fixture::KEY_NAME,
        CompactPartWriterW281Fixture.keys,
        [column_for(case_symbol)],
        rows_per_mark: ROWS_PER_MARK,
        frame_bytes: CompactPartWriterW281Fixture::FRAME_BYTES,
        mark_format: mark_format,
        variant_discriminator_mode: CrystalClick::CompactVariantDiscriminatorMode::Basic,
        compress_marks: false,
        profile: profile,
      )
    end

    column_name = column_name_for(case_symbol)
    recursive_reader = CrystalClick::CompactRecursiveJsonColumnReader.open(part_path, column_name, schema)
    part_origin = action == "read" ? "stock" : "generated"
    unless recursive_reader.row_count == ROW_COUNT.to_u64 &&
           recursive_reader.mark_count == DATA_MARK_COUNT && recursive_reader.mark_row_counts == DATA_MARK_ROWS
      raise CrystalClick::CorruptPartError.new("W281 helper recursive reader row/mark grid differs")
    end
    recursive_windows = read_recursive_windows(recursive_reader)
    typed_windows = read_typed_windows(part_path, column_name)
    write_report(action, case_name, mark_format_name, profile_name, part_path, schema.declaration,
      part_origin, recursive_reader.mark_count, recursive_reader.mark_row_counts,
      recursive_windows, typed_windows)
  end

  private def fixture_case(case_name : String) : Symbol
    case case_name
    when "static_bulk" then :static_bulk
    when "stock_bulk"  then :stock_bulk
    else                    raise ArgumentError.new("unknown W281 case: #{case_name}")
    end
  end

  private def schema_for(case_name : Symbol) : CrystalClick::StorageColumnSchema
    case case_name
    when :static_bulk then CompactPartWriterW281Fixture.schema
    when :stock_bulk  then CompactPartWriterW281Fixture.stock_schema
    else                   raise ArgumentError.new("unknown W281 fixture schema")
    end
  end

  private def column_name_for(case_name : Symbol) : String
    case case_name
    when :static_bulk then CompactPartWriterW281Fixture::COLUMN_NAME
    when :stock_bulk  then CompactPartWriterW281Fixture::STOCK_COLUMN_NAME
    else                   raise ArgumentError.new("unknown W281 fixture column")
    end
  end

  private def column_for(case_name : Symbol) : CrystalClick::CompactPartColumn
    case case_name
    when :static_bulk then CompactPartWriterW281Fixture.column
    when :stock_bulk  then CompactPartWriterW281Fixture.stock_column
    else                   raise ArgumentError.new("unknown W281 fixture column")
    end
  end

  private def read_recursive_windows(
    reader : CrystalClick::CompactRecursiveJsonColumnReader,
  ) : Hash(String, RecursiveWindow)
    WINDOW_SPECS.to_h do |name, spec|
      marks = reader.read_marks(spec[:first_mark], spec[:mark_count])
      signatures = CompactPartWriterW281Fixture.signatures_from(marks)
      {name, {signatures: signatures, first_mark: spec[:first_mark], mark_count: spec[:mark_count]}}
    end
  end

  private def read_typed_windows(
    part_path : String,
    column_name : String,
  ) : Hash(String, TypedWindow)
    table = CrystalClick::TypedPartTable.open_selected_typed([part_path], [column_name])
    unless table.total_row_count == ROW_COUNT.to_u64
      raise CrystalClick::CorruptPartError.new("W281 helper typed facade row count differs")
    end

    WINDOW_SPECS.to_h do |name, spec|
      signatures = [] of String
      table.scan_typed_window(spec[:start_row].to_u64, spec[:max_rows]) do |batch|
        batch.recursive_values_for(column_name).each do |row|
          signatures << CompactPartWriterW281Fixture.signature(row)
        end
      end
      {name, {signatures: signatures, start_row: spec[:start_row], row_count: signatures.size}}
    end
  end

  private def write_report(
    action : String,
    case_name : String,
    mark_format : String,
    profile : String,
    part_path : String,
    schema : String,
    part_origin : String,
    reader_mark_count : Int32,
    reader_mark_rows : Array(UInt64),
    recursive_windows : Hash(String, RecursiveWindow),
    typed_windows : Hash(String, TypedWindow),
  ) : Nil
    report = JSON.build do |json|
      json.object do
        json.field "format", FORMAT
        json.field "action", action
        json.field "case", case_name
        json.field "mark_format", mark_format
        json.field "string_profile", profile
        json.field "status", "ok"
        json.field "part_path", part_path
        json.field "schema", schema
        json.field "row_count", ROW_COUNT
        json.field "data_mark_count", DATA_MARK_COUNT
        json.field "part_origin", part_origin
        json.field "public_reader_grid", "nonempty_data_marks"
        json.field "public_reader_mark_count", reader_mark_count
        json.field "public_reader_mark_rows", reader_mark_rows
        json.field "recursive_windows" do
          json.object do
            recursive_windows.each do |name, window|
              json.field name do
                json.object do
                  json.field "signatures", window[:signatures]
                  json.field "first_mark", window[:first_mark]
                  json.field "mark_count", window[:mark_count]
                end
              end
            end
          end
        end
        json.field "typed_windows" do
          json.object do
            typed_windows.each do |name, window|
              json.field name do
                json.object do
                  json.field "signatures", window[:signatures]
                  json.field "start_row", window[:start_row]
                  json.field "row_count", window[:row_count]
                end
              end
            end
          end
        end
      end
    end
    puts report
  end
end

begin
  CompactStaticBulkW281Helper.main(ARGV)
rescue error
  error_report = JSON.build do |json|
    json.object do
      json.field "format", CompactStaticBulkW281Helper::FORMAT
      json.field "status", "error"
      json.field "error_class", error.class.name
      json.field "error", error.message || error.to_s
    end
  end
  STDERR.puts error_report
  exit 1
end

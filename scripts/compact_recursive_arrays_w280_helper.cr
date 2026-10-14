require "json"
require "../spec/support/compact_part_writer_w280_fixture"

module CompactRecursiveArraysW280Helper
  extend self

  alias RecursiveWindow = NamedTuple(signatures: Array(String), first_mark: Int32, mark_count: Int32)
  alias TypedWindow = NamedTuple(signatures: Array(String), start_row: Int32, row_count: Int32)
  alias WindowSpec = NamedTuple(first_mark: Int32, mark_count: Int32, start_row: Int32, max_rows: Int32)

  FORMAT          = "compact_recursive_arrays_w280_helper_v3"
  COLUMN_NAME     = "recursive_json_w280"
  ROW_COUNT       = 8
  ROWS_PER_MARK   = 2
  DATA_MARK_COUNT = 4
  DATA_MARK_ROWS  = [2_u64, 2_u64, 2_u64, 2_u64]
  WINDOW_SPECS    = {
    "full"   => {first_mark: 0, mark_count: 4, start_row: 0, max_rows: 8},
    "middle" => {first_mark: 1, mark_count: 2, start_row: 2, max_rows: 4},
    "last"   => {first_mark: 3, mark_count: 1, start_row: 6, max_rows: 2},
    "eof"    => {first_mark: 4, mark_count: 0, start_row: 8, max_rows: 1},
  } of String => WindowSpec

  def main(args : Array(String)) : Nil
    unless args.size == 4 && {"read", "write"}.includes?(args[0])
      raise ArgumentError.new("usage: helper read|write CASE mrk3|mrk4 PART")
    end
    action = args[0]
    case_name = args[1]
    mark_format_name = args[2]
    part_path = args[3]
    case_symbol = fixture_case(case_name)
    mark_format = case mark_format_name
                  when "mrk3" then CrystalClick::CompactMarkFormat::Mrk3
                  when "mrk4" then CrystalClick::CompactMarkFormat::Mrk4
                  else             raise ArgumentError.new("unsupported mark format: #{mark_format_name}")
                  end

    schema = schema_for(case_symbol)
    if action == "write"
      column = column_for(case_symbol, schema)
      CrystalClick::CompactPartWriter.write_uint64_columns(
        part_path,
        CompactPartWriterW280Fixture::KEY_NAME,
        CompactPartWriterW280Fixture.keys,
        [column],
        rows_per_mark: ROWS_PER_MARK,
        frame_bytes: CompactPartWriterW280Fixture::FRAME_BYTES,
        mark_format: mark_format,
        variant_discriminator_mode: CrystalClick::CompactVariantDiscriminatorMode::Basic,
        compress_marks: false,
        profile: CrystalClick::BinaryBulkProfile.single_stream,
      )
    end

    recursive_reader = CrystalClick::CompactRecursiveJsonColumnReader.open(part_path, COLUMN_NAME, schema)
    part_origin = action == "read" ? "stock" : "generated"
    unless recursive_reader.row_count == ROW_COUNT.to_u64 &&
           recursive_reader.mark_count == DATA_MARK_COUNT && recursive_reader.mark_row_counts == DATA_MARK_ROWS
      raise CrystalClick::CorruptPartError.new("W280 helper recursive reader row/mark grid differs")
    end
    recursive_windows = read_recursive_windows(recursive_reader)
    typed_windows = read_typed_windows(part_path, case_symbol)
    write_report(action, case_name, mark_format_name, part_path, schema.declaration,
      part_origin, recursive_reader.mark_count, recursive_reader.mark_row_counts,
      recursive_windows, typed_windows)
  end

  private def fixture_case(case_name : String) : Symbol
    case case_name
    when "array_json"           then :array_json
    when "named_sibling_arrays" then :sibling_arrays
    when "four_sibling_objects" then :four_sibling_objects
    when "nested_five_sites"    then :nested_five_sites
    when "positional_uint8"     then :positional_uint8
    else                             raise ArgumentError.new("unknown W280 case: #{case_name}")
    end
  end

  private def schema_for(case_name : Symbol) : CrystalClick::StorageColumnSchema
    if case_name == :sibling_arrays
      declaration = "Tuple(left Array(#{CompactPartWriterW280Fixture.json_declaration}), right Array(#{CompactPartWriterW280Fixture.json_declaration}))"
      return CrystalClick::CompactJsonColumnAdapter.schema_for_json_declaration(declaration) ||
        raise CrystalClick::UnsupportedFormatError.new("named W280 sibling Tuple declaration is not admitted")
    end
    CompactPartWriterW280Fixture.schema(case_name)
  end

  private def column_for(
    case_name : Symbol,
    schema : CrystalClick::StorageColumnSchema,
  ) : CrystalClick::CompactPartColumn
    return CompactPartWriterW280Fixture.column(case_name) unless case_name == :sibling_arrays

    plans = Hash(String, CrystalClick::ObjectDocumentPlan).new
    CompactPartWriterW280Fixture.json_site_keys(case_name).each do |site|
      plans[site] = object_plan
    end
    granules = CompactPartWriterW280Fixture.rows(case_name).each_slice(ROWS_PER_MARK).map(&.to_a).to_a
    CrystalClick::CompactPartColumn.json(
      COLUMN_NAME,
      schema,
      granules,
      CrystalClick::CompactJsonWriteContext.new(plans),
    )
  end

  private def object_plan : CrystalClick::ObjectDocumentPlan
    json_type = CompactPartWriterW280Fixture.json_type
    object = CrystalClick::ObjectStructure.new(
      [] of String,
      version: 4_u64,
      shared_data_version: 0_u64,
      bucket_count: 1_u64,
      statistics: CrystalClick::StructureStatistics.new(
        [] of UInt64,
        [] of CrystalClick::StructureStatistic,
      ),
    )
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      object,
      Hash(String, CrystalClick::DynamicStructure).new,
    )
    CrystalClick::ObjectDocumentPlan.new(
      structures,
      json_type.json_type.not_nil!.typed_paths,
    )
  end

  private def read_recursive_windows(
    reader : CrystalClick::CompactRecursiveJsonColumnReader,
  ) : Hash(String, RecursiveWindow)
    WINDOW_SPECS.to_h do |name, spec|
      marks = reader.read_marks(spec[:first_mark], spec[:mark_count])
      signatures = marks.flat_map { |mark| mark.map { |row| CompactPartWriterW280Fixture.signature(row) } }
      {name, {signatures: signatures, first_mark: spec[:first_mark], mark_count: spec[:mark_count]}}
    end
  end

  private def read_typed_windows(
    part_path : String,
    case_name : Symbol,
  ) : Hash(String, TypedWindow)
    table = CrystalClick::TypedPartTable.open_selected_typed([part_path], [COLUMN_NAME])
    raise CrystalClick::CorruptPartError.new("W280 helper typed facade row count differs") unless table.total_row_count == ROW_COUNT.to_u64

    WINDOW_SPECS.to_h do |name, spec|
      signatures = [] of String
      table.scan_typed_window(spec[:start_row].to_u64, spec[:max_rows]) do |batch|
        if case_name == :array_json
          batch.array_object_documents_for(COLUMN_NAME).each do |documents|
            ids = documents.map { |document| "J#{document.value_for("id").as_uint64}" }
            signatures << "A[#{ids.join(",")}]"
          end
        else
          batch.recursive_values_for(COLUMN_NAME).each do |row|
            signatures << CompactPartWriterW280Fixture.signature(row)
          end
        end
      end
      {name, {signatures: signatures, start_row: spec[:start_row], row_count: signatures.size}}
    end
  end

  private def write_report(
    action : String,
    case_name : String,
    mark_format : String,
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
  CompactRecursiveArraysW280Helper.main(ARGV)
rescue error
  error_report = JSON.build do |json|
    json.object do
      json.field "format", CompactRecursiveArraysW280Helper::FORMAT
      json.field "status", "error"
      json.field "error_class", error.class.name
      json.field "error", error.message || error.to_s
    end
  end
  STDERR.puts error_report
  exit 1
end

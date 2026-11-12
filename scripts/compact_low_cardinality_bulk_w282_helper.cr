require "json"
require "../spec/support/compact_part_writer_w282_fixture"

module CompactLowCardinalityBulkW282Helper
  extend self

  alias RecursiveWindow = NamedTuple(signatures: Array(String), first_mark: Int32, mark_count: Int32)
  alias WindowSpec = NamedTuple(first_mark: Int32, mark_count: Int32)

  FORMAT          = "compact_low_cardinality_bulk_w282_helper_v1"
  alias FIXTURE = CompactPartWriterW282Fixture
  ROW_COUNT = FIXTURE::ROW_COUNT
  DATA_MARK_COUNT = FIXTURE::MARK_COUNT
  DATA_MARK_ROWS = [2_u64, 2_u64, 2_u64, 2_u64]
  WINDOW_SPECS = {
    "full"   => {first_mark: 0, mark_count: 4},
    "middle" => {first_mark: 1, mark_count: 2},
    "last"   => {first_mark: 3, mark_count: 1},
    "eof"    => {first_mark: 4, mark_count: 0},
  } of String => WindowSpec

  def main(args : Array(String)) : Nil
    unless args.size == 4 && {"read", "write"}.includes?(args[0])
      raise ArgumentError.new("usage: helper read|write mrk3|mrk4 s0|s1 PART")
    end

    action = args[0]
    mark_format_name = args[1]
    profile_name = args[2]
    part_path = args[3]
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

    if action == "write"
      CrystalClick::CompactPartWriter.write_uint64_columns(
        part_path,
        FIXTURE::KEY_NAME,
        FIXTURE.keys,
        [FIXTURE.column],
        rows_per_mark: FIXTURE::ROWS_PER_MARK,
        frame_bytes: FIXTURE::FRAME_BYTES,
        mark_format: mark_format,
        variant_discriminator_mode: CrystalClick::CompactVariantDiscriminatorMode::Basic,
        compress_marks: false,
        profile: profile,
      )
    end

    reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
      part_path, FIXTURE::COLUMN_NAME, FIXTURE.schema,
    )
    part_origin = action == "read" ? "stock" : "generated"
    unless reader.ordinary_profile == profile
      raise CrystalClick::CorruptPartError.new("W282 reopened reader String profile differs from requested #{profile_name}")
    end
    unless reader.row_count == ROW_COUNT.to_u64 && reader.mark_count == DATA_MARK_COUNT &&
           reader.mark_row_counts == DATA_MARK_ROWS
      raise CrystalClick::CorruptPartError.new("W282 recursive reader row/mark grid differs")
    end
    recursive_windows = read_recursive_windows(reader)
    write_report(action, mark_format_name, profile_name, part_path, FIXTURE.schema.declaration,
      part_origin, reader.mark_count, reader.mark_row_counts, recursive_windows)
  end

  private def read_recursive_windows(
    reader : CrystalClick::CompactRecursiveJsonColumnReader,
  ) : Hash(String, RecursiveWindow)
    WINDOW_SPECS.to_h do |name, spec|
      marks = reader.read_marks(spec[:first_mark], spec[:mark_count])
      signatures = FIXTURE.signatures_from(marks)
      {name, {signatures: signatures, first_mark: spec[:first_mark], mark_count: spec[:mark_count]}}
    end
  end

  private def write_report(
    action : String,
    mark_format : String,
    profile : String,
    part_path : String,
    schema : String,
    part_origin : String,
    reader_mark_count : Int32,
    reader_mark_rows : Array(UInt64),
    recursive_windows : Hash(String, RecursiveWindow),
  ) : Nil
    report = JSON.build do |json|
      json.object do
        json.field "format", FORMAT
        json.field "action", action
        json.field "mark_format", mark_format
        json.field "string_profile", profile
        json.field "reader_ordinary_profile_matches_requested", true
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
      end
    end
    puts report
  end
end

begin
  CompactLowCardinalityBulkW282Helper.main(ARGV)
rescue error
  error_report = JSON.build do |json|
    json.object do
      json.field "format", CompactLowCardinalityBulkW282Helper::FORMAT
      json.field "status", "error"
      json.field "error_class", error.class.name
      json.field "error", error.message || error.to_s
    end
  end
  STDERR.puts error_report
  exit 1
end

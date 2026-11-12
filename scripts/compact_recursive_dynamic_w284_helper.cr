# W284 helper for the proposed public Compact JSON Dynamic-context API.
# Deliberately not compiled at preparation time: this checkout has not yet
# integrated dynamic_contexts into CompactPartColumn.json or its reader.
require "json"
require "support/compact_recursive_dynamic_w284_fixture"

module CompactRecursiveDynamicW284Helper
  extend self

  alias WindowSpec = NamedTuple(first_mark: Int32, mark_count: Int32)

  FORMAT         = "compact_recursive_dynamic_w284_helper_v1"
  alias FIXTURE = CompactRecursiveDynamicW284Fixture
  DATA_MARK_ROWS = [2_u64, 2_u64, 2_u64, 2_u64]
  WINDOW_SPECS = {
    "full"   => {first_mark: 0, mark_count: 4},
    "middle" => {first_mark: 1, mark_count: 2},
    "last"   => {first_mark: 3, mark_count: 1},
    "eof"    => {first_mark: 4, mark_count: 0},
  } of String => WindowSpec
  HEX = "0123456789abcdef"

  def main(args : Array(String)) : Nil
    unless args.size == 5 && {"read", "write"}.includes?(args[0])
      raise ArgumentError.new("usage: helper read|write basic|compact mrk3|mrk4 s0|s1 PART")
    end

    action = args[0]
    mode_name = args[1]
    mark_name = args[2]
    profile_name = args[3]
    part_path = args[4]
    mode = case mode_name
           when "basic"   then CrystalClick::CompactVariantDiscriminatorMode::Basic
           when "compact" then CrystalClick::CompactVariantDiscriminatorMode::Compact
           else                raise ArgumentError.new("unsupported Variant discriminator mode: #{mode_name}")
           end
    mark_format = case mark_name
                  when "mrk3" then CrystalClick::CompactMarkFormat::Mrk3
                  when "mrk4" then CrystalClick::CompactMarkFormat::Mrk4
                  else             raise ArgumentError.new("unsupported mark format: #{mark_name}")
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
        variant_discriminator_mode: mode,
        compress_marks: false,
        profile: profile,
      )
    end

    reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
      part_path, FIXTURE::COLUMN_NAME, FIXTURE.schema,
    )
    expected_grid = {FIXTURE::ROW_COUNT.to_u64, FIXTURE::MARK_COUNT, DATA_MARK_ROWS}
    observed_grid = {reader.row_count, reader.mark_count, reader.mark_row_counts}
    unless observed_grid == expected_grid
      raise CrystalClick::CorruptPartError.new("W284 recursive reader row/mark grid differs")
    end
    unless reader.ordinary_profile == profile
      raise CrystalClick::CorruptPartError.new("W284 reader String profile differs from requested #{profile_name}")
    end

    windows = read_windows(reader)
    write_report(action, mode_name, mark_name, profile_name, part_path,
      action == "read" ? "stock" : "generated", reader, windows)
  end

  private def read_windows(
    reader : CrystalClick::CompactRecursiveJsonColumnReader,
  ) : Hash(String, NamedTuple(signatures: Array(String), first_mark: Int32, mark_count: Int32))
    WINDOW_SPECS.to_h do |name, spec|
      marks = reader.read_marks(spec[:first_mark], spec[:mark_count])
      signatures = marks.flat_map { |mark| mark.map { |row| row_signature(row) } }
      {name, {signatures: signatures, first_mark: spec[:first_mark], mark_count: spec[:mark_count]}}
    end
  end

  private def row_signature(row : CrystalClick::StorageColumnValue) : String
    unless row.array?
      raise CrystalClick::CorruptPartError.new("W284 parent row is not an Array")
    end
    entries = row.array_values.map do |entry|
      unless entry.tuple? && entry.child_count == 2
        raise CrystalClick::CorruptPartError.new("W284 Array item is not the expected two-field Tuple")
      end
      tag_value = entry.child_at(0).object_document.value_for("t")
      unless tag_value.type.tag == CrystalClick::BinaryDataType::TAG_UINT8
        raise CrystalClick::CorruptPartError.new("W284 Object tag is not UInt8")
      end
      tag_bytes = tag_value.bytes
      unless tag_bytes.size == 1
        raise CrystalClick::CorruptPartError.new("W284 Object tag UInt8 payload is not one byte")
      end
      tag = tag_bytes[0]
      "#{tag}:#{dynamic_signature(entry.child_at(1).bulk_value)}"
    end
    "#{entries.size}[#{entries.join(';')}]"
  end

  private def dynamic_signature(value : CrystalClick::BinaryValue) : String
    unless value.type.tag == CrystalClick::BinaryDataType::TAG_DYNAMIC
      raise CrystalClick::CorruptPartError.new("W284 sample lost its Dynamic wrapper")
    end
    return "NULL" if value.is_null?
    unless value.child_count == 1
      raise CrystalClick::CorruptPartError.new("W284 non-NULL Dynamic lacks exactly one selected actual value")
    end
    actual = value.child_at(0)
    case actual.type.name
    when "UInt64"
      "UInt64:#{actual.as_uint64}"
    when "String"
      "String:#{binary_hex(actual.bytes)}"
    else
      raise CrystalClick::CorruptPartError.new("W284 reader returned an unsupported Dynamic actual type #{actual.type.name.inspect}")
    end
  end

  private def binary_hex(bytes : Bytes) : String
    String.build do |io|
      bytes.each do |byte|
        io << HEX[(byte >> 4).to_i]
        io << HEX[(byte & 0x0f).to_i]
      end
    end
  end

  private def profile_name(profile : CrystalClick::BinaryBulkProfile) : String
    profile.single_stream? ? "s0" : "s1"
  end

  private def write_report(
    action : String,
    mode : String,
    mark : String,
    profile : String,
    part_path : String,
    origin : String,
    reader : CrystalClick::CompactRecursiveJsonColumnReader,
    windows : Hash(String, NamedTuple(signatures: Array(String), first_mark: Int32, mark_count: Int32)),
  ) : Nil
    report = JSON.build do |json|
      json.object do
        json.field "format", FORMAT
        json.field "action", action
        json.field "variant_discriminator_mode", mode
        json.field "mark_format", mark
        json.field "string_profile", profile
        json.field "reader_ordinary_profile", profile_name(reader.ordinary_profile)
        json.field "status", "ok"
        json.field "part_path", part_path
        json.field "schema", FIXTURE::SCHEMA_DECLARATION
        json.field "row_count", FIXTURE::ROW_COUNT
        json.field "data_mark_count", FIXTURE::MARK_COUNT
        json.field "part_origin", origin
        json.field "public_reader_mark_rows", reader.mark_row_counts
        json.field "dynamic_prefix_capture", "not_implemented"
        json.field "dynamic_statistics_placement", "unobserved"
        json.field "recursive_windows" do
          json.object do
            windows.each do |name, window|
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
  CompactRecursiveDynamicW284Helper.main(ARGV)
rescue error
  error_report = JSON.build do |json|
    json.object do
      json.field "format", CompactRecursiveDynamicW284Helper::FORMAT
      json.field "status", "error"
      json.field "error_class", error.class.name
      json.field "error", error.message || error.to_s
    end
  end
  STDERR.puts error_report
  exit 1
end

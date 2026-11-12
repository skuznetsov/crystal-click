require "json"
require "../spec/support/compact_part_writer_w283_fixture"

module CompactVariantBulkW283Helper
  extend self

  alias WindowSpec = NamedTuple(first_mark: Int32, mark_count: Int32)

  FORMAT          = "compact_variant_bulk_w283_helper_v1"
  alias FIXTURE = CompactPartWriterW283Fixture
  ROW_COUNT = FIXTURE::ROW_COUNT
  DATA_MARK_COUNT = FIXTURE::MARK_COUNT
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
    variant_mode_name = args[1]
    mark_format_name = args[2]
    profile_name = args[3]
    part_path = args[4]
    variant_mode = case variant_mode_name
                   when "basic"   then CrystalClick::CompactVariantDiscriminatorMode::Basic
                   when "compact" then CrystalClick::CompactVariantDiscriminatorMode::Compact
                   else                raise ArgumentError.new("unsupported Variant discriminator mode: #{variant_mode_name}")
                   end
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
        variant_discriminator_mode: variant_mode,
        compress_marks: false,
        profile: profile,
      )
    end

    reader = CrystalClick::CompactRecursiveJsonColumnReader.open(
      part_path, FIXTURE::COLUMN_NAME, FIXTURE.schema,
    )
    part_origin = action == "read" ? "stock" : "generated"
    unless reader.ordinary_profile == profile
      raise CrystalClick::CorruptPartError.new("W283 reopened reader String profile differs from requested #{profile_name}")
    end
    unless reader.row_count == ROW_COUNT.to_u64 && reader.mark_count == DATA_MARK_COUNT &&
           reader.mark_row_counts == DATA_MARK_ROWS
      raise CrystalClick::CorruptPartError.new("W283 recursive reader row/mark grid differs")
    end
    recursive_windows = read_recursive_windows(reader)
    write_report(action, variant_mode_name, mark_format_name, profile_name, part_path,
      FIXTURE.schema.declaration, part_origin, reader.ordinary_profile, reader.mark_count,
      reader.mark_row_counts, recursive_windows)
  end

  private def read_recursive_windows(
    reader : CrystalClick::CompactRecursiveJsonColumnReader,
  ) : Hash(String, NamedTuple(signatures: Array(String), first_mark: Int32, mark_count: Int32))
    WINDOW_SPECS.to_h do |name, spec|
      marks = reader.read_marks(spec[:first_mark], spec[:mark_count])
      signatures = marks.flat_map { |mark| mark.map { |row| row_signature(row) } }
      {name, {signatures: signatures, first_mark: spec[:first_mark], mark_count: spec[:mark_count]}}
    end
  end

  private def row_signature(row : CrystalClick::StorageColumnValue) : String
    unless row.tuple? && row.child_count == 4
      raise CrystalClick::CorruptPartError.new("W283 recursive row is not the expected four-field Tuple")
    end

    left = object_id(row.child_at(0))
    array = row.child_at(1).bulk_value
    right = object_id(row.child_at(2))
    bulk = row.child_at(3).bulk_value
    unless array.type.tag == CrystalClick::BinaryDataType::TAG_ARRAY &&
           bulk.type.tag == CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE && bulk.element_count == 4
      raise CrystalClick::CorruptPartError.new("W283 recursive Bulk owner shape differs")
    end

    array_rows = array.elements.map do |entry|
      unless entry.type.tag == CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE && entry.element_count == 2
        raise CrystalClick::CorruptPartError.new("W283 Variant Array item is not the expected Tuple")
      end
      "#{variant_signature(entry.element_at(0))}/#{low_cardinality_hex(entry.element_at(1))}"
    end
    root_lc = low_cardinality_hex(bulk.element_at(0))
    root_variant = variant_signature(bulk.element_at(1))
    map = bulk.element_at(2)
    unless map.type.tag == CrystalClick::BinaryDataType::TAG_MAP && map.element_count.even?
      raise CrystalClick::CorruptPartError.new("W283 map Variant value shape differs")
    end
    map_entries = [] of String
    index = 0
    while index < map.element_count
      map_entries << "#{binary_hex(map.element_at(index).bytes)}=#{variant_signature(map.element_at(index + 1))}"
      index += 2
    end

    nested = bulk.element_at(3)
    unless nested.type.tag == CrystalClick::BinaryDataType::TAG_NESTED
      raise CrystalClick::CorruptPartError.new("W283 Nested Variant value shape differs")
    end
    nested_entries = nested.elements.map do |entry|
      unless entry.type.tag == CrystalClick::BinaryDataType::TAG_NAMED_TUPLE && entry.element_count == 2
        raise CrystalClick::CorruptPartError.new("W283 Nested item is not the expected two-field Tuple")
      end
      "#{variant_signature(entry.element_at(0))}/#{low_cardinality_hex(entry.element_at(1))}"
    end

    "#{left}|A[#{array_rows.join(';')}]|#{right}|B(#{root_lc}|#{root_variant}|" \
    "M[#{map_entries.join(';')}]|N[#{nested_entries.join(';')}])"
  end

  private def object_id(value : CrystalClick::StorageColumnValue) : UInt64
    unless value.object?
      raise CrystalClick::CorruptPartError.new("W283 JSON sibling is not an ObjectDocument")
    end
    value.object_document.value_for("id").as_uint64
  end

  private def low_cardinality_hex(value : CrystalClick::BinaryValue) : String
    unless value.type.tag == CrystalClick::BinaryDataType::TAG_LOW_CARDINALITY && value.element_count == 1
      raise CrystalClick::CorruptPartError.new("W283 LC String value lost its nominal wrapper")
    end
    binary_hex(value.element_at(0).bytes)
  end

  private def variant_signature(value : CrystalClick::BinaryValue) : String
    return "N" if value.is_null?
    index = value.variant_index? || raise CrystalClick::CorruptPartError.new("W283 non-NULL Variant has no selected arm")
    child = value.variant_child? || raise CrystalClick::CorruptPartError.new("W283 non-NULL Variant has no selected value")
    case index
    when 0
      bytes = child.elements.map { |byte| binary_hex(byte.bytes) }
      "A[#{bytes.join(',')}]"
    when 1
      "S#{binary_hex(child.bytes)}"
    when 2
      "U#{child.as_uint64}"
    else
      raise CrystalClick::CorruptPartError.new("W283 reader returned an unknown Variant discriminator #{index}")
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
    variant_mode : String,
    mark_format : String,
    profile : String,
    part_path : String,
    schema : String,
    part_origin : String,
    reader_profile : CrystalClick::BinaryBulkProfile,
    reader_mark_count : Int32,
    reader_mark_rows : Array(UInt64),
    recursive_windows : Hash(String, NamedTuple(signatures: Array(String), first_mark: Int32, mark_count: Int32)),
  ) : Nil
    report = JSON.build do |json|
      json.object do
        json.field "format", FORMAT
        json.field "action", action
        json.field "variant_discriminator_mode", variant_mode
        json.field "mark_format", mark_format
        json.field "string_profile", profile
        json.field "reader_ordinary_profile", profile_name(reader_profile)
        json.field "reader_ordinary_profile_matches_requested", profile_name(reader_profile) == profile
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
  CompactVariantBulkW283Helper.main(ARGV)
rescue error
  error_report = JSON.build do |json|
    json.object do
      json.field "format", CompactVariantBulkW283Helper::FORMAT
      json.field "status", "error"
      json.field "error_class", error.class.name
      json.field "error", error.message || error.to_s
    end
  end
  STDERR.puts error_report
  exit 1
end

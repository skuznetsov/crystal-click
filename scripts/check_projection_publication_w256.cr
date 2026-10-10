require "../src/crystal_click"
require "json"

module CheckProjectionPublicationW256
  extend self

  FORMAT               = "projection_publication_w256_helper_v1"
  KEY_NAME             = "id"
  SCORE_NAME           = "score"
  LABEL_NAME           = "label"
  ITEMS_NAME           = "items"
  PROJECTION_NAME      = "by_score"
  MARK_ROWS            = [2_u64, 2_u64, 2_u64]
  PROJECTION_MARK_ROWS = [3_u64, 3_u64]
  IDS                  = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64]
  SCORES               = [50_u64, 10_u64, 40_u64, 20_u64, 60_u64, 30_u64]
  LABELS               = ["a\0b", "", "café", "z\0", "é", "hi"]
  ITEMS                = [
    [1_u16, 2_u16], [] of UInt16, [3_u16], [2_u16, 4_u16], [] of UInt16, [6_u16, 7_u16],
  ]
  SORTED_SCORE_KEYS   = [10_u64, 20_u64, 30_u64, 40_u64, 50_u64, 60_u64]
  SORTED_SCORE_IDS    = [2_u64, 4_u64, 6_u64, 3_u64, 1_u64, 5_u64]
  SORTED_SCORE_LABELS = ["", "z\0", "hi", "café", "a\0b", "é"]
  SORTED_SCORE_ITEMS  = [
    [] of UInt16, [2_u16, 4_u16], [6_u16, 7_u16], [3_u16], [1_u16, 2_u16], [] of UInt16,
  ]

  alias Row = NamedTuple(id: UInt64, score: UInt64, label: String, items: Array(UInt16))
  alias TypeRow = Tuple(String, String)

  private def require!(condition : Bool, message : String) : Nil
    raise CrystalClick::CorruptPartError.new("W256 helper: #{message}") unless condition
  end

  private def uint16_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt16")
  end

  private def uint64_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt64")
  end

  private def string_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("String")
  end

  private def items_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.array(uint16_type)
  end

  private def uint16_value(value : UInt16) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.fixed(
      uint16_type,
      Bytes[(value & 0xff_u16).to_u8, (value >> 8).to_u8],
    )
  end

  private def items_value(values : Array(UInt16)) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.array(items_type, values.map { |value| uint16_value(value) })
  end

  private def grouped(values : Array(CrystalClick::BinaryValue), rows_per_mark : Int32) : Array(Array(CrystalClick::BinaryValue))
    result = [] of Array(CrystalClick::BinaryValue)
    values.each_slice(rows_per_mark) { |mark| result << mark.to_a }
    result
  end

  private def parent_columns : Array(CrystalClick::WidePartColumn)
    uint64 = uint64_type
    string = string_type
    array = items_type
    [
      CrystalClick::WidePartColumn.binary_bulk(
        SCORE_NAME, uint64, grouped(SCORES.map { |value| CrystalClick::BinaryValue.uint64(value) }, 2),
      ),
      CrystalClick::WidePartColumn.binary_bulk(
        LABEL_NAME, string, grouped(LABELS.map { |value| CrystalClick::BinaryValue.string(value) }, 2),
      ),
      CrystalClick::WidePartColumn.binary_bulk(
        ITEMS_NAME, array, grouped(ITEMS.map { |value| items_value(value) }, 2),
      ),
    ] of CrystalClick::WidePartColumn
  end

  private def projection_columns : Array(CrystalClick::WidePartColumn)
    [
      CrystalClick::WidePartColumn.binary_bulk(
        "id", uint64_type, grouped(SORTED_SCORE_IDS.map { |value| CrystalClick::BinaryValue.uint64(value) }, 3),
      ),
      CrystalClick::WidePartColumn.binary_bulk(
        LABEL_NAME, string_type, grouped(SORTED_SCORE_LABELS.map { |value| CrystalClick::BinaryValue.string(value) }, 3),
      ),
      CrystalClick::WidePartColumn.binary_bulk(
        ITEMS_NAME, items_type, grouped(SORTED_SCORE_ITEMS.map { |value| items_value(value) }, 3),
      ),
    ] of CrystalClick::WidePartColumn
  end

  private def parent_expected : Array(Row)
    IDS.each_with_index.map do |id, index|
      {id: id, score: SCORES[index], label: LABELS[index], items: ITEMS[index].dup}
    end.to_a
  end

  private def projection_expected : Array(Row)
    SORTED_SCORE_KEYS.each_with_index.map do |score, index|
      {id: SORTED_SCORE_IDS[index], score: score, label: SORTED_SCORE_LABELS[index], items: SORTED_SCORE_ITEMS[index].dup}
    end.to_a
  end

  private def decode_items(value : CrystalClick::BinaryValue) : Array(UInt16)
    require!(value.type == items_type, "items value descriptor differs")
    value.elements.map do |element|
      bytes = element.bytes
      require!(bytes.size == 2, "UInt16 array element width differs")
      bytes[0].to_u16 | (bytes[1].to_u16 << 8)
    end
  end

  private def collect_rows(table : CrystalClick::WidePartTable) : Array(Row)
    rows = [] of Row
    table.scan_typed do |batch|
      ids = batch.values_for(KEY_NAME, UInt64)
      scores = batch.values_for(SCORE_NAME, UInt64)
      labels = batch.strings_for(LABEL_NAME)
      items = batch.array_numeric_values(ITEMS_NAME, UInt16)
      require!(ids.size == scores.size && ids.size == labels.size && ids.size == items.size,
        "selected columns are not row-aligned")
      ids.each_index do |index|
        rows << {
          id: ids[index], score: scores[index], label: labels[index].dup,
          items: items[index].dup,
        }
      end
      nil
    end
    rows
  end

  private def mark_rows(table : CrystalClick::WidePartTable) : Array(UInt64)
    grids = table.part_mark_row_counts
    require!(grids.size == 1, "a helper read must contain exactly one part")
    grids.first
  end

  private def read_side(part : String, projection : Bool, origin : String) : NamedTuple(
    schema: Array(TypeRow), row_count: UInt64, mark_rows: Array(UInt64), rows: Array(Row),
  )
    selected = projection ? [SCORE_NAME, "id", LABEL_NAME, ITEMS_NAME] : [KEY_NAME, SCORE_NAME, LABEL_NAME, ITEMS_NAME]
    table = projection ? CrystalClick::WidePartTable.open_selected_projection_typed([part], PROJECTION_NAME, selected) : CrystalClick::WidePartTable.open_selected_typed([part], selected)
    rows = collect_rows(table)
    {schema: table.column_types, row_count: table.total_row_count, mark_rows: mark_rows(table), rows: rows}
  end

  private def validate_side!(side, expected_rows : Array(Row), expected_grid : Array(UInt64), expected_types : Array(TypeRow), origin : String) : Nil
    require!(side[:schema] == expected_types, "#{origin} exact selected schema differs: #{side[:schema].inspect}")
    require!(side[:row_count] == expected_rows.size.to_u64, "#{origin} row count differs")
    require!(side[:mark_rows] == expected_grid, "#{origin} data-mark grid differs: #{side[:mark_rows].inspect}")
    require!(side[:rows] == expected_rows, "#{origin} semantic values differ from independent literals")
  end

  private def json_rows(rows : Array(Row)) : JSON::Any
    JSON::Any.new(rows.map do |row|
      JSON::Any.new([
        JSON::Any.new(row[:id].to_i64), JSON::Any.new(row[:score].to_i64), JSON::Any.new(row[:label]),
        JSON::Any.new(row[:items].map { |value| JSON::Any.new(value.to_i64) }),
      ])
    end)
  end

  private def json_types(types : Array(TypeRow)) : JSON::Any
    JSON::Any.new(types.map do |name, type|
      JSON::Any.new({"name" => JSON::Any.new(name), "type" => JSON::Any.new(type)})
    end)
  end

  private def side_json(side, expected_origin : String) : JSON::Any
    JSON::Any.new({
      "schema"          => json_types(side[:schema]),
      "row_count"       => JSON::Any.new(side[:row_count].to_i64),
      "mark_row_counts" => JSON::Any.new(side[:mark_rows].map { |value| JSON::Any.new(value.to_i64) }),
      "rows"            => json_rows(side[:rows]),
      "semantic_origin" => JSON::Any.new(expected_origin),
    })
  end

  private def key_slice(values : Array(UInt64)) : Slice(UInt64)
    values.to_unsafe.to_slice(values.size)
  end

  private def write_library(destination : String) : Nil
    projection = CrystalClick::WidePartProjection.precomputed(
      PROJECTION_NAME,
      SCORE_NAME,
      key_slice(SORTED_SCORE_KEYS.dup),
      projection_columns,
      rows_per_mark: 3,
    )
    CrystalClick::WidePartWriter.write_uint64_columns(
      destination,
      KEY_NAME,
      key_slice(IDS.dup),
      parent_columns,
      rows_per_mark: 2,
      profile: CrystalClick::BinaryBulkProfile.with_size_stream,
      projections: [projection],
    )
    nil
  end

  private def part_inventory(path : String) : Array(String)
    raise CrystalClick::CorruptPartError.new("W256 helper: part must be a real directory") if File.symlink?(path) || !Dir.exists?(path)
    names = Dir.children(path).sort!
    names.each do |name|
      entry = File.join(path, name)
      raise CrystalClick::CorruptPartError.new("W256 helper: unexpected nested or linked entry #{name}") if File.symlink?(entry) || Dir.exists?(entry) || !File.file?(entry)
    end
    names
  end

  private def main(args : Array(String)) : Nil
    unless args.size == 2
      STDERR.puts "usage: check_projection_publication_w256.cr SOURCE_PARENT_PART LIBRARY_PARENT_PART_DEST"
      exit 64
    end
    source_part = File.expand_path(args[0])
    library_part = File.expand_path(args[1])
    raise CrystalClick::InvalidPartError.new("W256 helper: source part is missing, linked, or not a directory") if File.symlink?(source_part) || !Dir.exists?(source_part)
    raise CrystalClick::InvalidPartError.new("W256 helper: library destination already exists") if File.exists?(library_part) || File.symlink?(library_part)

    source_parent = read_side(source_part, false, "source_parent")
    source_projection = read_side(source_part, true, "source_projection")
    validate_side!(source_parent, parent_expected, MARK_ROWS, [{KEY_NAME, "UInt64"}, {SCORE_NAME, "UInt64"}, {LABEL_NAME, "String"}, {ITEMS_NAME, "Array(UInt16)"}], "source parent")
    validate_side!(source_projection, projection_expected, MARK_ROWS, [{SCORE_NAME, "UInt64"}, {"id", "UInt64"}, {LABEL_NAME, "String"}, {ITEMS_NAME, "Array(UInt16)"}], "source projection")

    write_library(library_part)
    library_parent = read_side(library_part, false, "library_parent")
    library_projection = read_side(library_part, true, "library_projection")
    validate_side!(library_parent, parent_expected, MARK_ROWS, [{KEY_NAME, "UInt64"}, {SCORE_NAME, "UInt64"}, {LABEL_NAME, "String"}, {ITEMS_NAME, "Array(UInt16)"}], "library parent")
    validate_side!(library_projection, projection_expected, PROJECTION_MARK_ROWS, [{SCORE_NAME, "UInt64"}, {"id", "UInt64"}, {LABEL_NAME, "String"}, {ITEMS_NAME, "Array(UInt16)"}], "library projection")

    checksum = CrystalClick::PartChecksums.open(library_part)
    summary = checksum.entry("#{PROJECTION_NAME}.proj") ||
              raise CrystalClick::CorruptPartError.new("W256 helper: projection parent checksum entry is absent")
    expected_child_names = CrystalClick::PartChecksums.open(File.join(library_part, "#{PROJECTION_NAME}.proj")).entries.keys + [
      "checksums.txt", "columns.txt", "columns_substreams.txt", "default_compression_codec.txt", "metadata_version.txt",
    ]
    child_names = part_inventory(File.join(library_part, "#{PROJECTION_NAME}.proj"))
    require!(child_names == expected_child_names.sort!, "library projection child file roster differs from its checksums")

    result = JSON::Any.new({
      "format"             => JSON::Any.new(FORMAT),
      "status"             => JSON::Any.new("observed"),
      "source_parent"      => side_json(source_parent, "stock-authored"),
      "source_projection"  => side_json(source_projection, "stock-authored"),
      "library_parent"     => side_json(library_parent, "library-generated"),
      "library_projection" => side_json(library_projection, "library-generated"),
      "library_part_path"  => JSON::Any.new(library_part),
      "projection_summary" => JSON::Any.new({
        "entry"            => JSON::Any.new("#{PROJECTION_NAME}.proj"),
        "physical_size"    => JSON::Any.new(summary.physical_size.to_i64),
        "file_hash"        => JSON::Any.new([JSON::Any.new(summary.file_hash[0].to_s), JSON::Any.new(summary.file_hash[1].to_s)]),
        "child_file_names" => JSON::Any.new(child_names.map { |name| JSON::Any.new(name) }),
      }),
    })
    puts result.to_json
  rescue ex : Exception
    STDERR.puts "W256 helper failed: #{ex.class}: #{ex.message}"
    exit 1
  end

  main(ARGV)
end

require "../src/crystal_click"
require "json"

module CheckCompactPhysicalContextW259
  FORMAT = "compact_physical_context_w259_helper_v1"

  alias SignatureScan = NamedTuple(keys: Array(UInt64), columns: Hash(String, Array(String)))
  alias WideReport = NamedTuple(
    mark_row_counts: Array(Array(UInt64)),
    full: SignatureScan,
    middle: SignatureScan,
  )
  alias CompactReport = NamedTuple(status: String, stage: String, error: String)

  COLUMNS            = ["u", "side", "arr", "tup", "lc", "v"]
  PHYSICAL_COLUMNS   = ["pk", "u", "side", "arr", "tup", "lc", "v"]
  SELECTED_COLUMNS   = ["pk", "u", "side", "arr", "tup", "lc", "v"]
  EXPECTED_KEYS      = [1001_u64, 1002_u64, 1003_u64, 1004_u64, 1005_u64, 1006_u64, 1007_u64, 1008_u64]
  MIDDLE_KEYS        = [1003_u64, 1004_u64, 1005_u64, 1006_u64]
  EXPECTED_MARK_ROWS = [[2_u64, 2_u64, 2_u64, 2_u64]]
  PHYSICAL_WINDOWS   = [
    {"full", 0, 4},
    {"first", 0, 1},
    {"middle", 1, 2},
    {"last", 3, 1},
    {"eof", 4, 0},
  ] of Tuple(String, Int32, Int32)

  def self.hex(value : String) : String
    String.build do |io|
      value.to_slice.each do |byte|
        io << byte.to_s(16).rjust(2, '0')
      end
    end
  end

  def self.hex_bytes(value : Bytes) : String
    String.build do |io|
      value.each do |byte|
        io << byte.to_s(16).rjust(2, '0')
      end
    end
  end

  def self.variant_signature(value : CrystalClick::VariantStringUInt64Value) : String
    case value
    when String
      "variant<String>(string:#{hex(value)})"
    when UInt64
      "variant<UInt64>(uint64:#{value})"
    else
      "variant<NULL>(null)"
    end
  end

  def self.expected_columns : Hash(String, Array(String))
    {
      "u"    => (0...8).map { |index| "uint64:#{2001 + index}" },
      "side" => (0...8).map { |index| "string:#{hex("side-#{index}")}" },
      "arr"  => [
        "array[]",
        "array[]",
        "array[null,uint64:17]",
        "array[uint64:23]",
        "array[]",
        "array[]",
        "array[uint64:7,uint64:8,null]",
        "array[null,uint64:9]",
      ],
      "tup" => (0...8).map { |index| "tuple[uint64:#{3001 + index},string:#{hex("tuple-#{index}")}]" },
      "lc"  => ["dup", "red", "dup", "", "blue", "dup", "blue", "tail"].map { |value| "string:#{hex(value)}" },
      "v"   => [
        "variant<String>(string:#{hex("variant-0")})",
        "variant<UInt64>(uint64:4002)",
        "variant<NULL>(null)",
        "variant<String>(string:#{hex("variant-3")})",
        "variant<UInt64>(uint64:4005)",
        "variant<String>(string:#{hex("variant-5")})",
        "variant<UInt64>(uint64:4007)",
        "variant<NULL>(null)",
      ],
    } of String => Array(String)
  end

  def self.append_public_batch(
    batch : CrystalClick::WidePartTableBatch,
    signatures : Hash(String, Array(String)),
  ) : Array(UInt64)
    keys = batch.values_for("pk", UInt64)
    sizes_before = Hash(String, Int32).new
    COLUMNS.each { |name| sizes_before[name] = signatures[name].size }

    batch.values_for("u", UInt64).each do |value|
      signatures["u"] << "uint64:#{value}"
    end
    batch.strings_for("side").each do |value|
      signatures["side"] << "string:#{hex(value)}"
    end
    batch.array_nullable_uint64s_for("arr").each do |row|
      children = row.map { |value| value ? "uint64:#{value}" : "null" }
      signatures["arr"] << "array[#{children.join(',')}]"
    end
    batch.tuple_rows_for("tup").each do |row|
      n = row.value_as("n", UInt64)
      s = row.value_as("s", String)
      signatures["tup"] << "tuple[uint64:#{n},string:#{hex(s)}]"
    end
    batch.low_cardinality_strings_for("lc").each do |value|
      signatures["lc"] << "string:#{hex(value)}"
    end
    batch.variant_string_uint64_for("v").each do |value|
      signatures["v"] << variant_signature(value)
    end
    COLUMNS.each do |name|
      unless signatures[name].size - sizes_before[name] == keys.size
        raise CrystalClick::CorruptPartError.new("W259 typed batch #{name} row count differs from its keys")
      end
    end
    keys.to_a
  end

  def self.read_public_window(
    table : CrystalClick::WidePartTable,
    start_row : UInt64,
    max_rows : Int32,
  ) : SignatureScan
    keys = [] of UInt64
    signatures = Hash(String, Array(String)).new { |values, name| values[name] = [] of String }
    COLUMNS.each { |name| signatures[name] = [] of String }
    table.scan_typed_window(start_row, max_rows) do |batch|
      batch_keys = append_public_batch(batch, signatures)
      keys.concat(batch_keys)
    end
    {keys: keys, columns: signatures}
  end

  def self.validate_scan(scan : SignatureScan, keys : Array(UInt64), expected_columns : Hash(String, Array(String)), label : String) : Nil
    unless scan[:keys] == keys
      raise CrystalClick::CorruptPartError.new("W259 #{label} key values differ from SQL literals")
    end
    expected_columns.each do |column, values|
      unless scan[:columns][column] == values
        raise CrystalClick::CorruptPartError.new("W259 #{label} #{column} values differ from SQL literals")
      end
    end
    nil
  end

  def self.inspect_wide(path : String) : WideReport
    table = CrystalClick::WidePartTable.open_selected_typed([File.expand_path(path)], SELECTED_COLUMNS)
    unless table.part_mark_row_counts == EXPECTED_MARK_ROWS
      raise CrystalClick::CorruptPartError.new("W259 Wide positive control mark rows differ from [2,2,2,2]")
    end

    expected = expected_columns
    full = read_public_window(table, 0_u64, 8)
    middle = read_public_window(table, 2_u64, 4)
    validate_scan(full, EXPECTED_KEYS, expected, "full Wide scan")
    middle_columns = Hash(String, Array(String)).new
    expected.each { |name, values| middle_columns[name] = values[2, 4] }
    validate_scan(middle, MIDDLE_KEYS, middle_columns, "middle Wide window")

    {mark_row_counts: table.part_mark_row_counts, full: full, middle: middle}
  end

  def self.inspect_compact(path : String, label : String) : CompactReport
    stage = "open"
    table = CrystalClick::WidePartTable.open_selected_typed([File.expand_path(path)], SELECTED_COLUMNS)
    stage = "scan"
    rows = 0
    table.scan_typed_window(0_u64, 8) do |batch|
      rows += batch.values_for("pk", UInt64).size
    end
    raise CrystalClick::CorruptPartError.new("W259 #{label} unexpectedly completed a typed scan with #{rows} rows")
  rescue ex : CrystalClick::InvalidPartError
    if stage == "open" && ex.message == "selected numeric stream files not found"
      {status: "missing_wide_streams", stage: "open", error: "#{ex.class}: #{ex.message}"}
    else
      raise ex
    end
  rescue ex : CrystalClick::UnsupportedFormatError
    {status: "unsupported", stage: stage || "open", error: "#{ex.class}: #{ex.message}"}
  end

  def self.write_physical_window(json : JSON::Builder, window) : Nil
    json.object do
      json.field "mode", window.mode.mrk3? ? "mrk3" : "mrk4"
      json.field "column", window.column
      json.field "first_mark", window.first_mark
      json.field "row_offset", window.row_offset
      json.field "granules" do
        json.array do
          window.granules.each do |granule|
            json.object do
              json.field "mark", granule.mark
              json.field "row_offset", granule.row_offset
              json.field "row_count", granule.row_count
              json.field "shards" do
                json.array do
                  granule.shards.each do |shard|
                    json.object do
                      json.field "slot_index", shard.slot_index
                      json.field "stream_name", shard.stream_name
                      json.field "logical_start", shard.logical_start
                      json.field "logical_end", shard.logical_end
                      json.field "bytes_hex", hex_bytes(shard.bytes)
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
    nil
  end

  def self.write_physical(json : JSON::Builder, part_path : String) : Nil
    context = CrystalClick::CompactPartPhysicalContext.open(File.expand_path(part_path))
    mark_rows = context.read_window(PHYSICAL_COLUMNS[0], 0, context.granule_count).granules.map(&.row_count)

    json.object do
      json.field "windows" do
        json.object do
          json.field "mode", context.mode.mrk3? ? "mrk3" : "mrk4"
          json.field "mark_rows", mark_rows
          json.field "columns" do
            json.object do
              PHYSICAL_COLUMNS.each do |column|
                json.field column do
                  json.object do
                    PHYSICAL_WINDOWS.each do |window_name, first_mark, mark_count|
                      json.field window_name do
                        write_physical_window(
                          json,
                          context.read_window(column, first_mark, mark_count)
                        )
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
    nil
  end

  def self.write_scan(json : JSON::Builder, scan : SignatureScan) : Nil
    json.object do
      json.field "keys", scan[:keys]
      json.field "columns" do
        json.object do
          COLUMNS.each do |column|
            json.field column, scan[:columns][column]
          end
        end
      end
    end
  end

  def self.write_compact(json : JSON::Builder, report : CompactReport) : Nil
    json.object do
      json.field "status", report[:status]
      json.field "stage", report[:stage]
      json.field "error", report[:error]
    end
  end

  def self.run(args : Array(String)) : Nil
    unless args.size == 4 && args[0] == "roundtrip"
      STDERR.puts "usage: check_compact_physical_context_w259.cr roundtrip WIDE_PART COMPACT_MRK3_PART COMPACT_MRK4_PART"
      exit(2)
    end

    wide = inspect_wide(args[1])
    compact_mrk3 = inspect_compact(args[2], "mrk3 Compact part")
    compact_mrk4 = inspect_compact(args[3], "mrk4 Compact part")
    compact_physical_paths = {"mrk3" => args[2], "mrk4" => args[3]}

    JSON.build(STDOUT) do |json|
      json.object do
        json.field "format", FORMAT
        json.field "wide_control" do
          json.object do
            json.field "status", "ok"
            json.field "mark_row_counts", wide[:mark_row_counts]
            json.field "full" do
              write_scan(json, wide[:full])
            end
            json.field "middle" do
              write_scan(json, wide[:middle])
            end
          end
        end
        json.field "compact_mrk3" do
          write_compact(json, compact_mrk3)
        end
        json.field "compact_mrk4" do
          write_compact(json, compact_mrk4)
        end
        json.field "compact_physical" do
          json.object do
            compact_physical_paths.each do |mode, path|
              json.field mode do
                write_physical(json, path)
              end
            end
          end
        end
      end
    end
    STDOUT << '\n'
    nil
  end
end

CheckCompactPhysicalContextW259.run(ARGV)

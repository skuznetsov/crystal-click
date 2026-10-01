# W106 stock-first RED probe for recursively nested named Tuple paths. This
# fixture deliberately stops at a three-Tuple-level declaration: no empty
# Tuple or dotted-name collision is assumed. Stream names below follow the
# pinned source's TupleElement escaping rule (ISerialization.cpp:338-346).
# Typed reading is attempted only after stock schema, stream topology, raw
# bytes, marks, serializer metadata, ATTACH/CHECK, and RowBinary are certified.
require "json"
require "file_utils"
require "../src/crystal_click"

W106_STOCK_VERSION         = "26.7.1.1315"
W106_TYPE                  = "Tuple(id UInt64, details Tuple(state Nullable(Enum8('neg' = -7, 'pos' = 7)), metadata Tuple(note Nullable(String), event DateTime64(3, 'America/New_York')), fixed FixedString(3), count UInt32))"
W106_SOURCE_TABLE          = "w106_nested_source"
W106_ATTACH_TABLE          = "w106_nested_attached"
W106_KEYS                  = [10_u64, 20_u64, 30_u64, 40_u64, 50_u64]
W106_IDS                   = [100_u64, 0_u64, 2_u64, 3_u64, UInt64::MAX]
W106_STATES                = [nil, -7_i64, 7_i64, nil, -7_i64] of Int64?
W106_NOTES                 = [nil, nil, "", "tail", nil] of String?
W106_EVENTS                = [-1_i64, 0_i64, 1_615_705_200_001_i64, 1_636_264_800_001_i64, -1_001_i64]
W106_FIXED                 = ["\0\0\0", "abc", "xyz", "end", "123"]
W106_COUNTS                = [0_u32, 0_u32, UInt32::MAX, 7_u32, 1_234_u32]
W106_MARK_ROWS             = [2_u64, 2_u64, 1_u64, 0_u64]
W106_MARK_BOUNDARIES       = [0, 2, 4, 5]
W106_ENUM_NULL_EXPECTATION = [0x00_u8, 0xf9_u8, 0x07_u8, 0x00_u8, 0xf9_u8]

class W106ByteMismatchError < Exception
end

def w106_unsigned_le(value : UInt64, width : Int32) : String
  String.build do |output|
    width.times do |index|
      output.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8)
    end
  end
end

def w106_signed_le(value : Int64, width : Int32) : String
  w106_unsigned_le(value.unsafe_as(UInt64), width)
end

def w106_byte(value : UInt8) : String
  String.new(Bytes[value])
end

def w106_varuint(value : UInt64) : String
  String.build do |output|
    remaining = value
    while remaining >= 0x80_u64
      output.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
      remaining >>= 7
    end
    output.write_byte(remaining.to_u8)
  end
end

def w106_streams : Array({String, Array(String)})
  state_raw = W106_STATES.map { |value| w106_signed_le(value || 0_i64, 1) }
  note_raw = W106_NOTES.map { |value| value || "" }
  note_sizes = W106_NOTES.map { |value| w106_unsigned_le((value ? value.bytesize : 0).to_u64, 8) }
  state_nulls = W106_STATES.map { |value| w106_byte(value ? 0_u8 : 1_u8) }
  note_nulls = W106_NOTES.map { |value| w106_byte(value ? 0_u8 : 1_u8) }

  [
    {"pk", W106_KEYS.map { |value| w106_unsigned_le(value, 8) }},
    {"payload%2Eid", W106_IDS.map { |value| w106_unsigned_le(value, 8) }},
    {"payload%2Edetails%2Estate.null", state_nulls},
    {"payload%2Edetails%2Estate", state_raw},
    {"payload%2Edetails%2Emetadata%2Enote.null", note_nulls},
    {"payload%2Edetails%2Emetadata%2Enote.size", note_sizes},
    {"payload%2Edetails%2Emetadata%2Enote", note_raw},
    {"payload%2Edetails%2Emetadata%2Eevent", W106_EVENTS.map { |value| w106_signed_le(value, 8) }},
    {"payload%2Edetails%2Efixed", W106_FIXED},
    {"payload%2Edetails%2Ecount", W106_COUNTS.map { |value| w106_unsigned_le(value.to_u64, 4) }},
  ]
end

def w106_expected_columns : Array(String)
  [
    "columns format version: 1",
    "2 columns:",
    "`pk` UInt64",
    "`payload` #{W106_TYPE}",
  ]
end

def w106_expected_substreams : String
  streams = w106_streams[1..].map(&.[0])
  lines = [
    "columns substreams version: 1",
    "2 columns:",
    "1 substreams for column `pk`:",
    "\tpk",
    "#{streams.size} substreams for column `payload`:",
  ]
  streams.each { |name| lines << "\t#{name}" }
  lines.join("\n") + "\n"
end

def w106_expected_marks(fragments : Array(String)) : Array({UInt64, UInt64, UInt64})
  W106_MARK_BOUNDARIES.each_with_index.map do |boundary, index|
    decompressed = fragments[0, boundary].sum(&.bytesize).to_u64
    {0_u64, decompressed, W106_MARK_ROWS[index]}
  end.to_a
end

def w106_actual_marks(part : String, stream : String) : Array({UInt64, UInt64, UInt64})
  path = File.join(part, "#{CrystalClick::StreamName.hash(stream)}.mrk2")
  bytes = File.read(path).to_slice
  mark_size = CrystalClick::WidePart::MARK_SIZE
  raise "#{stream}: truncated .mrk2 records" unless bytes.size % mark_size == 0
  Array({UInt64, UInt64, UInt64}).new(bytes.size // mark_size) do |index|
    offset = index * mark_size
    fields = Array(UInt64).new(3) do |field|
      start = offset + field * 8
      8.times.reduce(0_u64) { |value, byte| value | (bytes[start + byte].to_u64 << (byte * 8)) }
    end
    {fields[0], fields[1], fields[2]}
  end
end

def w106_assert_bytes(actual : String, expected : String, label : String) : Nil
  return if actual == expected
  limit = Math.min(actual.bytesize, expected.bytesize)
  difference = 0
  while difference < limit && actual.to_slice[difference] == expected.to_slice[difference]
    difference += 1
  end
  got = difference < actual.bytesize ? actual.to_slice[difference].to_s(16).rjust(2, '0') : "<eof>"
  wanted = difference < expected.bytesize ? expected.to_slice[difference].to_s(16).rjust(2, '0') : "<eof>"
  raise W106ByteMismatchError.new("#{label}: expected #{expected.bytesize} bytes, got #{actual.bytesize}; first difference #{difference}: expected #{wanted}, got #{got}")
end

def w106_seeded_comparator_control(actual : String, expected : String, label : String) : Nil
  raise "#{label}: baseline bytes did not match" unless actual == expected
  raise "#{label}: cannot seed an empty stream" if expected.empty?
  damaged = String.new(expected.to_slice)
  damaged.to_unsafe[0] = damaged.to_slice[0] ^ 0x01_u8
  begin
    w106_assert_bytes(actual, damaged, "#{label} seeded mismatch")
    raise "#{label}: comparator accepted a seeded mismatch"
  rescue ex : W106ByteMismatchError
  end
  puts "PASS #{label}: byte comparator rejects a seeded one-byte mismatch"
end

def w106_run(binary : String, store : String, query : String, input : IO? = nil) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = if input
             Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: error)
           else
             Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: error)
           end
  raise "ClickHouse query failed: #{error}\n#{query}" unless status.success?
  output.to_s
end

def w106_create_table(binary : String, store : String, table : String) : Nil
  settings = "index_granularity = 2, index_granularity_bytes = 10485760, enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, ratio_of_defaults_for_sparse_serialization = 0.9375, compress_marks = 0, compress_primary_key = 0, min_compress_block_size = 0, max_compress_block_size = 4096, default_compression_codec = 'LZ4'"
  w106_run(binary, store, "CREATE TABLE default.#{table} (pk UInt64, payload #{W106_TYPE}) ENGINE = MergeTree ORDER BY pk SETTINGS #{settings}")
  nil
end

def w106_expected_insert_rowbinary(indexes : Array(Int32)) : String
  String.build do |output|
    indexes.each do |index|
      output << w106_unsigned_le(W106_KEYS[index], 8)
      output << w106_unsigned_le(W106_IDS[index], 8)
      if state = W106_STATES[index]
        output << "\x00" << w106_signed_le(state, 1)
      else
        output << "\x01"
      end
      if note = W106_NOTES[index]
        output << "\x00" << w106_varuint(note.bytesize.to_u64) << note
      else
        output << "\x01"
      end
      output << w106_signed_le(W106_EVENTS[index], 8)
      output << W106_FIXED[index]
      output << w106_unsigned_le(W106_COUNTS[index].to_u64, 4)
    end
  end
end

def w106_insert(binary : String, store : String, table : String) : Nil
  input = IO::Memory.new(w106_expected_insert_rowbinary([0, 1, 2, 3, 4]).to_slice)
  w106_run(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", input)
  nil
end

def w106_part_path(binary : String, store : String, table : String) : String
  rows = w106_run(binary, store, "SELECT path, part_type, rows FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines.map(&.strip).reject(&.empty?)
  raise "#{table}: expected exactly one five-row Wide part, got #{rows.inspect}" unless rows.size == 1
  columns = rows[0].split('\t')
  raise "#{table}: malformed system.parts row #{rows[0].inspect}" unless columns.size == 3 && columns[1] == "Wide" && columns[2] == W106_KEYS.size.to_s
  columns[0]
end

def w106_assert_schema(binary : String, store : String, table : String) : Nil
  actual = w106_run(binary, store, "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw").lines.map(&.strip)
  expected = ["pk UInt64", "payload #{W106_TYPE}"]
  raise "#{table}: exact system.columns declarations differ: #{actual.inspect}" unless actual == expected
  nil
end

def w106_assert_json_keys(row : Hash(String, JSON::Any), expected : Array(String), label : String) : Nil
  actual = row.keys.sort
  wanted = expected.sort
  raise "#{label}: serializer keys differ; expected #{wanted.inspect}, got #{actual.inspect}" unless actual == wanted
end

def w106_validate_counter(row : Hash(String, JSON::Any), expected_defaults : Int32, label : String, keys : Array(String) = ["kind", "num_defaults", "num_rows"]) : Nil
  w106_assert_json_keys(row, keys, label)
  kind = row["kind"]?.try(&.as_s) || raise "#{label}: serializer kind missing"
  rows = row["num_rows"]?.try(&.as_i) || raise "#{label}: row count missing"
  defaults = row["num_defaults"]?.try(&.as_i) || raise "#{label}: default count missing"
  raise "#{label}: expected Default serializer, got #{kind}" unless kind == "Default"
  raise "#{label}: expected five rows, got #{rows}" unless rows == W106_KEYS.size.to_i64
  raise "#{label}: expected #{expected_defaults} defaults, got #{defaults}" unless defaults == expected_defaults.to_i64
end

def w106_assert_serialization(part : String) : Nil
  info = JSON.parse(File.read(File.join(part, "serialization.json"))).as_h
  puts "OBSERVED W106 serialization.json=#{info.to_json}"
  expected_keys = ["columns", "propagate_types_serialization_versions_to_nested_types", "types_serialization_versions", "version"].sort
  raise "W106 serialization.json envelope differs: #{info.keys.sort.inspect}" unless info.keys.sort == expected_keys
  raise "W106 serialization version differs" unless info["version"]?.try(&.as_i) == 1
  raise "W106 nested serialization-version propagation differs" unless info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) == true
  versions = info["types_serialization_versions"]?.try(&.as_h) || raise "W106 type-version map missing"
  raise "W106 type-version map differs: #{versions.to_json}" unless versions.size == 1 && versions["string"]?.try(&.as_i) == 1
  records = info["columns"]?.try(&.as_a) || raise "W106 serialization columns missing"
  names = records.map { |entry| entry.as_h["name"]?.try(&.as_s) || raise "W106 top-level serializer name missing" }
  raise "W106 serializer roots/order differ: #{names.inspect}" unless names == ["payload", "pk"]
  payload = records[0].as_h
  w106_validate_counter(payload, 0, "W106 root Tuple", ["kind", "name", "num_defaults", "num_rows", "subcolumns"])
  root_children = payload["subcolumns"]?.try(&.as_a) || raise "W106 root Tuple children missing"
  raise "W106 root Tuple child count differs" unless root_children.size == 2
  w106_validate_counter(root_children[0].as_h, 1, "W106 id UInt64")
  details = root_children[1].as_h
  w106_validate_counter(details, 0, "W106 details Tuple", ["kind", "num_defaults", "num_rows", "subcolumns"])
  detail_children = details["subcolumns"]?.try(&.as_a) || raise "W106 details Tuple children missing"
  raise "W106 details child count differs" unless detail_children.size == 4
  w106_validate_counter(detail_children[0].as_h, 2, "W106 state Nullable(Enum8)")
  metadata = detail_children[1].as_h
  w106_validate_counter(metadata, 1, "W106 metadata Tuple", ["kind", "num_defaults", "num_rows", "subcolumns"])
  metadata_children = metadata["subcolumns"]?.try(&.as_a) || raise "W106 metadata Tuple children missing"
  raise "W106 metadata child count differs" unless metadata_children.size == 2
  w106_validate_counter(metadata_children[0].as_h, 3, "W106 note Nullable(String)")
  w106_validate_counter(metadata_children[1].as_h, 1, "W106 event DateTime64")
  w106_validate_counter(detail_children[2].as_h, 1, "W106 fixed FixedString")
  w106_validate_counter(detail_children[3].as_h, 2, "W106 count UInt32")
  w106_validate_counter(records[1].as_h, 0, "W106 primary key", ["kind", "name", "num_defaults", "num_rows"])
  nil
end

def w106_assert_layout(part : String, label : String) : Nil
  actual_columns = File.read(File.join(part, "columns.txt")).lines.map(&.strip)
  raise "#{label}: exact columns.txt declaration differs: #{actual_columns.inspect}" unless actual_columns == w106_expected_columns
  actual_substreams = File.read(File.join(part, "columns_substreams.txt"))
  expected_substreams = w106_expected_substreams
  raise "#{label}: exact nested columns_substreams.txt differs:\nexpected:\n#{expected_substreams}actual:\n#{actual_substreams}" unless actual_substreams == expected_substreams
  codec = File.read(File.join(part, "default_compression_codec.txt"))
  raise "#{label}: expected LZ4 part codec, got #{codec.inspect}" unless codec == "CODEC(LZ4)"

  streams = w106_streams
  expected_bins = streams.map { |(name, _)| "#{CrystalClick::StreamName.hash(name)}.bin" }.sort
  expected_marks = streams.map { |(name, _)| "#{CrystalClick::StreamName.hash(name)}.mrk2" }.sort
  entries = Dir.children(part)
  actual_bins = entries.select(&.ends_with?(".bin")).sort
  actual_marks = entries.select(&.ends_with?(".mrk2")).sort
  raise "#{label}: exact .bin stream inventory differs: #{actual_bins.inspect}" unless actual_bins == expected_bins
  raise "#{label}: exact .mrk2 stream inventory differs: #{actual_marks.inspect}" unless actual_marks == expected_marks

  streams.each do |(name, fragments)|
    expected_raw = fragments.join
    encoded = File.read(File.join(part, "#{CrystalClick::StreamName.hash(name)}.bin")).to_slice
    actual_raw = String.new(CrystalClick::CompressedBlock.decode_all(encoded))
    w106_assert_bytes(actual_raw, expected_raw, "#{label} #{name} physical bytes")
    expected_marks = w106_expected_marks(fragments)
    actual_marks = w106_actual_marks(part, name)
    raise "#{label} #{name}: exact mark tuples differ; expected #{expected_marks.inspect}, got #{actual_marks.inspect}" unless actual_marks == expected_marks
    if name == "payload%2Edetails%2Estate"
      observed = actual_raw.to_slice.to_a
      puts "OBSERVED W106 RowBinary Nullable(Enum8) nested raw bytes=#{observed.inspect}"
      raise "W106 hidden Enum default raw bytes differ: #{observed.inspect}" unless observed == W106_ENUM_NULL_EXPECTATION
      w106_seeded_comparator_control(actual_raw, expected_raw, "#{label} nested Enum stream")
    end
  end
  w106_assert_serialization(part)
  puts "PASS #{label}: exact three-level declaration, escaped nested paths, #{streams.size} stream inventories, bytes, mark tuples, and recursive default statistics"
  nil
end

def w106_check_table(binary : String, store : String, table : String, part : String) : Nil
  actual = w106_run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated").strip
  expected = "#{File.basename(part.chomp("/"))}\t1"
  raise "#{table}: CHECK TABLE differs: #{actual.inspect}" unless actual == expected
  nil
end

def w106_attach(binary : String, store : String, source_part : String) : String
  w106_create_table(binary, store, W106_ATTACH_TABLE)
  data_path = w106_run(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{W106_ATTACH_TABLE}' FORMAT TSVRaw").strip
  raise "W106 ATTACH target has no data path" if data_path.empty?
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  FileUtils.cp_r(source_part, File.join(detached, "all_1_1_0"))
  w106_run(binary, store, "ALTER TABLE default.#{W106_ATTACH_TABLE} ATTACH PART 'all_1_1_0'")
  w106_part_path(binary, store, W106_ATTACH_TABLE)
end

def w106_expected_rowbinary(indexes : Array(Int32)) : String
  String.build do |output|
    indexes.each do |index|
      output << w106_unsigned_le(W106_KEYS[index], 8)
      output << w106_unsigned_le(W106_IDS[index], 8)
      if state = W106_STATES[index]
        output << "\x00" << w106_signed_le(state, 1)
      else
        output << "\x01"
      end
      if note = W106_NOTES[index]
        output << "\x00" << w106_varuint(note.bytesize.to_u64) << note
      else
        output << "\x01"
      end
      output << w106_signed_le(W106_EVENTS[index], 8)
      output << W106_FIXED[index]
      output << w106_unsigned_le(W106_COUNTS[index].to_u64, 4)
    end
  end
end

def w106_selected_query(binary : String, store : String, table : String, selected : Bool = false) : String
  predicate = selected ? " WHERE pk >= 20 AND pk < 50" : ""
  projection = "pk, payload.id, payload.details.state, payload.details.metadata.note, payload.details.metadata.event, payload.details.fixed, payload.details.count"
  w106_run(binary, store, "SELECT #{projection} FROM default.#{table}#{predicate} ORDER BY pk FORMAT RowBinary")
end

def w106_assert_rowbinary(binary : String, store : String, table : String, label : String) : Nil
  full = w106_selected_query(binary, store, table)
  w106_assert_bytes(full, w106_expected_rowbinary([0, 1, 2, 3, 4]), "#{label} full RowBinary")
  selected = w106_selected_query(binary, store, table, true)
  w106_assert_bytes(selected, w106_expected_rowbinary([1, 2, 3]), "#{label} selected RowBinary")
  puts "PASS #{label}: independently encoded full and selected nested RowBinary"
  nil
end

def w106_expect_reader_red(part : String) : Nil
  begin
    reader = CrystalClick::WidePart.open_typed(part, "payload")
    reader.read_tuple_mark_range("payload", 0, reader.mark_count)
  rescue ex : CrystalClick::UnsupportedFormatError
    allowed = ["unsupported exact typed column", "compositional Tuple accessor requires named supported scalar leaves"]
    raise "W106 reader failed for an unrelated reason: #{ex.message}" unless allowed.includes?(ex.message)
    puts "EXPECTED RED W106: stock-qualified nested Tuple rejected by public typed reader: #{ex.class}: #{ex.message}"
    return
  end
  raise "W106 RED failed: current reader admitted the nested Tuple declaration"
end

binary = ENV["CLICKHOUSE_BIN"]? || raise "set CLICKHOUSE_BIN to pinned ClickHouse 26.7.1.1315"
store = ENV["W106_STORE"]? || raise "set W106_STORE to a fresh temporary ClickHouse store directory"
unless store.starts_with?("/private/tmp/") || store.starts_with?("/tmp/")
  raise "refusing non-temporary W106_STORE path: #{store}"
end
if Dir.exists?(store)
  raise "W106_STORE must be empty: #{store}" unless Dir.empty?(store)
else
  Dir.mkdir_p(store)
end

version_output = IO::Memory.new
version_status = Process.run(binary, ["local", "--version"], output: version_output)
raise "could not read ClickHouse local version" unless version_status.success?
expected_version = "ClickHouse local version #{W106_STOCK_VERSION} (official build)."
raise "W106 requires #{expected_version}, got #{version_output.to_s.strip}" unless version_output.to_s.strip == expected_version
puts "Stock oracle: #{version_output.to_s.strip}"
raise "W106 nested type fixture differs" unless W106_TYPE == "Tuple(id UInt64, details Tuple(state Nullable(Enum8('neg' = -7, 'pos' = 7)), metadata Tuple(note Nullable(String), event DateTime64(3, 'America/New_York')), fixed FixedString(3), count UInt32))"

w106_create_table(binary, store, W106_SOURCE_TABLE)
w106_insert(binary, store, W106_SOURCE_TABLE)
source_part = w106_part_path(binary, store, W106_SOURCE_TABLE)
w106_assert_schema(binary, store, W106_SOURCE_TABLE)
w106_assert_layout(source_part, "W106 stock source")
w106_check_table(binary, store, W106_SOURCE_TABLE, source_part)
w106_assert_rowbinary(binary, store, W106_SOURCE_TABLE, "W106 stock source")

attached_part = w106_attach(binary, store, source_part)
w106_assert_schema(binary, store, W106_ATTACH_TABLE)
w106_assert_layout(attached_part, "W106 stock ATTACH")
w106_check_table(binary, store, W106_ATTACH_TABLE, attached_part)
w106_assert_rowbinary(binary, store, W106_ATTACH_TABLE, "W106 stock ATTACH")

# This is the only typed-reader call. It follows independent stock-created
# schema, physical stream, recursive statistics, ATTACH/CHECK, and RowBinary
# qualification for both the source part and its attached copy.
w106_expect_reader_red(attached_part)
puts "EXPECTED W106 RED: stock-certified nested Tuple rejected only after all independent qualifications"
exit 1

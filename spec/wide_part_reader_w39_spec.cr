require "./spec_helper"

W39_INTEGER_ARRAY_FIXTURE = File.expand_path("../test/fixtures/public/wide_array_integer128_256/part", __DIR__)

W39_ZERO_16_HEX       = "00" * 16
W39_ZERO_32_HEX       = "00" * 32
W39_ONES_16_HEX       = "ff" * 16
W39_ONES_32_HEX       = "ff" * 32
W39_INT128_MIN_HEX    = ("00" * 15) + "80"
W39_INT128_MAX_HEX    = ("ff" * 15) + "7f"
W39_UINT128_2_64_HEX  = ("00" * 8) + "01" + ("00" * 7)
W39_INT256_MIN_HEX    = ("00" * 31) + "80"
W39_INT256_MAX_HEX    = ("ff" * 31) + "7f"
W39_UINT256_2_128_HEX = ("00" * 16) + "01" + ("00" * 15)

W39_NON_NULL_SIZE0_HEX =
  "0000000000000000" + "0200000000000000" + "0100000000000000" + "0000000000000000" +
    "0200000000000000" + "0100000000000000" + "0000000000000000"
W39_NULLABLE_SIZE0_HEX =
  "0000000000000000" + "0300000000000000" + "0000000000000000" + "0200000000000000" +
    "0100000000000000" + "0100000000000000" + "0000000000000000"
W39_NULL_MAP_HEX = "01000000010001"

W39_INT128_PAYLOAD_HEX =
  W39_INT128_MIN_HEX + W39_ONES_16_HEX + W39_ZERO_16_HEX + "01" + ("00" * 15) + W39_INT128_MAX_HEX +
    "01" + ("00" * 14) + "80"
W39_UINT128_PAYLOAD_HEX =
  W39_ZERO_16_HEX + W39_ONES_16_HEX + "01" + ("00" * 15) + ("fe" + ("ff" * 15)) +
    W39_UINT128_2_64_HEX + "2a" + ("00" * 15)
W39_INT256_PAYLOAD_HEX =
  W39_INT256_MIN_HEX + W39_ONES_32_HEX + W39_ZERO_32_HEX + "01" + ("00" * 31) + W39_INT256_MAX_HEX +
    "01" + ("00" * 30) + "80"
W39_UINT256_PAYLOAD_HEX =
  W39_ZERO_32_HEX + W39_ONES_32_HEX + "01" + ("00" * 31) + ("fe" + ("ff" * 31)) +
    W39_UINT256_2_128_HEX + "2a" + ("00" * 31)

W39_NULLABLE_INT128_PAYLOAD_HEX =
  W39_ZERO_16_HEX + W39_INT128_MIN_HEX + W39_ONES_16_HEX + W39_ZERO_16_HEX + W39_ZERO_16_HEX +
    W39_INT128_MAX_HEX + W39_ZERO_16_HEX
W39_NULLABLE_UINT128_PAYLOAD_HEX =
  W39_ZERO_16_HEX + W39_ZERO_16_HEX + W39_ONES_16_HEX + "01" + ("00" * 15) + W39_ZERO_16_HEX +
    ("fe" + ("ff" * 15)) + W39_ZERO_16_HEX
W39_NULLABLE_INT256_PAYLOAD_HEX =
  W39_ZERO_32_HEX + W39_INT256_MIN_HEX + W39_ONES_32_HEX + W39_ZERO_32_HEX + W39_ZERO_32_HEX +
    W39_INT256_MAX_HEX + W39_ZERO_32_HEX
W39_NULLABLE_UINT256_PAYLOAD_HEX =
  W39_ZERO_32_HEX + W39_ZERO_32_HEX + W39_ONES_32_HEX + "01" + ("00" * 31) + W39_ZERO_32_HEX +
    ("fe" + ("ff" * 31)) + W39_ZERO_32_HEX

W39_INT256_MIN            = CrystalClick::Int256Value.from_words(0_u64, 0_u64, 0_u64, 0x8000000000000000_u64)
W39_INT256_MAX            = CrystalClick::Int256Value.from_words(UInt64::MAX, UInt64::MAX, UInt64::MAX, 0x7fffffffffffffff_u64)
W39_INT256_MIN_PLUS_ONE   = CrystalClick::Int256Value.from_words(1_u64, 0_u64, 0_u64, 0x8000000000000000_u64)
W39_INT256_NEGATIVE_ONE   = CrystalClick::Int256Value.from_words(UInt64::MAX, UInt64::MAX, UInt64::MAX, UInt64::MAX)
W39_UINT256_MAX_MINUS_ONE = CrystalClick::UInt256Value.from_words(UInt64::MAX - 1_u64, UInt64::MAX, UInt64::MAX, UInt64::MAX)
W39_UINT256_2_128         = CrystalClick::UInt256Value.from_words(0_u64, 0_u64, 1_u64, 0_u64)
W39_UINT256_FORTY_TWO     = CrystalClick::UInt256Value.from_words(42_u64, 0_u64, 0_u64, 0_u64)

W39_INT128_ROWS = [
  [] of Int128,
  [Int128::MIN, -1_i128],
  [0_i128],
  [] of Int128,
  [1_i128, Int128::MAX],
  [Int128::MIN + 1_i128],
  [] of Int128,
] of Array(Int128)
W39_UINT128_ROWS = [
  [] of UInt128,
  [0_u128, UInt128::MAX],
  [1_u128],
  [] of UInt128,
  [UInt128::MAX - 1_u128, 18_446_744_073_709_551_616_u128],
  [42_u128],
  [] of UInt128,
] of Array(UInt128)
W39_INT256_ROWS = [
  [] of CrystalClick::Int256Value,
  [W39_INT256_MIN, W39_INT256_NEGATIVE_ONE],
  [CrystalClick::Int256Value.from_words(0_u64, 0_u64, 0_u64, 0_u64)],
  [] of CrystalClick::Int256Value,
  [CrystalClick::Int256Value.from_words(1_u64, 0_u64, 0_u64, 0_u64), W39_INT256_MAX],
  [W39_INT256_MIN_PLUS_ONE],
  [] of CrystalClick::Int256Value,
] of Array(CrystalClick::Int256Value)
W39_UINT256_ROWS = [
  [] of CrystalClick::UInt256Value,
  [CrystalClick::UInt256Value.new(0_u128, 0_u128), CrystalClick::UInt256Value.new(UInt128::MAX, UInt128::MAX)],
  [CrystalClick::UInt256Value.new(1_u128, 0_u128)],
  [] of CrystalClick::UInt256Value,
  [W39_UINT256_MAX_MINUS_ONE, W39_UINT256_2_128],
  [W39_UINT256_FORTY_TWO],
  [] of CrystalClick::UInt256Value,
] of Array(CrystalClick::UInt256Value)

W39_NULLABLE_INT128_ROWS = [
  [] of Int128?, [nil, Int128::MIN, -1_i128] of Int128?, [] of Int128?,
  [0_i128, nil] of Int128?, [Int128::MAX] of Int128?, [nil] of Int128?, [] of Int128?,
] of Array(Int128?)
W39_NULLABLE_UINT128_ROWS = [
  [] of UInt128?, [nil, 0_u128, UInt128::MAX] of UInt128?, [] of UInt128?,
  [1_u128, nil] of UInt128?, [UInt128::MAX - 1_u128] of UInt128?, [nil] of UInt128?, [] of UInt128?,
] of Array(UInt128?)
W39_NULLABLE_INT256_ROWS = [
  [] of CrystalClick::Int256Value?, [nil, W39_INT256_MIN, W39_INT256_NEGATIVE_ONE] of CrystalClick::Int256Value?,
  [] of CrystalClick::Int256Value?,
  [CrystalClick::Int256Value.from_words(0_u64, 0_u64, 0_u64, 0_u64), nil] of CrystalClick::Int256Value?,
  [W39_INT256_MAX] of CrystalClick::Int256Value?, [nil] of CrystalClick::Int256Value?,
  [] of CrystalClick::Int256Value?,
] of Array(CrystalClick::Int256Value?)
W39_NULLABLE_UINT256_ROWS = [
  [] of CrystalClick::UInt256Value?,
  [nil, CrystalClick::UInt256Value.new(0_u128, 0_u128), CrystalClick::UInt256Value.new(UInt128::MAX, UInt128::MAX)] of CrystalClick::UInt256Value?,
  [] of CrystalClick::UInt256Value?,
  [CrystalClick::UInt256Value.new(1_u128, 0_u128), nil] of CrystalClick::UInt256Value?,
  [W39_UINT256_MAX_MINUS_ONE] of CrystalClick::UInt256Value?, [nil] of CrystalClick::UInt256Value?,
  [] of CrystalClick::UInt256Value?,
] of Array(CrystalClick::UInt256Value?)

private def w39_hex_bytes(hex : String) : Array(UInt8)
  raise "W39 hex fixture has odd length" unless hex.bytesize.even?
  Array(UInt8).new(hex.bytesize // 2) do |index|
    hex.byte_slice(index * 2, 2).to_i(16).to_u8
  end
end

private def w39_decode_stream(part : String, logical_name : String) : Array(UInt8)
  file = File.join(part, "#{CrystalClick::StreamName.hash(logical_name)}.bin")
  CrystalClick::CompressedBlock.decode_all(File.read(file).to_slice).to_a
end

private def w39_check_stock_numeric(column : String, type : T.class, type_name : String, rows : Array(Array(T)), payload_hex : String) : Nil forall T
  reader = CrystalClick::WidePart.open_typed(W39_INTEGER_ARRAY_FIXTURE, column)
  reader.column_type.should eq("Array(#{type_name})")
  reader.row_count.should eq(7_u64)
  reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
  reader.read_array_numeric_mark_range(column, 0, reader.mark_count, type).should eq(rows)
  reader.read_array_numeric_mark_range(column, 1, 2, type).should eq(rows[2, 4])
  w39_decode_stream(W39_INTEGER_ARRAY_FIXTURE, "#{column}.size0").should eq(w39_hex_bytes(W39_NON_NULL_SIZE0_HEX))
  w39_decode_stream(W39_INTEGER_ARRAY_FIXTURE, column).should eq(w39_hex_bytes(payload_hex))
end

private def w39_check_stock_nullable_numeric(column : String, type : T.class, type_name : String, rows : Array(Array(T?)), payload_hex : String) : Nil forall T
  reader = CrystalClick::WidePart.open_typed(W39_INTEGER_ARRAY_FIXTURE, column)
  reader.column_type.should eq("Array(Nullable(#{type_name}))")
  reader.row_count.should eq(7_u64)
  reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
  reader.read_array_nullable_numeric_mark_range(column, 0, reader.mark_count, type).should eq(rows)
  reader.read_array_nullable_numeric_mark_range(column, 1, 2, type).should eq(rows[2, 4])
  w39_decode_stream(W39_INTEGER_ARRAY_FIXTURE, "#{column}.size0").should eq(w39_hex_bytes(W39_NULLABLE_SIZE0_HEX))
  w39_decode_stream(W39_INTEGER_ARRAY_FIXTURE, "#{column}.null").should eq(w39_hex_bytes(W39_NULL_MAP_HEX))
  w39_decode_stream(W39_INTEGER_ARRAY_FIXTURE, column).should eq(w39_hex_bytes(payload_hex))
end

private def w39_check_numeric_writer(type : T.class, type_name : String, rows : Array(Array(T)), payload_hex : String) : Nil forall T
  parent = File.tempname("crystal-click-w39-array-#{type_name}")
  Dir.mkdir(parent)
  part = File.join(parent, "part")
  keys = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
  begin
    CrystalClick::WidePartWriter.write_uint64_array_numeric_pair(
      part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2
    )
    reader = CrystalClick::WidePart.open_typed(part, "payload")
    reader.column_type.should eq("Array(#{type_name})")
    reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    reader.read_array_numeric_mark_range("payload", 0, reader.mark_count, type).should eq(rows)
    reader.read_array_numeric_mark_range("payload", 1, 2, type).should eq(rows[2, 4])
    w39_decode_stream(part, "payload.size0").should eq(w39_hex_bytes(W39_NON_NULL_SIZE0_HEX))
    w39_decode_stream(part, "payload").should eq(w39_hex_bytes(payload_hex))
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w39_check_nullable_numeric_writer(type : T.class, type_name : String, rows : Array(Array(T?)), payload_hex : String) : Nil forall T
  parent = File.tempname("crystal-click-w39-array-null-#{type_name}")
  Dir.mkdir(parent)
  part = File.join(parent, "part")
  keys = [1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64]
  begin
    CrystalClick::WidePartWriter.write_uint64_array_nullable_numeric_pair(
      part, "pk", keys.to_unsafe.to_slice(keys.size), "payload", rows.to_unsafe.to_slice(rows.size), rows_per_mark: 2
    )
    reader = CrystalClick::WidePart.open_typed(part, "payload")
    reader.column_type.should eq("Array(Nullable(#{type_name}))")
    reader.mark_row_counts.should eq([2_u64, 2_u64, 2_u64, 1_u64])
    reader.read_array_nullable_numeric_mark_range("payload", 0, reader.mark_count, type).should eq(rows)
    reader.read_array_nullable_numeric_mark_range("payload", 1, 2, type).should eq(rows[2, 4])
    w39_decode_stream(part, "payload.size0").should eq(w39_hex_bytes(W39_NULLABLE_SIZE0_HEX))
    w39_decode_stream(part, "payload.null").should eq(w39_hex_bytes(W39_NULL_MAP_HEX))
    w39_decode_stream(part, "payload").should eq(w39_hex_bytes(payload_hex))
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w39_check_numeric_typed_batches(column : String, type : T.class, rows : Array(Array(T))) : Nil forall T
  parent = File.tempname("crystal-click-w39-array-batch-#{column}")
  Dir.mkdir(parent)
  part = File.join(parent, "all_1_1_0")
  begin
    FileUtils.cp_r(W39_INTEGER_ARRAY_FIXTURE, part)
    table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", column])
    observed_keys = [] of UInt64
    observed_values = [] of Array(T)
    batches = [] of {Int32, UInt64, Int32}
    table.scan_typed(batch_rows: 3) do |batch|
      keys = batch.values_for("pk", UInt64)
      values = batch.array_numeric_values(column, type)
      observed_keys.concat(keys)
      observed_values.concat(values)
      batches << {batch.mark_index, batch.part_row_offset, values.size.to_i32}
    end

    observed_keys.should eq([1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64])
    observed_values.should eq(rows)
    batches.should eq([
      {0_i32, 0_u64, 2_i32},
      {1_i32, 2_u64, 2_i32},
      {2_i32, 4_u64, 2_i32},
      {3_i32, 6_u64, 1_i32},
    ])

    later_rows = [] of Array(T)
    table.scan_typed_window(4_u64, max_rows: 3) do |batch|
      later_rows.concat(batch.array_numeric_values(column, type))
    end
    later_rows.should eq(rows[4, 3])
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w39_check_nullable_numeric_typed_batches(column : String, type : T.class, rows : Array(Array(T?))) : Nil forall T
  parent = File.tempname("crystal-click-w39-array-null-batch-#{column}")
  Dir.mkdir(parent)
  part = File.join(parent, "all_1_1_0")
  begin
    FileUtils.cp_r(W39_INTEGER_ARRAY_FIXTURE, part)
    table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", column])
    observed_keys = [] of UInt64
    observed_values = [] of Array(T?)
    batches = [] of {Int32, UInt64, Int32}
    table.scan_typed(batch_rows: 3) do |batch|
      keys = batch.values_for("pk", UInt64)
      values = batch.array_nullable_numeric_values(column, type)
      observed_keys.concat(keys)
      observed_values.concat(values)
      batches << {batch.mark_index, batch.part_row_offset, values.size.to_i32}
    end

    observed_keys.should eq([1_u64, 2_u64, 4_u64, 6_u64, 9_u64, 11_u64, 13_u64])
    observed_values.should eq(rows)
    batches.should eq([
      {0_i32, 0_u64, 2_i32},
      {1_i32, 2_u64, 2_i32},
      {2_i32, 4_u64, 2_i32},
      {3_i32, 6_u64, 1_i32},
    ])

    later_rows = [] of Array(T?)
    table.scan_typed_window(4_u64, max_rows: 3) do |batch|
      later_rows.concat(batch.array_nullable_numeric_values(column, type))
    end
    later_rows.should eq(rows[4, 3])
  ensure
    FileUtils.rm_rf(parent)
  end
end

W39_DATABASE_UUID   = "f5e11e4a-567f-4e21-b351-c6839936af08"
W39_TABLE_UUID      = "d155a312-e332-4a44-97a7-c006bf20f945"
W39_CATALOG_COLUMNS = [
  {"a_i128", "Array(Int128)"},
  {"a_u128", "Array(UInt128)"},
  {"a_i256", "Array(Int256)"},
  {"a_u256", "Array(UInt256)"},
  {"n_i128", "Array(Nullable(Int128))"},
  {"n_u128", "Array(Nullable(UInt128))"},
  {"n_i256", "Array(Nullable(Int256))"},
  {"n_u256", "Array(Nullable(UInt256))"},
]

private def w39_catalog_store_path(root : String, uuid : String) : String
  File.join(root, "store", uuid[0, 3], uuid)
end

private def with_w39_catalog_root(& : String ->)
  root = File.tempname("crystal-click-w39-offline-catalog")
  FileUtils.mkdir_p(File.join(root, "metadata"))
  FileUtils.mkdir_p(File.join(root, "store"))
  begin
    File.write(
      File.join(root, "metadata", "lab.sql"),
      "ATTACH DATABASE _ UUID '#{W39_DATABASE_UUID}'\nENGINE = Atomic\n"
    )

    database_path = w39_catalog_store_path(root, W39_DATABASE_UUID)
    table_path = w39_catalog_store_path(root, W39_TABLE_UUID)
    FileUtils.mkdir_p(database_path)
    FileUtils.mkdir_p(table_path)
    columns = String.build do |io|
      io << "    `pk` UInt64,\n"
      W39_CATALOG_COLUMNS.each_with_index do |(name, type), index|
        io << "    `" << name << "` " << type
        io << ",\n" unless index == W39_CATALOG_COLUMNS.size - 1
        io << "\n" if index == W39_CATALOG_COLUMNS.size - 1
      end
    end
    File.write(
      File.join(database_path, "events.sql"),
      "ATTACH TABLE _ UUID '#{W39_TABLE_UUID}'\n(\n#{columns})\nENGINE = MergeTree\nORDER BY pk\n"
    )
    File.write(File.join(table_path, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_path, "detached"))
    FileUtils.cp_r(W39_INTEGER_ARRAY_FIXTURE, File.join(table_path, "all_1_1_0"))
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

describe CrystalClick::WidePart do
  it "admits only one-level raw 128/256-bit integer Array leaves and their BASIC Nullable forms" do
    {
      "Array(Int128)", "Array(UInt128)", "Array(Int256)", "Array(UInt256)",
      "Array(Nullable(Int128))", "Array(Nullable(UInt128))",
      "Array(Nullable(Int256))", "Array(Nullable(UInt256))",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_true
    end

    {
      "Array(Decimal(38, 39))", "Array(Nullable(Decimal(38, 39)))",
      "Array(Decimal(75, 0))", "Array(Nullable(Decimal(75, 0)))",
      "Array(Array(Int128))", "Array(Nullable(Nullable(Int128)))",
      "Array(Int128) trailing", "Nullable(Array(Int128))",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end

    {"Int128", "UInt128", "Int256", "UInt256"}.each do |type|
      CrystalClick::WidePart.supports_numeric_type?(type).should be_false
    end
  end

  it "reads stock BASIC Array(Int128/UInt128/Int256/UInt256) streams and edge values" do
    w39_check_stock_numeric("a_i128", Int128, "Int128", W39_INT128_ROWS, W39_INT128_PAYLOAD_HEX)
    w39_check_stock_numeric("a_u128", UInt128, "UInt128", W39_UINT128_ROWS, W39_UINT128_PAYLOAD_HEX)
    w39_check_stock_numeric("a_i256", CrystalClick::Int256Value, "Int256", W39_INT256_ROWS, W39_INT256_PAYLOAD_HEX)
    w39_check_stock_numeric("a_u256", CrystalClick::UInt256Value, "UInt256", W39_UINT256_ROWS, W39_UINT256_PAYLOAD_HEX)

    w39_check_stock_nullable_numeric("n_i128", Int128, "Int128", W39_NULLABLE_INT128_ROWS, W39_NULLABLE_INT128_PAYLOAD_HEX)
    w39_check_stock_nullable_numeric("n_u128", UInt128, "UInt128", W39_NULLABLE_UINT128_ROWS, W39_NULLABLE_UINT128_PAYLOAD_HEX)
    w39_check_stock_nullable_numeric("n_i256", CrystalClick::Int256Value, "Int256", W39_NULLABLE_INT256_ROWS, W39_NULLABLE_INT256_PAYLOAD_HEX)
    w39_check_stock_nullable_numeric("n_u256", CrystalClick::UInt256Value, "UInt256", W39_NULLABLE_UINT256_ROWS, W39_NULLABLE_UINT256_PAYLOAD_HEX)
  end

  it "writes generic BASIC 128/256-bit integer array columns byte-for-byte" do
    w39_check_numeric_writer(Int128, "Int128", W39_INT128_ROWS, W39_INT128_PAYLOAD_HEX)
    w39_check_numeric_writer(UInt128, "UInt128", W39_UINT128_ROWS, W39_UINT128_PAYLOAD_HEX)
    w39_check_numeric_writer(CrystalClick::Int256Value, "Int256", W39_INT256_ROWS, W39_INT256_PAYLOAD_HEX)
    w39_check_numeric_writer(CrystalClick::UInt256Value, "UInt256", W39_UINT256_ROWS, W39_UINT256_PAYLOAD_HEX)

    w39_check_nullable_numeric_writer(Int128, "Int128", W39_NULLABLE_INT128_ROWS, W39_NULLABLE_INT128_PAYLOAD_HEX)
    w39_check_nullable_numeric_writer(UInt128, "UInt128", W39_NULLABLE_UINT128_ROWS, W39_NULLABLE_UINT128_PAYLOAD_HEX)
    w39_check_nullable_numeric_writer(CrystalClick::Int256Value, "Int256", W39_NULLABLE_INT256_ROWS, W39_NULLABLE_INT256_PAYLOAD_HEX)
    w39_check_nullable_numeric_writer(CrystalClick::UInt256Value, "UInt256", W39_NULLABLE_UINT256_ROWS, W39_NULLABLE_UINT256_PAYLOAD_HEX)
  end

  it "fails closed on non-canonical integer type spellings and typed accessor mismatches" do
    {
      "Array(Integer128)", "Array(Int128 )", "Array(int128)",
      "Array(Nullable(Integer128))", "Array(Nullable(Int128) )",
      "Array(Nullable(int128))",
    }.each do |type|
      CrystalClick::WidePart.supports_typed_type?(type).should be_false
    end

    reader = CrystalClick::WidePart.open_typed(W39_INTEGER_ARRAY_FIXTURE, "a_i128")
    expect_raises(CrystalClick::UnsupportedFormatError) do
      reader.read_array_numeric_mark_range("a_i128", 0, 1, UInt128)
    end

    nullable_reader = CrystalClick::WidePart.open_typed(W39_INTEGER_ARRAY_FIXTURE, "n_i128")
    expect_raises(CrystalClick::UnsupportedFormatError) do
      nullable_reader.read_array_nullable_numeric_mark_range("n_i128", 0, 1, UInt128)
    end
  end

  it "rejects a truncated 128-bit array payload frame as corruption" do
    parent = File.tempname("crystal-click-w39-corrupt-array")
    Dir.mkdir(parent)
    part = File.join(parent, "part")
    FileUtils.cp_r(W39_INTEGER_ARRAY_FIXTURE, part)
    begin
      payload_file = File.join(part, "#{CrystalClick::StreamName.hash("a_i128")}.bin")
      bytes = writable_file_bytes(payload_file)
      File.open(payload_file, "wb") { |io| io.write(bytes[0, bytes.size - 1]) }
      reader = CrystalClick::WidePart.open_typed(part, "a_i128")
      expect_raises(CrystalClick::CorruptPartError) do
        reader.read_array_numeric_mark_range("a_i128", 0, reader.mark_count, Int128)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a truncated nullable 256-bit child stream before publishing a typed batch" do
    parent = File.tempname("crystal-click-w39-corrupt-nullable-array")
    Dir.mkdir(parent)
    part = File.join(parent, "all_1_1_0")
    FileUtils.cp_r(W39_INTEGER_ARRAY_FIXTURE, part)
    begin
      payload_file = File.join(part, "#{CrystalClick::StreamName.hash("n_i256")}.bin")
      bytes = writable_file_bytes(payload_file)
      File.open(payload_file, "wb") { |io| io.write(bytes[0, bytes.size - 1]) }

      published_batches = 0
      expect_raises(CrystalClick::CorruptPartError) do
        table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "n_i256"])
        table.scan_typed do |_batch|
          published_batches += 1
        end
      end
      published_batches.should eq(0)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects mismatched 256-bit array row counts without publishing either shape" do
    parent = File.tempname("crystal-click-w39-array-writer-preflight")
    Dir.mkdir(parent)
    keys = [1_u64, 2_u64]
    numeric_rows = W39_UINT256_ROWS[0, 1]
    nullable_rows = W39_NULLABLE_UINT256_ROWS[0, 1]
    numeric_destination = File.join(parent, "numeric")
    nullable_destination = File.join(parent, "nullable")

    begin
      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_numeric_pair(
          numeric_destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          numeric_rows.to_unsafe.to_slice(numeric_rows.size), rows_per_mark: 1
        )
      end
      File.exists?(numeric_destination).should be_false
      Dir.children(parent).should be_empty

      expect_raises(ArgumentError) do
        CrystalClick::WidePartWriter.write_uint64_array_nullable_numeric_pair(
          nullable_destination, "pk", keys.to_unsafe.to_slice(keys.size), "payload",
          nullable_rows.to_unsafe.to_slice(nullable_rows.size), rows_per_mark: 1
        )
      end
      File.exists?(nullable_destination).should be_false
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end
end

describe CrystalClick::WidePartTable do
  it "materializes every W39 integer Array shape in typed mark batches and later row windows" do
    w39_check_numeric_typed_batches("a_i128", Int128, W39_INT128_ROWS)
    w39_check_numeric_typed_batches("a_u128", UInt128, W39_UINT128_ROWS)
    w39_check_numeric_typed_batches("a_i256", CrystalClick::Int256Value, W39_INT256_ROWS)
    w39_check_numeric_typed_batches("a_u256", CrystalClick::UInt256Value, W39_UINT256_ROWS)

    w39_check_nullable_numeric_typed_batches("n_i128", Int128, W39_NULLABLE_INT128_ROWS)
    w39_check_nullable_numeric_typed_batches("n_u128", UInt128, W39_NULLABLE_UINT128_ROWS)
    w39_check_nullable_numeric_typed_batches("n_i256", CrystalClick::Int256Value, W39_NULLABLE_INT256_ROWS)
    w39_check_nullable_numeric_typed_batches("n_u256", CrystalClick::UInt256Value, W39_NULLABLE_UINT256_ROWS)
  end
end

describe CrystalClick::OfflineCatalog do
  it "materializes every W39 integer Array shape as caller-owned values" do
    with_w39_catalog_root do |root|
      table = CrystalClick::OfflineCatalog.open(root)["lab"]["events"]
      table.columns.map { |column| {column.name, column.type} }.should eq(
        [{"pk", "UInt64"}] + W39_CATALOG_COLUMNS
      )

      table["a_i128"].values.map { |value| value.as(Array(Int128)) }.should eq(W39_INT128_ROWS)
      table["a_u128"].values.map { |value| value.as(Array(UInt128)) }.should eq(W39_UINT128_ROWS)
      table["a_i256"].values.map { |value| value.as(Array(CrystalClick::Int256Value)) }.should eq(W39_INT256_ROWS)
      table["a_u256"].values.map { |value| value.as(Array(CrystalClick::UInt256Value)) }.should eq(W39_UINT256_ROWS)

      table["n_i128"].values.map { |value| value.as(Array(Int128?)) }.should eq(W39_NULLABLE_INT128_ROWS)
      table["n_u128"].values.map { |value| value.as(Array(UInt128?)) }.should eq(W39_NULLABLE_UINT128_ROWS)
      table["n_i256"].values.map { |value| value.as(Array(CrystalClick::Int256Value?)) }.should eq(W39_NULLABLE_INT256_ROWS)
      table["n_u256"].values.map { |value| value.as(Array(CrystalClick::UInt256Value?)) }.should eq(W39_NULLABLE_UINT256_ROWS)

      owned_uint256 = table["a_u256"].values.map { |value| value.as(Array(CrystalClick::UInt256Value)) }
      owned_uint256[1][0] = CrystalClick::UInt256Value.new(77_u128, 0_u128)
      owned_uint256[1] << CrystalClick::UInt256Value.new(88_u128, 0_u128)
      table["a_u256"].values.map { |value| value.as(Array(CrystalClick::UInt256Value)) }.should eq(W39_UINT256_ROWS)

      owned_nullable_uint256 = table["n_u256"].values.map { |value| value.as(Array(CrystalClick::UInt256Value?)) }
      owned_nullable_uint256[1][0] = W39_UINT256_2_128
      owned_nullable_uint256[1] << nil
      table["n_u256"].values.map { |value| value.as(Array(CrystalClick::UInt256Value?)) }.should eq(W39_NULLABLE_UINT256_ROWS)
    end
  end
end

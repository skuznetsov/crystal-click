# Independent W114 Geometry GREEN oracle. Stock expectations are literal
# logical rows below; neither the reader nor writer supplies its own oracle.
require "file_utils"
require "../src/crystal_click"

private class W114GreenMismatch < Exception
end

private struct W114GreenProfile
  getter name : String
  getter keys : Array(UInt64)
  getter data : CrystalClick::WideGeometryColumnData
  getter mark_rows : Array(UInt64)
  getter selected_first_mark : Int32
  getter selected_mark_count : Int32
  getter selected_min : UInt64
  getter selected_max : UInt64

  def initialize(
    @name : String,
    @keys : Array(UInt64),
    @data : CrystalClick::WideGeometryColumnData,
    @mark_rows : Array(UInt64),
    @selected_first_mark : Int32,
    @selected_mark_count : Int32,
    @selected_min : UInt64,
    @selected_max : UInt64,
  )
  end
end

private W114G_P0 = CrystalClick::WidePointValue.from_bits(0x8000_0000_0000_0000_u64, 0_u64)
private W114G_P1 = CrystalClick::WidePointValue.from_bits(0x7ff8_0000_0000_1234_u64, 0x400c_0000_0000_0000_u64)
private W114G_P2 = CrystalClick::WidePointValue.from_bits(0xfff0_0000_0000_0000_u64, 1_u64)
private W114G_P3 = CrystalClick::WidePointValue.from_bits(0x4002_0000_0000_0000_u64, 0x7ff8_0000_0000_5678_u64)

private def w114g_fail(message : String) : NoReturn
  raise W114GreenMismatch.new(message)
end

private def w114g_require(condition : Bool, message : String) : Nil
  w114g_fail(message) unless condition
end

private def w114g_geo_array(
  type_name : String,
  level_sizes : Array(Array(UInt64)),
  points : Array(CrystalClick::WidePointValue),
) : CrystalClick::WideGeoArrayColumnData
  plan = CrystalClick::GeoArrayColumnType.for_type(type_name) || w114g_fail("unknown literal Geo Array arm #{type_name}")
  CrystalClick::WideGeoArrayColumnData.new(plan, level_sizes, points)
end

private def w114g_empty_arrays : Hash(CrystalClick::WideGeometryArm, CrystalClick::WideGeoArrayColumnData)
  arrays = {} of CrystalClick::WideGeometryArm => CrystalClick::WideGeoArrayColumnData
  {
    CrystalClick::WideGeometryArm::LineString,
    CrystalClick::WideGeometryArm::MultiLineString,
    CrystalClick::WideGeometryArm::MultiPolygon,
    CrystalClick::WideGeometryArm::Polygon,
    CrystalClick::WideGeometryArm::Ring,
    CrystalClick::WideGeometryArm::MultiPoint,
  }.each do |arm|
    levels = Array(Array(UInt64)).new(arm.depth) { [] of UInt64 }
    arrays[arm] = w114g_geo_array(arm.type_name, levels, [] of CrystalClick::WidePointValue)
  end
  arrays
end

private def w114g_mixed : CrystalClick::WideGeometryColumnData
  arrays = {} of CrystalClick::WideGeometryArm => CrystalClick::WideGeoArrayColumnData
  arrays[CrystalClick::WideGeometryArm::LineString] = w114g_geo_array(
    "LineString", [[1_u64, 1_u64, 2_u64, 1_u64]], [W114G_P0, W114G_P0, W114G_P1, W114G_P2, W114G_P2]
  )
  arrays[CrystalClick::WideGeometryArm::MultiLineString] = w114g_geo_array(
    "MultiLineString", [[2_u64, 0_u64], [1_u64, 0_u64]], [W114G_P0]
  )
  arrays[CrystalClick::WideGeometryArm::MultiPolygon] = w114g_geo_array(
    "MultiPolygon", [[2_u64, 1_u64], [1_u64, 2_u64, 0_u64], [1_u64, 0_u64, 1_u64]], [W114G_P2, W114G_P3]
  )
  arrays[CrystalClick::WideGeometryArm::Polygon] = w114g_geo_array(
    "Polygon", [[2_u64, 0_u64], [1_u64, 0_u64]], [W114G_P1]
  )
  arrays[CrystalClick::WideGeometryArm::Ring] = w114g_geo_array(
    "Ring", [[2_u64, 0_u64]], [W114G_P2, W114G_P3]
  )
  arrays[CrystalClick::WideGeometryArm::MultiPoint] = w114g_geo_array(
    "MultiPoint", [[1_u64, 1_u64]], [W114G_P1, W114G_P3]
  )
  CrystalClick::WideGeometryColumnData.new(
    [0_u8, 0_u8, 0_u8, 1_u8, 2_u8, 3_u8, 4_u8, 5_u8, 6_u8, 255_u8, 0_u8, 1_u8, 2_u8, 3_u8, 4_u8, 5_u8, 6_u8],
    [W114G_P3, W114G_P0],
    arrays
  )
end

private def w114g_profiles : Array(W114GreenProfile)
  mixed = w114g_mixed
  null_data = CrystalClick::WideGeometryColumnData.new(
    Array(UInt8).new(5, 255_u8), [] of CrystalClick::WidePointValue, w114g_empty_arrays
  )
  uniform_arrays = w114g_empty_arrays
  uniform_arrays[CrystalClick::WideGeometryArm::MultiPoint] = w114g_geo_array(
    "MultiPoint", [[1_u64, 1_u64, 0_u64]], [W114G_P2, W114G_P3]
  )
  uniform_data = CrystalClick::WideGeometryColumnData.new(
    [3_u8, 3_u8, 6_u8, 6_u8, 6_u8], [W114G_P0, W114G_P0], uniform_arrays
  )

  profiles = [] of W114GreenProfile
  {"mixed_basic", "mixed_compact"}.each do |name|
    profiles << W114GreenProfile.new(
      name,
      [0_u64, 0_u64, 1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64, 9_u64, 10_u64, 11_u64, 12_u64, 13_u64, 14_u64, 15_u64],
      mixed,
      [2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 1_u64],
      4, 5, 9_u64, 16_u64
    )
  end
  {"all_null_basic", "all_null_compact"}.each do |name|
    profiles << W114GreenProfile.new(name, [0_u64, 1_u64, 2_u64, 3_u64, 4_u64], null_data,
      [2_u64, 2_u64, 1_u64], 1, 2, 2_u64, 4_u64)
  end
  {"uniform_point_multipoint_basic", "uniform_point_multipoint_compact"}.each do |name|
    profiles << W114GreenProfile.new(name, [0_u64, 0_u64, 1_u64, 2_u64, 3_u64], uniform_data,
      [2_u64, 2_u64, 1_u64], 1, 2, 1_u64, 4_u64)
  end
  profiles
end

private def w114g_assert_point(actual : CrystalClick::WidePointValue, expected : CrystalClick::WidePointValue, label : String) : Nil
  w114g_require(actual.x_bits == expected.x_bits && actual.y_bits == expected.y_bits, "#{label}: raw Float64 coordinate words differ")
end

private def w114g_assert_geo(actual : CrystalClick::WideGeoArrayRow, expected : CrystalClick::WideGeoArrayRow, label : String) : Nil
  w114g_require(actual.type_name == expected.type_name, "#{label}: nominal nested arm differs")
  w114g_require(actual.level == expected.level && actual.terminal? == expected.terminal?, "#{label}: nested level differs")
  w114g_require(actual.size == expected.size, "#{label}: nested size differs")
  if expected.terminal?
    expected.size.times do |index|
      w114g_assert_point(actual.point_at(index), expected.point_at(index), "#{label}[#{index}]")
    end
  else
    expected.size.times do |index|
      w114g_assert_geo(actual.array_at(index), expected.array_at(index), "#{label}[#{index}]")
    end
  end
end

private def w114g_prior_arm_count(profile : W114GreenProfile, tag : UInt8, row_index : Int32) : Int32
  return 0 if tag == 255_u8
  (0...row_index).count { |index| profile.data.row(index).tag == tag }
end

private def w114g_assert_data(
  actual : CrystalClick::WideGeometryColumnData,
  profile : W114GreenProfile,
  fixture_start : Int32,
  owner_start : Int32,
  label : String,
) : Nil
  expected_count = actual.row_count
  w114g_require(fixture_start >= 0 && fixture_start + expected_count <= profile.data.row_count, "#{label}: expected fixture range is invalid")
  w114g_require(actual.type_name == "Geometry", "#{label}: actual owner lost exact Geometry identity")
  expected_count.times do |local_index|
    fixture_index = fixture_start + local_index
    got = actual.row(local_index)
    want = profile.data.row(fixture_index)
    w114g_require(got.type_name == "Geometry" && got.tag == want.tag, "#{label} row #{fixture_index}: global tag differs")
    w114g_require(got.null? == want.null? && got.arm == want.arm, "#{label} row #{fixture_index}: NULL/nominal arm differs")
    if tag = want.arm
      expected_rank = want.arm_index.not_nil! - w114g_prior_arm_count(profile, want.tag, owner_start)
      w114g_require(got.arm_index == expected_rank, "#{label} row #{fixture_index}: window-local sparse arm index differs")
      if tag == CrystalClick::WideGeometryArm::Point
        w114g_assert_point(got.point, want.point, "#{label} row #{fixture_index}")
      else
        w114g_assert_geo(got.geo_array, want.geo_array, "#{label} row #{fixture_index}")
      end
    else
      begin
        got.geo_array
        w114g_fail("#{label} row #{fixture_index}: NULL exposed a Geo Array")
      rescue ex : ArgumentError
        w114g_require(ex.message == "NULL Geometry row has no Geo Array value", "#{label} row #{fixture_index}: NULL accessor failed for an unrelated reason")
      end
    end
  end
end

private def w114g_write_u64(io : IO, value : UInt64) : Nil
  8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
end

private def w114g_write_varuint(io : IO, value : UInt64) : Nil
  remaining = value
  while remaining >= 0x80_u64
    io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
    remaining >>= 7
  end
  io.write_byte(remaining.to_u8)
end

private def w114g_write_point(io : IO, point : CrystalClick::WidePointValue) : Nil
  w114g_write_u64(io, point.x_bits)
  w114g_write_u64(io, point.y_bits)
end

private def w114g_write_geo(io : IO, row : CrystalClick::WideGeoArrayRow) : Nil
  w114g_write_varuint(io, row.size.to_u64)
  if row.terminal?
    row.size.times { |index| w114g_write_point(io, row.point_at(index)) }
  else
    row.size.times { |index| w114g_write_geo(io, row.array_at(index)) }
  end
end

private def w114g_rowbinary(profile : W114GreenProfile, indexes : Array(Int32)) : String
  String.build do |io|
    indexes.each do |index|
      w114g_write_u64(io, profile.keys[index])
      row = profile.data.row(index)
      if row.null?
        io.write_byte(255_u8)
      else
        io.write_byte(row.tag)
        if row.arm == CrystalClick::WideGeometryArm::Point
          w114g_write_point(io, row.point)
        else
          w114g_write_geo(io, row.geo_array)
        end
      end
    end
  end
end

private def w114g_selected_indexes(profile : W114GreenProfile) : Array(Int32)
  indexes = [] of Int32
  profile.keys.each_with_index do |key, index|
    indexes << index if key >= profile.selected_min && key < profile.selected_max
  end
  indexes
end

private def w114g_row_offset(mark_rows : Array(UInt64), mark_count : Int32) : Int32
  w114g_require(mark_count >= 0 && mark_count <= mark_rows.size, "selected Geometry mark count is out of range")
  rows = 0_u64
  mark_count.times do |index|
    next_rows = mark_rows[index]
    w114g_require(next_rows <= Int32::MAX.to_u64 - rows, "selected Geometry row offset exceeds Int32")
    rows += next_rows
  end
  rows.to_i32
end

private def w114g_query(binary : String, store : String, sql : String) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(binary, ["local", "--path", store, "--query", sql], output: output, error: error)
  w114g_require(status.success?, "ClickHouse query failed (#{sql}): #{error}")
  output.to_s
end

private def w114g_part_path(binary : String, store : String, table : String, expected_rows : Int32) : String
  rows = w114g_query(binary, store,
    "SELECT path, part_type, rows FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw"
  ).lines.map(&.strip).reject(&.empty?)
  w114g_require(rows.size == 1, "#{table}: expected one active part")
  fields = rows[0].split('\t')
  w114g_require(fields.size == 3 && fields[1] == "Wide" && fields[2] == expected_rows.to_s, "#{table}: active part is not the expected Wide row set")
  w114g_require(Dir.exists?(fields[0]), "#{table}: active part path is absent")
  fields[0]
end

private def w114g_check_and_rowbinary(
  binary : String,
  store : String,
  table : String,
  path : String,
  profile : W114GreenProfile,
  label : String,
) : Nil
  schema = w114g_query(binary, store,
    "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw"
  ).lines.map(&.strip)
  w114g_require(schema == ["pk UInt64", "payload Geometry"], "#{label}: actual table schema differs")
  check = w114g_query(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated")
  expected_check = "#{File.basename(path.chomp("/"))}\t1\t\n"
  w114g_require(check == expected_check, "#{label}: actual CHECK result is not the exact part-name/CHECK=1 row")

  indexes = (0...profile.keys.size).to_a
  expected_full = w114g_rowbinary(profile, indexes)
  actual_full = w114g_query(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  w114g_require(actual_full == expected_full, "#{label}: literal full RowBinary differs")
  selected = w114g_selected_indexes(profile)
  expected_selected = w114g_rowbinary(profile, selected)
  actual_selected = w114g_query(binary, store,
    "SELECT pk, payload FROM default.#{table} WHERE pk >= #{profile.selected_min} AND pk < #{profile.selected_max} ORDER BY pk FORMAT RowBinary"
  )
  w114g_require(actual_selected == expected_selected, "#{label}: literal selected RowBinary differs")
  puts "PASS #{label}: exact schema, actual CHECK=1, literal full/selected RowBinary (#{expected_full.bytesize}/#{expected_selected.bytesize} bytes)"
end

private def w114g_check_reader(path : String, profile : W114GreenProfile, label : String) : Nil
  reader = CrystalClick::WidePart.open_typed(path, "payload")
  w114g_require(reader.column_type == "Geometry", "#{label}: direct typed open lost exact Geometry identity")
  w114g_require(reader.mark_row_counts == profile.mark_rows, "#{label}: outer physical row grid differs")

  full_charge = reader.geometry_mark_range_materialization_charge("payload", 0, reader.mark_count)
  full = reader.read_geometry_mark_range("payload", 0, reader.mark_count, full_charge)
  w114g_require(full.row_count == profile.data.row_count, "#{label}: full direct read count differs")
  w114g_assert_data(full, profile, 0, 0, "#{label} full")

  first = profile.selected_first_mark
  count = profile.selected_mark_count
  selected_start = w114g_row_offset(profile.mark_rows, first)
  selected_count = w114g_row_offset(profile.mark_rows[first, count], count)
  selected_charge = reader.geometry_mark_range_materialization_charge("payload", first, count)
  selected = reader.read_geometry_mark_range("payload", first, count, selected_charge)
  w114g_require(selected.row_count == selected_count, "#{label}: selected direct read count differs")
  w114g_assert_data(selected, profile, selected_start, selected_start, "#{label} selected")

  observed_marks = [] of Int32
  next_row = selected_start
  reader.each_geometry_mark_range("payload", first, count) do |mark_data, mark_index|
    local = mark_index - first
    w114g_require(local >= 0 && local < count, "#{label}: streamed mark index is outside selected range")
    w114g_require(mark_data.row_count.to_u64 == profile.mark_rows[mark_index], "#{label}: streamed mark outer row count differs")
    w114g_assert_data(mark_data, profile, next_row, next_row, "#{label} mark #{mark_index}")
    observed_marks << mark_index
    next_row += mark_data.row_count
  end
  w114g_require(observed_marks == (first...(first + count)).to_a, "#{label}: selected mark callback sequence differs")
  w114g_require(next_row == selected_start + selected_count, "#{label}: selected streamed row total differs")
  puts "PASS #{label}: literal full/selected Geometry rows, sparse local ranks, nested topology and IEEE bits"
end

private def w114g_slice(values : Array(UInt64)) : Slice(UInt64)
  values.to_unsafe.to_slice(values.size)
end

private def w114g_attach_writer_part(binary : String, store : String, part : String, profile : W114GreenProfile, root : String) : String
  table = "w114_writer_only"
  settings = "index_granularity = 2, index_granularity_bytes = 10485760, enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, ratio_of_defaults_for_sparse_serialization = 0.9375, compress_marks = 0, compress_primary_key = 0, min_compress_block_size = 0, max_compress_block_size = 4096, default_compression_codec = 'LZ4', use_compact_variant_discriminators_serialization = 0"
  w114g_query(binary, store,
    "CREATE TABLE default.#{table} (pk UInt64, payload Geometry) ENGINE = MergeTree ORDER BY pk SETTINGS #{settings}"
  )
  data_path = w114g_query(binary, store,
    "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw"
  ).strip
  w114g_require(!data_path.empty? && Dir.exists?(data_path), "#{table}: fresh data path is absent")
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  target = File.join(detached, "all_1_1_0")
  w114g_require(!File.exists?(target), "#{table}: detached target already exists")
  FileUtils.cp_r(part, target)
  w114g_query(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  attached = w114g_part_path(binary, store, table, profile.data.row_count)
  w114g_check_and_rowbinary(binary, store, table, attached, profile, "W114 writer-only fresh ATTACH")
  w114g_check_reader(attached, profile, "W114 writer-only attached part")
  puts "W114 writer source retained at #{part}; fresh ATTACH at #{attached}; inspect under #{root}"
  attached
end

private def w114g_stock(binary : String, store : String) : Nil
  profiles = w114g_profiles
  w114g_require(CrystalClick::WidePart.supports_typed_type?("Geometry"), "exact Geometry typed admission remains closed")
  checked = 0
  profiles.each do |profile|
    {"source", "attached"}.each do |kind|
      table = "w114_#{kind}_#{profile.name}"
      path = w114g_part_path(binary, store, table, profile.data.row_count)
      w114g_check_and_rowbinary(binary, store, table, path, profile, "W114 stock #{profile.name} #{kind}")
      w114g_check_reader(path, profile, "W114 stock #{profile.name} #{kind}")
      checked += 1
    end
  end
  w114g_require(checked == 12, "W114 stock oracle did not cover six source and six fresh ATTACH profiles")
  puts "PASS W114 stock GREEN oracle: six literal profiles, source+fresh ATTACH=#{checked}"
end

private def w114g_writer(binary : String, store : String, root : String) : Nil
  profile = w114g_profiles.first
  source = File.join(root, "writer-part", "all_1_1_0")
  FileUtils.mkdir_p(File.dirname(source))
  w114g_require(!File.exists?(source), "W114 writer output path already exists")
  result = CrystalClick::WidePartWriter.write_uint64_geometry_pair(
    source,
    "pk",
    w114g_slice(profile.keys),
    "payload",
    profile.data,
    rows_per_mark: 2
  )
  w114g_require(result == source && Dir.exists?(source), "W114 Geometry writer did not publish the requested fresh part")
  w114g_check_reader(source, profile, "W114 independent writer part")
  w114g_attach_writer_part(binary, store, source, profile, root)
  nil
end

private def w114g_main : Nil
  binary = ENV["CLICKHOUSE_BIN"]? || raise "set CLICKHOUSE_BIN to the pinned ClickHouse executable"
  store = ENV["W114_STORE"]? || raise "set W114_STORE to the strict stock-qualification store"
  root = ENV["W114_GREEN_ROOT"]? || raise "set W114_GREEN_ROOT to the validated temporary parent"
  w114g_require(root.starts_with?("/private/tmp/"), "refusing non-temporary W114 GREEN root")
  w114g_require(Dir.exists?(root) && !File.symlink?(root), "W114 GREEN root must be an existing non-symlink directory")
  w114g_require(Dir.exists?(store) && !File.symlink?(store), "W114 stock store must be an existing non-symlink directory")
  w114g_stock(binary, store)
  w114g_writer(binary, store, root)
  puts "PASS W114 Geometry GREEN oracle: 12 stock source/ATTACH parts plus writer-only fresh ATTACH; full and nonzero-selected literal RowBinary; exact CHECK=1; all seven arms and NULL"
end

w114g_main

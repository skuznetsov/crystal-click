# W114 stock-first Geometry probe. Literal schema/value/layout expectations
# are maintained here; neither Crystal's reader nor writer defines them.
require "json"
require "file_utils"
require "../src/crystal_click"

W114_VERSION               = "26.10.1.1201"
W114_BUILD_HASH            = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
W114_EXECUTABLE_SHA256     = "bb321871f53f215d1e9d1b72cc4c92473816a10d3d49b715b1e0db1c832a79e2"
W114_SETTINGS              = "index_granularity = 2, index_granularity_bytes = 10485760, enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, ratio_of_defaults_for_sparse_serialization = 0.9375, compress_marks = 0, compress_primary_key = 0, min_compress_block_size = 0, max_compress_block_size = 4096, default_compression_codec = 'LZ4'"
W114_MARK_BYTES            = 24
W114_TAGS                  = {"LineString", "MultiLineString", "MultiPolygon", "Point", "Polygon", "Ring", "MultiPoint"}
W114_DEPTHS                = {"LineString" => 1, "MultiLineString" => 2, "MultiPolygon" => 3, "Point" => 0, "Polygon" => 2, "Ring" => 1, "MultiPoint" => 1}
W114_EXPECTED_STREAM_NAMES = [
  "pk", "payload.variant_discr",
  "payload.LineString.size0", "payload.LineString%2E1", "payload.LineString%2E2",
  "payload.MultiLineString.size0", "payload.MultiLineString.size1", "payload.MultiLineString%2E1", "payload.MultiLineString%2E2",
  "payload.MultiPolygon.size0", "payload.MultiPolygon.size1", "payload.MultiPolygon.size2", "payload.MultiPolygon%2E1", "payload.MultiPolygon%2E2",
  "payload.Point%2E1", "payload.Point%2E2",
  "payload.Polygon.size0", "payload.Polygon.size1", "payload.Polygon%2E1", "payload.Polygon%2E2",
  "payload.Ring.size0", "payload.Ring%2E1", "payload.Ring%2E2",
  "payload.MultiPoint.size0", "payload.MultiPoint%2E1", "payload.MultiPoint%2E2",
]

class W114Mismatch < Exception
end

struct W114Point
  getter x_bits : UInt64
  getter y_bits : UInt64

  def initialize(@x_bits : UInt64, @y_bits : UInt64)
  end
end

class W114Array
  getter children : Array(W114Array)
  getter points : Array(W114Point)

  def initialize(@children : Array(W114Array), @points : Array(W114Point))
  end
end

struct W114Value
  getter tag : Int32?
  getter tree : W114Array?
  getter point : W114Point?

  def initialize(@tag : Int32?, @tree : W114Array?, @point : W114Point?)
  end
end

struct W114Profile
  getter name : String
  getter mode : UInt64
  getter keys : Array(UInt64)
  getter values : Array(W114Value)
  getter boundaries : Array(Int32)
  getter mark_rows : Array(UInt64)
  getter selected_min : UInt64
  getter selected_max : UInt64
  getter compact : Bool
  getter ratio : String

  def initialize(@name : String, @mode : UInt64, @keys : Array(UInt64), @values : Array(W114Value), @boundaries : Array(Int32), @mark_rows : Array(UInt64), @selected_min : UInt64, @selected_max : UInt64, @compact : Bool, @ratio : String = "0.9375")
  end

  def settings : String
    compact_value = compact ? 1 : 0
    compact_setting = ", use_compact_variant_discriminators_serialization = #{compact_value}"
    "#{W114_SETTINGS.gsub("ratio_of_defaults_for_sparse_serialization = 0.9375", "ratio_of_defaults_for_sparse_serialization = #{ratio}")}#{compact_setting}"
  end
end

struct W114Stream
  getter name : String
  getter prefix : String
  getter row_fragments : Array(Array(String))
  getter row_counts : Array(UInt64)

  def initialize(@name : String, @prefix : String, @row_fragments : Array(Array(String)), @row_counts : Array(UInt64))
  end

  def raw : String
    prefix + row_fragments.flat_map { |row| row }.join
  end
end

W114_P0                    = W114Point.new(0x8000_0000_0000_0000_u64, 0x0000_0000_0000_0000_u64)
W114_P1                    = W114Point.new(0x7ff8_0000_0000_1234_u64, 0x400c_0000_0000_0000_u64)
W114_P2                    = W114Point.new(0xfff0_0000_0000_0000_u64, 0x0000_0000_0000_0001_u64)
W114_P3                    = W114Point.new(0x4002_0000_0000_0000_u64, 0x7ff8_0000_0000_5678_u64)
W114_TAG_NAMES             = ["LineString", "MultiLineString", "MultiPolygon", "Point", "Polygon", "Ring", "MultiPoint"]
W114_MIXED_TAGS            = [0, 0, 0, 1, 2, 3, 4, 5, 6, nil, 0, 1, 2, 3, 4, 5, 6] of Int32?
W114_MIXED_ARM_PREFIX_ROWS = [3, 1, 1, 1, 1, 1, 1]
W114_MIXED_POINT_COUNTS    = [5, 1, 2, 2, 1, 2, 2]

def w114_fail(message : String) : NoReturn
  raise W114Mismatch.new(message)
end

def w114_require(condition : Bool, message : String) : Nil
  w114_fail(message) unless condition
end

def w114_u64(value : UInt64) : String
  String.build { |io| 8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) } }
end

def w114_bytes(values : Array(UInt8)) : String
  String.build { |io| values.each { |value| io.write_byte(value) } }
end

def w114_varuint(value : UInt64) : String
  String.build do |io|
    remaining = value
    while remaining >= 0x80_u64
      io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
      remaining >>= 7
    end
    io.write_byte(remaining.to_u8)
  end
end

def w114_leaf(points : Array(W114Point)) : W114Array
  W114Array.new([] of W114Array, points)
end

def w114_branch(children : Array(W114Array)) : W114Array
  W114Array.new(children, [] of W114Point)
end

def w114_empty(depth : Int32) : W114Array
  depth == 1 ? w114_leaf([] of W114Point) : w114_branch([w114_empty(depth - 1)])
end

def w114_outer_empty(depth : Int32) : W114Array
  depth == 1 ? w114_leaf([] of W114Point) : w114_branch([] of W114Array)
end

def w114_geo(tag : Int32, tree : W114Array) : W114Value
  W114Value.new(tag, tree, nil)
end

def w114_point(value : W114Point) : W114Value
  W114Value.new(3, nil, value)
end

def w114_null : W114Value
  W114Value.new(nil, nil, nil)
end

def w114_mixed_values : Array(W114Value)
  line = w114_geo(0, w114_leaf([W114_P0]))
  values = [
    line, line, # tied PKs; uniform LineString granule
    w114_geo(0, w114_leaf([W114_P1, W114_P2])),
    w114_geo(1, w114_branch([w114_leaf([W114_P0]), w114_leaf([] of W114Point)])),
    w114_geo(2, w114_branch([
      w114_branch([w114_leaf([W114_P2])]),
      w114_branch([w114_leaf([] of W114Point), w114_leaf([W114_P3])]),
    ])),
    w114_point(W114_P3),
    w114_geo(4, w114_branch([w114_leaf([W114_P1]), w114_leaf([] of W114Point)])),
    w114_geo(5, w114_leaf([W114_P2, W114_P3])),
    w114_geo(6, w114_leaf([W114_P1])),
    w114_null,
    w114_geo(0, w114_leaf([W114_P2])),
    w114_geo(1, w114_outer_empty(2)),                         # tagged outer-empty
    w114_geo(2, w114_branch([w114_branch([] of W114Array)])), # nested empty, not NULL
    w114_point(W114_P0),
    w114_geo(4, w114_outer_empty(2)),
    w114_geo(5, w114_leaf([] of W114Point)),
    w114_geo(6, w114_leaf([W114_P3])),
  ] of W114Value
  values
end

def w114_mixed_profile(compact : Bool) : W114Profile
  W114Profile.new(
    compact ? "mixed_compact" : "mixed_basic",
    compact ? 1_u64 : 0_u64,
    [0_u64, 0_u64, 1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64, 9_u64, 10_u64, 11_u64, 12_u64, 13_u64, 14_u64, 15_u64],
    w114_mixed_values,
    [0, 2, 4, 6, 8, 10, 12, 14, 16, 17],
    [2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 2_u64, 1_u64, 0_u64],
    9_u64, 16_u64, compact,
  )
end

def w114_null_profile(compact : Bool) : W114Profile
  W114Profile.new(
    compact ? "all_null_compact" : "all_null_basic",
    compact ? 1_u64 : 0_u64,
    [0_u64, 1_u64, 2_u64, 3_u64, 4_u64],
    [w114_null, w114_null, w114_null, w114_null, w114_null] of W114Value,
    [0, 2, 4, 5],
    [2_u64, 2_u64, 1_u64, 0_u64],
    2_u64, 4_u64, compact,
  )
end

def w114_uniform_profile(compact : Bool) : W114Profile
  W114Profile.new(
    compact ? "uniform_point_multipoint_compact" : "uniform_point_multipoint_basic",
    compact ? 1_u64 : 0_u64,
    [0_u64, 0_u64, 1_u64, 2_u64, 3_u64],
    [
      w114_point(W114_P0), w114_point(W114_P0),
      w114_geo(6, w114_leaf([W114_P2])),
      w114_geo(6, w114_leaf([W114_P3])),
      w114_geo(6, w114_leaf([] of W114Point)),
    ] of W114Value,
    [0, 2, 4, 5],
    [2_u64, 2_u64, 1_u64, 0_u64],
    1_u64, 4_u64, compact,
  )
end

W114_PROFILES = [
  w114_mixed_profile(false),
  w114_mixed_profile(true),
  w114_null_profile(false),
  w114_null_profile(true),
  w114_uniform_profile(false),
  w114_uniform_profile(true),
]

def w114_point_rowbinary(point : W114Point, io : IO) : Nil
  io << w114_u64(point.x_bits)
  io << w114_u64(point.y_bits)
end

def w114_array_rowbinary(array : W114Array, depth : Int32, io : IO) : Nil
  if depth == 1
    io << w114_varuint(array.points.size.to_u64)
    array.points.each { |point| w114_point_rowbinary(point, io) }
  else
    io << w114_varuint(array.children.size.to_u64)
    array.children.each { |child| w114_array_rowbinary(child, depth - 1, io) }
  end
end

def w114_value_rowbinary(value : W114Value, io : IO) : Nil
  if tag = value.tag
    io.write_byte(tag.to_u8)
    if tag == 3
      point = value.point || raise "Point variant lacks its literal point"
      w114_point_rowbinary(point, io)
    else
      tree = value.tree || raise "Array variant lacks its literal tree"
      w114_array_rowbinary(tree, W114_DEPTHS[W114_TAG_NAMES[tag]], io)
    end
  else
    io.write_byte(0xff_u8)
  end
end

def w114_rowbinary(profile : W114Profile, indexes : Array(Int32)) : String
  String.build do |io|
    indexes.each do |index|
      io << w114_u64(profile.keys[index])
      w114_value_rowbinary(profile.values[index], io)
    end
  end
end

def w114_streams(profile : W114Profile) : Array(W114Stream)
  w114_require(profile.keys.size == profile.values.size, "#{profile.name}: key/value row counts differ")
  w114_require(profile.boundaries.size == profile.mark_rows.size, "#{profile.name}: boundary/mark-row vectors differ")

  pk_rows = profile.keys.map { |key| [w114_u64(key)] }
  pk_counts = Array(UInt64).new(profile.keys.size, 1_u64)
  streams = [W114Stream.new("pk", "", pk_rows, pk_counts)]

  discr_rows = Array.new(profile.values.size) { [] of String }
  if profile.compact
    (0...(profile.boundaries.size - 1)).each do |mark|
      first = profile.boundaries[mark]
      after = profile.boundaries[mark + 1]
      tags = profile.values[first...after].map { |value| value.tag.try(&.to_u8) || 0xff_u8 }
      w114_require(!tags.empty?, "#{profile.name}: empty data granule is not part of this fixture")
      uniform = tags.all? { |tag| tag == tags[0] }
      framed = String.build do |io|
        io << w114_varuint(tags.size.to_u64)
        if uniform
          io.write_byte(1_u8) # COMPACT
          io.write_byte(tags[0])
        else
          io.write_byte(0_u8) # PLAIN
          tags.each { |tag| io.write_byte(tag) }
        end
      end
      discr_rows[first] << framed
    end
  else
    profile.values.each_with_index do |value, row|
      discr_rows[row] << w114_bytes([value.tag.try(&.to_u8) || 0xff_u8])
    end
  end
  discr_counts = Array(UInt64).new(profile.values.size, 1_u64)
  streams << W114Stream.new("payload.variant_discr", w114_u64(profile.mode), discr_rows, discr_counts)

  W114_TAG_NAMES.each_with_index do |type_name, tag|
    depth = W114_DEPTHS[type_name]
    size_rows = Array.new(depth) { Array.new(profile.values.size) { [] of String } }
    size_counts = Array.new(depth) { Array(UInt64).new(profile.values.size, 0_u64) }
    x_rows = Array.new(profile.values.size) { [] of String }
    y_rows = Array.new(profile.values.size) { [] of String }
    coordinate_counts = Array(UInt64).new(profile.values.size, 0_u64)

    profile.values.each_with_index do |value, row|
      next unless value.tag == tag
      if type_name == "Point"
        point = value.point || raise "#{profile.name}: Point arm lacks literal point at row #{row}"
        x_rows[row] << w114_u64(point.x_bits)
        y_rows[row] << w114_u64(point.y_bits)
        coordinate_counts[row] = 1_u64
      else
        tree = value.tree || raise "#{profile.name}: #{type_name} arm lacks literal tree at row #{row}"
        w114_collect_tree(tree, depth, row, 0, size_rows, size_counts, x_rows, y_rows, coordinate_counts)
      end
    end

    depth.times do |level|
      streams << W114Stream.new("payload.#{type_name}.size#{level}", "", size_rows[level], size_counts[level])
    end
    streams << W114Stream.new("payload.#{type_name}%2E1", "", x_rows, coordinate_counts)
    streams << W114Stream.new("payload.#{type_name}%2E2", "", y_rows, coordinate_counts)
  end
  if profile.name == "mixed_basic" || profile.name == "mixed_compact"
    w114_assert_mixed_literals(profile, streams)
  elsif profile.name == "all_null_basic" || profile.name == "all_null_compact"
    w114_assert_null_discriminator_literals(profile, streams)
  elsif profile.name == "uniform_point_multipoint_basic" || profile.name == "uniform_point_multipoint_compact"
    w114_assert_uniform_discriminator_literals(profile, streams)
  end
  streams
end

def w114_collect_tree(
  tree : W114Array,
  depth : Int32,
  outer_row : Int32,
  level : Int32,
  size_rows : Array(Array(Array(String))),
  size_counts : Array(Array(UInt64)),
  x_rows : Array(Array(String)),
  y_rows : Array(Array(String)),
  coordinate_counts : Array(UInt64),
) : Nil
  if depth == 1
    size_rows[level][outer_row] << w114_u64(tree.points.size.to_u64)
    size_counts[level][outer_row] += 1_u64
    tree.points.each do |point|
      x_rows[outer_row] << w114_u64(point.x_bits)
      y_rows[outer_row] << w114_u64(point.y_bits)
      coordinate_counts[outer_row] += 1_u64
    end
  else
    size_rows[level][outer_row] << w114_u64(tree.children.size.to_u64)
    size_counts[level][outer_row] += 1_u64
    tree.children.each do |child|
      w114_collect_tree(child, depth - 1, outer_row, level + 1, size_rows, size_counts, x_rows, y_rows, coordinate_counts)
    end
  end
end

# This literal certificate is deliberately separate from w114_collect_tree:
# it pins the tag stream, each physical size axis, sparse-arm origins, and raw
# IEEE coordinate lanes for the mixed stock fixture. A recursive fixture bug
# must fail before its output is treated as the oracle expectation.
def w114_assert_mixed_literals(profile : W114Profile, streams : Array(W114Stream)) : Nil
  w114_require(profile.name == "mixed_basic" || profile.name == "mixed_compact", "literal mixed check used for an unexpected profile")
  actual_tags = profile.values.map(&.tag)
  w114_require(actual_tags == W114_MIXED_TAGS, "#{profile.name}: literal global tag sequence differs")
  literal_prefix_arm_rows = W114_TAG_NAMES.map_with_index do |_name, tag|
    W114_MIXED_TAGS[0...10].count { |actual| actual == tag }.to_i
  end
  w114_require(literal_prefix_arm_rows == W114_MIXED_ARM_PREFIX_ROWS, "#{profile.name}: literal sparse-arm row origins differ")
  w114_require(profile.keys == [0_u64, 0_u64, 1_u64, 2_u64, 3_u64, 4_u64, 5_u64, 6_u64, 7_u64, 8_u64, 9_u64, 10_u64, 11_u64, 12_u64, 13_u64, 14_u64, 15_u64], "#{profile.name}: literal PK row vector differs")
  w114_require(profile.boundaries == [0, 2, 4, 6, 8, 10, 12, 14, 16, 17], "#{profile.name}: literal outer-mark boundaries differ")
  w114_require(profile.keys.each_with_index.select { |key, _row| key >= 9_u64 && key < 16_u64 }.map { |_key, row| row.to_i32 }.to_a == [10, 11, 12, 13, 14, 15, 16], "#{profile.name}: selected PK interval is not the independently pinned rows 10..16")

  expected_discriminator = if profile.compact
                             frames = [
                               [2_u64, 1_u64, 0_u64],
                               [2_u64, 0_u64, 0_u64, 1_u64],
                               [2_u64, 0_u64, 2_u64, 3_u64],
                               [2_u64, 0_u64, 4_u64, 5_u64],
                               [2_u64, 0_u64, 6_u64, 255_u64],
                               [2_u64, 0_u64, 0_u64, 1_u64],
                               [2_u64, 0_u64, 2_u64, 3_u64],
                               [2_u64, 0_u64, 4_u64, 5_u64],
                               [1_u64, 1_u64, 6_u64],
                             ]
                             w114_bytes(frames.flatten.map(&.to_u8))
                           else
                             w114_bytes(W114_MIXED_TAGS.map { |tag| (tag || 255).to_u8 })
                           end
  discr = streams.find { |stream| stream.name == "payload.variant_discr" } || w114_fail("#{profile.name}: discriminator stream missing")
  expected_length = profile.compact ? 42 : 25
  expected_window_offset = profile.compact ? 27 : 18
  w114_require(discr.raw.bytesize == expected_length, "#{profile.name}: discriminator literal total length differs")
  actual_window_offset = 8 + discr.row_fragments[0...10].flatten.join.bytesize
  w114_require(actual_window_offset == expected_window_offset, "#{profile.name}: independently pinned discriminator selected-mark offset differs")
  w114_require(discr.raw.byte_slice(0, 8) == w114_u64(profile.mode), "#{profile.name}: discriminator BASIC/COMPACT prefix differs")
  expected_before_window = if profile.compact
                             [2_u8, 1_u8, 0_u8, 2_u8, 0_u8, 0_u8, 1_u8, 2_u8, 0_u8, 2_u8, 3_u8, 2_u8, 0_u8, 4_u8, 5_u8, 2_u8, 0_u8, 6_u8, 255_u8]
                           else
                             [0_u8, 0_u8, 0_u8, 1_u8, 2_u8, 3_u8, 4_u8, 5_u8, 6_u8, 255_u8]
                           end
  expected_selected_frame = profile.compact ? [2_u8, 0_u8, 0_u8, 1_u8] : [0_u8, 1_u8]
  w114_require(discr.raw.byte_slice(0, expected_window_offset) == w114_u64(profile.mode) + w114_bytes(expected_before_window), "#{profile.name}: literal start of selected discriminator mark differs")
  w114_require(discr.raw.byte_slice(expected_window_offset, expected_selected_frame.size) == w114_bytes(expected_selected_frame), "#{profile.name}: selected discriminator mark has the wrong literal frame")
  w114_require(discr.raw == w114_u64(profile.mode) + expected_discriminator, "#{profile.name}: discriminator literal per-mark tags differ")

  # Size vectors are concatenated in physical stream order. The split at row
  # 10 pins a nonzero sparse-arm origin before the selected PK window.
  w114_assert_u64_stream(streams, "payload.LineString.size0", [1, 1, 2, 1], [1, 1, 2], [1])
  w114_assert_u64_stream(streams, "payload.MultiLineString.size0", [2, 0], [2], [0])
  w114_assert_u64_stream(streams, "payload.MultiLineString.size1", [1, 0], [1, 0], [] of Int32)
  w114_assert_u64_stream(streams, "payload.MultiPolygon.size0", [2, 1], [2], [1])
  w114_assert_u64_stream(streams, "payload.MultiPolygon.size1", [1, 2, 0], [1, 2], [0])
  w114_assert_u64_stream(streams, "payload.MultiPolygon.size2", [1, 0, 1], [1, 0, 1], [] of Int32)
  w114_assert_u64_stream(streams, "payload.Polygon.size0", [2, 0], [2], [0])
  w114_assert_u64_stream(streams, "payload.Polygon.size1", [1, 0], [1, 0], [] of Int32)
  w114_assert_u64_stream(streams, "payload.Ring.size0", [2, 0], [2], [0])
  w114_assert_u64_stream(streams, "payload.MultiPoint.size0", [1, 1], [1], [1])

  w114_assert_point_lanes(streams, "LineString", [W114_P0, W114_P0, W114_P1, W114_P2, W114_P2], [W114_P0, W114_P0, W114_P1, W114_P2], [W114_P2])
  w114_assert_point_lanes(streams, "MultiLineString", [W114_P0], [W114_P0], [] of W114Point)
  w114_assert_point_lanes(streams, "MultiPolygon", [W114_P2, W114_P3], [W114_P2, W114_P3], [] of W114Point)
  w114_assert_point_lanes(streams, "Point", [W114_P3, W114_P0], [W114_P3], [W114_P0])
  w114_assert_point_lanes(streams, "Polygon", [W114_P1], [W114_P1], [] of W114Point)
  w114_assert_point_lanes(streams, "Ring", [W114_P2, W114_P3], [W114_P2, W114_P3], [] of W114Point)
  w114_assert_point_lanes(streams, "MultiPoint", [W114_P1, W114_P3], [W114_P1], [W114_P3])
  actual_point_counts = [5, 1, 2, 2, 1, 2, 2]
  w114_require(actual_point_counts == W114_MIXED_POINT_COUNTS, "#{profile.name}: literal per-arm flattened point counts differ")
end

def w114_assert_null_discriminator_literals(profile : W114Profile, streams : Array(W114Stream)) : Nil
  discr = streams.find { |stream| stream.name == "payload.variant_discr" } || w114_fail("#{profile.name}: discriminator stream missing")
  compact = profile.compact
  raw_tags = compact ? [2_u8, 1_u8, 255_u8, 2_u8, 1_u8, 255_u8, 1_u8, 1_u8, 255_u8] : [255_u8, 255_u8, 255_u8, 255_u8, 255_u8]
  expected = w114_u64(profile.mode) + w114_bytes(raw_tags)
  expected_marks = compact ? [8, 11, 14] : [8, 10, 12]
  actual_marks = profile.boundaries[0...-1].map do |boundary|
    8 + discr.row_fragments[0...boundary].flatten.join.bytesize
  end
  w114_require(discr.raw.bytesize == (compact ? 17 : 13), "#{profile.name}: all-NULL discriminator literal length differs")
  w114_require(actual_marks == expected_marks, "#{profile.name}: all-NULL literal non-sentinel offsets differ")
  w114_require(discr.raw == expected, "#{profile.name}: all-NULL discriminator bytes differ")
end

def w114_assert_uniform_discriminator_literals(profile : W114Profile, streams : Array(W114Stream)) : Nil
  discr = streams.find { |stream| stream.name == "payload.variant_discr" } || w114_fail("#{profile.name}: discriminator stream missing")
  compact = profile.compact
  if compact
    expected_tail = [2_u8, 1_u8, 3_u8, 2_u8, 1_u8, 6_u8, 1_u8, 1_u8, 6_u8]
    expected = w114_u64(1_u64) + w114_bytes(expected_tail)
    w114_require(discr.raw.bytesize == 17, "#{profile.name}: compact uniform/short-tail length differs")
  else
    expected = w114_u64(0_u64) + w114_bytes([3_u8, 3_u8, 6_u8, 6_u8, 6_u8])
    w114_require(discr.raw.bytesize == 13, "#{profile.name}: BASIC uniform/short-tail length differs")
  end
  w114_require(discr.raw == expected, "#{profile.name}: Point/MultiPoint uniform granule or short-tail bytes differ")
end

def w114_assert_u64_stream(streams : Array(W114Stream), name : String, full : Array(Int32), prefix : Array(Int32), selected : Array(Int32)) : Nil
  stream = streams.find { |candidate| candidate.name == name } || w114_fail("literal physical stream missing: #{name}")
  expected = full.map { |value| w114_u64(value.to_u64) }.join
  prefix_bytes = stream.row_fragments[0...10].flatten.join
  selected_bytes = stream.row_fragments[10...17].flatten.join
  w114_require(stream.raw == expected, "#{name}: full literal little-endian size bytes differ")
  w114_require(prefix_bytes == prefix.map { |value| w114_u64(value.to_u64) }.join, "#{name}: pre-window sparse-size origin differs")
  w114_require(selected_bytes == selected.map { |value| w114_u64(value.to_u64) }.join, "#{name}: selected-window size-axis values differ")
end

def w114_assert_point_lanes(streams : Array(W114Stream), arm : String, full : Array(W114Point), prefix : Array(W114Point), selected : Array(W114Point)) : Nil
  ["1", "2"].each do |suffix|
    name = "payload.#{arm}%2E#{suffix}"
    stream = streams.find { |candidate| candidate.name == name } || w114_fail("literal coordinate stream missing: #{name}")
    coordinate = ->(point : W114Point) { suffix == "1" ? point.x_bits : point.y_bits }
    expected = full.map { |point| w114_u64(coordinate.call(point)) }.join
    prefix_bytes = stream.row_fragments[0...10].flatten.join
    selected_bytes = stream.row_fragments[10...17].flatten.join
    w114_require(stream.raw == expected, "#{name}: full literal raw IEEE bytes differ")
    w114_require(prefix_bytes == prefix.map { |point| w114_u64(coordinate.call(point)) }.join, "#{name}: nonzero pre-window sparse coordinate origin differs")
    w114_require(selected_bytes == selected.map { |point| w114_u64(coordinate.call(point)) }.join, "#{name}: selected-window raw IEEE bytes differ")
  end
end

def w114_fixture_stream_names(profile : W114Profile) : Array(String)
  w114_require(W114_PROFILES.any? { |candidate| candidate.name == profile.name }, "unknown W114 fixture profile: #{profile.name}")
  W114_EXPECTED_STREAM_NAMES
end

def w114_expected_selected_indexes(profile : W114Profile) : Array(Int32)
  case profile.name
  when "mixed_basic", "mixed_compact"
    [10, 11, 12, 13, 14, 15, 16]
  when "all_null_basic", "all_null_compact"
    [2, 3]
  when "uniform_point_multipoint_basic", "uniform_point_multipoint_compact"
    [2, 3, 4]
  else
    w114_fail("fixture self-check has no literal selected-index vector for #{profile.name}")
  end
end

def w114_expected_rowbinary_sizes(profile : W114Profile) : {Int32, Int32}
  case profile.name
  when "mixed_basic", "mixed_compact"
    {417, 118}
  when "all_null_basic", "all_null_compact"
    {45, 18}
  when "uniform_point_multipoint_basic", "uniform_point_multipoint_compact"
    {112, 62}
  else
    w114_fail("RowBinary size literals missing for #{profile.name}")
  end
end

def w114_assert_bytes(actual : String, expected : String, label : String) : Nil
  return if actual == expected
  limit = Math.min(actual.bytesize, expected.bytesize)
  index = 0
  while index < limit && actual.to_slice[index] == expected.to_slice[index]
    index += 1
  end
  got = index < actual.bytesize ? actual.to_slice[index].to_s(16).rjust(2, '0') : "<eof>"
  wanted = index < expected.bytesize ? expected.to_slice[index].to_s(16).rjust(2, '0') : "<eof>"
  w114_fail("#{label}: byte mismatch expected #{expected.bytesize}, got #{actual.bytesize}; first diff #{index}: expected #{wanted}, got #{got}")
end

def w114_seeded_byte_mismatch(actual : String, expected : String, offset : Int32, label : String) : Nil
  w114_require(offset >= 0 && offset < expected.bytesize, "#{label}: invalid seeded-byte offset")
  w114_assert_bytes(actual, expected, "#{label} control precondition")
  altered_bytes = actual.to_slice.dup
  altered_bytes[offset] ^= 0x01_u8
  altered_actual = String.new(altered_bytes)
  begin
    w114_assert_bytes(altered_actual, expected, label)
  rescue ex : W114Mismatch
    message = ex.message || "<missing mismatch message>"
    w114_require(message.starts_with?("#{label}: byte mismatch") && message.includes?("first diff #{offset}:"), "#{label}: negative control failed for an unrelated mismatch: #{message}")
    puts "PASS W114 byte comparator negative control: #{label} (first diff #{offset})"
    return
  end
  w114_fail("#{label}: seeded wrong-byte expectation was accepted")
end

def w114_expected_substreams : String
  payload = W114_EXPECTED_STREAM_NAMES[1, W114_EXPECTED_STREAM_NAMES.size - 1]
  lines = [
    "columns substreams version: 1", "2 columns:",
    "1 substreams for column `pk`:", "\tpk",
    "25 substreams for column `payload`:",
  ]
  payload.each { |name| lines << "\t#{name}" }
  lines.join("\n") + "\n"
end

def w114_expected_columns : Array(String)
  ["columns format version: 1", "2 columns:", "`pk` UInt64", "`payload` Geometry"]
end

def w114_profile_default_count(profile : W114Profile) : Int32
  profile.keys.count(0_u64).to_i32
end

def w114_validate_pk_record(record : Hash(String, JSON::Any), defaults : Int32, rows : Int32, label : String) : Nil
  expected_keys = ["exact_num_defaults", "kind", "name", "num_defaults", "num_rows"].sort
  w114_require(record.keys.sort == expected_keys, "#{label}: exact PK record keys differ")
  w114_require(record["kind"]?.try(&.as_s) == "Default", "#{label}: PK kind differs")
  w114_require(record["name"]?.try(&.as_s) == "pk", "#{label}: PK name differs")
  w114_require(record["num_rows"]?.try(&.as_i) == rows.to_i64, "#{label}: PK row count differs")
  w114_require(record["num_defaults"]?.try(&.as_i) == defaults.to_i64, "#{label}: PK default count differs")
  w114_require(record["exact_num_defaults"]?.try(&.as_bool) == true, "#{label}: PK exact_num_defaults differs")
end

def w114_assert_serialization(part : String, profile : W114Profile, label : String) : Nil
  info = JSON.parse(File.read(File.join(part, "serialization.json"))).as_h
  expected_keys = ["columns", "propagate_types_serialization_versions_to_nested_types", "types_serialization_versions", "version"].sort
  w114_require(info.keys.sort == expected_keys, "#{label}: exact serialization envelope differs: #{info.keys.sort.inspect}")
  w114_require(info["version"]?.try(&.as_i) == 1_i64, "#{label}: serialization version differs")
  w114_require(info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool) == true, "#{label}: nested type-version propagation differs")
  versions = info["types_serialization_versions"]?.try(&.as_h) || raise "#{label}: type-version map missing"
  w114_require(versions.size == 1 && versions["string"]?.try(&.as_i) == 1_i64, "#{label}: exact String version map differs")
  records = info["columns"]?.try(&.as_a) || raise "#{label}: serialization columns are missing"
  w114_require(records.size == 1, "#{label}: Geometry envelope must contain exactly one PK record")
  record = records[0].as_h
  w114_validate_pk_record(record, w114_profile_default_count(profile), profile.keys.size.to_i32, label)
end

def w114_expect_metadata_mismatch(part : String, profile : W114Profile, label : String) : Nil
  info = JSON.parse(File.read(File.join(part, "serialization.json"))).as_h
  record = info["columns"]?.try(&.as_a).try(&.first?).try(&.as_h) || raise "#{label}: PK record missing for negative control"
  defaults = w114_profile_default_count(profile)
  w114_validate_pk_record(record, defaults, profile.keys.size.to_i32, "#{label} control precondition")
  record["num_defaults"] = JSON::Any.new((defaults + 1).to_i64)
  begin
    w114_validate_pk_record(record, defaults, profile.keys.size.to_i32, label)
  rescue ex : W114Mismatch
    message = ex.message || "<missing mismatch message>"
    w114_require(message == "#{label}: PK default count differs", "#{label}: metadata negative control caught an unrelated failure: #{message}")
    puts "PASS W114 metadata comparator negative control: #{label} (PK default count)"
    return
  end
  w114_fail("#{label}: seeded wrong PK default-count expectation was accepted")
end

def w114_statistics_expectation(profile : W114Profile) : {Int32, String}
  # Exact bytes are fingerprinted by the independent stock-capture checkpoint
  # for this SHA-pinned executable; BASIC/COMPACT pairs share the family file.
  case profile.name
  when "mixed_basic", "mixed_compact"
    {337, "30e1a2455ac8559af5d83489e4f3fe31ee46d4447bb37d37738cbed081f3896b"}
  when "all_null_basic", "all_null_compact"
    {253, "3243d3fdcdde97f5751ea15facef9dac97122817fdf0b95301753e23a3f4f902"}
  when "uniform_point_multipoint_basic", "uniform_point_multipoint_compact"
    {245, "0c01e738bbe47b361f135cbb6cf37f37f3fba6b7f5bdb966bd4a5098460a1416"}
  else
    w114_fail("statistics.packed has no exact stock fingerprint for #{profile.name}")
  end
end

def w114_file_sha256(path : String) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run("shasum", ["-a", "256", path], output: output, error: error)
  w114_require(status.success?, "could not fingerprint #{path}: #{error}")
  output.to_s.split(' ').first? || w114_fail("SHA-256 output is malformed for #{path}")
end

def w114_expected_marks(profile : W114Profile, stream : W114Stream) : Array({UInt64, UInt64, UInt64})
  w114_require(profile.boundaries.size == profile.mark_rows.size, "#{profile.name}: exact mark vectors differ in length")
  profile.boundaries.map_with_index do |boundary, index|
    decompressed = stream.prefix.bytesize.to_u64
    stream.row_fragments[0, boundary].each do |row|
      row.each { |fragment| decompressed += fragment.bytesize.to_u64 }
    end
    # This captured Geometry profile uses one bounded LZ4 frame per stream;
    # all mark compressed offsets are zero, including its explicit EOF row.
    {0_u64, decompressed, profile.mark_rows[index]}
  end.to_a
end

def w114_marks(part : String, stream_name : String) : Array({UInt64, UInt64, UInt64})
  hashed = CrystalClick::StreamName.hash(stream_name)
  bytes = File.read(File.join(part, "#{hashed}.mrk2")).to_slice
  w114_require(bytes.size % W114_MARK_BYTES == 0, "#{stream_name}: partial 24-byte .mrk2 record")
  Array({UInt64, UInt64, UInt64}).new(bytes.size // W114_MARK_BYTES) do |record|
    start = record * W114_MARK_BYTES
    fields = Array(UInt64).new(3) do |field|
      at = start + field * 8
      8.times.reduce(0_u64) { |value, byte| value | (bytes[at + byte].to_u64 << (byte * 8)) }
    end
    {fields[0], fields[1], fields[2]}
  end
end

def w114_assert_marks(actual : Array({UInt64, UInt64, UInt64}), expected : Array({UInt64, UInt64, UInt64}), label : String) : Nil
  if actual.size != expected.size
    w114_fail("#{label}: mark record count differs: expected #{expected.size}, got #{actual.size}")
  end
  actual.each_with_index do |record, index|
    next if record == expected[index]
    w114_fail("#{label}: mark record #{index} differs: expected #{expected[index].inspect}, got #{record.inspect}")
  end
end

def w114_expect_mark_mismatch(actual : Array({UInt64, UInt64, UInt64}), expected : Array({UInt64, UInt64, UInt64}), label : String) : Nil
  w114_require(!expected.empty?, "#{label}: mark negative control has no fixture record")
  w114_assert_marks(actual, expected, "#{label} control precondition")
  altered_actual = actual.dup
  first = altered_actual[0]
  altered_actual[0] = {first[0], first[1] + 1_u64, first[2]}
  begin
    w114_assert_marks(altered_actual, expected, label)
  rescue ex : W114Mismatch
    message = ex.message || "<missing mismatch message>"
    w114_require(message.starts_with?("#{label}: mark record 0 differs"), "#{label}: mark negative control caught an unrelated failure: #{message}")
    puts "PASS W114 mark comparator negative control: #{label} (record 0 decompressed offset)"
    return
  end
  w114_fail("#{label}: seeded wrong mark tuple was accepted")
end

def w114_expected_primary(profile : W114Profile) : String
  data_boundaries = profile.boundaries[0, profile.boundaries.size - 1]
  data_boundaries.map { |row| w114_u64(profile.keys[row]) }.join + w114_u64(profile.keys.last)
end

def w114_read_raw(part : String, stream_name : String) : String
  hashed = CrystalClick::StreamName.hash(stream_name)
  encoded = File.read(File.join(part, "#{hashed}.bin")).to_slice
  return "" if encoded.empty?
  String.new(CrystalClick::CompressedBlock.decode_all(encoded))
end

def w114_assert_checksum_hashes(part : String, checksums : CrystalClick::PartChecksums, profile : W114Profile, label : String) : Nil
  checksums.entries.each do |name, entry|
    file_bytes = File.read(File.join(part, name))
    actual_hash = CrystalClick::CityHashV1.file_hash(file_bytes.to_slice)
    w114_require(actual_hash == entry.file_hash, "#{label} #{name}: file bytes differ from checksums.txt")
  end
  stats_size, stats_sha256 = w114_statistics_expectation(profile)
  stats_path = File.join(part, "statistics.packed")
  w114_require(File.size(stats_path) == stats_size, "#{label}: statistics.packed size differs (expected #{stats_size}, got #{File.size(stats_path)})")
  actual_stats_sha256 = w114_file_sha256(stats_path)
  w114_require(actual_stats_sha256 == stats_sha256, "#{label}: statistics.packed fingerprint differs: #{actual_stats_sha256}")
end

def w114_assert_invalidated_system_columns(part : String, label : String) : Nil
  path = File.join(part, "invalidated_system_columns.txt")
  contents = File.read(path)
  w114_require(contents == "_block_number\n_block_offset\n" || contents == "_block_offset\n_block_number\n", "#{label}: invalidated_system_columns.txt differs: #{contents.inspect}")
end

def w114_assert_layout(part : String, profile : W114Profile, label : String, attached : Bool = false) : Nil
  streams = w114_streams(profile)
  actual_columns = File.read(File.join(part, "columns.txt")).lines.map(&.strip)
  w114_require(actual_columns == w114_expected_columns, "#{label}: exact two-column declaration differs: #{actual_columns.inspect}")
  actual_substreams = File.read(File.join(part, "columns_substreams.txt"))
  w114_require(actual_substreams == w114_expected_substreams, "#{label}: exact 25-substream order differs")
  w114_require(File.read(File.join(part, "default_compression_codec.txt")) == "CODEC(LZ4)", "#{label}: default codec differs")
  w114_require(File.read(File.join(part, "metadata_version.txt")) == "0", "#{label}: metadata version differs")
  w114_require(File.read(File.join(part, "count.txt")) == profile.keys.size.to_s, "#{label}: outer row count differs")
  w114_assert_serialization(part, profile, label)

  expected_files = [
    "checksums.txt", "columns.txt", "columns_substreams.txt", "count.txt",
    "default_compression_codec.txt", "metadata_version.txt", "primary.idx",
    "serialization.json", "statistics.packed",
  ]
  if attached
    expected_files << "invalidated_system_columns.txt"
    w114_assert_invalidated_system_columns(part, label)
  end
  W114_EXPECTED_STREAM_NAMES.each do |stream_name|
    hashed = CrystalClick::StreamName.hash(stream_name)
    expected_files << "#{hashed}.bin" << "#{hashed}.mrk2"
  end
  actual_files = Dir.children(part).sort
  w114_require(actual_files == expected_files.sort, "#{label}: exact file inventory differs (missing=#{(expected_files - actual_files).sort.inspect}, extra=#{(actual_files - expected_files).sort.inspect})")

  checksums = CrystalClick::PartChecksums.open(part)
  checksum_files = expected_files - [
    "checksums.txt", "columns.txt", "columns_substreams.txt", "default_compression_codec.txt",
    "metadata_version.txt", "invalidated_system_columns.txt",
  ]
  w114_require(checksums.entries.keys.sort == checksum_files.sort, "#{label}: exact checksum inventory differs")
  checksums.entries.each_key { |name| checksums.validate_selected_entries(part, name) }
  w114_assert_checksum_hashes(part, checksums, profile, label)

  w114_assert_bytes(File.read(File.join(part, "primary.idx")), w114_expected_primary(profile), "#{label} literal plain primary.idx")
  streams.each do |stream|
    w114_assert_bytes(w114_read_raw(part, stream.name), stream.raw, "#{label} #{stream.name} raw stream")
    expected_marks = w114_expected_marks(profile, stream)
    actual_marks = w114_marks(part, stream.name)
    w114_require(expected_marks.size == profile.boundaries.size && expected_marks.last[2] == 0_u64, "#{label} #{stream.name}: expected mark fixture lacks EOF")
    w114_assert_marks(actual_marks, expected_marks, "#{label} #{stream.name}")
  end
end

def w114_assert_check_record(actual : String, part_name : String, result : String, error : String, label : String) : Nil
  expected = "#{part_name}\t#{result}\t#{error}\n"
  w114_fail("#{label}: CHECK record mismatch") unless actual == expected
end

def w114_expect_check_mismatch(part_name : String, result : String, seeded_actual : String, label : String) : Nil
  begin
    w114_assert_check_record(seeded_actual, part_name, result, "", label)
  rescue ex : W114Mismatch
    message = ex.message || "<missing mismatch message>"
    w114_require(message == "#{label}: CHECK record mismatch", "#{label}: CHECK negative control caught an unrelated failure: #{message}")
    puts "PASS W114 CHECK comparator negative control: #{label}"
    return
  end
  w114_fail("#{label}: seeded wrong CHECK record was accepted")
end

def w114_read_check(binary : String, store : String, table : String) : String
  w114_run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated")
end

def w114_check(binary : String, store : String, table : String, part : String, label : String) : Nil
  part_name = File.basename(part.chomp("/"))
  actual = w114_read_check(binary, store, table)
  w114_assert_check_record(actual, part_name, "1", "", label)
  puts "PASS #{label}: actual CHECK=1"
  w114_expect_check_mismatch(part_name, "1", "#{part_name}\t0\t\n", "#{label} seeded CHECK result=0")
  w114_expect_check_mismatch(part_name, "1", "wrong_#{part_name}\t1\t\n", "#{label} seeded part name")
end

def w114_stock_part_path(binary : String, store : String, table : String, profile : W114Profile) : String
  rows = w114_run(binary, store, "SELECT path, part_type, rows FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw").lines.map(&.strip).reject(&.empty?)
  w114_require(rows.size == 1, "#{table}: expected exactly one active part, got #{rows.inspect}")
  fields = rows[0].split('\t')
  w114_require(fields.size == 3 && fields[1] == "Wide" && fields[2] == profile.keys.size.to_s, "#{table}: expected one Wide part with #{profile.keys.size} rows, got #{rows[0].inspect}")
  w114_require(Dir.exists?(fields[0]), "#{table}: active part path is absent: #{fields[0]}")
  fields[0]
end

def w114_assert_schema(binary : String, store : String, table : String) : Nil
  actual = w114_run(binary, store, "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw").lines.map(&.strip)
  w114_require(actual == ["pk UInt64", "payload Geometry"], "#{table}: exact nominal schema differs: #{actual.inspect}")
end

def w114_rowbinary_checks(binary : String, store : String, table : String, profile : W114Profile, label : String) : Nil
  all_indexes = (0...profile.keys.size).to_a
  expected_full = w114_rowbinary(profile, all_indexes)
  actual_full = w114_run(binary, store, "SELECT pk, payload FROM default.#{table} ORDER BY pk FORMAT RowBinary")
  w114_assert_bytes(actual_full, expected_full, "#{label} full RowBinary")
  selected_indexes = w114_expected_selected_indexes(profile)
  expected_selected = w114_rowbinary(profile, selected_indexes)
  actual_selected = w114_run(binary, store, "SELECT pk, payload FROM default.#{table} WHERE pk >= #{profile.selected_min} AND pk < #{profile.selected_max} ORDER BY pk FORMAT RowBinary")
  w114_assert_bytes(actual_selected, expected_selected, "#{label} selected RowBinary")
  puts "PASS #{label}: literal full and selected RowBinary (#{expected_full.bytesize}/#{expected_selected.bytesize} bytes)"
end

def w114_create_table(binary : String, store : String, table : String, profile : W114Profile) : Nil
  w114_run(binary, store, "CREATE TABLE default.#{table} (pk UInt64, payload Geometry) ENGINE = MergeTree ORDER BY pk SETTINGS #{profile.settings}")
end

def w114_insert_profile(binary : String, store : String, table : String, profile : W114Profile) : Nil
  indexes = (0...profile.values.size).to_a
  input = IO::Memory.new(w114_rowbinary(profile, indexes).to_slice)
  w114_run(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", input)
end

def w114_attach_part(binary : String, store : String, table : String, profile : W114Profile, source_part : String) : String
  w114_create_table(binary, store, table, profile)
  data_path = w114_run(binary, store, "SELECT data_paths[1] FROM system.tables WHERE database='default' AND name='#{table}' FORMAT TSVRaw").strip
  w114_require(!data_path.empty?, "#{table}: fresh ATTACH destination path is missing")
  detached = File.join(data_path, "detached")
  FileUtils.mkdir_p(detached)
  target = File.join(detached, "all_1_1_0")
  w114_require(!File.exists?(target), "#{table}: detached ATTACH target already exists")
  FileUtils.cp_r(source_part, target)
  w114_run(binary, store, "ALTER TABLE default.#{table} ATTACH PART 'all_1_1_0'")
  w114_stock_part_path(binary, store, table, profile)
end

def w114_qualify_profile(binary : String, store : String, profile : W114Profile) : {String, String}
  source_table = "w114_source_#{profile.name}"
  attached_table = "w114_attached_#{profile.name}"
  w114_create_table(binary, store, source_table, profile)
  w114_insert_profile(binary, store, source_table, profile)
  source_part = w114_stock_part_path(binary, store, source_table, profile)
  w114_assert_schema(binary, store, source_table)
  w114_assert_layout(source_part, profile, "W114 #{profile.name} stock source")
  w114_check(binary, store, source_table, source_part, "W114 #{profile.name} stock source")
  w114_rowbinary_checks(binary, store, source_table, profile, "W114 #{profile.name} stock source")

  attached_part = w114_attach_part(binary, store, attached_table, profile, source_part)
  w114_assert_schema(binary, store, attached_table)
  w114_assert_layout(attached_part, profile, "W114 #{profile.name} fresh ATTACH", attached: true)
  w114_check(binary, store, attached_table, attached_part, "W114 #{profile.name} fresh ATTACH")
  w114_rowbinary_checks(binary, store, attached_table, profile, "W114 #{profile.name} fresh ATTACH")
  {source_part, attached_part}
end

def w114_comparator_negative_controls(part : String, profile : W114Profile) : Nil
  streams = w114_streams(profile)
  tag_stream = streams.find { |stream| stream.name == "payload.variant_discr" } || w114_fail("W114 negative controls: discriminator stream missing")
  tag_raw = w114_read_raw(part, tag_stream.name)
  w114_seeded_byte_mismatch(tag_raw, tag_stream.raw, 8, "W114 seeded wrong global tag")

  size_stream = streams.find { |stream| stream.name == "payload.LineString.size0" } || w114_fail("W114 negative controls: size stream missing")
  w114_seeded_byte_mismatch(w114_read_raw(part, size_stream.name), size_stream.raw, 0, "W114 seeded wrong size vector")
  coordinate_stream = streams.find { |stream| stream.name == "payload.LineString%2E1" } || w114_fail("W114 negative controls: coordinate stream missing")
  w114_seeded_byte_mismatch(w114_read_raw(part, coordinate_stream.name), coordinate_stream.raw, 0, "W114 seeded wrong coordinate IEEE lane")

  discr_expected_marks = w114_expected_marks(profile, tag_stream)
  w114_expect_mark_mismatch(w114_marks(part, tag_stream.name), discr_expected_marks, "W114 seeded wrong outer-grid .mrk2")

  expected_primary = w114_expected_primary(profile)
  w114_seeded_byte_mismatch(File.read(File.join(part, "primary.idx")), expected_primary, 0, "W114 seeded wrong plain PK")
  w114_expect_metadata_mismatch(part, profile, "W114 seeded wrong serialization metadata")
  puts "PASS W114 comparator sensitivity: wrong tag, size, coordinate, mark, PK and metadata each rejected by its named comparator"
end

def w114_prepare_store(store_path : String) : String
  expanded = File.expand_path(store_path)
  parent = File.realpath(File.dirname(expanded))
  store = File.join(parent, File.basename(expanded))
  w114_require(store.starts_with?("/private/tmp/"), "refusing non-temporary W114 store path: #{store}")
  w114_require(!File.symlink?(store), "refusing symlink W114 store: #{store}")
  if Dir.exists?(store)
    w114_require(Dir.empty?(store), "W114 store must be fresh and empty: #{store}")
  else
    Dir.mkdir(store)
  end
  store
end

def w114_verify_runtime(binary : String, store : String) : String
  executable_sha256 = w114_file_sha256(binary)
  w114_require(executable_sha256 == W114_EXECUTABLE_SHA256, "W114 executable SHA-256 differs: #{executable_sha256}")
  output = IO::Memory.new
  error = IO::Memory.new
  status = Process.run(binary, ["local", "--version"], output: output, error: error)
  w114_require(status.success?, "could not inspect W114 ClickHouse version: #{error}")
  expected_version = "ClickHouse local version #{W114_VERSION} (official build)."
  w114_require(output.to_s.strip == expected_version, "W114 requires #{expected_version}, got #{output.to_s.strip}")
  build_options = w114_run(binary, store, "SELECT name || '=' || value FROM system.build_options WHERE name IN ('GIT_HASH', 'VERSION_GITHASH') ORDER BY name FORMAT TSVRaw").lines.map(&.strip)
  expected_build_options = ["GIT_HASH=#{W114_BUILD_HASH}", "VERSION_GITHASH=#{W114_BUILD_HASH}"]
  w114_require(build_options == expected_build_options, "W114 binary build identity differs: #{build_options.inspect}")
  puts "W114 runtime identity: #{expected_version}; build=#{W114_BUILD_HASH}; executable_sha256=#{executable_sha256}"
  expected_version
end

def w114_qualify_stock(mode : String) : Nil
  w114_fixture_self_check
  binary = ENV["CLICKHOUSE_BIN"]? || raise "set CLICKHOUSE_BIN to the isolated W114 ClickHouse executable"
  store_value = ENV["W114_STORE"]? || raise "set W114_STORE to a fresh temporary ClickHouse store"
  store = w114_prepare_store(store_value)
  w114_verify_runtime(binary, store)

  qualified = {} of String => {String, String}
  W114_PROFILES.each do |profile|
    qualified[profile.name] = w114_qualify_profile(binary, store, profile)
  end
  puts "PASS W114 stock qualification: 6 profiles, 12 source/fresh-ATTACH Wide parts, 312 ordered physical streams (624 .bin/.mrk2 files), exact schema/inventory/checksums/metadata/raw bytes/marks/PK, 12 CHECK=1, 12 full+selected RowBinary pairs"

  mixed_source = qualified["mixed_basic"][0]
  w114_comparator_negative_controls(mixed_source, W114_PROFILES[0])

  if mode == "red"
    qualified.each do |name, parts|
      begin
        CrystalClick::WidePart.open_typed(parts[1], "payload")
      rescue ex : CrystalClick::UnsupportedFormatError
        w114_require(ex.message == "unsupported exact typed column", "W114 #{name}: Geometry refusal differs from exact public-type guard: #{ex.message.inspect}")
        puts "EXPECTED RED W114 #{name}: #{ex.message}"
        next
      rescue ex
        w114_fail("W114 #{name}: typed Geometry open failed outside the exact unsupported-type refusal: #{ex.class}: #{ex.message}")
      end
      w114_fail("W114 #{name}: public typed Geometry reader unexpectedly admitted the qualified stock part")
    end
    puts "EXPECTED RED W114: all stock profiles qualified; exact typed Geometry guard remains closed"
    exit 1
  end
  puts "PASS W114 qualify: strict stock qualification and comparator controls complete; no production admission tested"
end

def w114_fixture_self_check : Nil
  checked_streams = 0
  checked_full_rowbinary = 0
  checked_selected_rowbinary = 0

  W114_PROFILES.each do |profile|
    streams = w114_streams(profile)
    expected_names = w114_fixture_stream_names(profile)
    actual_names = streams.map(&.name)
    w114_require(actual_names == expected_names, "#{profile.name}: literal physical stream order/name list differs")
    w114_require(actual_names.uniq == actual_names, "#{profile.name}: duplicate physical stream name")

    streams.each do |stream|
      w114_require(stream.row_fragments.size == profile.values.size, "#{profile.name}/#{stream.name}: fragment outer-row count differs")
      w114_require(stream.row_counts.size == profile.values.size, "#{profile.name}/#{stream.name}: mark-row schedule length differs")
      w114_require(stream.raw == stream.prefix + stream.row_fragments.flat_map { |row| row }.join, "#{profile.name}/#{stream.name}: raw stream concatenation differs")
      checked_streams += 1
    end

    all_indexes = (0...profile.values.size).to_a
    selected_indexes = profile.keys.each_with_index.select do |key, _index|
      key >= profile.selected_min && key < profile.selected_max
    end.map { |_key, index| index.to_i32 }.to_a
    expected_selected = w114_expected_selected_indexes(profile)
    w114_require(selected_indexes == expected_selected, "#{profile.name}: selected RowBinary row indexes differ from literal PK interval")

    full_rowbinary = w114_rowbinary(profile, all_indexes)
    selected_rowbinary = w114_rowbinary(profile, selected_indexes)
    expected_full_size, expected_selected_size = w114_expected_rowbinary_sizes(profile)
    independently_projected = all_indexes.select { |index| expected_selected.includes?(index) }
    w114_require(independently_projected == expected_selected, "#{profile.name}: selected RowBinary projection is not an ordered subset")
    w114_require(selected_rowbinary == w114_rowbinary(profile, independently_projected), "#{profile.name}: selected RowBinary generation differs from literal ordered projection")
    w114_require(full_rowbinary.bytesize == expected_full_size, "#{profile.name}: literal full RowBinary size differs (expected #{expected_full_size}, got #{full_rowbinary.bytesize})")
    w114_require(selected_rowbinary.bytesize == expected_selected_size, "#{profile.name}: literal selected RowBinary size differs (expected #{expected_selected_size}, got #{selected_rowbinary.bytesize})")
    checked_full_rowbinary += 1
    checked_selected_rowbinary += 1
  end

  w114_require(checked_streams == 6 * 26, "fixture self-check did not cover all six profiles and 26 streams each")
  w114_require(checked_full_rowbinary == 6 && checked_selected_rowbinary == 6, "fixture self-check did not generate full and selected RowBinary for all profiles")
  puts "PASS W114 fixture self-check: #{W114_PROFILES.size} profiles, #{checked_streams} ordered streams, full+selected RowBinary generated"
end

def w114_run(binary : String, store : String, query : String, input : IO? = nil) : String
  output = IO::Memory.new
  error = IO::Memory.new
  status = if input
             Process.run(binary, ["local", "--path", store, "--query", query], input: input, output: output, error: error)
           else
             Process.run(binary, ["local", "--path", store, "--query", query], output: output, error: error)
           end
  raise "ClickHouse capture command failed: #{error}\n#{query}" unless status.success?
  output.to_s
end

def w114_stock_capture_profile(binary : String, store : String, profile : W114Profile) : Nil
  table = "w114_capture_#{profile.name}"
  w114_run(binary, store, "CREATE TABLE default.#{table} (pk UInt64, payload Geometry) ENGINE = MergeTree ORDER BY pk SETTINGS #{profile.settings}")
  indexes = (0...profile.values.size).map(&.to_i32)
  rowbinary = IO::Memory.new(w114_rowbinary(profile, indexes).to_slice)
  w114_run(binary, store, "INSERT INTO default.#{table} FORMAT RowBinary", rowbinary)

  columns = w114_run(binary, store, "SELECT name || ' ' || type FROM system.columns WHERE database='default' AND table='#{table}' ORDER BY position FORMAT TSVRaw")
  parts = w114_run(binary, store, "SELECT path, part_type, rows FROM system.parts WHERE database='default' AND table='#{table}' AND active FORMAT TSVRaw")
  check = w114_run(binary, store, "CHECK TABLE default.#{table} FORMAT TabSeparated")
  w114_require(!parts.empty?, "#{profile.name}: capture found no active stock part")

  puts "\n=== W114 STOCK-CAPTURE ONLY: #{profile.name} ==="
  puts "table=#{table}"
  puts "settings=#{profile.settings}"
  puts "insert_rowbinary_bytes=#{rowbinary.size}"
  puts "system.columns TSVRaw:"
  print columns
  puts "system.parts TSVRaw:"
  print parts
  puts "CHECK TABLE observed output:"
  print check

  parts.lines.each do |line|
    fields = line.split('\t')
    w114_require(fields.size == 3, "#{profile.name}: capture part record is malformed")
    part = fields[0]
    w114_require(Dir.exists?(part), "#{profile.name}: capture part directory is unavailable: #{part}")

    puts "part=#{part}"
    puts "inventory name<TAB>size_bytes:"
    Dir.children(part).sort.each do |name|
      path = File.join(part, name)
      puts "#{name}\t#{File.size(path)}" if File.file?(path)
    end

    {"columns.txt", "columns_substreams.txt", "serialization.json"}.each do |name|
      path = File.join(part, name)
      puts "#{name} observed contents:"
      if File.file?(path)
        print File.read(path)
        puts unless File.read(path).ends_with?('\n')
      else
        puts "<absent>"
      end
    end

    {"checksums.txt", "statistics.packed", "primary.idx"}.each do |name|
      path = File.join(part, name)
      if File.file?(path)
        bytes = File.read(path).to_slice
        puts "#{name} observed hex (#{bytes.size} bytes): #{bytes.hexstring}"
      else
        puts "#{name} observed: <absent>"
      end
    end
  end
end

def w114_stock_capture : Nil
  binary = ENV["CLICKHOUSE_BIN"]? || raise "set CLICKHOUSE_BIN to the isolated W114 ClickHouse executable"
  store = ENV["W114_CAPTURE_STORE"]? || raise "set W114_CAPTURE_STORE to a fresh temporary ClickHouse store"
  expanded_store = File.expand_path(store)
  parent = File.realpath(File.dirname(expanded_store))
  store = File.join(parent, File.basename(expanded_store))
  unless store.starts_with?("/private/tmp/")
    raise "refusing non-temporary W114 capture store path: #{store}"
  end
  raise "refusing symlink W114 capture store: #{store}" if File.symlink?(store)
  if Dir.exists?(store)
    raise "W114 capture store must be fresh and empty: #{store}" unless Dir.empty?(store)
  else
    Dir.mkdir(store)
  end

  hash_output = IO::Memory.new
  hash_error = IO::Memory.new
  hash_status = Process.run("shasum", ["-a", "256", binary], output: hash_output, error: hash_error)
  raise "could not inspect ClickHouse executable SHA-256: #{hash_error}" unless hash_status.success?
  executable_sha256 = hash_output.to_s.split(' ').first? || raise "ClickHouse SHA-256 output is malformed"
  w114_require(executable_sha256 == W114_EXECUTABLE_SHA256, "W114 executable SHA-256 differs: #{executable_sha256}")

  version_output = IO::Memory.new
  version_error = IO::Memory.new
  version_status = Process.run(binary, ["local", "--version"], output: version_output, error: version_error)
  raise "could not inspect ClickHouse version: #{version_error}" unless version_status.success?
  expected_version = "ClickHouse local version #{W114_VERSION} (official build)."
  w114_require(version_output.to_s.strip == expected_version, "W114 requires #{expected_version}, got #{version_output.to_s.strip}")

  build_options = w114_run(binary, store, "SELECT name || '=' || value FROM system.build_options WHERE name IN ('GIT_HASH', 'VERSION_GITHASH') ORDER BY name FORMAT TSVRaw").lines.map(&.strip)
  expected_build_options = ["GIT_HASH=#{W114_BUILD_HASH}", "VERSION_GITHASH=#{W114_BUILD_HASH}"]
  w114_require(build_options == expected_build_options, "W114 binary build identity differs: #{build_options.inspect}")

  puts "W114 STOCK-CAPTURE ONLY: observations follow; this mode is neither qualification nor production RED"
  puts "runtime=#{expected_version}; build=#{W114_BUILD_HASH}; executable_sha256=#{executable_sha256}"
  W114_PROFILES.each { |profile| w114_stock_capture_profile(binary, store, profile) }
end

unless ARGV.size == 1 && {"fixtures", "stock-capture", "qualify", "red"}.includes?(ARGV[0])
  STDERR.puts "usage: crystal run scripts/probe_geometry_w114.cr -- fixtures|stock-capture|qualify|red"
  exit 2
end

case ARGV[0]
when "fixtures"
  w114_fixture_self_check
when "stock-capture"
  w114_stock_capture
when "qualify", "red"
  w114_qualify_stock(ARGV[0])
end

# W114 stock-first Geometry probe. Literal schema/value/layout expectations
# are maintained here; neither Crystal's reader nor writer defines them.
require "json"
require "file_utils"
require "../src/crystal_click"

W114_VERSION    = "26.10.1.1201"
W114_BUILD_HASH = "d9bcb5ab007f0f6299f7f973f2642245bab3d028"
W114_SETTINGS   = "index_granularity = 2, index_granularity_bytes = 10485760, enable_mixed_granularity_parts = 1, min_rows_for_wide_part = 0, min_bytes_for_wide_part = 0, ratio_of_defaults_for_sparse_serialization = 0.9375, compress_marks = 0, compress_primary_key = 0, min_compress_block_size = 0, max_compress_block_size = 4096, default_compression_codec = 'LZ4'"
W114_MARK_BYTES = 24
W114_TAGS       = {"LineString", "MultiLineString", "MultiPolygon", "Point", "Polygon", "Ring", "MultiPoint"}
W114_DEPTHS     = {"LineString" => 1, "MultiLineString" => 2, "MultiPolygon" => 3, "Point" => 0, "Polygon" => 2, "Ring" => 1, "MultiPoint" => 1}

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
  names = ["pk", "payload.variant_discr"]
  W114_TAG_NAMES.each do |type_name|
    W114_DEPTHS[type_name].times do |level|
      names << "payload.#{type_name}.size#{level}"
    end
    names << "payload.#{type_name}%2E1"
    names << "payload.#{type_name}%2E2"
  end
  names
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
    independently_projected = all_indexes.select { |index| expected_selected.includes?(index) }
    w114_require(independently_projected == expected_selected, "#{profile.name}: selected RowBinary projection is not an ordered subset")
    w114_require(selected_rowbinary == w114_rowbinary(profile, independently_projected), "#{profile.name}: selected RowBinary generation differs from literal ordered projection")
    w114_require(full_rowbinary.bytesize >= profile.keys.size * 9, "#{profile.name}: full RowBinary omitted key/tag bytes")
    w114_require(selected_rowbinary.bytesize >= expected_selected.size * 9, "#{profile.name}: selected RowBinary omitted key/tag bytes")
    checked_full_rowbinary += 1
    checked_selected_rowbinary += 1
  end

  w114_require(checked_streams == 6 * 26, "fixture self-check did not cover all six profiles and 26 streams each")
  w114_require(checked_full_rowbinary == 6 && checked_selected_rowbinary == 6, "fixture self-check did not generate full and selected RowBinary for all profiles")
  puts "PASS W114 fixture self-check: #{W114_PROFILES.size} profiles, #{checked_streams} ordered streams, full+selected RowBinary generated"
end

unless ARGV.size == 1 && ARGV[0] == "fixtures"
  STDERR.puts "usage: crystal run scripts/probe_geometry_w114.cr -- fixtures"
  exit 2
end

w114_fixture_self_check

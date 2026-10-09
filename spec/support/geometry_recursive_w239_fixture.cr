require "file_utils"

W239_GEOMETRY_TAGS = [255_u8, 0_u8, 3_u8, 6_u8, 4_u8, 1_u8, 2_u8, 5_u8, 0_u8, 3_u8, 255_u8]

def w239g_slice(values : Array(T)) : Slice(T) forall T
  values.to_unsafe.to_slice(values.size)
end

def w239g_type(name : String) : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.custom(name)
end

def w239g_float(seed : UInt64, axis : UInt64) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.float64_bits(0x3ff0_0000_0000_0000_u64 &+ seed &+ axis)
end

def w239g_static_value(
  type : CrystalClick::BinaryDataType,
  seed : UInt64,
  force_empty : Bool = false,
) : CrystalClick::BinaryValue
  case type.tag
  when CrystalClick::BinaryDataType::TAG_CUSTOM
    body = w239g_static_value(type.child_at(0), seed &+ 1_u64, force_empty)
    CrystalClick::BinaryValue.custom(type, body)
  when CrystalClick::BinaryDataType::TAG_ARRAY
    count = force_empty ? 0 : (seed % 3_u64).to_i
    children = Array(CrystalClick::BinaryValue).new(count) do |index|
      w239g_static_value(type.child_at(0), seed &+ index.to_u64 &+ 1_u64)
    end
    CrystalClick::BinaryValue.array(type, children)
  when CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE,
       CrystalClick::BinaryDataType::TAG_NAMED_TUPLE
    children = Array(CrystalClick::BinaryValue).new(type.child_count)
    type.child_count.times do |index|
      child_type = type.child_at(index)
      child = if child_type.tag == CrystalClick::BinaryDataType::TAG_FLOAT64
                w239g_float(seed, index.to_u64)
              else
                w239g_static_value(child_type, seed &+ index.to_u64 &+ 1_u64)
              end
      children << child
    end
    CrystalClick::BinaryValue.tuple(type, children)
  when CrystalClick::BinaryDataType::TAG_STRING
    CrystalClick::BinaryValue.string("g#{seed}\u0000tail")
  when CrystalClick::BinaryDataType::TAG_FLOAT64
    w239g_float(seed, 0_u64)
  when CrystalClick::BinaryDataType::TAG_BOOL
    CrystalClick::BinaryValue.bool(seed.odd?)
  else
    raise ArgumentError.new("W239 fixture encountered an unsupported static leaf")
  end
end

def w239g_geometry_value(
  geometry : CrystalClick::BinaryDataType,
  tag : UInt8,
  seed : UInt64,
  force_empty : Bool = false,
) : CrystalClick::BinaryValue
  storage = geometry.child_at(0)
  variant = if tag == 255_u8
              CrystalClick::BinaryValue.variant_null(storage)
            else
              arm_type = storage.child_at(tag.to_i)
              arm = w239g_static_value(arm_type, seed, force_empty)
              CrystalClick::BinaryValue.variant(storage, tag.to_i, arm)
            end
  CrystalClick::BinaryValue.custom(geometry, variant)
end

def w239g_assert_value(
  actual : CrystalClick::BinaryValue,
  expected : CrystalClick::BinaryValue,
) : Nil
  actual.type.name.should eq(expected.type.name)
  actual.is_null?.should eq(expected.is_null?)
  if actual.type.tag == CrystalClick::BinaryDataType::TAG_VARIANT
    actual.variant_index?.should eq(expected.variant_index?)
  end
  actual.byte_size.should eq(expected.byte_size)
  actual.byte_size.times { |index| actual.byte_at(index).should eq(expected.byte_at(index)) }
  actual.child_count.should eq(expected.child_count)
  actual.child_count.times do |index|
    w239g_assert_value(actual.child_at(index), expected.child_at(index))
  end
end

def w239g_assert_marks(
  actual : Array(Array(CrystalClick::BinaryValue)),
  expected : Array(Array(CrystalClick::BinaryValue)),
) : Nil
  actual.size.should eq(expected.size)
  actual.each_with_index do |mark, mark_index|
    mark.size.should eq(expected[mark_index].size)
    mark.each_with_index do |value, row_index|
      w239g_assert_value(value, expected[mark_index][row_index])
    end
  end
end

def w239g_assert_geo_array(
  actual : CrystalClick::WideGeoArrayRow,
  expected : CrystalClick::BinaryValue,
  root_type_name : String,
) : Nil
  body = expected.child_at(0)
  actual.type_name.should eq(root_type_name)
  expected_terminal = body.type.child_at(0).name == "Point"
  actual.terminal?.should eq(expected_terminal)
  actual.size.should eq(body.child_count)
  body.child_count.times do |index|
    expected_child = body.child_at(index)
    if expected_terminal
      expected_child.type.name.should eq("Point")
      point = actual.point_at(index)
      point.x_bits.should eq(expected_child.child_at(0).child_at(0).as_float64_bits)
      point.y_bits.should eq(expected_child.child_at(0).child_at(1).as_float64_bits)
    else
      w239g_assert_geo_array(actual.array_at(index), expected_child, root_type_name)
    end
  end
end

def w239g_assert_legacy_row(
  actual : CrystalClick::WideGeometryRow,
  expected : CrystalClick::BinaryValue,
) : Nil
  actual.type_name.should eq("Geometry")
  inner = expected.child_at(0)
  tag = inner.variant_index? || 255
  actual.tag.should eq(tag.to_u8)
  if tag == 255
    actual.null?.should be_true
  elsif tag == 3
    point_value = inner.child_at(0).child_at(0)
    point = actual.point
    point.x_bits.should eq(point_value.child_at(0).as_float64_bits)
    point.y_bits.should eq(point_value.child_at(1).as_float64_bits)
  else
    actual.geo_array.type_name.should eq(inner.child_at(0).type.name)
    w239g_assert_geo_array(actual.geo_array, inner.child_at(0), inner.child_at(0).type.name)
  end
end

class W239GeometryFixture
  getter root : String
  getter geometry_type : CrystalClick::BinaryDataType
  getter geometry_marks : Array(Array(CrystalClick::BinaryValue))
  getter composed_type : CrystalClick::BinaryDataType
  getter composed_marks : Array(Array(CrystalClick::BinaryValue))
  getter rows_per_mark : Int32
  getter keys : Array(UInt64)

  def initialize
    @root = File.tempname("crystal-click-w239-geometry-")
    Dir.mkdir(@root)
    @rows_per_mark = 4
    @keys = Array(UInt64).new(W239_GEOMETRY_TAGS.size) { |index| 100_u64 &+ index.to_u64 }
    @geometry_type = w239g_type("Geometry")

    values = W239_GEOMETRY_TAGS.map_with_index do |tag, index|
      w239g_geometry_value(@geometry_type, tag, (index + 1).to_u64, tag == 0_u8 && index == 1)
    end
    @geometry_marks = [values[0, 4], values[4, 4], values[8, 3]] of Array(CrystalClick::BinaryValue)

    geometry = @geometry_type
    string = CrystalClick::BinaryDataType.primitive("String")
    array_type = CrystalClick::BinaryDataType.array(geometry)
    map_type = CrystalClick::BinaryDataType.map(string, geometry)
    nested_type = CrystalClick::BinaryDataType.nested(
      [geometry, string] of CrystalClick::BinaryDataType,
      ["shape", "label"] of String,
    )
    tuple_geo_type = CrystalClick::BinaryDataType.tuple([geometry] of CrystalClick::BinaryDataType)
    nullable_type = CrystalClick::BinaryDataType.nullable(tuple_geo_type)
    variant_tuple_type = CrystalClick::BinaryDataType.tuple([geometry] of CrystalClick::BinaryDataType)
    variant_type = CrystalClick::BinaryDataType.variant(
      [string, variant_tuple_type] of CrystalClick::BinaryDataType,
    )
    @composed_type = CrystalClick::BinaryDataType.tuple(
      [array_type, map_type, nested_type, nullable_type, variant_type] of CrystalClick::BinaryDataType,
      ["items", "lookup", "records", "optional", "choice"] of String,
    )

    all_values = Array(CrystalClick::BinaryValue).new(W239_GEOMETRY_TAGS.size) do |index|
      tag = W239_GEOMETRY_TAGS[index]
      current = values[index]
      following = values[(index + 1) % values.size]
      array_items = if index % 4 == 0
                      [] of CrystalClick::BinaryValue
                    elsif index == W239_GEOMETRY_TAGS.size - 1
                      [
                        current,
                        w239g_geometry_value(geometry, 0_u8, 99_u64, true),
                      ] of CrystalClick::BinaryValue
                    elsif index % 3 == 0
                      [current, following] of CrystalClick::BinaryValue
                    else
                      [current] of CrystalClick::BinaryValue
                    end

      map_items = [
        CrystalClick::BinaryValue.string("key#{index}\u0000"),
        following,
      ] of CrystalClick::BinaryValue
      records = Array(CrystalClick::BinaryValue).new(index % 3) do |record_index|
        CrystalClick::BinaryValue.tuple(
          nested_type.child_at(0),
          [values[(index + record_index) % values.size], CrystalClick::BinaryValue.string("row#{index}")] of CrystalClick::BinaryValue,
        )
      end
      optional = if index.even?
                   CrystalClick::BinaryValue.nullable(nullable_type)
                 else
                   tuple = CrystalClick::BinaryValue.tuple(
                     tuple_geo_type,
                     [current] of CrystalClick::BinaryValue,
                   )
                   CrystalClick::BinaryValue.nullable(nullable_type, tuple)
                 end
      string_index = variant_type.children.index(string).not_nil!
      tuple_index = variant_type.children.index(variant_tuple_type).not_nil!
      choice = if index.even?
                 CrystalClick::BinaryValue.variant(
                   variant_type,
                   string_index,
                   CrystalClick::BinaryValue.string("alternative\u0000#{index}"),
                 )
               else
                 tuple = CrystalClick::BinaryValue.tuple(
                   variant_tuple_type,
                   [following] of CrystalClick::BinaryValue,
                 )
                 CrystalClick::BinaryValue.variant(variant_type, tuple_index, tuple)
               end

      CrystalClick::BinaryValue.tuple(
        @composed_type,
        [
          CrystalClick::BinaryValue.array(array_type, array_items),
          CrystalClick::BinaryValue.map(map_type, map_items),
          CrystalClick::BinaryValue.nested(nested_type, records),
          optional,
          choice,
        ] of CrystalClick::BinaryValue,
      )
    end
    @composed_marks = [all_values[0, 4], all_values[4, 4], all_values[8, 3]] of Array(CrystalClick::BinaryValue)
  end

  def bare_part : String
    File.join(@root, "bare", "all_1_1_0")
  end

  def composed_part : String
    File.join(@root, "composed", "all_1_1_0")
  end

  def write_bare : String
    FileUtils.mkdir_p(File.dirname(bare_part))
    CrystalClick::WidePartWriter.write_uint64_custom_geo_bulk_part(
      bare_part, "pk", w239g_slice(@keys), "v", @geometry_type, @geometry_marks,
      rows_per_mark: @rows_per_mark,
      profile: CrystalClick::BinaryBulkProfile.with_size_stream,
      frame_bytes: 4096,
    )
  end

  def write_composed : String
    FileUtils.mkdir_p(File.dirname(composed_part))
    CrystalClick::WidePartWriter.write_uint64_custom_geo_bulk_part(
      composed_part, "pk", w239g_slice(@keys), "v", @composed_type, @composed_marks,
      rows_per_mark: @rows_per_mark,
      profile: CrystalClick::BinaryBulkProfile.single_stream,
      frame_bytes: 4096,
    )
  end

  def close : Nil
    FileUtils.rm_rf(@root)
  end
end

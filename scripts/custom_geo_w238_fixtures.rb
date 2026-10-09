# Independent, finite stock/native literals for the W238 Custom Geo lane.
# This file deliberately does not load Crystal codecs or parse arbitrary SQL
# types: the descriptor and value visitors are closed over the 13 admitted
# source-valid declarations.
module CustomGeoW238Fixtures
  extend self

  ROW_KEYS = [11, 22, 33, 44, 55].freeze
  MARK_ROWS = [2, 2, 1].freeze
  GEO_NAMES = %w[Point MultiPoint LineString Ring MultiLineString Polygon MultiPolygon].freeze
  TYPED_CONSUMER_IDS = %w[
    nullable_point array_point tuple_string_point map_string_point nested_point_line
    variant_point_string
  ].each(&:freeze).freeze

  P0 = [0.0, 0.0].freeze
  P1 = [1.5, -2.25].freeze
  P2 = [10.0, 0.0].freeze
  P3 = [-5.5, 9.25].freeze
  P4 = [42.0, -0.5].freeze

  PROFILES = [
    { 'id' => 'point', 'declared_type' => 'Point', 'kind' => 'point',
      'values' => [P0, P1, P2, P3, P4] },
    { 'id' => 'multi_point', 'declared_type' => 'MultiPoint', 'kind' => 'array_point',
      'values' => [[], [P0], [P1, P2], [P3, P4, P0], []] },
    { 'id' => 'line_string', 'declared_type' => 'LineString', 'kind' => 'array_point',
      'values' => [[], [P0], [P1, P2], [P3, P4, P0], []] },
    { 'id' => 'ring', 'declared_type' => 'Ring', 'kind' => 'array_point',
      'values' => [[], [P0], [P1, P2], [P3, P4, P0], []] },
    { 'id' => 'multi_line_string', 'declared_type' => 'MultiLineString', 'kind' => 'array_array_point',
      'values' => [[], [[]], [[P0, P1]], [[P2, P3], [P4, P0]], []] },
    { 'id' => 'polygon', 'declared_type' => 'Polygon', 'kind' => 'array_array_point',
      'values' => [[], [[]], [[P0, P1, P2]], [[P3, P4, P0], [P1, P2, P3]], []] },
    { 'id' => 'multi_polygon', 'declared_type' => 'MultiPolygon', 'kind' => 'array_array_array_point',
      'values' => [[], [[]], [[[P0, P1, P2]]], [[[P3, P4, P0], [P1, P2, P3]], [[]]], []] },
    { 'id' => 'nullable_point', 'declared_type' => 'Nullable(Point)', 'kind' => 'nullable_point',
      'values' => [P0, nil, P2, nil, P4] },
    { 'id' => 'array_point', 'declared_type' => 'Array(Point)', 'kind' => 'array_point',
      'values' => [[], [P0], [P1, P2], [P3, P4, P0], []] },
    { 'id' => 'tuple_string_point', 'declared_type' => 'Tuple(label String, point Point)', 'kind' => 'tuple_string_point',
      'values' => [['', P0], ['alpha', P1], ["λ", P2], ["nul\x00byte", P3], ['tail', P4]] },
    { 'id' => 'map_string_point', 'declared_type' => 'Map(String, Point)', 'kind' => 'map_string_point',
      'values' => [[], [['a', P0]], [['a', P1], ['b', P2]], [['z', P3]], [['x', P4], ['y', P0]]] },
    { 'id' => 'nested_point_line', 'declared_type' => 'Nested(point Point, line LineString)', 'kind' => 'nested_point_line',
      'values' => [[], [[P0, []]], [[P1, [P2]], [P3, []]], [], [[P4, [P0, P1]]]] },
    { 'id' => 'variant_point_string', 'declared_type' => 'Variant(Point, String)', 'kind' => 'variant_point_string',
      'values' => [{ 'arm' => 'Point', 'value' => P0 }, { 'arm' => 'String', 'value' => 'λ' }, nil,
        { 'arm' => 'Point', 'value' => P4 }, { 'arm' => 'String', 'value' => 'geo' }] },
  ].freeze

  def fail!(message)
    raise ArgumentError, message
  end

  def profiles
    PROFILES
  end

  def varuint(value)
    fail!('VarUInt literal is not a nonnegative UInt64') unless value.is_a?(Integer) && value >= 0 && value <= 18_446_744_073_709_551_615
    bytes = []
    while value >= 0x80
      bytes << ((value & 0x7f) | 0x80)
      value >>= 7
    end
    (bytes << value).pack('C*').b
  end

  def rb_string(value)
    bytes = value.encode(Encoding::UTF_8).b
    varuint(bytes.bytesize) + bytes
  end

  def custom_descriptor(name)
    fail!("unlisted Custom Geo name #{name.inspect}") unless GEO_NAMES.include?(name)
    "\x2c".b + rb_string(name)
  end

  # Independently authored from ClickHouse DataTypesBinaryEncoding tags.
  def type_descriptor(name)
    case name
    when 'Point', 'MultiPoint', 'LineString', 'Ring', 'MultiLineString', 'Polygon', 'MultiPolygon'
      custom_descriptor(name)
    when 'Array(Point)'
      "\x1e".b + custom_descriptor('Point')
    when 'Nullable(Point)'
      "\x23".b + custom_descriptor('Point')
    when 'Tuple(label String, point Point)'
      "\x20".b + varuint(2) + rb_string('label') + "\x15".b + rb_string('point') + custom_descriptor('Point')
    when 'Map(String, Point)'
      "\x27".b + "\x15".b + custom_descriptor('Point')
    when 'Nested(point Point, line LineString)'
      "\x2f".b + varuint(2) + rb_string('point') + custom_descriptor('Point') +
        rb_string('line') + custom_descriptor('LineString')
    when 'Variant(Point, String)'
      "\x2a".b + varuint(2) + custom_descriptor('Point') + "\x15".b
    else
      fail!("unlisted W238 descriptor type #{name.inspect}")
    end
  end

  def descriptor_hex(name)
    type_descriptor(name).unpack1('H*')
  end

  def shape_node(tag, name, field_names, children)
    { 'tag' => tag, 'name' => name, 'field_names' => field_names, 'children' => children }
  end

  def custom_shape(name)
    shape_node(0x2c, name, [], [geo_storage_shape(name)])
  end

  def geo_storage_shape(name)
    case name
    when 'Point'
      float = shape_node(0x0e, 'Float64', [], [])
      shape_node(0x1f, 'Tuple(Float64, Float64)', [], [float, float])
    when 'MultiPoint', 'LineString', 'Ring'
      shape_node(0x1e, 'Array(Point)', [], [custom_shape('Point')])
    when 'MultiLineString'
      shape_node(0x1e, 'Array(LineString)', [], [custom_shape('LineString')])
    when 'Polygon'
      shape_node(0x1e, 'Array(Ring)', [], [custom_shape('Ring')])
    when 'MultiPolygon'
      shape_node(0x1e, 'Array(Polygon)', [], [custom_shape('Polygon')])
    else
      fail!("unlisted Custom Geo storage shape #{name.inspect}")
    end
  end

  def expected_type_shape(name)
    case name
    when *GEO_NAMES
      custom_shape(name)
    when 'Nullable(Point)'
      shape_node(0x23, name, [], [custom_shape('Point')])
    when 'Array(Point)'
      shape_node(0x1e, name, [], [custom_shape('Point')])
    when 'Tuple(label String, point Point)'
      shape_node(0x20, name, %w[label point], [
        shape_node(0x15, 'String', [], []), custom_shape('Point'),
      ])
    when 'Map(String, Point)'
      shape_node(0x27, name, [], [shape_node(0x15, 'String', [], []), custom_shape('Point')])
    when 'Nested(point Point, line LineString)'
      tuple = shape_node(0x20, 'Tuple(point Point, line LineString)', %w[point line], [
        custom_shape('Point'), custom_shape('LineString'),
      ])
      shape_node(0x2f, name, [], [tuple])
    when 'Variant(Point, String)'
      shape_node(0x2a, name, [], [custom_shape('Point'), shape_node(0x15, 'String', [], [])])
    else
      fail!("unlisted W238 nominal type shape #{name.inspect}")
    end
  end

  def f64(value)
    [Float(value)].pack('E').b
  end

  def point_bytes(point)
    fail!('Point literal must have exactly two coordinates') unless point.is_a?(Array) && point.length == 2
    f64(point[0]) + f64(point[1])
  end

  def string_bytes(value)
    bytes = value.encode(Encoding::UTF_8).b
    varuint(bytes.bytesize) + bytes
  end

  def array_bytes(values)
    varuint(values.length) + values.map { |value| yield(value) }.join.b
  end

  def value_bytes(profile, value)
    case profile.fetch('kind')
    when 'point'
      point_bytes(value)
    when 'array_point'
      array_bytes(value) { |point| point_bytes(point) }
    when 'array_array_point'
      array_bytes(value) { |line_or_ring| array_bytes(line_or_ring) { |point| point_bytes(point) } }
    when 'array_array_array_point'
      array_bytes(value) do |polygon|
        array_bytes(polygon) { |ring| array_bytes(ring) { |point| point_bytes(point) } }
      end
    when 'nullable_point'
      value.nil? ? "\x01".b : "\x00".b + point_bytes(value)
    when 'tuple_string_point'
      string_bytes(value.fetch(0)) + point_bytes(value.fetch(1))
    when 'map_string_point'
      array_bytes(value) { |key, point| string_bytes(key) + point_bytes(point) }
    when 'nested_point_line'
      array_bytes(value) { |point, line| point_bytes(point) + array_bytes(line) { |item| point_bytes(item) } }
    when 'variant_point_string'
      if value.nil?
        "\xff".b
      elsif value.fetch('arm') == 'Point'
        "\x00".b + point_bytes(value.fetch('value'))
      elsif value.fetch('arm') == 'String'
        "\x01".b + string_bytes(value.fetch('value'))
      else
        fail!("unlisted Variant arm #{value.fetch('arm').inspect}")
      end
    else
      fail!("unlisted W238 value kind #{profile.fetch('kind').inspect}")
    end
  end

  def values_hex(profile)
    profile.fetch('values').map { |value| value_bytes(profile, value).unpack1('H*') }
  end

  def schema_header(profile)
    varuint(1) + rb_string('payload') + type_descriptor(profile.fetch('declared_type'))
  end

  def rowbinary_with_names_and_types(profile)
    schema_header(profile) + profile.fetch('values').map { |value| value_bytes(profile, value) }.join.b
  end

  def uint64(value)
    fail!('row key outside UInt64') unless value.is_a?(Integer) && value >= 0 && value <= 18_446_744_073_709_551_615
    [value].pack('Q<').b
  end

  def rowbinary_rows(profile)
    ROW_KEYS.zip(profile.fetch('values')).map { |key, value| uint64(key) + value_bytes(profile, value) }
  end

  def rowbinary_windows(profile)
    rows = rowbinary_rows(profile)
    {
      'full' => rows.join.b,
      'middle' => rows[1, 3].join.b,
      'zero' => ''.b,
    }
  end

  def sql_string(value)
    "CAST(unhex('#{value.encode(Encoding::UTF_8).b.unpack1('H*')}'), 'String')"
  end

  def sql_float(value)
    "toFloat64(#{Float(value).to_s})"
  end

  def sql_point(point)
    "CAST(tuple(#{sql_float(point.fetch(0))}, #{sql_float(point.fetch(1))}), 'Point')"
  end

  def sql_array(values)
    "[#{values.join(', ')}]"
  end

  def sql_custom_array(name, values)
    "CAST(#{sql_array(values)}, '#{name}')"
  end

  def sql_expression(profile, value)
    case profile.fetch('kind')
    when 'point'
      sql_point(value)
    when 'array_point'
      element_type = profile.fetch('declared_type') == 'Array(Point)' ? 'Array(Point)' : profile.fetch('declared_type')
      sql_custom_array(element_type, value.map { |point| sql_point(point) })
    when 'array_array_point'
      child_name = profile.fetch('declared_type') == 'MultiLineString' ? 'LineString' : 'Ring'
      child_values = value.map { |points| sql_custom_array(child_name, points.map { |point| sql_point(point) }) }
      sql_custom_array(profile.fetch('declared_type'), child_values)
    when 'array_array_array_point'
      polygons = value.map do |rings|
        ring_values = rings.map { |points| sql_custom_array('Ring', points.map { |point| sql_point(point) }) }
        sql_custom_array('Polygon', ring_values)
      end
      sql_custom_array('MultiPolygon', polygons)
    when 'nullable_point'
      value.nil? ? "CAST(NULL, 'Nullable(Point)')" : "CAST(#{sql_point(value)}, 'Nullable(Point)')"
    when 'tuple_string_point'
      "CAST(tuple(#{sql_string(value.fetch(0))}, #{sql_point(value.fetch(1))}), 'Tuple(label String, point Point)')"
    when 'map_string_point'
      pairs = value.flat_map { |key, point| [sql_string(key), sql_point(point)] }
      "CAST(map(#{pairs.join(', ')}), 'Map(String, Point)')"
    when 'nested_point_line'
      tuples = value.map do |point, line|
        line_value = sql_custom_array('LineString', line.map { |item| sql_point(item) })
        "tuple(#{sql_point(point)}, #{line_value})"
      end
      "CAST(#{sql_array(tuples)}, 'Nested(point Point, line LineString)')"
    when 'variant_point_string'
      if value.nil?
        "CAST(NULL, 'Variant(Point, String)')"
      elsif value.fetch('arm') == 'Point'
        "CAST(#{sql_point(value.fetch('value'))}, 'Variant(Point, String)')"
      else
        "CAST(#{sql_string(value.fetch('value'))}, 'Variant(Point, String)')"
      end
    else
      fail!("unlisted SQL fixture kind #{profile.fetch('kind').inspect}")
    end
  end

  def source_refusal_cases
    [
      { 'id' => 'nullable_multipoint', 'type' => 'Nullable(MultiPoint)', 'diagnostic' => /Nullable|MultiPoint/i },
      { 'id' => 'low_cardinality_point', 'type' => 'LowCardinality(Point)', 'diagnostic' => /LowCardinality|Point/i },
      { 'id' => 'low_cardinality_nullable_point', 'type' => 'LowCardinality(Nullable(Point))', 'diagnostic' => /LowCardinality|Nullable|Point/i },
      { 'id' => 'low_cardinality_multipolygon', 'type' => 'LowCardinality(MultiPolygon)', 'diagnostic' => /LowCardinality|MultiPolygon/i },
      { 'id' => 'unknown_custom_geo', 'type' => 'CustomGeoW238Unknown', 'diagnostic' => /Unknown|CustomGeoW238Unknown/i },
    ].freeze
  end
end

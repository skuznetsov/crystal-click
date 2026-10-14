require "../../src/crystal_click"

module CompactPartWriterW280Fixture
  extend self

  KEY_NAME      = "pk"
  COLUMN_NAME   = "recursive_json_w280"
  ROWS_PER_MARK =    2
  ROW_COUNT     =    8
  MARK_COUNT    =    4
  FRAME_BYTES   = 4096

  CASES = [
    :array_json,
    :sibling_arrays,
    :four_sibling_objects,
    :nested_five_sites,
    :positional_uint8,
  ] of Symbol

  def keys : Slice(UInt64)
    Slice(UInt64).new(ROW_COUNT) { |index| index.to_u64 + 1_u64 }
  end

  def uint8_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt8")
  end

  def uint64_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.primitive("UInt64")
  end

  def array_uint8_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.array(uint8_type)
  end

  def json_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.json(
      max_dynamic_paths: 0,
      max_dynamic_types: 0,
      typed_paths: {"id" => uint64_type} of String => CrystalClick::BinaryDataType,
    )
  end

  def json_declaration : String
    json_type.name
  end

  def schema(case_name : Symbol) : CrystalClick::StorageColumnSchema
    declaration = case case_name
                  when :array_json
                    "Array(#{json_declaration})"
                  when :sibling_arrays
                    "Tuple(Array(#{json_declaration}), Array(#{json_declaration}))"
                  when :four_sibling_objects
                    "Tuple(Tuple(#{json_declaration}, #{json_declaration}), Tuple(#{json_declaration}, #{json_declaration}))"
                  when :nested_five_sites
                    nested = "Array(Tuple(Array(#{json_declaration}), UInt8, #{json_declaration}))"
                    "Tuple(#{nested}, #{nested}, #{json_declaration})"
                  when :positional_uint8
                    "Tuple(UInt8, #{json_declaration}, Array(UInt8), UInt8, #{json_declaration}, Array(#{json_declaration}), UInt8)"
                  else
                    raise ArgumentError.new("unknown W280 schema case: #{case_name}")
                  end
    CrystalClick::CompactJsonColumnAdapter.schema_for_json_declaration(declaration) ||
      raise CrystalClick::UnsupportedFormatError.new("W280 fixture declaration is not admitted by the schema parser")
  end

  # Paths are literal schema-tree identities and intentionally do not come
  # from CompactRecursiveJsonSchemaPlan: they are the independent DFS oracle.
  def json_site_keys(case_name : Symbol) : Array(String)
    case case_name
    when :array_json
      ["root/array[0]"] of String
    when :sibling_arrays
      ["root/tuple[0]/array[0]", "root/tuple[1]/array[0]"] of String
    when :four_sibling_objects
      [
        "root/tuple[0]/tuple[0]",
        "root/tuple[0]/tuple[1]",
        "root/tuple[1]/tuple[0]",
        "root/tuple[1]/tuple[1]",
      ] of String
    when :nested_five_sites
      [
        "root/tuple[0]/array[0]/tuple[0]/array[0]",
        "root/tuple[0]/array[0]/tuple[2]",
        "root/tuple[1]/array[0]/tuple[0]/array[0]",
        "root/tuple[1]/array[0]/tuple[2]",
        "root/tuple[2]",
      ] of String
    when :positional_uint8
      [
        "root/tuple[1]",
        "root/tuple[4]",
        "root/tuple[5]/array[0]",
      ] of String
    else
      raise ArgumentError.new("unknown W280 JSON-site case: #{case_name}")
    end
  end

  def array_site_keys(case_name : Symbol) : Array(String)
    case case_name
    when :array_json
      ["root"] of String
    when :sibling_arrays
      ["root/tuple[0]", "root/tuple[1]"] of String
    when :four_sibling_objects
      [] of String
    when :nested_five_sites
      [
        "root/tuple[0]",
        "root/tuple[0]/array[0]/tuple[0]",
        "root/tuple[1]",
        "root/tuple[1]/array[0]/tuple[0]",
      ] of String
    when :positional_uint8
      ["root/tuple[5]"] of String
    else
      raise ArgumentError.new("unknown W280 Array-site case: #{case_name}")
    end
  end

  def uint8_site_keys(case_name : Symbol) : Array(String)
    case case_name
    when :array_json, :sibling_arrays, :four_sibling_objects
      [] of String
    when :nested_five_sites
      [
        "root/tuple[0]/array[0]/tuple[1]",
        "root/tuple[1]/array[0]/tuple[1]",
      ] of String
    when :positional_uint8
      [
        "root/tuple[0]",
        "root/tuple[3]",
        "root/tuple[6]",
      ] of String
    else
      raise ArgumentError.new("unknown W280 UInt8-site case: #{case_name}")
    end
  end

  # JSON-free compound Bulk subtrees are deliberately retained as opaque sites;
  # direct UInt8 leaves keep their existing dedicated-site ownership.
  def bulk_site_keys(case_name : Symbol) : Array(String)
    case case_name
    when :array_json, :sibling_arrays, :four_sibling_objects, :nested_five_sites
      [] of String
    when :positional_uint8
      ["root/tuple[2]"] of String
    else
      raise ArgumentError.new("unknown W280 Bulk-site case: #{case_name}")
    end
  end

  # This token stream is the literal DFS witness for post-prefix callbacks.
  # Structural Array nodes emit size before descending; opaque Bulk Array
  # sites retain their own size-then-data role order at the site boundary.
  # Direct UInt8 lanes and Object bodies retain schema-relative order.
  def body_dfs(case_name : Symbol) : Array(Tuple(Symbol, String))
    case case_name
    when :array_json
      [
        {:array, "root"},
        {:json, "root/array[0]"},
      ] of Tuple(Symbol, String)
    when :sibling_arrays
      [
        {:array, "root/tuple[0]"},
        {:json, "root/tuple[0]/array[0]"},
        {:array, "root/tuple[1]"},
        {:json, "root/tuple[1]/array[0]"},
      ] of Tuple(Symbol, String)
    when :four_sibling_objects
      [
        {:json, "root/tuple[0]/tuple[0]"},
        {:json, "root/tuple[0]/tuple[1]"},
        {:json, "root/tuple[1]/tuple[0]"},
        {:json, "root/tuple[1]/tuple[1]"},
      ] of Tuple(Symbol, String)
    when :nested_five_sites
      [
        {:array, "root/tuple[0]"},
        {:array, "root/tuple[0]/array[0]/tuple[0]"},
        {:json, "root/tuple[0]/array[0]/tuple[0]/array[0]"},
        {:uint8, "root/tuple[0]/array[0]/tuple[1]"},
        {:json, "root/tuple[0]/array[0]/tuple[2]"},
        {:array, "root/tuple[1]"},
        {:array, "root/tuple[1]/array[0]/tuple[0]"},
        {:json, "root/tuple[1]/array[0]/tuple[0]/array[0]"},
        {:uint8, "root/tuple[1]/array[0]/tuple[1]"},
        {:json, "root/tuple[1]/array[0]/tuple[2]"},
        {:json, "root/tuple[2]"},
      ] of Tuple(Symbol, String)
    when :positional_uint8
      [
        {:uint8, "root/tuple[0]"},
        {:json, "root/tuple[1]"},
        {:bulk_size, "root/tuple[2]"},
        {:bulk_data, "root/tuple[2]"},
        {:uint8, "root/tuple[3]"},
        {:json, "root/tuple[4]"},
        {:array, "root/tuple[5]"},
        {:json, "root/tuple[5]/array[0]"},
        {:uint8, "root/tuple[6]"},
      ] of Tuple(Symbol, String)
    else
      raise ArgumentError.new("unknown W280 body-order case: #{case_name}")
    end
  end

  def rows(case_name : Symbol) : Array(CrystalClick::StorageColumnValue)
    case case_name
    when :array_json
      [
        array_json([1_u64, 2_u64]), array_json([] of UInt64),
        array_json([3_u64]), array_json([4_u64, 5_u64]),
        array_json([] of UInt64), array_json([6_u64]),
        array_json([] of UInt64), array_json([7_u64, 8_u64]),
      ] of CrystalClick::StorageColumnValue
    when :sibling_arrays
      [
        tuple([array_json([11_u64, 12_u64]), array_json([101_u64])]),
        tuple([array_json([] of UInt64), array_json([102_u64, 103_u64])]),
        tuple([array_json([13_u64]), array_json([] of UInt64)]),
        tuple([array_json([14_u64, 15_u64]), array_json([104_u64])]),
        tuple([array_json([] of UInt64), array_json([105_u64, 106_u64])]),
        tuple([array_json([16_u64]), array_json([107_u64])]),
        tuple([array_json([17_u64, 18_u64]), array_json([] of UInt64)]),
        tuple([array_json([] of UInt64), array_json([108_u64])]),
      ] of CrystalClick::StorageColumnValue
    when :four_sibling_objects
      [
        pair_of_pairs(1_u64, 101_u64, 2_u64, 102_u64),
        pair_of_pairs(3_u64, 103_u64, 4_u64, 104_u64),
        pair_of_pairs(5_u64, 105_u64, 6_u64, 106_u64),
        pair_of_pairs(7_u64, 107_u64, 8_u64, 108_u64),
        pair_of_pairs(9_u64, 109_u64, 10_u64, 110_u64),
        pair_of_pairs(11_u64, 111_u64, 12_u64, 112_u64),
        pair_of_pairs(13_u64, 113_u64, 14_u64, 114_u64),
        pair_of_pairs(15_u64, 115_u64, 16_u64, 116_u64),
      ] of CrystalClick::StorageColumnValue
    when :nested_five_sites
      [
        nested_row(
          [{[201_u64, 202_u64], 1_u8, 301_u64}, {[] of UInt64, 2_u8, 302_u64}],
          [{[401_u64], 3_u8, 501_u64}],
          601_u64,
        ),
        nested_row([] of Tuple(Array(UInt64), UInt8, UInt64), [{[402_u64, 403_u64], 4_u8, 502_u64}], 602_u64),
        nested_row([{[203_u64], 5_u8, 303_u64}], [] of Tuple(Array(UInt64), UInt8, UInt64), 603_u64),
        nested_row([{[] of UInt64, 6_u8, 304_u64}], [{[] of UInt64, 7_u8, 503_u64}, {[404_u64], 8_u8, 504_u64}], 604_u64),
        nested_row([] of Tuple(Array(UInt64), UInt8, UInt64), [] of Tuple(Array(UInt64), UInt8, UInt64), 605_u64),
        nested_row([{[204_u64, 205_u64], 9_u8, 305_u64}], [{[405_u64], 10_u8, 505_u64}], 606_u64),
        nested_row([{[206_u64], 11_u8, 306_u64}], [] of Tuple(Array(UInt64), UInt8, UInt64), 607_u64),
        nested_row([] of Tuple(Array(UInt64), UInt8, UInt64), [{[] of UInt64, 12_u8, 506_u64}], 608_u64),
      ] of CrystalClick::StorageColumnValue
    when :positional_uint8
      [
        positional_row(1_u8, 11_u64, [2_u8, 3_u8], 4_u8, 21_u64, [31_u64, 32_u64], 5_u8),
        positional_row(2_u8, 12_u64, [] of UInt8, 5_u8, 22_u64, [] of UInt64, 6_u8),
        positional_row(3_u8, 13_u64, [4_u8], 6_u8, 23_u64, [33_u64], 7_u8),
        positional_row(4_u8, 14_u64, [5_u8, 6_u8], 7_u8, 24_u64, [34_u64, 35_u64], 8_u8),
        positional_row(5_u8, 15_u64, [] of UInt8, 8_u8, 25_u64, [] of UInt64, 9_u8),
        positional_row(6_u8, 16_u64, [7_u8], 9_u8, 26_u64, [36_u64], 10_u8),
        positional_row(7_u8, 17_u64, [8_u8, 9_u8], 10_u8, 27_u64, [37_u64, 38_u64], 11_u8),
        positional_row(8_u8, 18_u64, [] of UInt8, 11_u8, 28_u64, [] of UInt64, 12_u8),
      ] of CrystalClick::StorageColumnValue
    else
      raise ArgumentError.new("unknown W280 rows case: #{case_name}")
    end
  end

  # Independent scalar/tree spellings used for writer-to-reader comparison.
  def expected_signatures(case_name : Symbol) : Array(String)
    case case_name
    when :array_json
      ["A[J1,J2]", "A[]", "A[J3]", "A[J4,J5]", "A[]", "A[J6]", "A[]", "A[J7,J8]"] of String
    when :sibling_arrays
      [
        "T(A[J11,J12],A[J101])", "T(A[],A[J102,J103])",
        "T(A[J13],A[])", "T(A[J14,J15],A[J104])",
        "T(A[],A[J105,J106])", "T(A[J16],A[J107])",
        "T(A[J17,J18],A[])", "T(A[],A[J108])",
      ] of String
    when :four_sibling_objects
      [
        "T(T(J1,J101),T(J2,J102))", "T(T(J3,J103),T(J4,J104))",
        "T(T(J5,J105),T(J6,J106))", "T(T(J7,J107),T(J8,J108))",
        "T(T(J9,J109),T(J10,J110))", "T(T(J11,J111),T(J12,J112))",
        "T(T(J13,J113),T(J14,J114))", "T(T(J15,J115),T(J16,J116))",
      ] of String
    when :nested_five_sites
      [
        "T(A[T(A[J201,J202],U1,J301),T(A[],U2,J302)],A[T(A[J401],U3,J501)],J601)",
        "T(A[],A[T(A[J402,J403],U4,J502)],J602)",
        "T(A[T(A[J203],U5,J303)],A[],J603)",
        "T(A[T(A[],U6,J304)],A[T(A[],U7,J503),T(A[J404],U8,J504)],J604)",
        "T(A[],A[],J605)",
        "T(A[T(A[J204,J205],U9,J305)],A[T(A[J405],U10,J505)],J606)",
        "T(A[T(A[J206],U11,J306)],A[],J607)",
        "T(A[],A[T(A[],U12,J506)],J608)",
      ] of String
    when :positional_uint8
      [
        "T(U1,J11,A[U2,U3],U4,J21,A[J31,J32],U5)",
        "T(U2,J12,A[],U5,J22,A[],U6)",
        "T(U3,J13,A[U4],U6,J23,A[J33],U7)",
        "T(U4,J14,A[U5,U6],U7,J24,A[J34,J35],U8)",
        "T(U5,J15,A[],U8,J25,A[],U9)",
        "T(U6,J16,A[U7],U9,J26,A[J36],U10)",
        "T(U7,J17,A[U8,U9],U10,J27,A[J37,J38],U11)",
        "T(U8,J18,A[],U11,J28,A[],U12)",
      ] of String
    else
      raise ArgumentError.new("unknown W280 expected-signature case: #{case_name}")
    end
  end

  def signature(value : CrystalClick::StorageColumnValue) : String
    case value.kind
    when CrystalClick::StorageColumnValue::OBJECT
      "J#{value.object_document.value_for("id").as_uint64}"
    when CrystalClick::StorageColumnValue::ARRAY
      "A[#{value.array_values.map { |child| signature(child) }.join(",")}]"
    when CrystalClick::StorageColumnValue::TUPLE
      "T(#{value.tuple_values.map { |child| signature(child) }.join(",")})"
    when CrystalClick::StorageColumnValue::BULK
      bulk = value.bulk_value
      if bulk.type.tag == CrystalClick::BinaryDataType::TAG_ARRAY &&
         bulk.type.child_at(0).tag == CrystalClick::BinaryDataType::TAG_UINT8
        "A[#{bulk.elements.map { |child| "U#{child.bytes[0]}" }.join(",")}]"
      elsif bulk.type.tag == CrystalClick::BinaryDataType::TAG_UINT8
        "U#{bulk.bytes[0]}"
      else
        raise ArgumentError.new("W280 signature observed an unsupported Bulk leaf")
      end
    else
      raise ArgumentError.new("W280 signature observed an unknown storage value node")
    end
  end

  def column(case_name : Symbol) : CrystalClick::CompactPartColumn
    schema = schema(case_name)
    plans = Hash(String, CrystalClick::ObjectDocumentPlan).new
    json_site_keys(case_name).each { |site| plans[site] = object_plan }
    granules = rows(case_name).each_slice(ROWS_PER_MARK).map(&.to_a).to_a
    CrystalClick::CompactPartColumn.json(
      COLUMN_NAME,
      schema,
      granules,
      CrystalClick::CompactJsonWriteContext.new(plans),
    )
  end

  private def object_plan : CrystalClick::ObjectDocumentPlan
    object = CrystalClick::ObjectStructure.new(
      [] of String,
      version: 4_u64,
      shared_data_version: 0_u64,
      bucket_count: 1_u64,
      statistics: CrystalClick::StructureStatistics.new(
        [] of UInt64,
        [] of CrystalClick::StructureStatistic,
      ),
    )
    structures = CrystalClick::ObjectDynamicStructureSet.new(
      object,
      Hash(String, CrystalClick::DynamicStructure).new,
    )
    CrystalClick::ObjectDocumentPlan.new(
      structures,
      json_type.json_type.not_nil!.typed_paths,
    )
  end

  private def json_value(id : UInt64) : CrystalClick::StorageColumnValue
    CrystalClick::StorageColumnValue.object_document(
      CrystalClick::ObjectDocument.new(
        {"id" => CrystalClick::BinaryValue.uint64(id)} of String => CrystalClick::BinaryValue,
      ),
    )
  end

  private def array_json(ids : Array(UInt64)) : CrystalClick::StorageColumnValue
    CrystalClick::StorageColumnValue.array(ids.map { |id| json_value(id) }.to_a)
  end

  private def array_uint8(values : Array(UInt8)) : CrystalClick::StorageColumnValue
    binary_values = values.map do |value|
      CrystalClick::BinaryValue.fixed(uint8_type, Bytes[value])
    end.to_a
    CrystalClick::StorageColumnValue.bulk(
      CrystalClick::BinaryValue.array(array_uint8_type, binary_values),
    )
  end

  private def uint8_value(value : UInt8) : CrystalClick::StorageColumnValue
    CrystalClick::StorageColumnValue.bulk(
      CrystalClick::BinaryValue.fixed(uint8_type, Bytes[value]),
    )
  end

  private def tuple(values : Array(CrystalClick::StorageColumnValue)) : CrystalClick::StorageColumnValue
    CrystalClick::StorageColumnValue.tuple(values)
  end

  private def pair_of_pairs(a : UInt64, b : UInt64, c : UInt64, d : UInt64) : CrystalClick::StorageColumnValue
    tuple([
      tuple([json_value(a), json_value(b)] of CrystalClick::StorageColumnValue),
      tuple([json_value(c), json_value(d)] of CrystalClick::StorageColumnValue),
    ] of CrystalClick::StorageColumnValue)
  end

  private def nested_item(
    children : Array(UInt64),
    tag : UInt8,
    audit_id : UInt64,
  ) : CrystalClick::StorageColumnValue
    tuple([
      array_json(children),
      uint8_value(tag),
      json_value(audit_id),
    ] of CrystalClick::StorageColumnValue)
  end

  private def nested_row(
    left : Array(Tuple(Array(UInt64), UInt8, UInt64)),
    right : Array(Tuple(Array(UInt64), UInt8, UInt64)),
    audit_id : UInt64,
  ) : CrystalClick::StorageColumnValue
    left_values = left.map { |entry| nested_item(entry[0], entry[1], entry[2]) }.to_a
    right_values = right.map { |entry| nested_item(entry[0], entry[1], entry[2]) }.to_a
    tuple([
      CrystalClick::StorageColumnValue.array(left_values),
      CrystalClick::StorageColumnValue.array(right_values),
      json_value(audit_id),
    ] of CrystalClick::StorageColumnValue)
  end

  private def positional_row(
    before : UInt8,
    first_json : UInt64,
    ordinary_array : Array(UInt8),
    between : UInt8,
    second_json : UInt64,
    json_array : Array(UInt64),
    after : UInt8,
  ) : CrystalClick::StorageColumnValue
    tuple([
      uint8_value(before),
      json_value(first_json),
      array_uint8(ordinary_array),
      uint8_value(between),
      json_value(second_json),
      array_json(json_array),
      uint8_value(after),
    ] of CrystalClick::StorageColumnValue)
  end
end

require "../../src/crystal_click"
require "digest/sha256"
require "json"

module MultiColumnTupleDynamicW246Fixture
  extend self

  FORMAT                = "multi_column_tuple_dynamic_w246_fixture_v1"
  KEY_NAME              = "pk"
  NAMED_NAME            = "named_tuple"
  UNNAMED_NAME          = "unnamed_tuple"
  FRAME_BYTES           = 32
  ROWS_PER_MARK         =  2
  KEYS                  = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
  MARK_ROW_COUNTS       = [2_u64, 2_u64, 1_u64]
  ACTUAL_BULK_MODE_NAME = "basic"

  alias Columns = Array(CrystalClick::WidePartColumn)

  def profile(name : String) : CrystalClick::BinaryBulkProfile
    case name
    when "single"
      CrystalClick::BinaryBulkProfile.single_stream
    when "sized"
      CrystalClick::BinaryBulkProfile.with_size_stream
    else
      raise ArgumentError.new("W246 String profile must be single or sized")
    end
  end

  def operation_mode(name : String) : UInt64
    case name
    when "basic"
      CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE
    when "compact"
      CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE
    else
      raise ArgumentError.new("W246 requested operation mode must be basic or compact")
    end
  end

  def named_type : CrystalClick::BinaryDataType
    dynamic = dynamic_type
    CrystalClick::BinaryDataType.tuple(
      [dynamic, CrystalClick::BinaryDataType.array(dynamic)] of CrystalClick::BinaryDataType,
      ["sequence", "items"] of String,
    )
  end

  def unnamed_type : CrystalClick::BinaryDataType
    dynamic = dynamic_type
    CrystalClick::BinaryDataType.tuple(
      [dynamic, dynamic] of CrystalClick::BinaryDataType,
    )
  end

  def named_structures : Hash(String, CrystalClick::DynamicStructure)
    {
      "root.field.0" => CrystalClick::DynamicStructure.new(
        [CrystalClick::BinaryDataType.primitive("UInt64")] of CrystalClick::BinaryDataType
      ),
      "root.field.1.elements" => CrystalClick::DynamicStructure.new(
        [CrystalClick::BinaryDataType.primitive("String")] of CrystalClick::BinaryDataType
      ),
    } of String => CrystalClick::DynamicStructure
  end

  def unnamed_structures : Hash(String, CrystalClick::DynamicStructure)
    {
      "root.field.0" => CrystalClick::DynamicStructure.new(
        [CrystalClick::BinaryDataType.primitive("Bool")] of CrystalClick::BinaryDataType
      ),
      "root.field.1" => CrystalClick::DynamicStructure.new(
        [CrystalClick::BinaryDataType.primitive("UInt32")] of CrystalClick::BinaryDataType
      ),
    } of String => CrystalClick::DynamicStructure
  end

  def named_rows : Array(CrystalClick::BinaryValue)
    tuple = named_type
    sequence = tuple.child_at(0)
    items = tuple.child_at(1)
    item_dynamic = items.child_at(0)
    uint8 = CrystalClick::BinaryDataType.primitive("UInt8")

    [
      tuple_value(tuple,
        dynamic_value(sequence, CrystalClick::BinaryValue.uint64(7_u64)),
        array_value(items, [] of CrystalClick::BinaryValue)),
      tuple_value(tuple,
        dynamic_value(sequence),
        array_value(items, [] of CrystalClick::BinaryValue)),
      tuple_value(tuple,
        dynamic_value(sequence, CrystalClick::BinaryValue.uint64(42_u64)),
        array_value(items, [
          dynamic_value(item_dynamic, CrystalClick::BinaryValue.string("array-dedicated")),
          dynamic_value(item_dynamic, fixed_unsigned(uint8, 9_u64)),
          dynamic_value(item_dynamic),
        ] of CrystalClick::BinaryValue)),
      tuple_value(tuple,
        dynamic_value(sequence, CrystalClick::BinaryValue.string("sequence-overflow")),
        array_value(items, [dynamic_value(item_dynamic, CrystalClick::BinaryValue.uint64(99_u64))] of CrystalClick::BinaryValue)),
      tuple_value(tuple,
        dynamic_value(sequence, CrystalClick::BinaryValue.string("sequence-overflow-tail")),
        array_value(items, [
          dynamic_value(item_dynamic, CrystalClick::BinaryValue.string("array-dedicated-tail")),
          dynamic_value(item_dynamic),
        ] of CrystalClick::BinaryValue)),
    ] of CrystalClick::BinaryValue
  end

  def unnamed_rows : Array(CrystalClick::BinaryValue)
    tuple = unnamed_type
    first = tuple.child_at(0)
    second = tuple.child_at(1)
    uint32 = CrystalClick::BinaryDataType.primitive("UInt32")

    [
      tuple_value(tuple,
        dynamic_value(first, CrystalClick::BinaryValue.bool(true)),
        dynamic_value(second, fixed_unsigned(uint32, 10_u64))),
      tuple_value(tuple,
        dynamic_value(first, CrystalClick::BinaryValue.string("left-overflow")),
        dynamic_value(second, CrystalClick::BinaryValue.uint64(20_u64))),
      tuple_value(tuple,
        dynamic_value(first),
        dynamic_value(second, fixed_unsigned(uint32, 42_u64))),
      tuple_value(tuple,
        dynamic_value(first, CrystalClick::BinaryValue.bool(false)),
        dynamic_value(second)),
      tuple_value(tuple,
        dynamic_value(first, CrystalClick::BinaryValue.string("left-overflow-tail")),
        dynamic_value(second, CrystalClick::BinaryValue.uint64(100_u64))),
    ] of CrystalClick::BinaryValue
  end

  def named_granules : Array(Array(CrystalClick::BinaryValue))
    split_marks(named_rows)
  end

  def unnamed_granules : Array(Array(CrystalClick::BinaryValue))
    split_marks(unnamed_rows)
  end

  def multi_columns : Columns
    [
      CrystalClick::WidePartColumn.dynamic_bulk(
        NAMED_NAME, named_type, named_structures, named_granules
      ),
      CrystalClick::WidePartColumn.dynamic_bulk(
        UNNAMED_NAME, unnamed_type, unnamed_structures, unnamed_granules
      ),
    ] of CrystalClick::WidePartColumn
  end

  def column_declarations : Array(Hash(String, JSON::Any))
    [
      {
        "name"       => json(NAMED_NAME),
        "type"       => json(named_type.name),
        "tuple_kind" => json("named"),
        "fields"     => JSON::Any.new([
          field("sequence", "Dynamic(max_types=1)", "root.field.0", ["UInt64"] of String),
          field("items", "Array(Dynamic(max_types=1))", "root.field.1.elements", ["String"] of String),
        ] of JSON::Any),
      } of String => JSON::Any,
      {
        "name"       => json(UNNAMED_NAME),
        "type"       => json(unnamed_type.name),
        "tuple_kind" => json("unnamed"),
        "fields"     => JSON::Any.new([
          field(nil, "Dynamic(max_types=1)", "root.field.0", ["Bool"] of String),
          field(nil, "Dynamic(max_types=1)", "root.field.1", ["UInt32"] of String),
        ] of JSON::Any),
      } of String => JSON::Any,
    ] of Hash(String, JSON::Any)
  end

  # This manifest is descriptive data for a separately implemented native
  # oracle. It does not turn the library's own round trip into qualification.
  def manifest(
    part_path : String,
    string_profile_name : String,
    requested_operation_mode : String,
    write_mode : String,
  ) : Hash(String, JSON::Any)
    row_roster = expected_rows(write_mode)
    {
      "format"                         => json(FORMAT),
      "status"                         => json("part_created"),
      "part_path"                      => json(part_path),
      "write_mode"                     => json(write_mode),
      "requested_string_profile"       => json(string_profile_name),
      "requested_operation_mode"       => json(requested_operation_mode),
      "actual_bulk_discriminator_mode" => json(ACTUAL_BULK_MODE_NAME),
      "frame_bytes"                    => json(FRAME_BYTES.to_i64),
      "rows_per_mark"                  => json(ROWS_PER_MARK.to_i64),
      "key_column"                     => JSON::Any.new({
        "name" => json(KEY_NAME),
        "type" => json("UInt64"),
      } of String => JSON::Any),
      "columns" => JSON::Any.new(
        (write_mode == "legacy" ? [column_declarations[0]] : column_declarations).map do |column|
          JSON::Any.new(column)
        end
      ),
      "keys"            => JSON::Any.new(KEYS.map { |key| json(key.to_i64) }),
      "mark_row_counts" => JSON::Any.new(MARK_ROW_COUNTS.map { |rows| json(rows.to_i64) }),
      "rows"            => JSON::Any.new(row_roster),
      "serialization"   => JSON.parse(File.read(File.join(part_path, "serialization.json"))),
      "files"           => JSON::Any.new(file_inventory(part_path)),
    } of String => JSON::Any
  end

  def expected_rows(write_mode : String = "multi") : Array(JSON::Any)
    named = [
      JSON::Any.new({
        "sequence" => dynamic_json("UInt64", "dedicated", json(7_i64)),
        "items"    => JSON::Any.new([] of JSON::Any),
      } of String => JSON::Any),
      JSON::Any.new({
        "sequence" => dynamic_json(nil, "null", JSON::Any.new(nil)),
        "items"    => JSON::Any.new([] of JSON::Any),
      } of String => JSON::Any),
      JSON::Any.new({
        "sequence" => dynamic_json("UInt64", "dedicated", json(42_i64)),
        "items"    => JSON::Any.new([
          dynamic_json("String", "dedicated", json("array-dedicated")),
          dynamic_json("UInt8", "shared", json(9_i64)),
          dynamic_json(nil, "null", JSON::Any.new(nil)),
        ] of JSON::Any),
      } of String => JSON::Any),
      JSON::Any.new({
        "sequence" => dynamic_json("String", "shared", json("sequence-overflow")),
        "items"    => JSON::Any.new([
          dynamic_json("UInt64", "shared", json(99_i64)),
        ] of JSON::Any),
      } of String => JSON::Any),
      JSON::Any.new({
        "sequence" => dynamic_json("String", "shared", json("sequence-overflow-tail")),
        "items"    => JSON::Any.new([
          dynamic_json("String", "dedicated", json("array-dedicated-tail")),
          dynamic_json(nil, "null", JSON::Any.new(nil)),
        ] of JSON::Any),
      } of String => JSON::Any),
    ] of JSON::Any
    unnamed = [
      JSON::Any.new([
        dynamic_json("Bool", "dedicated", json(true)),
        dynamic_json("UInt32", "dedicated", json(10_i64)),
      ] of JSON::Any),
      JSON::Any.new([
        dynamic_json("String", "shared", json("left-overflow")),
        dynamic_json("UInt64", "shared", json(20_i64)),
      ] of JSON::Any),
      JSON::Any.new([
        dynamic_json(nil, "null", JSON::Any.new(nil)),
        dynamic_json("UInt32", "dedicated", json(42_i64)),
      ] of JSON::Any),
      JSON::Any.new([
        dynamic_json("Bool", "dedicated", json(false)),
        dynamic_json(nil, "null", JSON::Any.new(nil)),
      ] of JSON::Any),
      JSON::Any.new([
        dynamic_json("String", "shared", json("left-overflow-tail")),
        dynamic_json("UInt64", "shared", json(100_i64)),
      ] of JSON::Any),
    ] of JSON::Any

    Array(JSON::Any).new(KEYS.size) do |index|
      values = {
        "pk"       => json(KEYS[index].to_i64),
        NAMED_NAME => named[index],
      } of String => JSON::Any
      values[UNNAMED_NAME] = unnamed[index] if write_mode == "multi"
      JSON::Any.new(values)
    end
  end

  def file_inventory(part_path : String) : Array(JSON::Any)
    Dir.children(part_path).sort.map do |name|
      path = File.join(part_path, name)
      unless !File.symlink?(path) && File.file?(path) && File.info(path).file?
        raise CrystalClick::CorruptPartError.new("W246 generated part contains a non-regular file")
      end
      JSON::Any.new({
        "path"   => json(name),
        "size"   => json(File.size(path).to_i64),
        "sha256" => json(Digest::SHA256.hexdigest(File.read(path))),
      } of String => JSON::Any)
    end
  end

  private def dynamic_type : CrystalClick::BinaryDataType
    CrystalClick::BinaryDataType.dynamic(max_types: 1)
  end

  private def tuple_value(
    type : CrystalClick::BinaryDataType,
    first : CrystalClick::BinaryValue,
    second : CrystalClick::BinaryValue,
  ) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.tuple(type, [first, second] of CrystalClick::BinaryValue)
  end

  private def dynamic_value(
    type : CrystalClick::BinaryDataType,
    child : CrystalClick::BinaryValue? = nil,
  ) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.dynamic(type, child)
  end

  private def array_value(
    type : CrystalClick::BinaryDataType,
    elements : Array(CrystalClick::BinaryValue),
  ) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.array(type, elements)
  end

  private def split_marks(
    rows : Array(CrystalClick::BinaryValue),
  ) : Array(Array(CrystalClick::BinaryValue))
    [
      rows[0, 2],
      rows[2, 2],
      rows[4, 1],
    ] of Array(CrystalClick::BinaryValue)
  end

  private def fixed_unsigned(
    type : CrystalClick::BinaryDataType,
    value : UInt64,
  ) : CrystalClick::BinaryValue
    width = type.fixed_width || raise ArgumentError.new("W246 unsigned fixture type is not fixed-width")
    bytes = Bytes.new(width) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
    CrystalClick::BinaryValue.fixed(type, bytes)
  end

  private def field(
    name : String?,
    type : String,
    dynamic_site : String,
    registered_actual_types : Array(String),
  ) : JSON::Any
    JSON::Any.new({
      "name"                    => name ? json(name) : JSON::Any.new(nil),
      "type"                    => json(type),
      "dynamic_site"            => json(dynamic_site),
      "registered_actual_types" => JSON::Any.new(registered_actual_types.map { |actual| json(actual) }),
    } of String => JSON::Any)
  end

  private def dynamic_json(
    actual_type : String?,
    storage : String,
    value : JSON::Any,
  ) : JSON::Any
    JSON::Any.new({
      "actual_type" => actual_type ? json(actual_type) : JSON::Any.new(nil),
      "storage"     => json(storage),
      "value"       => value,
    } of String => JSON::Any)
  end

  private def json(value : String) : JSON::Any
    JSON::Any.new(value)
  end

  private def json(value : Int64) : JSON::Any
    JSON::Any.new(value)
  end

  private def json(value : Bool) : JSON::Any
    JSON::Any.new(value)
  end
end

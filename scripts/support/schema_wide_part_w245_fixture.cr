require "../../src/crystal_click"
require "digest/sha256"
require "json"

module SchemaWidePartW245Fixture
  extend self

  FORMAT          = "schema_wide_part_w245_fixture_v1"
  FRAME_BYTES     = 32
  ROWS_PER_MARK   =  2
  KEY_NAME        = "pk"
  KEYS            = [1_u64, 2_u64, 3_u64, 4_u64, 5_u64]
  MARK_ROW_COUNTS = [2_u64, 2_u64, 1_u64]

  STATE_NAME     = "state"
  DYNAMIC_NAME   = "dyn"
  OBJECT_NAME    = "object"
  RECURSIVE_NAME = "recursive"

  STATE_DECLARATION     = "Tuple(label LowCardinality(String), total AggregateFunction(sum, UInt8))"
  DYNAMIC_DECLARATION   = "Dynamic(max_types=1)"
  OBJECT_DECLARATION    = "JSON(max_dynamic_types=1, max_dynamic_paths=1, label String)"
  RECURSIVE_DECLARATION = "Array(Tuple(doc JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8), sample Dynamic(max_types=1)))"

  alias Columns = Array(CrystalClick::WidePartColumn)

  def profile(name : String) : CrystalClick::BinaryBulkProfile
    case name
    when "single"
      CrystalClick::BinaryBulkProfile.single_stream
    when "sized"
      CrystalClick::BinaryBulkProfile.with_size_stream
    else
      raise ArgumentError.new("W245 String profile must be single or sized")
    end
  end

  def mode(name : String) : UInt64
    case name
    when "basic"
      CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE
    when "compact"
      CrystalClick::DynamicDiscriminatorCodec::COMPACT_MODE
    else
      raise ArgumentError.new("W245 Dynamic mode must be basic or compact")
    end
  end

  def columns(profile : CrystalClick::BinaryBulkProfile, mode : UInt64) : Columns
    state_descriptor = state_type
    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 1)
    object_schema = CrystalClick::ObjectDocumentSchema.parse_declaration(OBJECT_DECLARATION)
    recursive_schema = CrystalClick::StorageColumnSchema.parse(RECURSIVE_DECLARATION)
    recursive_object_schema = CrystalClick::ObjectDocumentSchema.parse_declaration(
      "JSON(max_dynamic_types=1, max_dynamic_paths=1, t UInt8)"
    )

    state_granules = Array(Array(CrystalClick::BinaryValue)).new(3) do |mark|
      start = mark == 0 ? 0 : mark == 1 ? 2 : 4
      count = mark == 2 ? 1 : 2
      Array(CrystalClick::BinaryValue).new(count) do |offset|
        row = start + offset
        label = ["red", "red", "blue", "red", "blue"][row]
        sum = [0_u64, 42_u64, 200_u64, 255_u64, 1000_u64][row]
        state_value(state_type, label, sum)
      end
    end

    dynamic_rows = [
      dynamic_value(dynamic_type, CrystalClick::BinaryValue.uint64(7_u64)),
      dynamic_value(dynamic_type, CrystalClick::BinaryValue.string("spill")),
      dynamic_value(dynamic_type),
      dynamic_value(dynamic_type, CrystalClick::BinaryValue.uint64(42_u64)),
      dynamic_value(dynamic_type, CrystalClick::BinaryValue.string("tail-spill")),
    ]
    dynamic_granules = split_marks(dynamic_rows)

    object_dynamic = CrystalClick::DynamicStructure.new(
      [CrystalClick::BinaryDataType.primitive("UInt64")] of CrystalClick::BinaryDataType
    )
    object_plan = CrystalClick::ObjectDocumentPlan.new(
      CrystalClick::ObjectDynamicStructureSet.new(
        CrystalClick::ObjectStructure.new(["shape"]),
        {"shape" => object_dynamic},
      ),
      object_schema.typed_paths,
    )
    object_shapes = [
      CrystalClick::BinaryValue.uint64(7_u64),
      CrystalClick::BinaryValue.string("spill"),
      CrystalClick::BinaryValue.null,
      CrystalClick::BinaryValue.uint64(42_u64),
      CrystalClick::BinaryValue.string("object-spill"),
    ]
    object_rows = Array(CrystalClick::ObjectDocument).new(5) do |index|
      CrystalClick::ObjectDocument.new({
        "label" => CrystalClick::BinaryValue.string("doc-#{index + 1}"),
        "shape" => object_shapes[index],
      })
    end
    object_granules = split_marks(object_rows)

    recursive_dynamic = CrystalClick::BinaryDynamicBulkPlan.new(
      dynamic_type,
      {"root" => CrystalClick::DynamicStructure.new(
        [CrystalClick::BinaryDataType.primitive("UInt64")] of CrystalClick::BinaryDataType
      )},
      profile,
    )
    recursive_object_plan = CrystalClick::ObjectDocumentPlan.new(
      CrystalClick::ObjectDynamicStructureSet.new(
        CrystalClick::ObjectStructure.new([] of String),
        {} of String => CrystalClick::DynamicStructure,
      ),
      recursive_object_schema.typed_paths,
    )
    recursive_object_plans = {
      "root/array[0]/tuple[0]" => recursive_object_plan,
    }
    recursive_dynamic_plans = {
      "root/array[0]/tuple[1]" => recursive_dynamic,
    }
    recursive_rows = recursive_rows(dynamic_type)
    recursive_granules = split_marks(recursive_rows)

    unless state_descriptor.name == STATE_DECLARATION &&
           dynamic_type.name == DYNAMIC_DECLARATION &&
           object_schema.declaration == OBJECT_DECLARATION &&
           recursive_schema.declaration == RECURSIVE_DECLARATION
      raise CrystalClick::UnsupportedFormatError.new("W245 fixture declarations differ from the native oracle schema")
    end

    [
      CrystalClick::WidePartColumn.binary_bulk(STATE_NAME, state_descriptor, state_granules),
      CrystalClick::WidePartColumn.dynamic_bulk(
        DYNAMIC_NAME,
        dynamic_type,
        {"root" => CrystalClick::DynamicStructure.new(
          [CrystalClick::BinaryDataType.primitive("UInt64")] of CrystalClick::BinaryDataType
        )},
        dynamic_granules,
      ),
      CrystalClick::WidePartColumn.object(OBJECT_NAME, object_schema, object_plan, object_granules),
      CrystalClick::WidePartColumn.recursive(
        RECURSIVE_NAME,
        recursive_schema,
        recursive_object_plans,
        recursive_granules,
        recursive_dynamic_plans,
      ),
    ] of CrystalClick::WidePartColumn
  end

  def column_roster : Array(Hash(String, String))
    [
      {"name" => STATE_NAME, "type" => STATE_DECLARATION},
      {"name" => DYNAMIC_NAME, "type" => DYNAMIC_DECLARATION},
      {"name" => OBJECT_NAME, "type" => OBJECT_DECLARATION},
      {"name" => RECURSIVE_NAME, "type" => RECURSIVE_DECLARATION},
    ]
  end

  def expected_rows : Array(JSON::Any)
    sums = [0, 42, 200, 255, 1000]
    labels = ["red", "red", "blue", "red", "blue"]
    dynamic = [
      dynamic_json("uint64", 7), dynamic_json("string", "spill"), dynamic_json("null"),
      dynamic_json("uint64", 42), dynamic_json("string", "tail-spill"),
    ]
    shapes = [
      dynamic_json("uint64", 7), dynamic_json("string", "spill"), dynamic_json("null"),
      dynamic_json("uint64", 42), dynamic_json("string", "object-spill"),
    ]
    children = [
      [] of JSON::Any,
      [] of JSON::Any,
      [recursive_child(31, dynamic_json("uint64", 7))],
      [recursive_child(41, dynamic_json("string", "recursive-spill"))],
      [recursive_child(51, dynamic_json("uint64", 42)),
       recursive_child(52, dynamic_json("string", "tail-recursive")),
       recursive_child(53, dynamic_json("null"))],
    ]

    Array(JSON::Any).new(5) do |index|
      JSON::Any.new({
        "pk"    => JSON::Any.new(index + 1),
        "state" => JSON::Any.new({
          "label" => JSON::Any.new(labels[index]),
          "sum"   => JSON::Any.new(sums[index]),
        } of String => JSON::Any),
        "dyn"    => dynamic[index],
        "object" => JSON::Any.new({
          "label" => JSON::Any.new("doc-#{index + 1}"),
          "shape" => shapes[index],
        } of String => JSON::Any),
        "recursive" => JSON::Any.new(children[index]),
      } of String => JSON::Any)
    end
  end

  def file_inventory(part : String) : Array(Hash(String, JSON::Any))
    Dir.children(part).sort.map do |name|
      path = File.join(part, name)
      unless File.file?(path) && !File.symlink?(path)
        raise CrystalClick::CorruptPartError.new("W245 generated part contains a non-regular file")
      end
      {
        "name"   => JSON::Any.new(name),
        "size"   => JSON::Any.new(File.size(path).to_i64),
        "sha256" => JSON::Any.new(Digest::SHA256.hexdigest(File.read(path))),
      }
    end
  end

  private def state_type : CrystalClick::BinaryDataType
    string = CrystalClick::BinaryDataType.primitive("String")
    low_cardinality = CrystalClick::BinaryDataType.low_cardinality(string)
    aggregate = CrystalClick::BinaryDataType.aggregate_function(
      "sum", CrystalClick::BinaryDataType.primitive("UInt8")
    )
    CrystalClick::BinaryDataType.tuple(
      [low_cardinality, aggregate] of CrystalClick::BinaryDataType,
      ["label", "total"] of String,
    )
  end

  private def state_value(
    type : CrystalClick::BinaryDataType,
    label : String,
    sum : UInt64,
  ) : CrystalClick::BinaryValue
    aggregate = type.child_at(1)
    CrystalClick::BinaryValue.tuple(type, [
      CrystalClick::BinaryValue.low_cardinality(
        type.child_at(0), CrystalClick::BinaryValue.string(label)
      ),
      CrystalClick::BinaryValue.aggregate_function_state(aggregate, u64_bytes(sum)),
    ] of CrystalClick::BinaryValue)
  end

  private def dynamic_value(
    type : CrystalClick::BinaryDataType,
    child : CrystalClick::BinaryValue? = nil,
  ) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.dynamic(type, child)
  end

  private def recursive_rows(
    dynamic_type : CrystalClick::BinaryDataType,
  ) : Array(CrystalClick::StorageColumnValue)
    rows = [
      [] of Tuple(UInt8, CrystalClick::BinaryValue),
      [] of Tuple(UInt8, CrystalClick::BinaryValue),
      [{31_u8, dynamic_value(dynamic_type, CrystalClick::BinaryValue.uint64(7_u64))}],
      [{41_u8, dynamic_value(dynamic_type, CrystalClick::BinaryValue.string("recursive-spill"))}],
      [{51_u8, dynamic_value(dynamic_type, CrystalClick::BinaryValue.uint64(42_u64))},
       {52_u8, dynamic_value(dynamic_type, CrystalClick::BinaryValue.string("tail-recursive"))},
       {53_u8, dynamic_value(dynamic_type)}],
    ]
    rows.map do |children|
      values = children.map do |(tag, sample)|
        document = CrystalClick::ObjectDocument.new({
          "t" => CrystalClick::BinaryValue.fixed(
            CrystalClick::BinaryDataType.primitive("UInt8"), Bytes[tag]
          ),
        })
        CrystalClick::StorageColumnValue.tuple([
          CrystalClick::StorageColumnValue.object_document(document),
          CrystalClick::StorageColumnValue.bulk(sample),
        ] of CrystalClick::StorageColumnValue)
      end
      CrystalClick::StorageColumnValue.array(values)
    end
  end

  private def split_marks(rows : Array(CrystalClick::BinaryValue)) : Array(Array(CrystalClick::BinaryValue))
    [rows[0, 2], rows[2, 2], rows[4, 1]]
  end

  private def split_marks(rows : Array(CrystalClick::ObjectDocument)) : Array(Array(CrystalClick::ObjectDocument))
    [rows[0, 2], rows[2, 2], rows[4, 1]]
  end

  private def split_marks(rows : Array(CrystalClick::StorageColumnValue)) : Array(Array(CrystalClick::StorageColumnValue))
    [rows[0, 2], rows[2, 2], rows[4, 1]]
  end

  private def u64_bytes(value : UInt64) : Bytes
    Bytes.new(8) { |index| ((value >> (index * 8)) & 0xff_u64).to_u8 }
  end

  private def dynamic_json(kind : String, value : Int32? = nil) : JSON::Any
    if value
      JSON::Any.new({"kind" => JSON::Any.new(kind), "value" => JSON::Any.new(value)} of String => JSON::Any)
    else
      JSON::Any.new({"kind" => JSON::Any.new(kind)} of String => JSON::Any)
    end
  end

  private def dynamic_json(kind : String, value : String) : JSON::Any
    JSON::Any.new({"kind" => JSON::Any.new(kind), "value" => JSON::Any.new(value)} of String => JSON::Any)
  end

  private def recursive_child(tag : Int32, sample : JSON::Any) : JSON::Any
    JSON::Any.new({
      "doc"    => JSON::Any.new({"t" => JSON::Any.new(tag)} of String => JSON::Any),
      "sample" => sample,
    } of String => JSON::Any)
  end
end

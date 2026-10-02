require "../src/crystal_click"
require "./w116_json_physical_vectors"
require "./w120_structure_vectors"

# Independent W115 Dynamic logical rows for the W122 bulk-value oracle.
# Physical lane bytes/marks are compared with the separately authored W116
# vectors only after W116 validates the retained source part against stock.
module W122BulkVectors
  PROFILES = {"dynamic_paths", "typed_mixed"}

  def self.check_profile(profile : String) : Nil
    raise "unknown W122 retained profile: #{profile.inspect}" unless PROFILES.includes?(profile)
  end

  def self.dynamic_paths(profile : String) : Array(String)
    check_profile(profile)
    W120StructureVectors.dynamic_paths(profile)
  end

  def self.structure(profile : String, path : String) : CrystalClick::DynamicStructure
    check_profile(profile)
    W120StructureVectors.expected_set(profile).dynamics[path]? ||
      raise "W122 literal profile #{profile.inspect} has no Dynamic path #{path.inspect}"
  end

  # Eight literal values, in W115 insertion order. A top-level missing/NULL
  # Dynamic value is represented by the W121 Nothing sentinel. The rows here
  # are inputs/semantic expectations; the independent stream oracle below
  # does not derive bytes from these BinaryValue constructors.
  def self.values(profile : String, path : String) : Array(CrystalClick::BinaryValue)
    check_profile(profile)
    case {profile, path}
    when {"dynamic_paths", "a"}
      [int64(10), null_value, int64(3), null_value, int64(5), int64(6), int64(7), int64(8)]
    when {"dynamic_paths", "arr"}
      [array_int64([1_i64, 2_i64]), array_int64([] of Int64), array_int64([3_i64]), null_value,
       array_int64([4_i64, 5_i64]), null_value, array_int64([6_i64]), array_int64([7_i64])]
    when {"dynamic_paths", "dot.key"}
      [int64(101), int64(102), int64(103), null_value, int64(105), int64(106), int64(107), int64(108)]
    when {"dynamic_paths", "flag"}
      [bool_value(true), bool_value(false), null_value, null_value,
       bool_value(true), bool_value(false), null_value, bool_value(true)]
    when {"dynamic_paths", "nest.leaf"}
      [string_value("one"), string_value("two"), null_value, null_value,
       string_value("five"), null_value, string_value("end"), string_value("")]
    when {"dynamic_paths", "s"}
      [string_value("alpha"), string_value(""), string_value("a\0b"), null_value,
       int64(42), null_value, string_value("last"), bool_value(true)]
    when {"typed_mixed", "s"}
      [string_value("alpha"), string_value(""), string_value("a\0b"), null_value,
       int64(42), null_value, string_value("last"), bool_value(true)]
    else
      raise "W122 literal rows are absent for #{profile}.#{path}"
    end
  end

  def self.granules(profile : String, path : String) : Array(Array(CrystalClick::BinaryValue))
    source = values(profile, path)
    raise "W122 literal input must contain four two-row marks" unless source.size == 8
    result = [] of Array(CrystalClick::BinaryValue)
    0.step(to: 6, by: 2) { |index| result << [source[index], source[index + 1]] }
    result
  end

  def self.expected_granules(profile : String, path : String, first_mark : Int32 = 0, mark_count : Int32 = 4) : Array(Array(CrystalClick::BinaryValue))
    source = granules(profile, path)
    raise ArgumentError.new("invalid W122 literal selection") if first_mark < 0 || mark_count < 0 || first_mark > source.size - mark_count
    source[first_mark, mark_count]
  end

  def self.expected_rows(profile : String, path : String, first_mark : Int32 = 0, mark_count : Int32 = 4) : Array(CrystalClick::BinaryValue)
    check_profile(profile)
    raise ArgumentError.new("invalid W122 literal selection") if first_mark < 0 || mark_count < 0 || first_mark > 4 - mark_count
    first = first_mark * 2
    values(profile, path)[first, mark_count * 2]
  end

  # Maps the only admitted W115 arm types to exact source logical-stream
  # names. These spellings come from the retained W116 stream inventory.
  def self.logical_streams(profile : String, path : String, arm_name : String) : Array(String)
    check_profile(profile)
    prefix = "payload.#{W120StructureVectors.physical_path(path)}"
    case arm_name
    when "String", "SharedVariant"
      ["#{prefix}.#{arm_name}.size", "#{prefix}.#{arm_name}"]
    when "Array(Nullable(Int64))"
      ["#{prefix}.Array%28Nullable%28Int64%29%29.size0",
       "#{prefix}.Array%28Nullable%28Int64%29%29.null",
       "#{prefix}.Array%28Nullable%28Int64%29%29"]
    when "Bool", "Int64"
      ["#{prefix}.#{arm_name}"]
    else
      raise "W122 retained profile has no physical lane map for #{arm_name.inspect}"
    end
  end

  # Role-to-logical-lane mapping is intentionally explicit: role names are
  # codec structure, while these stream names are from the retained W116 part.
  def self.role_streams(profile : String, path : String, arm_name : String) : Array(Tuple(String, String))
    logical = logical_streams(profile, path, arm_name)
    case arm_name
    when "String", "SharedVariant"
      [
        {"root.string_sizes", logical[0]},
        {"root.data", logical[1]},
      ]
    when "Array(Nullable(Int64))"
      [
        {"root.sizes", logical[0]},
        {"root.elements.nulls", logical[1]},
        {"root.elements.nested.data", logical[2]},
      ]
    when "Bool", "Int64"
      [{"root.data", logical[0]}]
    else
      raise "W122 retained profile has no bulk role map for #{arm_name.inspect}"
    end
  end

  def self.arm_names(structure : CrystalClick::DynamicStructure) : Array(String)
    (structure.types.map(&.name) + [CrystalClick::DynamicStructure::SHARED_VARIANT_NAME]).sort
  end

  def self.assert_value_rows(expected : Array(CrystalClick::BinaryValue), actual : Array(CrystalClick::BinaryValue), label : String) : Nil
    unless expected.size == actual.size && expected.each_with_index.all? { |value, index| value_equal?(value, actual[index]) }
      raise "#{label}: logical BinaryValue rows differ from independent W115 literals"
    end
  end

  # Compare the model semantically and nominally, without asking BinaryValue
  # or its codec to supply its own expected serialization.
  def self.value_equal?(expected : CrystalClick::BinaryValue, actual : CrystalClick::BinaryValue) : Bool
    return false unless expected.type == actual.type && expected.is_null? == actual.is_null?
    return true if expected.is_null?

    case expected.type.tag
    when CrystalClick::BinaryDataType::TAG_STRING
      expected.as_string == actual.as_string
    when CrystalClick::BinaryDataType::TAG_BOOL
      expected.as_bool == actual.as_bool
    when CrystalClick::BinaryDataType::TAG_INT64
      expected.as_int64 == actual.as_int64
    when CrystalClick::BinaryDataType::TAG_ARRAY, CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE,
         CrystalClick::BinaryDataType::TAG_NAMED_TUPLE, CrystalClick::BinaryDataType::TAG_MAP
      expected.element_count == actual.element_count && expected.element_count.times.all? do |index|
        value_equal?(expected.element_at(index), actual.element_at(index))
      end
    when CrystalClick::BinaryDataType::TAG_NULLABLE
      expected.child_count == actual.child_count &&
        (expected.child_count == 0 || value_equal?(expected.child_at(0), actual.child_at(0)))
    else
      expected.bytes == actual.bytes
    end
  end

  private def self.int64(value : Int64) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.int64(value)
  end

  private def self.bool_value(value : Bool) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.bool(value)
  end

  private def self.string_value(value : String) : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.string(value)
  end

  private def self.null_value : CrystalClick::BinaryValue
    CrystalClick::BinaryValue.null
  end

  private def self.array_int64(values : Array(Int64)) : CrystalClick::BinaryValue
    int64_type = CrystalClick::BinaryDataType.primitive("Int64")
    nullable_type = CrystalClick::BinaryDataType.nullable(int64_type)
    array_type = CrystalClick::BinaryDataType.array(nullable_type)
    elements = values.map do |value|
      CrystalClick::BinaryValue.nullable(nullable_type, int64(value))
    end
    CrystalClick::BinaryValue.array(array_type, elements)
  end
end

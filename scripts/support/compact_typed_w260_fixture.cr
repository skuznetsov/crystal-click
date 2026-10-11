require "json"
require "file_utils"

module CompactTypedW260Fixture
  SCHEMA_A = [
    {"pk", "UInt64"},
    {"s", "String"},
    {"n", "Nullable(UInt64)"},
    {"arr", "Array(Nullable(UInt64))"},
    {"pair", "Tuple(left String, right String, code UInt64)"},
    {"seq", "Array(Tuple(label String, value Nullable(UInt64)))"},
    {"lookup", "Map(String, Array(Nullable(UInt64)))"},
    {"lc", "LowCardinality(String)"},
    {"v", "Variant(String, UInt64)"},
  ] of Tuple(String, String)

  SCHEMA_B = [
    {"pk", "UInt64"},
    {"label", "String"},
    {"pair", "Tuple(l Array(LowCardinality(UInt64)), v Array(Variant(String, UInt64)))"},
  ] of Tuple(String, String)

  SCHEMA_A_LABELS = [
    "a_mrk3_s0_vbasic", "a_mrk3_s0_vcompact", "a_mrk3_s1_vbasic", "a_mrk3_s1_vcompact",
    "a_mrk4_s0_vbasic", "a_mrk4_s0_vcompact", "a_mrk4_s1_vbasic", "a_mrk4_s1_vcompact",
  ] of String
  SCHEMA_B_LABELS = ["b_mrk3", "b_mrk4"] of String
  COMPACT_LABELS  = SCHEMA_A_LABELS + SCHEMA_B_LABELS
  SELECTED_A      = SCHEMA_A.map(&.[0])
  SELECTED_B      = SCHEMA_B.map(&.[0])
  # Keep the inherited Wide control within its already-supported typed API.
  # The native Wide fixture still has all nine schema-A columns; only this
  # typed control omits the two existing unsupported carriers.
  SELECTED_WIDE = ["pk", "s", "n", "arr", "pair", "lc", "v"] of String

  def self.schema_for(label : String) : Array(Tuple(String, String))
    if SCHEMA_A_LABELS.includes?(label)
      SCHEMA_A
    elsif SCHEMA_B_LABELS.includes?(label)
      SCHEMA_B
    else
      raise ArgumentError.new("unknown W260 fixture label")
    end
  end

  def self.columns_for(label : String) : Array(String)
    schema_for(label).map(&.[0])
  end

  def self.compact_mode_for(label : String) : String
    if label.includes?("mrk3")
      "mrk3"
    elsif label.includes?("mrk4")
      "mrk4"
    else
      raise ArgumentError.new("W260 fixture label has no mark mode")
    end
  end

  def self.string_profile_for(label : String) : String
    label.includes?("_s1_") || label == "b_mrk3" || label == "b_mrk4" ? "with_size_stream" : "single_stream"
  end

  def self.variant_profile_for(label : String) : String
    label.includes?("vcompact") || label == "b_mrk3" || label == "b_mrk4" ? "compact" : "basic"
  end

  # Small public-profile witness used by focused metadata tests. It deliberately
  # writes only the two bounded profile files; physical data/mark fixtures are
  # owned by the separate native matrix and must not be implied here.
  def self.write_profile_metadata(part_path : String, serialization_json : String) : Nil
    FileUtils.mkdir_p(part_path)
    File.write(File.join(part_path, "default_compression_codec.txt"), "CODEC(LZ4)")
    File.write(File.join(part_path, "serialization.json"), serialization_json)
    nil
  end

  def self.profile_envelope(
    records : Array(String),
    type_versions : String = "{}",
    propagate_nested_versions : Bool = true,
  ) : String
    "{\"version\":1,\"columns\":[#{records.join(",")}]," \
    "\"types_serialization_versions\":#{type_versions}," \
    "\"propagate_types_serialization_versions_to_nested_types\":#{propagate_nested_versions}}"
  end

  def self.open_profile(
    part_path : String,
    column_name : String,
    type_name : String,
    row_count : UInt64,
    budget : CrystalClick::CompressedStreamBudget = CrystalClick::CompressedStreamBudget.read_default,
  ) : CrystalClick::CompactSerializationProfile
    type = CrystalClick::StaticBinaryBulkColumnDeclaration.parse(type_name) ||
           raise ArgumentError.new("W260 profile fixture type is not a canonical static BinaryBulk declaration")
    CrystalClick::CompactSerializationProfile.open(
      part_path,
      [{column_name, type_name}],
      column_name,
      type,
      row_count,
      budget,
    )
  end
end

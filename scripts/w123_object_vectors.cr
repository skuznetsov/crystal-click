require "../src/crystal_click"
require "./w115_json_semantic_vectors"
require "./w120_structure_vectors"
require "./w122_bulk_vectors"

# Independent flattened Object documents for the retained W115 literal rows.
# These are semantic inputs/expectations; no physical bytes are derived from
# ObjectDocumentCodec or its encoders here.
module W123ObjectVectors
  PROFILES = {"dynamic_paths", "typed_mixed"}

  def self.check_profile(profile : String) : Nil
    raise "unknown W123 stock profile: #{profile.inspect}" unless PROFILES.includes?(profile)
  end

  def self.plan(profile : String) : CrystalClick::ObjectDocumentPlan
    check_profile(profile)
    typed = if profile == "typed_mixed"
              {"a" => CrystalClick::BinaryDataType.primitive("UInt64")}
            else
              {} of String => CrystalClick::BinaryDataType
            end
    CrystalClick::ObjectDocumentPlan.new(W120StructureVectors.expected_set(profile), typed)
  end

  def self.documents(profile : String) : Array(Array(CrystalClick::ObjectDocument))
    check_profile(profile)
    rows = Array(CrystalClick::ObjectDocument).new(8)
    8.times do |row_index|
      fields = {} of String => CrystalClick::BinaryValue

      if profile == "typed_mixed"
        typed_values = {10_u64, 0_u64, 3_u64, 0_u64, 5_u64, 6_u64, 7_u64, 8_u64}
        fields["a"] = CrystalClick::BinaryValue.uint64(typed_values[row_index])
      end

      W120StructureVectors.dynamic_paths(profile).each do |path|
        value = W122BulkVectors.values(profile, path)[row_index]
        fields[path] = value unless value.is_null?
      end

      if profile == "typed_mixed"
        add_shared_typed_fields(fields, row_index)
      end

      rows << CrystalClick::ObjectDocument.new(fields)
    end

    granules = [] of Array(CrystalClick::ObjectDocument)
    0.step(to: rows.size - 1, by: 2) { |index| granules << [rows[index], rows[index + 1]] }
    granules
  end

  def self.flat_documents(profile : String) : Array(CrystalClick::ObjectDocument)
    documents(profile).flatten
  end

  private def self.add_shared_typed_fields(fields : Hash(String, CrystalClick::BinaryValue), row : Int32) : Nil
    case row
    when 0
      fields["arr"] = array_int64([1_i64, 2_i64])
      fields["dot.key"] = CrystalClick::BinaryValue.int64(101_i64)
      fields["flag"] = CrystalClick::BinaryValue.bool(true)
      fields["nest.leaf"] = CrystalClick::BinaryValue.string("one")
    when 1
      # W115 stores this empty shared array with its inferred String child
      # nominal type, independently evidenced by the retained envelope lane.
      fields["arr"] = array_string([] of String)
      fields["dot.key"] = CrystalClick::BinaryValue.int64(102_i64)
      fields["flag"] = CrystalClick::BinaryValue.bool(false)
      fields["nest.leaf"] = CrystalClick::BinaryValue.string("two")
    when 2
      fields["arr"] = array_int64([3_i64])
      fields["dot.key"] = CrystalClick::BinaryValue.int64(103_i64)
    when 4
      fields["arr"] = array_int64([4_i64, 5_i64])
      fields["dot.key"] = CrystalClick::BinaryValue.int64(105_i64)
      fields["flag"] = CrystalClick::BinaryValue.bool(true)
      fields["nest.leaf"] = CrystalClick::BinaryValue.string("five")
    when 5
      fields["dot.key"] = CrystalClick::BinaryValue.int64(106_i64)
      fields["flag"] = CrystalClick::BinaryValue.bool(false)
    when 6
      fields["arr"] = array_int64([6_i64])
      fields["dot.key"] = CrystalClick::BinaryValue.int64(107_i64)
      fields["nest.leaf"] = CrystalClick::BinaryValue.string("end")
    when 7
      fields["arr"] = array_int64([7_i64])
      fields["dot.key"] = CrystalClick::BinaryValue.int64(108_i64)
      fields["flag"] = CrystalClick::BinaryValue.bool(true)
      fields["nest.leaf"] = CrystalClick::BinaryValue.string("")
    end
  end

  private def self.array_int64(values : Array(Int64)) : CrystalClick::BinaryValue
    nullable = CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("Int64"))
    array = CrystalClick::BinaryDataType.array(nullable)
    elements = values.map do |value|
      CrystalClick::BinaryValue.nullable(nullable, CrystalClick::BinaryValue.int64(value))
    end
    CrystalClick::BinaryValue.array(array, elements)
  end

  private def self.array_string(values : Array(String)) : CrystalClick::BinaryValue
    nullable = CrystalClick::BinaryDataType.nullable(CrystalClick::BinaryDataType.primitive("String"))
    array = CrystalClick::BinaryDataType.array(nullable)
    elements = values.map do |value|
      CrystalClick::BinaryValue.nullable(nullable, CrystalClick::BinaryValue.string(value))
    end
    CrystalClick::BinaryValue.array(array, elements)
  end
end

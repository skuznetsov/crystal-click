require "./spec_helper"
require "file_utils"

private def w221_part_type(source : String) : CrystalClick::BinaryDataType
  CrystalClick::SimpleAggregateBulkColumnDeclaration.parse(source) ||
    raise "W221 part declaration was not admitted: #{source}"
end

private def w221_part_uint8(value : UInt8) : CrystalClick::BinaryValue
  type = CrystalClick::BinaryDataType.primitive("UInt8")
  CrystalClick::BinaryValue.fixed(type, Bytes[value])
end

private def w221_part_write(
  destination : String,
  type : CrystalClick::BinaryDataType,
  granules : Array(Array(CrystalClick::BinaryValue)),
  keys : Slice(UInt64),
  profile : CrystalClick::BinaryBulkProfile = CrystalClick::BinaryBulkProfile.single_stream,
) : String
  CrystalClick::WidePartWriter.write_uint64_simple_aggregate_bulk_part(
    destination,
    "pk",
    keys,
    "v",
    type,
    granules,
    rows_per_mark: 1,
    profile: profile,
  )
end

private def w221_part_assert_key_default_metadata(metadata : Hash(String, JSON::Any)) : Nil
  columns = metadata["columns"].as_a
  columns.size.should eq(1)
  entry = columns[0].as_h
  entry["exact_num_defaults"].as_bool.should be_true
  entry["kind"].as_s.should eq("Default")
  entry["name"].as_s.should eq("pk")
  entry["num_defaults"].as_i.should eq(0)
  entry["num_rows"].as_i.should eq(2)
  nil
end

private def w221_part_assert_same_stream_names(left : CrystalClick::BinaryDataType, right : CrystalClick::BinaryDataType) : Nil
  left_streams = CrystalClick::BinaryBulkPhysicalPlan.new(left, "v").stream_names.values.sort
  right_streams = CrystalClick::BinaryBulkPhysicalPlan.new(right, "v").stream_names.values.sort
  left_streams.should eq(right_streams)
end

class CrystalClick::BinaryBulkColumnReader
  # Test-only staged-readback substitution, patterned after the W171 seam.
  # It is dormant unless both the exact descriptor and writer-stage path match.
  class_property w221_staged_readback_defect = ""
  class_property w221_staged_readback_type_name = ""
  class_property w221_staged_readback_parent = ""
  class_property w221_staged_readback_calls = 0

  def read_marks(first_mark : Int, mark_count : Int) : Array(Array(BinaryValue))
    decoded = previous_def
    defect = CrystalClick::BinaryBulkColumnReader.w221_staged_readback_defect
    target_name = CrystalClick::BinaryBulkColumnReader.w221_staged_readback_type_name
    target_parent = CrystalClick::BinaryBulkColumnReader.w221_staged_readback_parent
    return decoded if defect.empty? || target_name.empty? || @type.name != target_name
    return decoded unless File.basename(@part_path).starts_with?(".crystal-click-wide-writer-")
    return decoded unless File.dirname(@part_path) == target_parent
    return decoded if decoded.empty? || decoded[0].empty?

    CrystalClick::BinaryBulkColumnReader.w221_staged_readback_calls += 1
    replacement = case defect
                  when "nominal"
                    alternate = CrystalClick::SimpleAggregateBulkColumnDeclaration.parse(
                      "SimpleAggregateFunction(anyLast_respect_nulls, UInt8)"
                    ) || raise "W221 staged nominal control was not admitted"
                    child = CrystalClick::BinaryValue.fixed(
                      alternate.child_at(0), Bytes[0x5a_u8]
                    )
                    CrystalClick::BinaryValue.simple_aggregate(alternate, child)
                  when "value"
                    child = CrystalClick::BinaryValue.fixed(
                      @type.child_at(0), Bytes[0x5b_u8]
                    )
                    CrystalClick::BinaryValue.simple_aggregate(@type, child)
                  else
                    raise "unknown W221 staged-readback defect"
                  end
    decoded[0][0] = replacement
    decoded
  end
end

describe "W221 SimpleAggregateFunction paired static part writer" do
  it "round-trips inner Nullable and outer Nullable as distinct nominal shapes" do
    inner = w221_part_type("SimpleAggregateFunction(any_respect_nulls, Nullable(UInt8))")
    inner_child = inner.child_at(0)
    inner_values = [
      [CrystalClick::BinaryValue.simple_aggregate(inner, CrystalClick::BinaryValue.nullable(inner_child))] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.simple_aggregate(
        inner,
        CrystalClick::BinaryValue.nullable(inner_child, w221_part_uint8(0xa5_u8)),
      )] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)

    scalar = w221_part_type("SimpleAggregateFunction(anyLast_respect_nulls, UInt8)")
    outer = w221_part_type("Nullable(SimpleAggregateFunction(anyLast_respect_nulls, UInt8))")
    outer_values = [
      [CrystalClick::BinaryValue.nullable(outer)] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.nullable(
        outer,
        CrystalClick::BinaryValue.simple_aggregate(scalar, w221_part_uint8(0x5a_u8)),
      )] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)

    parent = File.tempname("crystal-click-w221-simple-aggregate-shapes-")
    Dir.mkdir(parent)
    begin
      inner_path = File.join(parent, "inner")
      w221_part_write(inner_path, inner, inner_values, Slice[1_u64, 2_u64]).should eq(inner_path)
      inner_reader = CrystalClick::BinaryBulkColumnReader.open(inner_path, "v", inner)
      inner_reader.schema_declaration.should eq(inner.name)
      inner_reader.mark_row_counts.should eq([1_u64, 1_u64])
      inner_reader.physical_stream_names.should eq(["v", "v.null"])
      actual_inner = inner_reader.read_marks(0, 2)
      actual_inner[0][0].type.should eq(inner)
      actual_inner[0][0].is_null?.should be_false
      actual_inner[0][0].as_simple_aggregate.is_null?.should be_true
      actual_inner[1][0].as_simple_aggregate.child_at(0).byte_at(0).should eq(0xa5_u8)

      # Nullable applies to the SAF root here, rather than to its storage
      # child; exact descriptor and physical null lane remain separate.
      outer_path = File.join(parent, "outer")
      w221_part_write(outer_path, outer, outer_values, Slice[3_u64, 4_u64]).should eq(outer_path)
      outer_reader = CrystalClick::BinaryBulkColumnReader.open(outer_path, "v", outer)
      outer_reader.schema_declaration.should eq(outer.name)
      outer_reader.physical_stream_names.should eq(["v", "v.null"])
      actual_outer = outer_reader.read_marks(0, 2)
      actual_outer[0][0].type.should eq(outer)
      actual_outer[0][0].is_null?.should be_true
      actual_outer[1][0].is_null?.should be_false
      actual_outer[1][0].child_at(0).as_simple_aggregate.byte_at(0).should eq(0x5a_u8)

      # Ordinary nullable storage has no synthetic `nullable` serialization
      # version; the global String profile entry remains version zero here.
      [inner_path, outer_path].each do |part|
        serialization = JSON.parse(File.read(File.join(part, "serialization.json"))).as_h
        serialization["version"].as_i.should eq(1)
        serialization["propagate_types_serialization_versions_to_nested_types"].as_bool.should be_true
        versions = serialization["types_serialization_versions"].as_h
        versions.should eq(
          {"string" => JSON::Any.new(0_i64)} of String => JSON::Any
        )
        w221_part_assert_key_default_metadata(serialization)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "keeps the with-size String lane and measured stock serialization profile" do
    type = w221_part_type("SimpleAggregateFunction(any_respect_nulls, String)")
    values = [
      [CrystalClick::BinaryValue.simple_aggregate(type, CrystalClick::BinaryValue.string("alpha"))] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.simple_aggregate(type, CrystalClick::BinaryValue.string("beta"))] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    parent = File.tempname("crystal-click-w221-simple-aggregate-string-")
    Dir.mkdir(parent)
    begin
      destination = File.join(parent, "part")
      w221_part_write(
        destination, type, values, Slice[10_u64, 20_u64],
        CrystalClick::BinaryBulkProfile.with_size_stream,
      )
      reader = CrystalClick::BinaryBulkColumnReader.open(destination, "v", type)
      reader.ordinary_profile.should eq(CrystalClick::BinaryBulkProfile.with_size_stream)
      reader.physical_stream_names.should eq(["v", "v.size"])
      decoded = reader.read_marks(0, 2)
      decoded[0][0].as_simple_aggregate.as_string.should eq("alpha")
      decoded[1][0].as_simple_aggregate.as_string.should eq("beta")

      serialization = JSON.parse(File.read(File.join(destination, "serialization.json"))).as_h
      serialization["version"].as_i.should eq(1)
      serialization["propagate_types_serialization_versions_to_nested_types"].as_bool.should be_true
      serialization["types_serialization_versions"].as_h.should eq(
        {"string" => JSON::Any.new(1_i64)} of String => JSON::Any
      )
      w221_part_assert_key_default_metadata(serialization)
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects double Nullable before creating a destination or stage" do
    parent = File.tempname("crystal-click-w221-simple-aggregate-double-nullable-")
    Dir.mkdir(parent)
    begin
      inner = w221_part_type("SimpleAggregateFunction(any_respect_nulls, Nullable(UInt8))")
      # Constructing the outer wrapper is rejected by the descriptor policy;
      # the source declaration parser also rejects its canonical spelling.
      expect_raises(ArgumentError) { CrystalClick::BinaryDataType.nullable(inner) }
      CrystalClick::SimpleAggregateBulkColumnDeclaration.parse(
        "Nullable(SimpleAggregateFunction(any_respect_nulls, Nullable(UInt8)))"
      ).should be_nil
      Dir.children(parent).should be_empty
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects valid but nominally wrong declarations even when their streams coincide" do
    parent = File.tempname("crystal-click-w221-simple-aggregate-nominal-read-")
    Dir.mkdir(parent)
    begin
      inner_type = w221_part_type("SimpleAggregateFunction(any_respect_nulls, Nullable(UInt8))")
      inner_child = inner_type.child_at(0)
      inner_value = CrystalClick::BinaryValue.simple_aggregate(
        inner_type,
        CrystalClick::BinaryValue.nullable(inner_child, w221_part_uint8(0x41_u8)),
      )
      inner_values = [[inner_value]] of Array(CrystalClick::BinaryValue)

      # A different aggregate function has the same child and lane grammar.
      other_function = w221_part_type(
        "SimpleAggregateFunction(anyLast_respect_nulls, Nullable(UInt8))"
      )
      w221_part_assert_same_stream_names(inner_type, other_function)
      function_part = File.join(parent, "function")
      w221_part_write(function_part, inner_type, inner_values, Slice[1_u64])
      expect_raises(CrystalClick::CorruptPartError, /source declaration differs/) do
        CrystalClick::BinaryBulkColumnReader.open(function_part, "v", other_function)
      end

      # Nullable inside SAF and Nullable around SAF both expose v.null + v,
      # but the source declaration is not interchangeable.
      outer_type = w221_part_type(
        "Nullable(SimpleAggregateFunction(any_respect_nulls, UInt8))"
      )
      w221_part_assert_same_stream_names(inner_type, outer_type)
      placement_part = File.join(parent, "nullable-placement")
      w221_part_write(placement_part, inner_type, inner_values, Slice[2_u64])
      expect_raises(CrystalClick::CorruptPartError, /source declaration differs/) do
        CrystalClick::BinaryBulkColumnReader.open(placement_part, "v", outer_type)
      end

      # Same-width signed and unsigned leaves share one physical lane only.
      # That coincidence must not substitute for exact source identity.
      unsigned_type = w221_part_type("SimpleAggregateFunction(any_respect_nulls, UInt8)")
      signed_type = w221_part_type("SimpleAggregateFunction(any_respect_nulls, Int8)")
      unsigned_value = CrystalClick::BinaryValue.simple_aggregate(
        unsigned_type, w221_part_uint8(0x7f_u8)
      )
      w221_part_assert_same_stream_names(unsigned_type, signed_type)
      width_part = File.join(parent, "same-width")
      width_values = [[unsigned_value]] of Array(CrystalClick::BinaryValue)
      w221_part_write(
        width_part, unsigned_type, width_values, Slice[3_u64]
      )
      expect_raises(CrystalClick::CorruptPartError, /source declaration differs/) do
        CrystalClick::BinaryBulkColumnReader.open(width_part, "v", signed_type)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a selected Nullable lane roster that omits the null map" do
    type = w221_part_type("SimpleAggregateFunction(any_respect_nulls, Nullable(UInt8))")
    child = type.child_at(0)
    values = [
      [CrystalClick::BinaryValue.simple_aggregate(type, CrystalClick::BinaryValue.nullable(child))] of CrystalClick::BinaryValue,
      [CrystalClick::BinaryValue.simple_aggregate(
        type, CrystalClick::BinaryValue.nullable(child, w221_part_uint8(0x42_u8))
      )] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    parent = File.tempname("crystal-click-w221-simple-aggregate-null-roster-")
    Dir.mkdir(parent)
    begin
      destination = File.join(parent, "part")
      w221_part_write(destination, type, values, Slice[1_u64, 2_u64])

      metadata_path = File.join(destination, "columns_substreams.txt")
      original = File.read(metadata_path)
      original.should contain("\tv.null\n")
      original.should contain("2 substreams for column `v`:")
      malformed = original.gsub(
        "2 substreams for column `v`:\n\tv\n\tv.null\n",
        "1 substreams for column `v`:\n\tv\n"
      )
      malformed.should_not eq(original)
      File.write(metadata_path, malformed)

      expect_raises(CrystalClick::CorruptPartError, /selected columns_substreams roster differs/) do
        CrystalClick::BinaryBulkColumnReader.open(destination, "v", type)
      end
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  it "rejects a wrong BinaryValue descriptor before creating a destination or stage" do
    parent = File.tempname("crystal-click-w221-simple-aggregate-wrong-value-")
    Dir.mkdir(parent)
    begin
      keep_path = File.join(parent, "keep")
      File.write(keep_path, "unchanged")
      before = Dir.children(parent).sort
      expected = w221_part_type("SimpleAggregateFunction(any_respect_nulls, UInt8)")
      wrong = w221_part_type("SimpleAggregateFunction(anyLast_respect_nulls, UInt8)")
      wrong_value = CrystalClick::BinaryValue.simple_aggregate(wrong, w221_part_uint8(0x5a_u8))
      destination = File.join(parent, "part")
      wrong_values = [[wrong_value]] of Array(CrystalClick::BinaryValue)

      expect_raises(CrystalClick::UnsupportedFormatError, /value does not match its descriptor/) do
        w221_part_write(
          destination, expected, wrong_values, Slice[9_u64]
        )
      end
      Dir.children(parent).sort.should eq(before)
      File.exists?(destination).should be_false
      File.read(keep_path).should eq("unchanged")
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  ["nominal", "value"].each do |defect|
    it "rejects a same-shape staged #{defect} mismatch and removes the stage" do
      parent = File.tempname("crystal-click-w221-simple-aggregate-staged-#{defect}-")
      Dir.mkdir(parent)
      File.write(File.join(parent, "keep"), "unchanged")
      before = Dir.children(parent).sort
      type = w221_part_type("SimpleAggregateFunction(any_respect_nulls, UInt8)")
      value = CrystalClick::BinaryValue.simple_aggregate(type, w221_part_uint8(0x5a_u8))
      staged_values = [[value]] of Array(CrystalClick::BinaryValue)
      CrystalClick::BinaryBulkColumnReader.w221_staged_readback_type_name = type.name
      CrystalClick::BinaryBulkColumnReader.w221_staged_readback_parent = parent
      CrystalClick::BinaryBulkColumnReader.w221_staged_readback_defect = defect
      CrystalClick::BinaryBulkColumnReader.w221_staged_readback_calls = 0
      begin
        expected_error = if defect == "nominal"
                           /staged SimpleAggregate BinaryValue differs from input descriptor/
                         else
                           /staged SimpleAggregate BinaryValue scalar bytes differ from input/
                         end
        expect_raises(CrystalClick::CorruptPartError, expected_error) do
          w221_part_write(
            File.join(parent, "part"), type, staged_values, Slice[11_u64]
          )
        end
        CrystalClick::BinaryBulkColumnReader.w221_staged_readback_calls.should eq(1)
        Dir.children(parent).sort.should eq(before)
        File.exists?(File.join(parent, "part")).should be_false
        File.read(File.join(parent, "keep")).should eq("unchanged")
      ensure
        CrystalClick::BinaryBulkColumnReader.w221_staged_readback_defect = ""
        CrystalClick::BinaryBulkColumnReader.w221_staged_readback_type_name = ""
        CrystalClick::BinaryBulkColumnReader.w221_staged_readback_parent = ""
        CrystalClick::BinaryBulkColumnReader.w221_staged_readback_calls = 0
        FileUtils.rm_rf(parent)
      end
    end
  end
end

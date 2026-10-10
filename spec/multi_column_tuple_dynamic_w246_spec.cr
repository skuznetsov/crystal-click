require "./spec_helper"
require "../scripts/support/multi_column_tuple_dynamic_w246_fixture"
require "file_utils"

private def w246_with_parent(&)
  parent = File.tempname("crystal-click-w246-tuple-dynamic-")
  Dir.mkdir(parent)
  begin
    yield parent
  ensure
    FileUtils.rm_rf(parent)
  end
end

private def w246_unsigned(value : CrystalClick::BinaryValue) : UInt64
  bytes = value.bytes
  result = 0_u64
  bytes.each_with_index do |byte, index|
    result |= byte.to_u64 << (index * 8)
  end
  result
end

private def w246_expect_null(value : CrystalClick::BinaryValue) : Nil
  value.type.tag.should eq(CrystalClick::BinaryDataType::TAG_DYNAMIC)
  value.is_null?.should be_true
  value.child_count.should eq(0)
end

private def w246_expect_dynamic(
  value : CrystalClick::BinaryValue,
  actual_type : String,
  expected : UInt64,
) : Nil
  value.type.tag.should eq(CrystalClick::BinaryDataType::TAG_DYNAMIC)
  value.is_null?.should be_false
  value.child_count.should eq(1)
  actual = value.child_at(0)
  actual.type.name.should eq(actual_type)
  w246_unsigned(actual).should eq(expected)
  nil
end

private def w246_expect_dynamic(
  value : CrystalClick::BinaryValue,
  actual_type : String,
  expected : String,
) : Nil
  value.type.tag.should eq(CrystalClick::BinaryDataType::TAG_DYNAMIC)
  value.is_null?.should be_false
  value.child_count.should eq(1)
  actual = value.child_at(0)
  actual.type.name.should eq(actual_type)
  actual.as_string.should eq(expected)
  nil
end

private def w246_expect_dynamic_bool(
  value : CrystalClick::BinaryValue,
  expected : Bool,
) : Nil
  value.type.tag.should eq(CrystalClick::BinaryDataType::TAG_DYNAMIC)
  value.is_null?.should be_false
  value.child_count.should eq(1)
  actual = value.child_at(0)
  actual.type.name.should eq("Bool")
  actual.as_bool.should eq(expected)
  nil
end

private def w246_assert_dynamic_headers(
  part_path : String,
  column_name : String,
  type : CrystalClick::BinaryDataType,
  structures : Hash(String, CrystalClick::DynamicStructure),
  profile : CrystalClick::BinaryBulkProfile,
) : Nil
  prepared = CrystalClick::BinaryDynamicBulkPlan.new(type, structures, profile)
  physical = CrystalClick::BinaryDynamicBulkPhysicalPlan.new(prepared, column_name)
  source = CrystalClick::PartStreamSource.new(part_path)
  prepared.site_paths.each do |site_path|
    role = "#{site_path}.discriminators"
    window = source.read_window(
      physical.data_file_for(role, true),
      physical.marks_file_for(role, true),
      0,
      1,
      CrystalClick::BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES,
    )
    CrystalClick::BinaryBulkDiscriminatorFramingAdapter.validate_header(
      role,
      window.bytes,
      CrystalClick::BinaryBulkDiscriminatorFramingAdapter::PREFIX_BYTES,
    ).should eq(CrystalClick::DynamicDiscriminatorCodec::BASIC_MODE)
  end
  nil
end

describe "W246 root Tuple Dynamic in N-column Wide publication" do
  it "writes named and unnamed root Tuple columns with independent sites, exact recursive values and omitted metadata" do
    ["single", "sized"].each do |profile_name|
      ["basic", "compact"].each do |requested_mode_name|
        profile = MultiColumnTupleDynamicW246Fixture.profile(profile_name)
        requested_mode = MultiColumnTupleDynamicW246Fixture.operation_mode(requested_mode_name)
        named_type = MultiColumnTupleDynamicW246Fixture.named_type
        unnamed_type = MultiColumnTupleDynamicW246Fixture.unnamed_type
        named_structures = MultiColumnTupleDynamicW246Fixture.named_structures
        unnamed_structures = MultiColumnTupleDynamicW246Fixture.unnamed_structures

        w246_with_parent do |parent|
          destination = File.join(parent, "all_1_1_0")
          CrystalClick::WidePartWriter.write_uint64_columns(
            destination,
            MultiColumnTupleDynamicW246Fixture::KEY_NAME,
            MultiColumnTupleDynamicW246Fixture::KEYS.to_unsafe.to_slice(
              MultiColumnTupleDynamicW246Fixture::KEYS.size
            ),
            MultiColumnTupleDynamicW246Fixture.multi_columns,
            rows_per_mark: MultiColumnTupleDynamicW246Fixture::ROWS_PER_MARK,
            profile: profile,
            shared_profile: CrystalClick::BinaryBulkProfile.single_stream,
            mode: requested_mode,
            frame_bytes: MultiColumnTupleDynamicW246Fixture::FRAME_BYTES,
          ).should eq(destination)

          key_part = CrystalClick::WidePart.open(destination, "pk")
          key_part.row_count.should eq(5_u64)
          key_part.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
          key_part.read_uint64_mark_range("pk", 0, 3).should eq(
            MultiColumnTupleDynamicW246Fixture::KEYS
          )

          named_type.tag.should eq(CrystalClick::BinaryDataType::TAG_NAMED_TUPLE)
          named_type.field_names.should eq(["sequence", "items"])
          named_type.child_at(0).name.should eq("Dynamic(max_types=1)")
          named_type.child_at(1).name.should eq("Array(Dynamic(max_types=1))")
          unnamed_type.tag.should eq(CrystalClick::BinaryDataType::TAG_UNNAMED_TUPLE)
          unnamed_type.field_names.should be_empty
          unnamed_type.child_at(0).name.should eq("Dynamic(max_types=1)")
          unnamed_type.child_at(1).name.should eq("Dynamic(max_types=1)")

          named_reader = CrystalClick::DynamicBulkColumnReader.open(destination, "named_tuple", named_type)
          unnamed_reader = CrystalClick::DynamicBulkColumnReader.open(destination, "unnamed_tuple", unnamed_type)
          named_reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])
          unnamed_reader.mark_row_counts.should eq([2_u64, 2_u64, 1_u64])

          named_marks = named_reader.read_marks(0, named_reader.mark_count)
          unnamed_marks = unnamed_reader.read_marks(0, unnamed_reader.mark_count)
          named_marks.map(&.size).should eq([2, 2, 1])
          unnamed_marks.map(&.size).should eq([2, 2, 1])
          named_rows = named_marks.flat_map { |mark| mark }
          unnamed_rows = unnamed_marks.flat_map { |mark| mark }
          named_rows.size.should eq(5)
          unnamed_rows.size.should eq(5)

          # Row 1: dedicated registered arms and empty nested Array(Dynamic).
          w246_expect_dynamic(named_rows[0].child_at(0), "UInt64", 7_u64)
          named_rows[0].child_at(1).element_count.should eq(0)
          w246_expect_dynamic_bool(unnamed_rows[0].child_at(0), true)
          w246_expect_dynamic(unnamed_rows[0].child_at(1), "UInt32", 10_u64)

          # Row 2: NULL and independent shared overflow at both unnamed sites.
          w246_expect_null(named_rows[1].child_at(0))
          named_rows[1].child_at(1).element_count.should eq(0)
          w246_expect_dynamic(unnamed_rows[1].child_at(0), "String", "left-overflow")
          w246_expect_dynamic(unnamed_rows[1].child_at(1), "UInt64", 20_u64)

          # Row 3: the Array(Dynamic) site appears after two empty parent rows;
          # check dedicated, shared and NULL occurrences in order.
          w246_expect_dynamic(named_rows[2].child_at(0), "UInt64", 42_u64)
          items = named_rows[2].child_at(1)
          items.element_count.should eq(3)
          w246_expect_dynamic(items.element_at(0), "String", "array-dedicated")
          w246_expect_dynamic(items.element_at(1), "UInt8", 9_u64)
          w246_expect_null(items.element_at(2))
          w246_expect_null(unnamed_rows[2].child_at(0))
          w246_expect_dynamic(unnamed_rows[2].child_at(1), "UInt32", 42_u64)

          # Row 4: root sequence spill, array child spill and NULL sibling.
          w246_expect_dynamic(named_rows[3].child_at(0), "String", "sequence-overflow")
          items = named_rows[3].child_at(1)
          items.element_count.should eq(1)
          w246_expect_dynamic(items.element_at(0), "UInt64", 99_u64)
          w246_expect_dynamic_bool(unnamed_rows[3].child_at(0), false)
          w246_expect_null(unnamed_rows[3].child_at(1))

          # Row 5: selected final mark proves late shared/registered values and
          # the two-element child schedule survive a short parent granule.
          late_named = named_reader.read_marks(2, 1)[0][0]
          late_unnamed = unnamed_reader.read_marks(2, 1)[0][0]
          w246_expect_dynamic(late_named.child_at(0), "String", "sequence-overflow-tail")
          late_items = late_named.child_at(1)
          late_items.element_count.should eq(2)
          w246_expect_dynamic(late_items.element_at(0), "String", "array-dedicated-tail")
          w246_expect_null(late_items.element_at(1))
          w246_expect_dynamic(late_unnamed.child_at(0), "String", "left-overflow-tail")
          w246_expect_dynamic(late_unnamed.child_at(1), "UInt64", 100_u64)

          metadata = JSON.parse(File.read(File.join(destination, "serialization.json")))
          metadata["columns"].as_a.should be_empty
          metadata["types_serialization_versions"]["string"].as_i.should eq(
            profile.with_size_stream? ? 1 : 0
          )

          w246_assert_dynamic_headers(
            destination, "named_tuple", named_type, named_structures, profile
          )
          w246_assert_dynamic_headers(
            destination, "unnamed_tuple", unnamed_type, unnamed_structures, profile
          )
        end
      end
    end
  end
end

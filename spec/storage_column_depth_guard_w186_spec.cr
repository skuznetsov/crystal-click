require "./spec_helper"
require "../src/crystal_click/storage_column_depth_guard"

private def w186_depth_limits(max_depth : Int) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: max_depth,
    max_nodes: 1_000,
    max_elements: 1_000,
    max_bytes: 1_000_000,
  )
end

private def w186_uint8_type : CrystalClick::BinaryDataType
  CrystalClick::BinaryDataType.primitive("UInt8")
end

private def w186_uint8(value : UInt8) : CrystalClick::BinaryValue
  CrystalClick::BinaryValue.fixed(w186_uint8_type, Bytes[value])
end

private def w186_nested_array_value : CrystalClick::BinaryValue
  uint8 = w186_uint8_type
  inner_type = CrystalClick::BinaryDataType.array(uint8)
  outer_type = CrystalClick::BinaryDataType.array(inner_type)
  inner = CrystalClick::BinaryValue.array(inner_type, [w186_uint8(7_u8)] of CrystalClick::BinaryValue)
  CrystalClick::BinaryValue.array(outer_type, [inner] of CrystalClick::BinaryValue)
end

private def w186_object_value(value : CrystalClick::BinaryValue) : CrystalClick::StorageColumnValue
  document = CrystalClick::ObjectDocument.new({"value" => value})
  CrystalClick::StorageColumnValue.object_document(document)
end

describe CrystalClick::StorageColumnDepthGuard do
  it "uses storage depth one and admits Tuple(JSON UInt8) at cap two" do
    document = CrystalClick::ObjectDocument.new({
      "value" => w186_uint8(7_u8),
    })
    value = CrystalClick::StorageColumnValue.tuple([
      CrystalClick::StorageColumnValue.object_document(document),
    ] of CrystalClick::StorageColumnValue)

    CrystalClick::StorageColumnDepthGuard.validate(value, w186_depth_limits(2))
    CrystalClick::StorageColumnDepthGuard.validate(value, w186_depth_limits(2), writing: false)
  end

  it "counts every Array descriptor/value edge from the inherited JSON site" do
    wrapped = CrystalClick::StorageColumnValue.tuple([
      w186_object_value(w186_nested_array_value),
    ] of CrystalClick::StorageColumnValue)

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::StorageColumnDepthGuard.validate(wrapped, w186_depth_limits(3))
    end
    CrystalClick::StorageColumnDepthGuard.validate(wrapped, w186_depth_limits(4))
  end

  it "visits every untyped Object value, including a selected Dynamic Array runtime value" do
    runtime = w186_nested_array_value
    dynamic = CrystalClick::BinaryValue.dynamic(CrystalClick::BinaryDataType.dynamic, runtime)
    document = CrystalClick::ObjectDocument.new({
      "first"  => CrystalClick::BinaryValue.uint64(1_u64),
      "shared" => dynamic,
    })
    wrapped = CrystalClick::StorageColumnValue.tuple([
      CrystalClick::StorageColumnValue.object_document(document),
    ] of CrystalClick::StorageColumnValue)

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::StorageColumnDepthGuard.validate(wrapped, w186_depth_limits(4))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::StorageColumnDepthGuard.validate(wrapped, w186_depth_limits(4), writing: false)
    end
    CrystalClick::StorageColumnDepthGuard.validate(wrapped, w186_depth_limits(5))
  end

  it "counts nested BinaryBulk below a storage Tuple without resetting depth" do
    nested_bulk = CrystalClick::StorageColumnValue.tuple([
      CrystalClick::StorageColumnValue.bulk(w186_nested_array_value),
    ] of CrystalClick::StorageColumnValue)

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::StorageColumnDepthGuard.validate(nested_bulk, w186_depth_limits(3))
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::StorageColumnDepthGuard.validate(nested_bulk, w186_depth_limits(3), writing: false)
    end
    CrystalClick::StorageColumnDepthGuard.validate(nested_bulk, w186_depth_limits(4))
  end

  it "accepts empty child domains at the current cap" do
    empty_array = CrystalClick::BinaryValue.array(
      CrystalClick::BinaryDataType.array(w186_uint8_type),
      [] of CrystalClick::BinaryValue,
    )
    empty_dynamic = CrystalClick::BinaryValue.dynamic(CrystalClick::BinaryDataType.dynamic)
    empty_document = CrystalClick::ObjectDocument.new({
      "array"   => empty_array,
      "dynamic" => empty_dynamic,
    })

    CrystalClick::StorageColumnDepthGuard.validate(
      CrystalClick::StorageColumnValue.object_document(empty_document),
      w186_depth_limits(2),
    )
  end
end

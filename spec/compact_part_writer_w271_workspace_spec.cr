require "./spec_helper"

private def w271_workspace_string_owner_bytes(value : String) : UInt64
  sizeof(String).to_u64 + value.bytesize.to_u64
end

describe "W271 retained inline JSON prefix workspace" do
  it "matches the exact empty-body inline prefix and Dynamic JSON leaf owner census" do
    budget = CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default)
    # Exact V4 MAP0 Object prefix: version, zero Dynamic paths, and shared-data
    # version zero. Inline prefixes carry structure metadata without statistics.
    bytes = Bytes[4, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    key = CrystalClick::BinaryDynamicJsonLeafKey.new("root", 0, [] of Int32)
    tape = CrystalClick::ObjectSharedPathTapeReader.new(
      bytes,
      [CrystalClick::ObjectSharedPathSubstreamEvent.new(".child.object_structure", 0_u64)],
      budget,
    )
    prefix = CrystalClick::ObjectDocumentInlinePlanReader.read_json_leaf_prefix(
      tape,
      CrystalClick::BinaryDataType.json(max_dynamic_paths: 0, max_dynamic_types: 0),
      key,
      1_i32,
      ".child",
      ".child",
      0_u64,
      CrystalClick::ObjectSharedNestedSerializationContext.for_read(
        0_u64,
        CrystalClick::BinaryBulkProfile.single_stream,
      ),
      budget,
    )
    tape.finish!
    prefix.capture_json_leaf_body_start!
    prefix.capture_json_leaf_body_finish!(0)

    prefix.physical_prefix.should eq(".child")
    prefix.callback_prefix.should eq(".child")
    prefix.prefix_callback_count.should eq(1)
    prefix.body_callback_count.should eq(0)
    prefix.body_callback_slice_count.should eq(0)
    callback_name, callback_bytes = prefix.prefix_callback_at(0, budget)
    callback_name.should eq(".child.object_structure")
    callback_bytes.size.should eq(10)

    expected = instance_sizeof(CrystalClick::ObjectDocumentInlinePrefix).to_u64
    expected += instance_sizeof(CrystalClick::BinaryDynamicJsonLeafKey).to_u64
    expected += sizeof(String).to_u64 + key.dynamic_site_bytesize.to_u64
    expected += instance_sizeof(Array(Int32)).to_u64
    # PrefixOnly observes no statistics entries, but the callback owner still
    # retains its empty owner-local offsets map.
    expected += instance_sizeof(Hash(String, Int32)).to_u64
    expected += w271_workspace_string_owner_bytes(prefix.physical_prefix)
    expected += w271_workspace_string_owner_bytes(prefix.callback_prefix)

    expected += instance_sizeof(Array(Tuple(String, Bytes))).to_u64
    expected += prefix.prefix_callback_count.to_u64 * sizeof(Tuple(String, Bytes)).to_u64
    expected += w271_workspace_string_owner_bytes(callback_name)
    expected += sizeof(Bytes).to_u64 + callback_bytes.size.to_u64

    # Empty captured body still retains its two collection owners; both have
    # zero elements, so there are no callback tuples, slices, or payload bytes.
    expected += instance_sizeof(Array(Tuple(String, Bytes))).to_u64
    expected += prefix.body_callback_count.to_u64 * sizeof(Tuple(String, Bytes)).to_u64
    expected += instance_sizeof(Array(CrystalClick::ObjectSharedInlineCallbackReadSlice)).to_u64
    expected += prefix.body_callback_slice_count.to_u64 *
                sizeof(Pointer(CrystalClick::ObjectSharedInlineCallbackReadSlice)).to_u64

    prefix.retained_callback_capture_workspace_bytes.should eq(expected)
  end
end

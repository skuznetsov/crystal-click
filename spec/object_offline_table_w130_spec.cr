require "./spec_helper"

private def w130_offline_empty_table(columns : Array(CrystalClick::OfflineColumn), key : String? = nil) : CrystalClick::OfflineTable
  CrystalClick::OfflineTable.new(
    "events",
    "13000000-0000-4000-8000-000000000001",
    "MergeTree",
    columns,
    [] of CrystalClick::OfflinePartCandidate,
    primary_key_column: key,
  )
end

describe "W130 OfflineTable Object schema admission" do
  it "validates a selected whole-Object DDL schema before an empty-part return" do
    valid = w130_offline_empty_table([
      CrystalClick::OfflineColumn.new("payload", "JSON(t UInt64, max_dynamic_paths=1, max_dynamic_types=1)"),
    ])
    callbacks = 0
    valid.scan_typed(["payload"]) { |_batch| callbacks += 1; nil }
    valid.scan_typed_window(["payload"], 0_u64) { |_batch| callbacks += 1; nil }
    callbacks.should eq(0)

    invalid = w130_offline_empty_table([
      CrystalClick::OfflineColumn.new("payload", "JSON(t Float64)"),
    ])
    expect_raises(CrystalClick::UnsupportedFormatError) do
      invalid.scan_typed(["payload"]) { |_batch| callbacks += 1; nil }
    end
    callbacks.should eq(0)
  end

  it "keeps unrelated scalar codecs and JSON options outside the selected binding" do
    table = w130_offline_empty_table([
      CrystalClick::OfflineColumn.new("pk", "UInt64"),
      CrystalClick::OfflineColumn.new("payload", "JSON(t UInt64, max_dynamic_paths=1, max_dynamic_types=1)"),
      CrystalClick::OfflineColumn.new("unused", "UnsupportedScalarType"),
      CrystalClick::OfflineColumn.new("other", "JSON(t Float64)"),
    ], "pk")

    callbacks = 0
    table.scan_typed(["payload"]) { |_batch| callbacks += 1; nil }
    table.scan_uint64_pk_candidates(["pk"], lower_bound: 0_u64) { |_batch| callbacks += 1; nil }
    table.scan_typed(["pk"]) { |_batch| callbacks += 1; nil }
    callbacks.should eq(0)
  end
end

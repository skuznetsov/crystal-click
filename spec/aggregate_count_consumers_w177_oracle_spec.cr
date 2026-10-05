require "./spec_helper"

# Independent literal consumer oracle over stock-authored parts. It does not
# use the library writer/encoder to construct its expected states or keys.
private class W177ConsumerOracle
  KEYS   = [7_u64, 13_u64, 22_u64, 31_u64, 50_u64]
  COUNTS = [0_u64, 127_u64, 128_u64, 16_384_u64, UInt64::MAX]

  def self.type(label : String) : CrystalClick::BinaryDataType
    uint64 = CrystalClick::BinaryDataType.primitive("UInt64")
    case label
    when "none"     then CrystalClick::BinaryDataType.aggregate_count
    when "uint64"   then CrystalClick::BinaryDataType.aggregate_count(uint64)
    when "nullable" then CrystalClick::BinaryDataType.aggregate_count(CrystalClick::BinaryDataType.nullable(uint64))
    else                 raise ArgumentError.new("unknown Count oracle profile")
    end
  end

  def self.with_parts(stock_root : String, label : String, & : String, Array(String) ->)
    root = File.tempname("crystal-click-w177-literal-oracle")
    Dir.mkdir(root)
    parts = ["all_1_1_0", "all_2_2_0"].map do |name|
      path = File.join(root, name)
      FileUtils.cp_r(File.join(stock_root, "part-#{label}"), path)
      path
    end
    yield root, parts
  ensure
    FileUtils.rm_rf(root) if root && Dir.exists?(root)
  end

  def self.assert_states(values : Array(CrystalClick::BinaryValue), type : CrystalClick::BinaryDataType, expected : Array(UInt64)) : Nil
    values.map(&.count_state).should eq(expected)
    values.each_with_index do |value, index|
      value.type.should eq(type)
      value.bytes.size.should eq(8)
      expect_raises(ArgumentError) { value.as_uint64 }
      bytes = value.bytes
      bytes.fill(0_u8)
      value.count_state.should eq(expected[index])
    end
    nil
  end

  def self.catalog(root : String, parts : Array(String), type_name : String) : CrystalClick::OfflineTable
    catalog_root = File.join(root, "catalog")
    db_uuid = "17700000-0000-4000-8000-000000000011"
    table_uuid = "17700000-0000-4000-8000-000000000012"
    metadata = File.join(catalog_root, "metadata")
    db_store = File.join(catalog_root, "store", db_uuid[0, 3], db_uuid)
    table_store = File.join(catalog_root, "store", table_uuid[0, 3], table_uuid)
    FileUtils.mkdir_p(metadata)
    FileUtils.mkdir_p(db_store)
    FileUtils.mkdir_p(table_store)
    File.write(File.join(metadata, "lab.sql"), "ATTACH DATABASE _ UUID '#{db_uuid}'\nENGINE = Atomic\n")
    File.write(File.join(db_store, "counts.sql"),
      "ATTACH TABLE _ UUID '#{table_uuid}'\n(\n    `pk` UInt64,\n    `c` #{type_name}\n)\nENGINE = MergeTree\nPRIMARY KEY pk\nORDER BY pk\n")
    File.write(File.join(table_store, "format_version.txt"), "1\n")
    Dir.mkdir(File.join(table_store, "detached"))
    parts.each { |part| FileUtils.cp_r(part, File.join(table_store, File.basename(part))) }
    CrystalClick::OfflineCatalog.open(catalog_root)["lab"]["counts"]
  end
end

describe "W177 independent stock literal consumer oracle" do
  if stock_root = ENV["W177_STOCK_ROOT"]?
    ["none", "uint64", "nullable"].each do |label|
      it "retains exact #{label} states across all two-part windows and catalog values" do
        W177ConsumerOracle.with_parts(stock_root, label) do |root, parts|
          type = W177ConsumerOracle.type(label)
          expected = W177ConsumerOracle::COUNTS * 2
          expected_keys = W177ConsumerOracle::KEYS * 2
          table = CrystalClick::WidePartTable.open_selected_typed(parts, ["c", "pk"])
          retained = [] of CrystalClick::BinaryValue
          keys = [] of UInt64
          table.scan_typed(batch_rows: 1) do |batch|
            retained.concat(batch.aggregate_count_states_for("c", type).to_a)
            keys.concat(batch.values_for("pk").to_a)
            nil
          end
          keys.should eq(expected_keys)
          W177ConsumerOracle.assert_states(retained, type, expected)

          # Exhaust every start, including the end, at several requested sizes.
          (0..10).each do |start|
            [1, 2, 3, 6, 12].each do |limit|
              window = [] of CrystalClick::BinaryValue
              window_keys = [] of UInt64
              offsets = [] of UInt64
              table.scan_typed_window(start.to_u64, limit) do |batch|
                states = batch.aggregate_count_states_for("c", type)
                states.each_with_index { |_state, index| offsets << batch.source_row_offset + index.to_u64 }
                window.concat(states.to_a)
                window_keys.concat(batch.values_for("pk").to_a)
                nil
              end
              size = {limit, 10 - start}.min
              W177ConsumerOracle.assert_states(window, type, expected[start, size])
              window_keys.should eq(expected_keys[start, size])
              offsets.should eq((start...(start + size)).map(&.to_u64))
            end
          end

          candidate = [] of CrystalClick::BinaryValue
          table.scan_typed_candidate_marks([[1], [2]]) do |batch|
            candidate.concat(batch.aggregate_count_states_for("c", type).to_a)
            nil
          end
          W177ConsumerOracle.assert_states(candidate, type, [128_u64, 16_384_u64, UInt64::MAX])
          callbacks = 0
          table.scan_typed_candidate_marks([[] of Int32, [] of Int32]) { |_batch| callbacks += 1 }
          callbacks.should eq(0)
          W177ConsumerOracle.assert_states(retained, type, expected)

          offline = W177ConsumerOracle.catalog(root, parts, type.name)
          materialized = offline["c"].values.map(&.as(CrystalClick::BinaryValue))
          W177ConsumerOracle.assert_states(materialized, type, expected)
          offline_keys = [] of UInt64
          offline_states = [] of CrystalClick::BinaryValue
          offline.scan_uint64_pk_candidates(["pk", "c"], 22_u64, 31_u64) do |batch|
            offline_keys.concat(batch.values_for("pk").to_a)
            offline_states.concat(batch.aggregate_count_states_for("c", type).to_a)
            nil
          end
          # The existing sparse-PK policy deliberately includes the preceding
          # granule; these are candidates, not exact range predicate matches.
          offline_keys.should eq([7_u64, 13_u64, 22_u64, 31_u64] * 2)
          W177ConsumerOracle.assert_states(offline_states, type, [0_u64, 127_u64, 128_u64, 16_384_u64] * 2)
          W177ConsumerOracle.assert_states(materialized, type, expected)
        end
      end
    end
  end
end

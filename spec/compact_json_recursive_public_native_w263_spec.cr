require "./spec_helper"
require "file_utils"
require "../scripts/support/compact_json_w263_fixture"
require "./support/compact_json_recursive_public_w263_fixture"

describe "W263 recursive/public Compact JSON native matrix" do
  root = CompactJsonRecursivePublicW263Fixture.evidence_root
  expected = CompactJsonRecursivePublicW263Fixture.expected_signatures
  expected_keys = (1_u64..CompactJsonW263Fixture::ROWS.to_u64).to_a
  selected = CompactJsonRecursivePublicW263Fixture::MIXED_COLUMNS

  CompactJsonRecursivePublicW263Fixture.all_labels.each do |label|
    it "reads #{label} through public recursive Compact JSON carriers" do
      evidence = CompactJsonRecursivePublicW263Fixture.authenticate(root)
      source = CompactJsonRecursivePublicW263Fixture.source_part(evidence, label)
      part_path = source[:path]
      CompactJsonRecursivePublicW263Fixture.assert_native_json_rows!(evidence[0], label)

      # The exact UInt64 control must succeed before mixed public selection is
      # attempted. It distinguishes declaration admission from bad capture or
      # general Compact part opening.
      compact_control = CrystalClick::CompactPartTable.open_selected_typed([part_path], ["pk"])
      compact_control.total_row_count.should eq(CompactJsonW263Fixture::ROWS.to_u64)
      compact_control.part_mark_row_counts.should eq([CompactJsonW263Fixture::MARK_ROWS])
      CompactJsonRecursivePublicW263Fixture.primary_keys(compact_control).should eq(expected_keys)

      typed_control = CrystalClick::TypedPartTable.open_selected_typed([part_path], ["pk"])
      typed_control.total_row_count.should eq(CompactJsonW263Fixture::ROWS.to_u64)
      typed_control.part_mark_row_counts.should eq([CompactJsonW263Fixture::MARK_ROWS])
      CompactJsonRecursivePublicW263Fixture.primary_keys(typed_control).should eq(expected_keys)

      # These are deliberately uncaught positive reads. On the current source,
      # the declaration guard should reject this first mixed Compact open;
      # neither that refusal nor pending support satisfies this test.
      compact = CrystalClick::CompactPartTable.open_selected_typed([part_path], selected)
      typed = CrystalClick::TypedPartTable.open_selected_typed([part_path], selected)
      CompactJsonRecursivePublicW263Fixture.assert_public_matrix!(compact, expected)
      CompactJsonRecursivePublicW263Fixture.assert_public_matrix!(typed, expected)

      parent = File.tempname("crystal-click-w263-recursive-public-")
      Dir.mkdir(parent, 0o700)
      begin
        copied = CompactJsonRecursivePublicW263Fixture.prepare_offline_catalog(
          part_path,
          File.join(parent, "offline-work"),
        )
        CompactJsonW263Fixture.assert_native_inventory!(copied[:part], source[:inventory])
        catalog = CrystalClick::OfflineCatalog.open(copied[:root])
        table = catalog["lab"]["events"]
        table.columns.map { |column| {column.name, column.type} }.should eq(CompactJsonW263Fixture::SCHEMA)
        candidates = table.resolved_scan_parts
        candidates.size.should eq(1)
        File.realpath(candidates[0].path).should eq(File.realpath(copied[:part]))

        CompactJsonRecursivePublicW263Fixture::JSON_COLUMNS.each do |column|
          CompactJsonRecursivePublicW263Fixture.offline_signatures(table, column).should eq(expected[column])
        end
        CompactJsonW263Fixture.assert_native_inventory!(source[:path], source[:inventory])
        CompactJsonW263Fixture.assert_native_inventory!(copied[:part], source[:inventory])
      ensure
        FileUtils.rm_rf(parent)
      end
    end
  end
end

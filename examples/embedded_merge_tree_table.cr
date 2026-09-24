require "../src/crystal_click"

module EmbeddedMergeTreeTableExample
  extend self

  def run(args : Array(String)) : Nil
    unless args.size == 1
      STDERR.puts "usage: crystal run examples/embedded_merge_tree_table.cr -- NEW_TABLE_ROOT"
      STDERR.puts "NEW_TABLE_ROOT must not already exist; this example creates a Crystal-owned table"
      exit 64
    end

    root = args[0]
    table = CrystalClick::EmbeddedMergeTreeTable.create(root, "pk", "value")
    keys = [1_u64, 2_u64, 3_u64]
    values = ["alpha", "", "é"]
    part = table.insert(keys.to_unsafe.to_slice(keys.size), values.to_unsafe.to_slice(values.size), rows_per_mark: 2)
    puts "committed #{part} under #{root}"

    reopened = CrystalClick::EmbeddedMergeTreeTable.open(root)
    reopened.scan_typed(["pk", "value"]) do |batch|
      batch_keys = batch.values_for("pk")
      batch_values = batch.strings_for("value")
      batch_keys.each_with_index do |key, index|
        puts "#{key}\t#{batch_values[index]}"
      end
    end
  rescue ex : Exception
    STDERR.puts "embedded table example failed: #{ex.message}"
    exit 1
  end
end

EmbeddedMergeTreeTableExample.run(ARGV)

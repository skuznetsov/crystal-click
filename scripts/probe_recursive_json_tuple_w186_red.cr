require "../src/crystal_click"
require "json"

module ProbeRecursiveJSONTupleW186RED
  extend self

  def usage : NoReturn
    STDERR.puts "usage: probe_recursive_json_tuple_w186_red STOCK_TUPLE_JSON_PART"
    exit 64
  end

  # Baseline falsifier: call the pre-feature public typed-table path against a
  # stock-written Tuple(JSON, JSON, UInt64) part and report only its real result.
  # Process and non-format failures remain errors rather than being relabeled.
  def run(args : Array(String)) : Nil
    usage unless args.size == 1
    part = args[0]
    begin
      table = CrystalClick::WidePartTable.open_selected_typed([part], ["pk", "pair"])
      rows = 0
      table.scan_typed(batch_rows: 2) do |batch|
        rows += batch.tuple_rows_for("pair").size
        nil
      end
      puts({
        "status"    => "accepted",
        "row_count" => rows,
      }.to_json)
    rescue ex : CrystalClick::UnsupportedFormatError
      puts({
        "status"      => "unsupported",
        "error_class" => ex.class.to_s,
        "message"     => ex.message || "",
      }.to_json)
    rescue ex : Exception
      STDERR.puts "W186 RED helper failed outside the expected format guard: #{ex.class}: #{ex.message}"
      exit 1
    end
  end
end

ProbeRecursiveJSONTupleW186RED.run(ARGV)

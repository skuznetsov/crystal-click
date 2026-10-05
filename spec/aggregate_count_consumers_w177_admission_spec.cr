require "./spec_helper"

private def w177_admission_copy(stock_root : String, label : String, & : String ->)
  parent = File.tempname("crystal-click-w177-admission")
  Dir.mkdir(parent)
  path = File.join(parent, "all_1_1_0")
  FileUtils.cp_r(File.join(stock_root, "part-#{label}"), path)
  yield path
ensure
  FileUtils.rm_rf(parent) if parent && Dir.exists?(parent)
end

describe "W177 Count table public admission" do
  if stock_root = ENV["W177_STOCK_ROOT"]?
    {
      "none"     => "AggregateFunction(count)",
      "uint64"   => "AggregateFunction(count, UInt64)",
      "nullable" => "AggregateFunction(count, Nullable(UInt64))",
    }.each do |label, type_name|
      it "scans exact #{type_name} through the ordinary typed entry point" do
        w177_admission_copy(stock_root, label) do |path|
          accepted = true
          callbacks = 0
          begin
            table = CrystalClick::WidePartTable.open_selected_typed([path], ["c"])
            table.scan_typed { |_batch| callbacks += 1 }
          rescue CrystalClick::UnsupportedFormatError
            accepted = false
          end
          accepted.should be_true
          callbacks.should be > 0
        end
      end
    end

    it "retains an independent primitive UInt64 key-only control" do
      w177_admission_copy(stock_root, "none") do |path|
        table = CrystalClick::WidePartTable.open_selected_typed([path], ["pk"])
        keys = [] of UInt64
        table.scan_typed { |batch| keys.concat(batch.values_for("pk").to_a) }
        keys.should eq([7_u64, 13_u64, 22_u64, 31_u64, 50_u64])
      end
    end
  end
end

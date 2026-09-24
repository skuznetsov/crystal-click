require "./spec_helper"

{% if flag?(:crystal_click_test_failpoints) %}
  # This spec executable doubles as a child writer/GC worker. The test parent
  # waits until TestFailpoint has published its phase-ready file, then sends
  # SIGKILL while the operation is held at the selected boundary.
  if worker = ENV["CRYSTAL_CLICK_W6_CRASH_WORKER"]?
    begin
      root = ENV["CRYSTAL_CLICK_W6_CRASH_ROOT"]? || raise "missing W6 crash root"
      table = CrystalClick::EmbeddedMergeTreeTable.open(root)
      case worker
      when "insert"
        table.insert([7_u64].to_unsafe.to_slice(1), ["crash-row"].to_unsafe.to_slice(1), rows_per_mark: 1)
      when "reclaim"
        table.reclaim_obsolete!
      else
        raise "unknown W6 crash worker: #{worker}"
      end
      Process.exit(0)
    rescue ex
      STDERR.puts ex.message || ex.class.name
      Process.exit(2)
    end
  end

  def with_embedded_fault_parent(&)
    parent = File.tempname("crystal-click-embedded-fault-spec")
    Dir.mkdir(parent)
    begin
      yield parent
    ensure
      FileUtils.rm_rf(parent)
    end
  end

  def embedded_fault_rows(table : CrystalClick::EmbeddedMergeTreeTable) : Array({UInt64, String})
    rows = [] of {UInt64, String}
    table.scan_typed(["pk", "value"], batch_rows: 2) do |batch|
      keys = batch.values_for("pk", UInt64)
      values = batch.strings_for("value")
      keys.size.should eq(values.size)
      keys.size.times { |index| rows << {keys[index], values[index]} }
    end
    rows
  end

  def sigkill_embedded_fault_worker(root : String, operation : String, phase : String, ready_path : String) : Process::Status
    executable = Process.executable_path || raise "spec executable path unavailable"
    child = Process.new(
      executable,
      env: {
        "CRYSTAL_CLICK_W6_CRASH_WORKER"      => operation,
        "CRYSTAL_CLICK_W6_CRASH_ROOT"        => root,
        "CRYSTAL_CLICK_TEST_FAILPOINT"       => phase,
        "CRYSTAL_CLICK_TEST_FAILPOINT_READY" => ready_path,
      },
      output: Process::Redirect::Pipe,
      error: Process::Redirect::Pipe
    )
    waited = false
    begin
      deadline = Time.instant + 10.seconds
      until File.exists?(ready_path)
        raise "worker exited before reaching failpoint #{phase}" if child.terminated?
        raise "worker did not reach failpoint #{phase}" if Time.instant > deadline
        sleep 5.milliseconds
      end
      File.read(ready_path).should eq(phase)

      child.signal(Signal::KILL)
      status = child.wait
      waited = true
      status.exit_signal?.should eq(Signal::KILL)
      status
    ensure
      unless waited
        child.signal(Signal::KILL) unless child.terminated?
        begin
          child.wait
        rescue Channel::ClosedError
        end
      end
    end
  end

  describe "EmbeddedMergeTreeTable process-crash windows" do
    it "reopens after SIGKILL immediately after writer-stage creation" do
      with_embedded_fault_parent do |parent|
        root = File.join(parent, "table")
        table = CrystalClick::EmbeddedMergeTreeTable.create(root, "pk", "value")
        ready_path = File.join(parent, "writer-stage-ready")

        sigkill_embedded_fault_worker(root, "insert", "writer_stage_created", ready_path)

        reopened = CrystalClick::EmbeddedMergeTreeTable.open(root)
        stage_names = reopened.orphan_part_names
        stage_names.size.should eq(1)
        stage_names[0].should start_with(CrystalClick::EmbeddedMergeTreeTable::WRITER_STAGE_PREFIX)
        Dir.exists?(File.join(root, "parts", stage_names[0])).should be_true
        reopened.part_paths.should be_empty
        embedded_fault_rows(reopened).should be_empty
        Dir.children(File.join(root, "committed")).should be_empty
      end
    end

    it "keeps a fully published pre-marker part invisible and reserves its block after SIGKILL" do
      with_embedded_fault_parent do |parent|
        root = File.join(parent, "table")
        table = CrystalClick::EmbeddedMergeTreeTable.create(root, "pk", "value")
        ready_path = File.join(parent, "part-published-ready")

        sigkill_embedded_fault_worker(root, "insert", "part_published", ready_path)

        reopened = CrystalClick::EmbeddedMergeTreeTable.open(root)
        reopened.orphan_part_names.should eq(["all_1_1_0"])
        Dir.exists?(File.join(root, "parts", "all_1_1_0")).should be_true
        Dir.children(File.join(root, "committed")).should be_empty
        reopened.part_paths.should be_empty
        embedded_fault_rows(reopened).should be_empty

        reopened.insert([8_u64].to_unsafe.to_slice(1), ["retry-row"].to_unsafe.to_slice(1), rows_per_mark: 1).should eq("all_2_2_0")
        embedded_fault_rows(reopened).should eq([{8_u64, "retry-row"}])
      end
    end

    it "reopens the committed row after SIGKILL following marker creation" do
      with_embedded_fault_parent do |parent|
        root = File.join(parent, "table")
        CrystalClick::EmbeddedMergeTreeTable.create(root, "pk", "value")
        ready_path = File.join(parent, "marker-created-ready")

        sigkill_embedded_fault_worker(root, "insert", "marker_created", ready_path)

        reopened = CrystalClick::EmbeddedMergeTreeTable.open(root)
        reopened.orphan_part_names.should be_empty
        reopened.part_paths.map { |path| File.basename(path) }.should eq(["all_1_1_0"])
        Dir.children(File.join(root, "committed")).should eq(["all_1_1_0"])
        embedded_fault_rows(reopened).should eq([{7_u64, "crash-row"}])
      end
    end

    it "retries marker-first reclamation after SIGKILL without changing active rows" do
      with_embedded_fault_parent do |parent|
        root = File.join(parent, "table")
        table = CrystalClick::EmbeddedMergeTreeTable.create(root, "pk", "value")
        left = table.insert([1_u64].to_unsafe.to_slice(1), ["left"].to_unsafe.to_slice(1), rows_per_mark: 1)
        right = table.insert([2_u64].to_unsafe.to_slice(1), ["right"].to_unsafe.to_slice(1), rows_per_mark: 1)
        merged = table.merge_adjacent(left, right, rows_per_mark: 1)
        expected_rows = [{1_u64, "left"}, {2_u64, "right"}]
        embedded_fault_rows(table).should eq(expected_rows)
        ready_path = File.join(parent, "gc-marker-removed-ready")

        sigkill_embedded_fault_worker(root, "reclaim", "gc_marker_removed", ready_path)

        reopened = CrystalClick::EmbeddedMergeTreeTable.open(root)
        reopened.part_paths.map { |path| File.basename(path) }.should eq([merged])
        embedded_fault_rows(reopened).should eq(expected_rows)
        interrupted_orphans = reopened.orphan_part_names
        interrupted_orphans.should_not be_empty
        interrupted_orphans.each do |name|
          Dir.exists?(File.join(root, "parts", name)).should be_true
          Dir.exists?(File.join(root, "committed", name)).should be_false
        end

        reopened.reclaim_obsolete!
        reopened.orphan_part_names.should be_empty
        Dir.children(File.join(root, "parts")).should eq([merged])
        Dir.children(File.join(root, "committed")).should eq([merged])
        embedded_fault_rows(reopened).should eq(expected_rows)
      end
    end
  end
{% end %}

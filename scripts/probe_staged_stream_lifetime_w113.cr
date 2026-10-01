require "file_utils"
require "../src/crystal_click"

# This probe exercises the existing public writer routes while injecting one
# failure at a stage-local .mrk2 open. It records the real earlier File handles
# and closes them in ensure so the diagnostic itself does not leak resources.
module W113OpenTrace
  class InjectedOpenError < Exception
    getter token : String

    def initialize(@token : String)
      super("W113 injected File.open failure: #{@token}")
    end
  end

  class State
    getter sentinel : InjectedOpenError
    getter intercept_count : Int32
    getter events : Array(String)

    def initialize(@stage_prefix : String, @target_basename : String, @sentinel : InjectedOpenError)
      @files = [] of File
      @intercept_count = 0
      @events = [] of String
    end

    def intercept?(path : String, mode : String) : Bool
      return false unless mode == "rb"
      return false unless path.starts_with?(@stage_prefix)
      return false unless File.basename(path) == @target_basename
      return false unless @intercept_count == 0

      @intercept_count += 1
      @events << "inject #{File.basename(path)}"
      true
    end

    def capture(path : String, mode : String, file : File) : Nil
      return unless mode == "rb" && path.starts_with?(@stage_prefix)

      @files << file
      @events << "open #{File.basename(path)}"
    end

    def open_handle_count : Int32
      @files.count { |file| !file.closed? }
    end

    def close_all : Nil
      @files.each do |file|
        file.close unless file.closed?
      end
      nil
    end
  end

  @@state : State? = nil

  def self.activate(state : State) : Nil
    @@state = state
  end

  def self.state : State?
    @@state
  end

  def self.deactivate : Nil
    @@state = nil
  end
end

# The public writer validators use the no-block File.open(path, "rb") form.
# Keep all other File.open calls unchanged and delegate through previous_def.
class File
  def self.open(
    filename : Path | String,
    mode = "r",
    perm = DEFAULT_CREATE_PERMISSIONS,
    encoding = nil,
    invalid = nil,
    blocking = nil,
  ) : self
    path = filename.to_s
    if state = W113OpenTrace.state
      raise state.sentinel if state.intercept?(path, mode)
    end

    file = previous_def(filename, mode, perm, encoding, invalid, blocking)
    if state = W113OpenTrace.state
      state.capture(path, mode, file)
    end
    file
  end
end

private def w113_run_case(
  label : String,
  parent : String,
  target_basename : String,
  &block : -> String
) : Int32
  token = "#{Process.pid}:#{label}:#{target_basename}"
  sentinel = W113OpenTrace::InjectedOpenError.new(token)
  stage_prefix = File.join(parent, ".crystal-click-wide-writer-")
  state = W113OpenTrace::State.new(stage_prefix, target_basename, sentinel)
  W113OpenTrace.activate(state)

  completed = false
  caught_sentinel = false
  same_sentinel = false
  open_handles = 0
  begin
    yield
    completed = true
  rescue error : W113OpenTrace::InjectedOpenError
    caught_sentinel = true
    same_sentinel = error.object_id == sentinel.object_id
  ensure
    open_handles = state.open_handle_count
    begin
      state.close_all
    ensure
      W113OpenTrace.deactivate
    end
  end

  raise "#{label}: writer unexpectedly completed without reaching injected open" if completed
  raise "#{label}: target stage .mrk2 open was not intercepted exactly once" unless state.intercept_count == 1
  raise "#{label}: injected sentinel did not propagate unchanged" unless caught_sentinel && same_sentinel

  puts "QUALIFIED-OBSERVATION #{label}: intercepted once; #{open_handles} earlier stage File handle(s) remained open at unwind"
  puts "  stage rb trace: #{state.events.join(" -> ")}"
  open_handles
end

private def w113_run_numeric_partial_open(parent : String) : Int32
  keys = [1_u64, 2_u64, 3_u64]
  values = [] of Array(Array(Tuple(UInt64, Array(UInt64))))

  first_map = [] of Tuple(UInt64, Array(UInt64))
  first_map << {10_u64, [11_u64, 12_u64]}
  first_row = [] of Array(Tuple(UInt64, Array(UInt64)))
  first_row << first_map
  values << first_row
  values << ([] of Array(Tuple(UInt64, Array(UInt64))))

  last_map = [] of Tuple(UInt64, Array(UInt64))
  last_map << {20_u64, [21_u64]}
  last_row = [] of Array(Tuple(UInt64, Array(UInt64)))
  last_row << last_map
  values << last_row

  destination = File.join(parent, "numeric-part")
  target = "#{CrystalClick::StreamName.hash("nested.size1")}.mrk2"
  open_handles = w113_run_case("array-map-array-numeric", parent, target) do
    CrystalClick::WidePartWriter.write_uint64_array_map_uint64_array_numeric_pair(
      destination,
      "pk",
      keys.to_unsafe.to_slice(keys.size),
      "nested",
      values.to_unsafe.to_slice(values.size),
      2
    )
  end
  raise "numeric case published a destination after validation failure" if File.exists?(destination)
  raise "numeric case left stage files in its temporary parent" unless Dir.children(parent).empty?
  open_handles
end

private def w113_run_nullable_bool_partial_open(parent : String) : Int32
  keys = [4_u64, 5_u64, 6_u64]
  values = [] of Array(Array(Tuple(UInt64, Bool?)))

  first_map = [] of Tuple(UInt64, Bool?)
  first_map << {40_u64, true}
  values << [first_map]
  second_map = [] of Tuple(UInt64, Bool?)
  second_map << {50_u64, nil}
  values << [second_map]
  third_map = [] of Tuple(UInt64, Bool?)
  third_map << {60_u64, false}
  values << [third_map]

  destination = File.join(parent, "nullable-bool-part")
  target = "#{CrystalClick::StreamName.hash("nullable%2Evalues.null")}.mrk2"
  open_handles = w113_run_case("array-map-nullable-bool", parent, target) do
    CrystalClick::WidePartWriter.write_uint64_array_map_uint64_nullable_bool_pair(
      destination,
      "pk",
      keys.to_unsafe.to_slice(keys.size),
      "nullable",
      values.to_unsafe.to_slice(values.size),
      2
    )
  end
  raise "Nullable(Bool) case published a destination after validation failure" if File.exists?(destination)
  raise "Nullable(Bool) case left stage files in its temporary parent" unless Dir.children(parent).empty?
  open_handles
end

mode = ARGV.first? || "qualify"
raise "usage: probe_staged_stream_lifetime_w113.cr [qualify|red]" unless mode == "qualify" || mode == "red"

parent = File.tempname("crystal-click-staged-stream-lifetime-w113")
Dir.mkdir(parent)
begin
  observed = [
    w113_run_numeric_partial_open(parent),
    w113_run_nullable_bool_partial_open(parent),
  ]

  case mode
  when "qualify"
    unless observed.all? { |count| count > 0 }
      raise "qualification inconclusive: expected both current validators to leave an earlier acquired handle open"
    end
    puts "QUALIFIED: both existing validators leak earlier real File handles when a later stage mark open raises"
  when "red"
    unless observed.all? { |count| count == 0 }
      raise "RED: expected every earlier acquired stage File handle to be closed before sentinel propagation"
    end
    puts "PASS: both validators close all earlier acquired stage File handles before sentinel propagation"
  end
ensure
  FileUtils.rm_rf(parent)
end

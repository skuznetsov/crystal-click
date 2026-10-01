require "./spec_helper"

module W113StagedFiles
  class InjectedError < Exception
  end

  class State
    getter paths : Array(String)
    getter opened_paths = [] of String
    getter opened_files = [] of File
    getter open_attempts = [] of String
    getter close_paths = [] of String

    @open_failure_path : String?
    @open_failure : Exception?
    @close_failure_on_open_error : Exception?
    @path_by_file_id = {} of UInt64 => String
    @close_failures = {} of UInt64 => Exception

    def initialize(
      @paths : Array(String),
      @open_failure_path : String? = nil,
      @open_failure : Exception? = nil,
      @close_failure_on_open_error : Exception? = nil,
    )
    end

    def before_open(path : String, mode : String) : Exception?
      return unless mode == "rb" && @paths.includes?(path)

      @open_attempts << path
      return unless path == @open_failure_path

      if close_error = @close_failure_on_open_error
        if file = @opened_files.first?
          @close_failures[file.object_id] = close_error
        end
      end
      @open_failure
    end

    def capture_open(path : String, mode : String, file : File) : Nil
      return unless mode == "rb" && @paths.includes?(path)

      @opened_paths << path
      @opened_files << file
      @path_by_file_id[file.object_id] = path
    end

    def fail_close(file : File, error : Exception) : Nil
      @close_failures[file.object_id] = error
    end

    def before_close(file : File) : Exception?
      file_id = file.object_id
      return unless path = @path_by_file_id[file_id]?

      @close_paths << path
      @close_failures[file_id]?
    end

    def all_closed? : Bool
      @opened_files.all?(&.closed?)
    end

    def cleanup : Nil
      @opened_files.each do |file|
        file.close unless file.closed?
      end
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

# Keep the real File API as the delegated implementation and inject only
# stage handles opened by this focused owner test.
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
    if state = W113StagedFiles.state
      if error = state.before_open(path, mode)
        raise error
      end
    end

    file = previous_def(filename, mode, perm, encoding, invalid, blocking)
    if state = W113StagedFiles.state
      state.capture_open(path, mode, file)
    end
    file
  end

  def close
    if state = W113StagedFiles.state
      error = state.before_close(self)
      if error
        super
        raise error
      end
    end
    super
  end
end

module CrystalClick::WidePartWriter
  def self.with_staged_stream_files_for_spec(paths : Array(String), & : StagedStreamFileSet -> T) : T forall T
    StagedStreamFileSet.with_paths(paths) do |files|
      yield files
    end
  end
end

def with_w113_stream_paths(count : Int32, &)
  root = File.tempname("crystal-click-w113-streams")
  Dir.mkdir(root)
  paths = Array(String).new(count) do |index|
    path = File.join(root, "stream-#{index}.bin")
    File.write(path, "stream-#{index}")
    path
  end
  begin
    yield paths
  ensure
    W113StagedFiles.deactivate
    FileUtils.rm_rf(root)
  end
end

describe CrystalClick::WidePartWriter do
  it "closes every successfully acquired prefix when each open position fails" do
    with_w113_stream_paths(4) do |paths|
      paths.each_with_index do |failed_path, failed_index|
        sentinel = W113StagedFiles::InjectedError.new("open #{failed_index}")
        state = W113StagedFiles::State.new(paths, failed_path, sentinel)
        W113StagedFiles.activate(state)

        begin
          error = expect_raises(W113StagedFiles::InjectedError) do
            CrystalClick::WidePartWriter.with_staged_stream_files_for_spec(paths) { |_| nil }
          end
          error.should be(sentinel)
          state.open_attempts.should eq(paths[0..failed_index])
          state.opened_paths.should eq(paths[0...failed_index])
          state.opened_files.size.should eq(failed_index)
          state.all_closed?.should be_true
        ensure
          W113StagedFiles.deactivate
          state.cleanup
        end
      end
    end
  end

  it "preserves an acquisition exception when closing an earlier handle also fails" do
    with_w113_stream_paths(3) do |paths|
      open_error = W113StagedFiles::InjectedError.new("late open failure")
      close_error = W113StagedFiles::InjectedError.new("earlier close failure")
      state = W113StagedFiles::State.new(paths, paths[2], open_error, close_error)
      W113StagedFiles.activate(state)

      begin
        error = expect_raises(W113StagedFiles::InjectedError) do
          CrystalClick::WidePartWriter.with_staged_stream_files_for_spec(paths) { |_| nil }
        end

        error.should be(open_error)
        state.open_attempts.should eq(paths[0..2])
        state.opened_paths.should eq(paths[0...2])
        state.close_paths.should eq(paths[0...2])
        state.all_closed?.should be_true
      ensure
        W113StagedFiles.deactivate
        state.cleanup
      end
    end
  end

  it "opens in caller order, provides indexed handles only during the block, and closes on success" do
    with_w113_stream_paths(3) do |paths|
      state = W113StagedFiles::State.new(paths)
      W113StagedFiles.activate(state)

      begin
        values = CrystalClick::WidePartWriter.with_staged_stream_files_for_spec(paths) do |files|
          paths.each_index do |index|
            file = files.file_at(index)
            file.closed?.should be_false
            file.gets.should eq("stream-#{index}")
          end
          state.opened_paths.dup
        end

        values.should eq(paths)
        state.open_attempts.should eq(paths)
        state.opened_paths.should eq(paths)
        state.close_paths.should eq(paths)
        state.all_closed?.should be_true
      ensure
        W113StagedFiles.deactivate
        state.cleanup
      end
    end
  end

  it "closes the acquired set when the caller breaks out of the block" do
    with_w113_stream_paths(2) do |paths|
      state = W113StagedFiles::State.new(paths)
      W113StagedFiles.activate(state)

      begin
        escaped = CrystalClick::WidePartWriter.with_staged_stream_files_for_spec(paths) do |files|
          state.opened_paths.should eq(paths)
          files.file_at(0).closed?.should be_false
          break :escaped
        end

        escaped.should eq(:escaped)
        state.close_paths.should eq(paths)
        state.all_closed?.should be_true
      ensure
        W113StagedFiles.deactivate
        state.cleanup
      end
    end
  end

  it "preserves the body exception identity while attempting every close" do
    with_w113_stream_paths(3) do |paths|
      sentinel = W113StagedFiles::InjectedError.new("body failure")
      state = W113StagedFiles::State.new(paths)
      W113StagedFiles.activate(state)

      begin
        error = expect_raises(W113StagedFiles::InjectedError) do
          CrystalClick::WidePartWriter.with_staged_stream_files_for_spec(paths) do |files|
            state.fail_close(files.file_at(0), W113StagedFiles::InjectedError.new("close zero"))
            state.fail_close(files.file_at(1), W113StagedFiles::InjectedError.new("close one"))
            raise sentinel
          end
        end

        error.should be(sentinel)
        state.close_paths.should eq(paths)
        state.all_closed?.should be_true
      ensure
        W113StagedFiles.deactivate
        state.cleanup
      end
    end
  end

  it "attempts every close and reports the first close failure after a successful body" do
    with_w113_stream_paths(3) do |paths|
      first_close_error = W113StagedFiles::InjectedError.new("first close failure")
      second_close_error = W113StagedFiles::InjectedError.new("second close failure")
      state = W113StagedFiles::State.new(paths)
      W113StagedFiles.activate(state)

      begin
        error = expect_raises(W113StagedFiles::InjectedError) do
          CrystalClick::WidePartWriter.with_staged_stream_files_for_spec(paths) do |files|
            state.fail_close(files.file_at(0), first_close_error)
            state.fail_close(files.file_at(1), second_close_error)
            :body_succeeded
          end
        end

        error.should be(first_close_error)
        state.close_paths.should eq(paths)
        state.all_closed?.should be_true
      ensure
        W113StagedFiles.deactivate
        state.cleanup
      end
    end
  end
end

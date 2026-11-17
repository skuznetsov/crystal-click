module CrystalClick
  class MMapCleanupError < Error
    getter callback_error : Exception
    getter cleanup_error : Error

    def initialize(@callback_error : Exception, @cleanup_error : Error)
      super("mmap cleanup failed after callback error: #{callback_error.message || callback_error.class}; #{cleanup_error.message || cleanup_error.class}")
    end
  end

  # Opens read-only mappings for bounded scan operations.
  module MMapDataSource
    {% if flag?(:unix) %}
      private struct NativeBackend
        def map(file : File, size : UInt64, offset : Int64) : Pointer(Void)
          {% if flag?(:read_rows_profile) %}
            started = Time.instant
          {% end %}
          pointer = LibC.mmap(nil, size, LibC::PROT_READ, LibC::MAP_PRIVATE, file.fd, offset)
          {% if flag?(:read_rows_profile) %}
            finished = Time.instant
            if worker = ReadRowsProfile.current_worker?
              worker.add_mapping(ReadRowsProfile.elapsed_ns_between(started, finished), size, pointer != LibC::MAP_FAILED)
            end
          {% end %}
          pointer
        end

        def unmap(file : File, pointer : Pointer(Void), size : UInt64) : Int32
          {% if flag?(:read_rows_profile) %}
            started = Time.instant
          {% end %}
          result = LibC.munmap(pointer, size)
          {% if flag?(:read_rows_profile) %}
            finished = Time.instant
            ReadRowsProfile.current_worker?.try &.add_unmapping(ReadRowsProfile.elapsed_ns_between(started, finished))
          {% end %}
          result
        end
      end

      # :nodoc:
      # Explicit owner for callers that retain a read-only mapping across
      # scans or share it among isolated workers. The file descriptor is
      # closed after mmap succeeds. The owner closes the mapping after users
      # finish. By default mappings are private. A shared mapping exposes
      # writes to the same file through the read-only view.
      class MappedFile
        getter bytes : Bytes

        @pointer : Pointer(Void)
        @size : UInt64
        @closed : Bool

        def initialize(pointer : Pointer(Void), size : UInt64)
          @pointer = pointer
          @size = size
          @closed = false
          @bytes = Bytes.new(pointer.as(UInt8*), size.to_i, read_only: true)
        end

        def close : Nil
          return nil if @closed
          @closed = true
          if LibC.munmap(@pointer, @size) != 0
            raise CorruptPartError.new("cannot unmap data file")
          end
          nil
        end
      end

      def self.open_mapped_file(path : String, expected_size : Int64, max_size : Int64, shared : Bool = false) : MappedFile
        file = open_regular_file(path, expected_size, max_size)

        pointer = Pointer(Void).null
        mapped_size = 0_u64
        mapped = false
        begin
          if expected_size > Int32::MAX
            raise CorruptPartError.new("data file exceeds supported in-memory domain")
          end
          size = expected_size.to_u64
          flags = shared ? LibC::MAP_SHARED : LibC::MAP_PRIVATE
          pointer = LibC.mmap(nil, size, LibC::PROT_READ, flags, file.fd, 0_i64)
          raise CorruptPartError.new("cannot map data file") if pointer == LibC::MAP_FAILED
          mapped_size = size
          mapped = true

          begin
            file.close
          rescue ex : IO::Error
            cleanup_error = nil.as(Error?)
            if LibC.munmap(pointer, size) != 0
              cleanup_error = CorruptPartError.new("cannot unmap data file after descriptor-close failure")
            end
            mapped = false
            close_error = CorruptPartError.new(ex.message || "cannot close mapped data file")
            if cleanup = cleanup_error
              raise MMapCleanupError.new(close_error, cleanup)
            end
            raise close_error
          end

          MappedFile.new(pointer, size)
        rescue ex
          if mapped && LibC.munmap(pointer, mapped_size) != 0
            raise MMapCleanupError.new(ex, CorruptPartError.new("cannot unmap data file after mapping failure"))
          end
          raise ex
        ensure
          file.close unless file.closed?
        end
      end

      def self.with_file(path : String, expected_size : Int64, max_size : Int64, & : Bytes ->) : Nil
        with_file_using_backend(path, expected_size, max_size, NativeBackend.new) do |bytes|
          yield bytes
        end
      end

      # Internal/test-only backend injection. Mapped bytes remain callback-scoped.
      private def self.with_file_using_backend(path : String, expected_size : Int64, max_size : Int64, backend, & : Bytes ->) : Nil
        file = open_regular_file(path, expected_size, max_size)

        begin
          size = expected_size.to_u64
          pointer = backend.map(file, size, 0_i64)
          raise CorruptPartError.new("cannot map data file") if pointer == LibC::MAP_FAILED

          callback_error : Exception? = nil
          begin
            bytes = Bytes.new(pointer.as(UInt8*), expected_size.to_i, read_only: true)
            yield bytes
          rescue ex
            callback_error = ex
            raise ex
          ensure
            if backend.unmap(file, pointer, size) != 0
              cleanup_error = CorruptPartError.new("cannot unmap data file")
              if callback_error.nil?
                raise cleanup_error
              else
                raise MMapCleanupError.new(callback_error.not_nil!, cleanup_error)
              end
            end
          end
        ensure
          {% if flag?(:read_rows_profile) %}
            close_started = Time.instant
          {% end %}
          file.close
          {% if flag?(:read_rows_profile) %}
            close_finished = Time.instant
            ReadRowsProfile.current_worker?.try &.add_file_close(ReadRowsProfile.elapsed_ns_between(close_started, close_finished))
          {% end %}
        end
      end

      private def self.open_regular_file(path : String, expected_size : Int64, max_size : Int64) : File
        raise CorruptPartError.new("data file size is invalid") if expected_size <= 0 || expected_size > max_size

        file = begin
          {% if flag?(:read_rows_profile) %}
            open_started = Time.instant
          {% end %}
          opened = File.open(path, "rb")
          {% if flag?(:read_rows_profile) %}
            open_finished = Time.instant
            ReadRowsProfile.current_worker?.try &.add_file_open(ReadRowsProfile.elapsed_ns_between(open_started, open_finished))
          {% end %}
          opened
        rescue ex : IO::Error
          raise CorruptPartError.new(ex.message || "cannot open data file")
        end

        begin
          info = begin
            {% if flag?(:read_rows_profile) %}
              stat_started = Time.instant
            {% end %}
            result = file.info
            {% if flag?(:read_rows_profile) %}
              stat_finished = Time.instant
              ReadRowsProfile.current_worker?.try &.add_file_stat(ReadRowsProfile.elapsed_ns_between(stat_started, stat_finished))
            {% end %}
            result
          rescue ex : IO::Error
            raise CorruptPartError.new(ex.message || "cannot stat data file")
          end
          raise CorruptPartError.new("data file is not a regular file") unless info.file?
          actual_size = info.size
          raise CorruptPartError.new("data file size changed") unless actual_size == expected_size
          raise CorruptPartError.new("data file size is invalid") if actual_size <= 0 || actual_size > max_size
          file
        rescue ex
          file.close unless file.closed?
          raise ex
        end
      end
    {% else %}
      class MappedFile
        getter bytes : Bytes

        private def initialize(@bytes : Bytes)
        end

        def close : Nil
          nil
        end
      end

      def self.open_mapped_file(path : String, expected_size : Int64, max_size : Int64, shared : Bool = false) : MappedFile
        raise UnsupportedFormatError.new("mmap data source is unsupported on this platform")
      end

      def self.with_file(path : String, expected_size : Int64, max_size : Int64, & : Bytes ->) : Nil
        raise UnsupportedFormatError.new("mmap data source is unsupported on this platform")
      end
    {% end %}
  end
end

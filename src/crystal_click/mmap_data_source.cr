module CrystalClick
  class MMapCleanupError < Error
    getter callback_error : Exception
    getter cleanup_error : Error

    def initialize(@callback_error : Exception, @cleanup_error : Error)
      super("mmap cleanup failed after callback error: #{callback_error.message || callback_error.class}; #{cleanup_error.message || cleanup_error.class}")
    end
  end

  # Owns a read-only mapping for exactly one bounded callback operation.
  module MMapDataSource
    {% if flag?(:unix) %}
      private struct NativeBackend
        def map(file : File, size : UInt64, offset : Int64) : Pointer(Void)
          LibC.mmap(nil, size, LibC::PROT_READ, LibC::MAP_PRIVATE, file.fd, offset)
        end

        def unmap(file : File, pointer : Pointer(Void), size : UInt64) : Int32
          LibC.munmap(pointer, size)
        end
      end

      def self.with_file(path : String, expected_size : Int64, max_size : Int64, & : Bytes ->) : Nil
        with_file_using_backend(path, expected_size, max_size, NativeBackend.new) do |bytes|
          yield bytes
        end
      end

      # Internal/test-only backend injection. Mapped bytes remain callback-scoped.
      private def self.with_file_using_backend(path : String, expected_size : Int64, max_size : Int64, backend, & : Bytes ->) : Nil
        raise CorruptPartError.new("data file size is invalid") if expected_size <= 0 || expected_size > max_size

        file = begin
          File.open(path, "rb")
        rescue ex : IO::Error
          raise CorruptPartError.new(ex.message || "cannot open data file")
        end

        begin
          info = begin
            file.info
          rescue ex : IO::Error
            raise CorruptPartError.new(ex.message || "cannot stat data file")
          end
          raise CorruptPartError.new("data file is not a regular file") unless info.file?

          actual_size = info.size
          raise CorruptPartError.new("data file size changed") unless actual_size == expected_size
          raise CorruptPartError.new("data file size is invalid") if actual_size <= 0 || actual_size > max_size

          size = actual_size.to_u64
          pointer = backend.map(file, size, 0_i64)
          raise CorruptPartError.new("cannot map data file") if pointer == LibC::MAP_FAILED

          callback_error : Exception? = nil
          begin
            bytes = Bytes.new(pointer.as(UInt8*), actual_size.to_i, read_only: true)
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
          file.close
        end
      end
    {% else %}
      def self.with_file(path : String, expected_size : Int64, max_size : Int64, & : Bytes ->) : Nil
        raise UnsupportedFormatError.new("mmap data source is unsupported on this platform")
      end
    {% end %}
  end
end

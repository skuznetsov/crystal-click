module CrystalClick
  module WidePartWriter
    # Owns the ordered set of stage stream handles for one validation scope.
    # Callers can read a handle by index, but cannot take ownership of the
    # mutable handle array or append a handle that cleanup would miss.
    private class StagedStreamFileSet
      @files : Array(File)

      private def initialize(capacity : Int32)
        @files = Array(File).new(capacity)
      end

      def self.with_paths(paths : Array(String), &block : StagedStreamFileSet -> T) : T forall T
        files = new(paths.size)
        original_error : Exception? = nil
        begin
          paths.each { |path| files.acquire(path) }
          yield files
        rescue error : Exception
          original_error = error
          raise error
        ensure
          close_error = files.close_all
          raise close_error if original_error.nil? && close_error
        end
      end

      def file_at(index : Int32) : File
        @files[index]
      end

      protected def acquire(path : String) : Nil
        @files << File.open(path, "rb")
      end

      # Attempt every close, retaining only the first failure. The caller
      # decides whether a prior acquisition/body exception takes precedence.
      protected def close_all : Exception?
        first_error : Exception? = nil
        @files.each do |file|
          begin
            file.close unless file.closed?
          rescue error : Exception
            first_error ||= error
          end
        end
        @files.clear
        first_error
      end
    end
  end
end

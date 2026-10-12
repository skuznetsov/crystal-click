module CrystalClick
  module PartWriterInfrastructure
    RENAME_EXCL = 0x0000_0004_u32

    {% if flag?(:darwin) %}
      @[Link("c")]
      lib LibPartWriterInfrastructureAtomicPublish
        fun renamex_np(old_path : UInt8*, new_path : UInt8*, flags : UInt32) : Int32
      end
    {% end %}

    # Shared same-parent staging and no-replace publication primitives. The
    # caller retains responsibility for writing, validating and cleaning its
    # complete staged representation.
    class PartDirectoryPublisher
      def self.create_stage(parent : String) : String
        8.times do
          candidate = File.tempname(".crystal-click-wide-writer-", nil, dir: parent)
          next if File.exists?(candidate) || File.symlink?(candidate)
          begin
            Dir.mkdir(candidate)
            {% if flag?(:crystal_click_test_failpoints) %}
              TestFailpoint.hit("writer_stage_created")
            {% end %}
            return candidate
          rescue ex : File::Error
            raise ex unless Errno.value == Errno::EEXIST
          end
        end
        raise IO::Error.new("cannot allocate a unique Wide-part staging directory")
      end

      def self.publish_exclusively(stage : String, target : String) : Nil
        {% if flag?(:darwin) %}
          result = LibPartWriterInfrastructureAtomicPublish.renamex_np(
            stage.to_unsafe,
            target.to_unsafe,
            RENAME_EXCL
          )
          if result != 0
            raise ArgumentError.new("destination already exists") if Errno.value == Errno::EEXIST
            raise IO::Error.from_errno("atomic Wide-part publish failed")
          end
        {% else %}
          raise UnsupportedFormatError.new("atomic exclusive Wide-part publication is unsupported on this platform")
        {% end %}
        {% if flag?(:crystal_click_test_failpoints) %}
          TestFailpoint.hit("part_published")
        {% end %}
        nil
      end
    end
  end
end

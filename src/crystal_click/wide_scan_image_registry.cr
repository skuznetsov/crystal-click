module CrystalClick
  # Shares one lazily opened per-part image among the workers scheduled for
  # that part. The fixed user count prevents an early worker from unmapping a
  # part before a later scheduled worker acquires it.
  class WideScanImageRegistry
    @contexts : Array(WidePartTable?)
    @remaining_users : Array(Int32)
    @images : Array(WideScanImage?)
    @errors : Array(Exception?)
    @mutex : Thread::Mutex

    def initialize(@contexts : Array(WidePartTable?), expected_users : Array(Int32))
      unless @contexts.size == expected_users.size
        raise ArgumentError.new("Wide scan image registry inputs differ in size")
      end
      @remaining_users = expected_users.dup
      @images = Array(WideScanImage?).new(@contexts.size, nil)
      @errors = Array(Exception?).new(@contexts.size, nil)
      @mutex = Thread::Mutex.new
    end

    def acquire(part_index : Int) : WideScanImage
      @mutex.synchronize do
        unless part_index >= 0 && part_index < @contexts.size && @remaining_users[part_index] > 0
          raise CorruptPartError.new("Wide scan image acquisition is outside its worker schedule")
        end
        if error = @errors[part_index]
          raise error
        end
        if image = @images[part_index]
          image
        else
          context = @contexts[part_index] || raise(CorruptPartError.new("Wide scan image has no admitted table context"))
          begin
            image = context.open_parallel_scan_image
            @images[part_index] = image
            image
          rescue ex
            @errors[part_index] = ex
            raise ex
          end
        end
      end
    end

    def release(part_index : Int) : Nil
      @mutex.synchronize do
        unless part_index >= 0 && part_index < @remaining_users.size && @remaining_users[part_index] > 0
          raise CorruptPartError.new("Wide scan image release is outside its worker schedule")
        end
        remaining = @remaining_users[part_index] - 1
        @remaining_users[part_index] = remaining
        if remaining == 0
          image = @images[part_index]
          @images[part_index] = nil
          image.try(&.close)
        end
      end
      nil
    end

    # Called after all workers join. It handles cancellation, worker errors,
    # and any scheduled user that never reached its part.
    def close_all : Nil
      first_error = nil.as(Error?)
      @mutex.synchronize do
        @images.each_with_index do |image, index|
          next unless image
          @images[index] = nil
          begin
            image.close
          rescue ex : Error
            first_error ||= ex
          end
        end
      end
      raise first_error.not_nil! if first_error
      nil
    end
  end
end

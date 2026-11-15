module CrystalClick
  # Lazily shares one validated scan image across all workers assigned marks
  # from a Compact part. The expected user count is fixed from the schedule so
  # a fast worker cannot unmap the image before a late worker acquires it.
  class CompactUInt64ScanImageRegistry
    @contexts : Array(CompactPartPhysicalContext?)
    @budgets : Array(CompressedStreamBudget?)
    @remaining_users : Array(Int32)
    @images : Array(CompactUInt64ScanImage?)
    @errors : Array(Exception?)
    @mutex : Thread::Mutex

    def initialize(
      @contexts : Array(CompactPartPhysicalContext?),
      @budgets : Array(CompressedStreamBudget?),
      expected_users : Array(Int32),
    )
      unless @contexts.size == @budgets.size && @contexts.size == expected_users.size
        raise ArgumentError.new("Compact scan image registry inputs differ in size")
      end
      @remaining_users = expected_users.dup
      @images = Array(CompactUInt64ScanImage?).new(@contexts.size, nil)
      @errors = Array(Exception?).new(@contexts.size, nil)
      @mutex = Thread::Mutex.new
    end

    def acquire(part_index : Int) : CompactUInt64ScanImage
      @mutex.synchronize do
        unless part_index >= 0 && part_index < @contexts.size && @remaining_users[part_index] > 0
          raise CorruptPartError.new("Compact scan image acquisition is outside its worker schedule")
        end
        if error = @errors[part_index]
          raise error
        end
        if image = @images[part_index]
          image
        else
          context = @contexts[part_index] || raise(CorruptPartError.new("Compact scan image has no admitted physical context"))
          budget = @budgets[part_index] || raise(CorruptPartError.new("Compact scan image has no shared transport budget"))
          begin
            image = CompactUInt64ScanImage.new(context, budget)
            @images[part_index] = image
            image
          rescue ex
            # Cache the failed first acquire before releasing the part lock;
            # other workers must not remap or revalidate the same broken part.
            @errors[part_index] = ex
            raise ex
          end
        end
      end
    end

    def release(part_index : Int) : Nil
      @mutex.synchronize do
        unless part_index >= 0 && part_index < @remaining_users.size && @remaining_users[part_index] > 0
          raise CorruptPartError.new("Compact scan image release is outside its worker schedule")
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

    # Called only after all isolated workers have joined. This closes images
    # left live by callback cancellation, worker errors, or unstarted marks.
    def close_all : Nil
      first_error = nil.as(Exception?)
      @mutex.synchronize do
        @images.each_with_index do |image, index|
          next unless image
          @images[index] = nil
          begin
            image.close
          rescue ex
            first_error ||= ex
          end
        end
      end
      raise first_error.not_nil! if first_error
      nil
    end
  end
end

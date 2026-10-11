module CrystalClick
  # Detached paths and declared physical sizes for one paired part stream.
  # The file contents remain owned by the source reader and are never retained
  # through this value.
  struct PartPhysicalInput
    getter data_name : String
    getter marks_name : String
    getter data_path : String
    getter marks_path : String
    getter data_size : Int64
    getter marks_size : Int64

    def initialize(
      data_name : String,
      marks_name : String,
      data_path : String,
      marks_path : String,
      @data_size : Int64,
      @marks_size : Int64,
    )
      @data_name = String.new(data_name.to_slice)
      @marks_name = String.new(marks_name.to_slice)
      @data_path = String.new(data_path.to_slice)
      @marks_path = String.new(marks_path.to_slice)
    end

    # PartPhysicalInput is stored inline in CompactPartPhysicalContext, so
    # this counts only its four detached String owners, not the struct twice.
    def retained_string_workspace_bytes : UInt64
      bytes = string_owner_bytes(@data_name)
      bytes = checked_add(bytes, string_owner_bytes(@marks_name))
      bytes = checked_add(bytes, string_owner_bytes(@data_path))
      checked_add(bytes, string_owner_bytes(@marks_path))
    end

    private def string_owner_bytes(value : String) : UInt64
      checked_add(instance_sizeof(String).to_u64, checked_add(value.bytesize.to_u64, 1_u64))
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise CorruptPartError.new("Compact physical input workspace estimate overflows UInt64")
      end
      left + right
    end
  end
end

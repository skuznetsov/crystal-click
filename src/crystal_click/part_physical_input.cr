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
  end
end

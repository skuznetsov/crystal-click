module CrystalClick
  # Exact paths and independently observed file sizes for one compressed lane.
  class ObjectSharedPhysicalLaneInput
    getter expected_data_size : Int64
    getter expected_mark_size : Int64

    @data_path : String
    @marks_path : String

    def initialize(data_path : String, marks_path : String, expected_data_size : Int64, expected_mark_size : Int64)
      if expected_data_size < 0 || expected_mark_size < 0
        raise ArgumentError.new("Object shared lane file sizes must be nonnegative")
      end
      @data_path = String.new(data_path.to_slice)
      @marks_path = String.new(marks_path.to_slice)
      @expected_data_size = expected_data_size
      @expected_mark_size = expected_mark_size
    end

    def data_path : String
      String.new(@data_path.to_slice)
    end

    def marks_path : String
      String.new(@marks_path.to_slice)
    end
  end
end

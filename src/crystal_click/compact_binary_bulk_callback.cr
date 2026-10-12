module CrystalClick
  # One ordered physical callback in a Compact BinaryBulk column. A positive
  # prefix_size makes this a generated state-prefix event; otherwise the event
  # emits the selected logical role's per-mark body extent.
  class CompactBinaryBulkCallback
    @name : String
    @role : String
    getter prefix_size : Int32

    def initialize(name : String, role : String, @prefix_size : Int32)
      raise ArgumentError.new("Compact callback name and role must be nonempty") if name.empty? || role.empty?
      raise ArgumentError.new("Compact callback prefix size must be nonnegative") if @prefix_size < 0
      @name = String.new(name.to_slice)
      @role = String.new(role.to_slice)
    end

    def name : String
      String.new(@name.to_slice)
    end

    def role : String
      String.new(@role.to_slice)
    end

    def prefix? : Bool
      @prefix_size > 0
    end
  end
end

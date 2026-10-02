module CrystalClick
  # Detached owner for one exact set of role-addressed physical lanes.
  class BinaryBulkStreams
    @mark_count : Int32
    @streams : Hash(String, BinaryBulkStream)

    def initialize(mark_count : Int, streams : Hash(String, BinaryBulkStream))
      unless mark_count >= 0 && mark_count <= Int32::MAX
        raise ArgumentError.new("binary bulk mark count is outside the supported domain")
      end
      @mark_count = mark_count.to_i32
      @streams = Hash(String, BinaryBulkStream).new
      streams.each do |role, stream|
        detached_role = String.new(role.to_slice)
        if @streams.has_key?(detached_role)
          raise ArgumentError.new("binary bulk roles must be unique by raw bytes")
        end
        @streams[detached_role] = stream
      end
    end

    def mark_count : Int32
      @mark_count
    end

    def roles : Array(String)
      @streams.keys.map { |role| String.new(role.to_slice) }.sort!
    end

    def role_count : Int32
      @streams.size
    end

    def has_role?(role : String) : Bool
      @streams.has_key?(role)
    end

    def stream(role : String) : BinaryBulkStream
      @streams[role]
    end

    # Sum all detached lane sizes without returning any lane or copying bytes.
    # Callers still decide which selected ranges are charged to a codec budget.
    def total_input_byte_size : UInt64
      total = 0_u64
      @streams.each_value do |stream|
        size = stream.byte_size.to_u64
        if total > UInt64::MAX - size
          raise CorruptPartError.new("binary bulk aggregate lane size overflows UInt64")
        end
        total += size
      end
      total
    end
  end
end

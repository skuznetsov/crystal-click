module CrystalClick
  private enum QBitElementKind
    Int8
    BFloat16
    Float32
    Float64
  end

  # Exact QBit element identity and physical dimension/stride parameters.
  # The owner retains only a closed enum and integers; caller Strings never
  # become part of the descriptor.
  struct QBitType
    MAX_RAW_ROW_BYTES = 64_i64 * 1024 * 1024
    MAX_STRIDE_GROUPS = 1024_u64

    @kind : QBitElementKind
    @dimension : UInt64
    @stride : UInt64
    @element_width : Int32
    @element_bits : Int32
    @plane_width : Int32
    @plane_count : Int32
    @stride_groups : Int32
    @raw_row_bytes : Int32

    def initialize(element_type : String, @dimension : UInt64, stride : UInt64? = nil)
      @kind, @element_width, @element_bits = case element_type
                                             when "Int8"
                                               {QBitElementKind::Int8, 1, 8}
                                             when "BFloat16"
                                               {QBitElementKind::BFloat16, 2, 16}
                                             when "Float32"
                                               {QBitElementKind::Float32, 4, 32}
                                             when "Float64"
                                               {QBitElementKind::Float64, 8, 64}
                                             else
                                               raise ArgumentError.new("QBit element type must be Int8, BFloat16, Float32, or Float64")
                                             end

      raise ArgumentError.new("QBit dimension must be positive") if @dimension == 0_u64
      @stride = stride || @dimension
      raise ArgumentError.new("QBit stride must be positive and no greater than dimension") if @stride == 0_u64 || @stride > @dimension
      raise ArgumentError.new("QBit stride must divide dimension") unless @dimension % @stride == 0_u64
      if @stride < @dimension && @stride % 8_u64 != 0_u64
        raise ArgumentError.new("strided QBit stride must be a multiple of eight")
      end

      groups = @dimension // @stride
      raise ArgumentError.new("QBit stride groups exceed supported limit 1024") if groups > MAX_STRIDE_GROUPS
      @stride_groups = groups.to_i32

      # `element_width` is already measured in bytes (1/2/4/8).
      bytes_per_element = @element_width.to_u64
      raise ArgumentError.new("QBit raw row exceeds 64 MiB resource limit") if @dimension > MAX_RAW_ROW_BYTES.to_u64 // bytes_per_element
      @raw_row_bytes = (@dimension * bytes_per_element).to_i32

      # Use division/remainder rather than stride + 7 so UInt64 addition cannot
      # overflow before the result is checked and narrowed.
      plane_width_u64 = @stride // 8_u64
      plane_width_u64 += 1_u64 if @stride % 8_u64 != 0_u64
      raise ArgumentError.new("QBit plane width exceeds Int32 representation") if plane_width_u64 > Int32::MAX.to_u64
      @plane_width = plane_width_u64.to_i32

      plane_count = @element_bits.to_u64 * groups
      raise ArgumentError.new("QBit plane count exceeds Int32 representation") if plane_count > Int32::MAX.to_u64
      @plane_count = plane_count.to_i32
    end

    def element_type : String
      case @kind
      when QBitElementKind::Int8     then "Int8".dup
      when QBitElementKind::BFloat16 then "BFloat16".dup
      when QBitElementKind::Float32  then "Float32".dup
      when QBitElementKind::Float64  then "Float64".dup
      else
        raise "unknown QBit element kind"
      end
    end

    def dimension : UInt64
      @dimension
    end

    # Effective stride; a missing stride is canonicalized to dimension.
    def stride : UInt64
      @stride
    end

    def element_width : Int32
      @element_width
    end

    def element_bits : Int32
      @element_bits
    end

    def plane_width : Int32
      @plane_width
    end

    def plane_count : Int32
      @plane_count
    end

    def stride_groups : Int32
      @stride_groups
    end

    def raw_row_bytes : Int32
      @raw_row_bytes
    end

    def type_name : String
      if @stride == @dimension
        "QBit(#{element_type}, #{@dimension})"
      else
        "QBit(#{element_type}, #{@dimension}, #{@stride})"
      end
    end

    # Persisted admission is intentionally canonical-only. In particular,
    # explicit default stride, leading zeroes, and alternate spacing reject.
    def self.for_type(type_name : String) : QBitType?
      return nil if type_name.bytesize > 128
      match = /\AQBit\((Int8|BFloat16|Float32|Float64), (0|[1-9][0-9]*)(?:, (0|[1-9][0-9]*))?\)\z/.match(type_name) || return nil
      dimension = match[2].to_u64? || return nil
      stride = match[3]?.try(&.to_u64?)
      value = new(match[1], dimension, stride)
      return nil unless value.type_name == type_name
      value
    rescue ArgumentError
      nil
    end

    def ==(other : self) : Bool
      @kind == other.@kind && @dimension == other.@dimension && @stride == other.@stride
    end

    def hash(hasher)
      hasher = @kind.hash(hasher)
      hasher = @dimension.hash(hasher)
      @stride.hash(hasher)
    end

    def to_s(io : IO) : Nil
      io << type_name
    end
  end
end

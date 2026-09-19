module CrystalClick
  @[Link("zstd")]
  lib LibZSTD
    alias SizeT = LibC::SizeT

    fun ZSTD_decompress(dst : Void*, dst_capacity : SizeT, src : Void*, compressed_size : SizeT) : SizeT
    fun ZSTD_findFrameCompressedSize(src : Void*, src_size : SizeT) : SizeT
    fun ZSTD_isError(code : SizeT) : UInt32
  end

  module ZSTD
    def self.decode(input : Bytes, expected_size : Int, max_size : Int64) : Bytes
      raise CorruptPartError.new("negative ZSTD output size") if expected_size < 0
      raise CorruptPartError.new("ZSTD output size is invalid") if expected_size == 0
      raise CorruptPartError.new("invalid ZSTD output limit") if max_size < 0
      raise CorruptPartError.new("ZSTD output exceeds limit") if expected_size.to_i64 > max_size
      raise CorruptPartError.new("empty ZSTD payload") if input.empty?

      input_size = input.size.to_u64
      frame_size = LibZSTD.ZSTD_findFrameCompressedSize(input.to_unsafe.as(Void*), input_size)
      raise CorruptPartError.new("invalid ZSTD frame") unless LibZSTD.ZSTD_isError(frame_size) == 0
      raise CorruptPartError.new("ZSTD payload has trailing bytes") unless frame_size == input_size

      output = Bytes.new(expected_size)
      decoded_size = LibZSTD.ZSTD_decompress(
        output.to_unsafe.as(Void*),
        expected_size.to_u64,
        input.to_unsafe.as(Void*),
        input_size
      )
      raise CorruptPartError.new("ZSTD decompression failed") unless LibZSTD.ZSTD_isError(decoded_size) == 0
      raise CorruptPartError.new("ZSTD output size mismatch") unless decoded_size == expected_size.to_u64
      output
    end
  end
end

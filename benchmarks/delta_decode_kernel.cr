require "../src/crystal_click"

# Decoder-only control for the UInt64 Delta backend experiment. This intentionally
# keeps the same hot input/output buffers across trials: it measures a warm
# 64 KiB Delta frame, not mmap, ZSTD, marks, or a ClickHouse query.
module CrystalClickDeltaKernelBenchmark
  WORDS      = 8_192
  ITERATIONS = 2_000
  TRIALS     =     7

  {% if flag?(:delta_byte_scalar) %}
    BACKEND = "byte_scalar"
  {% elsif flag?(:delta_neon) && flag?(:aarch64) %}
    BACKEND = "neon"
  {% else %}
    BACKEND = "scalar"
  {% end %}

  def self.run : Nil
    input = Bytes.new(WORDS * 8, 0_u8)
    output = Bytes.new(WORDS * 8, 0_u8)
    WORDS.times { |index| input[index * 8] = 1_u8 }

    10.times { verify_decode(input, output) }
    puts "backend=#{BACKEND} words=#{WORDS} iterations=#{ITERATIONS} trials=#{TRIALS}"
    TRIALS.times do |trial|
      GC.collect
      started = Time.instant
      accumulator = 0_u64
      ITERATIONS.times do
        accumulator = CrystalClick::CompressedBlock.decode_delta_words(input, output, WORDS, accumulator)
      end
      elapsed_ns = (Time.instant - started).total_nanoseconds.to_i64
      raise "incorrect final accumulator" unless accumulator == (WORDS * ITERATIONS).to_u64
      verify_output(output, (WORDS * (ITERATIONS - 1)).to_u64)
      puts "trial=#{trial + 1} elapsed_ns=#{elapsed_ns}"
    end
  end

  private def self.verify_decode(input : Bytes, output : Bytes) : Nil
    last = CrystalClick::CompressedBlock.decode_delta_words(input, output, WORDS)
    raise "incorrect final accumulator" unless last == WORDS.to_u64
    verify_output(output)
  end

  private def self.verify_output(output : Bytes, initial : UInt64 = 0_u64) : Nil
    WORDS.times do |index|
      actual = IO::ByteFormat::LittleEndian.decode(UInt64, output[index * 8, 8])
      raise "incorrect Delta output" unless actual == initial &+ (index + 1).to_u64
    end
  end
end

CrystalClickDeltaKernelBenchmark.run

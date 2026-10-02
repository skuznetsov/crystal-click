require "../src/crystal_click"
require "./w120_structure_vectors"

# Independently authored W115 Dynamic discriminator tags and their derived
# schedule expectations. This helper never reads a captured discriminator
# stream and never calls the W121 production codec to define expected data.
struct W121ExpectedSchedule
  getter mark_index : UInt64
  getter first_row : UInt64
  getter tags : Array(UInt8)
  getter ranks : Array(Int32?)
  getter arm_counts : Array(UInt64)
  getter arm_offsets : Array(UInt64)

  def initialize(@mark_index : UInt64, @first_row : UInt64, @tags : Array(UInt8),
                 @ranks : Array(Int32?), @arm_counts : Array(UInt64), @arm_offsets : Array(UInt64))
  end
end

module W121DiscriminatorVectors
  MODE_BASIC   = 0_u64
  MODE_COMPACT = 1_u64

  PROFILES = [
    {"dynamic_paths", ["a", "arr", "dot.key", "flag", "nest.leaf", "s"]},
    {"typed_mixed", ["s"]},
  ]

  # Literal row tags copied from the independently authored W116 row model,
  # with the W121 sorted-name mapping made explicit here. Tag 255 is NULL and
  # is not an arm occurrence. Variant names are sorted including SharedVariant.
  def self.tags(profile : String, path : String) : Array(UInt8)
    case {profile, path}
    when {"dynamic_paths", "a"}         then [0_u8, 255_u8, 0_u8, 255_u8, 0_u8, 0_u8, 0_u8, 0_u8]
    when {"dynamic_paths", "arr"}       then [0_u8, 0_u8, 0_u8, 255_u8, 0_u8, 255_u8, 0_u8, 0_u8]
    when {"dynamic_paths", "dot.key"}   then [0_u8, 0_u8, 0_u8, 255_u8, 0_u8, 0_u8, 0_u8, 0_u8]
    when {"dynamic_paths", "flag"}      then [0_u8, 0_u8, 255_u8, 255_u8, 0_u8, 0_u8, 255_u8, 0_u8]
    when {"dynamic_paths", "nest.leaf"} then [1_u8, 1_u8, 255_u8, 255_u8, 1_u8, 255_u8, 1_u8, 1_u8]
    when {"dynamic_paths", "s"}         then [3_u8, 3_u8, 3_u8, 255_u8, 1_u8, 255_u8, 3_u8, 0_u8]
    when {"typed_mixed", "s"}           then [1_u8, 1_u8, 1_u8, 255_u8, 0_u8, 255_u8, 1_u8, 0_u8]
    else
      raise "no independently authored W121 tag vector for #{profile}.#{path}"
    end
  end

  def self.dynamic(profile : String, path : String) : CrystalClick::DynamicStructure
    W120StructureVectors.expected_set(profile).dynamics[path]? || raise "no W121 Dynamic model for #{profile}.#{path}"
  end

  def self.variant_names(structure : CrystalClick::DynamicStructure) : Array(String)
    (structure.types.map(&.name) + ["SharedVariant"]).sort
  end

  def self.rows(profile : String, path : String) : Array(Array(UInt8))
    authored = tags(profile, path)
    raise "W121 literal row vector must contain four two-row marks" unless authored.size == 8
    result = [] of Array(UInt8)
    0.step(to: authored.size - 1, by: 2) do |offset|
      result << [authored[offset], authored[offset + 1]]
    end
    result
  end

  # Test-only wire authoring from the seal's grammar, independent of production
  # encode/decode: LE mode prefix, then one COMPACT row-count/format body per
  # two-row mark, or raw BASIC tags per mark.
  def self.stream_bytes(profile : String, path : String, mode : UInt64) : Bytes
    raise ArgumentError.new("unsupported W121 literal mode") unless mode == MODE_BASIC || mode == MODE_COMPACT
    io = IO::Memory.new
    write_u64_le(io, mode)
    rows(profile, path).each do |mark_tags|
      if mode == MODE_BASIC
        mark_tags.each { |tag| io.write_byte(tag) }
      elsif mark_tags[0] == mark_tags[1]
        write_varuint(io, mark_tags.size.to_u64)
        io.write_byte(1_u8)
        io.write_byte(mark_tags[0])
      else
        write_varuint(io, mark_tags.size.to_u64)
        io.write_byte(0_u8)
        mark_tags.each { |tag| io.write_byte(tag) }
      end
    end
    io.to_slice
  end

  # Includes the first mark (byte 8) and one terminal boundary.
  def self.mark_offsets(profile : String, path : String, mode : UInt64) : Array(UInt64)
    bytes = stream_bytes(profile, path, mode)
    offsets = [8_u64]
    rows(profile, path).each do |mark_tags|
      extent = if mode == MODE_BASIC
                 mark_tags.size
               elsif mark_tags[0] == mark_tags[1]
                 3 # one-byte VarUInt(2), uniform-format byte, one tag
               else
                 4 # one-byte VarUInt(2), row-format byte, two tags
               end
      offsets << offsets.last + extent.to_u64
    end
    raise "W121 authored terminal offset differs from literal stream size" unless offsets.last == bytes.size.to_u64
    offsets
  end

  def self.schedules(profile : String, path : String, first_mark : Int32 = 0, mark_count : Int32 = 4) : Array(W121ExpectedSchedule)
    raise ArgumentError.new("invalid W121 expected selection") if first_mark < 0 || mark_count < 0 || first_mark + mark_count > 4
    tags = self.tags(profile, path)
    arm_count = variant_names(dynamic(profile, path)).size
    running = Array(UInt64).new(arm_count, 0_u64)
    result = [] of W121ExpectedSchedule
    stop = first_mark + mark_count
    if mark_count > 0
      first_mark.upto(stop - 1) do |mark_index|
        mark_tags = [tags[mark_index * 2], tags[mark_index * 2 + 1]]
        offsets = running.dup
        local = Array(UInt64).new(arm_count, 0_u64)
        ranks = [] of Int32?
        mark_tags.each do |tag|
          if tag == 255_u8
            ranks << nil
          else
            arm = tag.to_i32
            raise "W121 authored tag is outside its canonical roster" if arm >= arm_count
            ranks << local[arm].to_i32
            local[arm] += 1_u64
          end
        end
        result << W121ExpectedSchedule.new(
          mark_index.to_u64,
          (mark_index * 2).to_u64,
          mark_tags,
          ranks,
          local,
          offsets,
        )
        arm_count.times { |arm| running[arm] += local[arm] }
      end
    end
    result
  end

  def self.with_wrong_first_tag(schedules : Array(W121ExpectedSchedule)) : Array(W121ExpectedSchedule)
    copy = schedules.dup
    first = copy.first? || raise "W121 tag control requires a schedule"
    changed = first.tags.dup
    changed[0] = changed[0] == 255_u8 ? 0_u8 : (changed[0] == 0_u8 ? 1_u8 : 0_u8)
    copy[0] = W121ExpectedSchedule.new(first.mark_index, first.first_row, changed, first.ranks.dup, first.arm_counts.dup, first.arm_offsets.dup)
    copy
  end

  def self.with_wrong_first_rank(schedules : Array(W121ExpectedSchedule)) : Array(W121ExpectedSchedule)
    copy = schedules.dup
    first = copy.first? || raise "W121 rank control requires a schedule"
    changed = first.ranks.dup
    index = changed.index { |rank| !rank.nil? } || raise "W121 rank control requires a non-NULL arm"
    changed[index] = (changed[index] || 0_i32) + 1_i32
    copy[0] = W121ExpectedSchedule.new(first.mark_index, first.first_row, first.tags.dup, changed, first.arm_counts.dup, first.arm_offsets.dup)
    copy
  end

  private def self.write_u64_le(io : IO, value : UInt64) : Nil
    8.times { |index| io.write_byte(((value >> (index * 8)) & 0xff_u64).to_u8) }
  end

  private def self.write_varuint(io : IO, value : UInt64) : Nil
    remaining = value
    while remaining >= 0x80_u64
      io.write_byte(((remaining & 0x7f_u64) | 0x80_u64).to_u8)
      remaining >>= 7
    end
    io.write_byte(remaining.to_u8)
  end
end

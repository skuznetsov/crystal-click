module CrystalClick
  # Owned sparse ranks for one selected outer Dynamic mark. Arm offsets are
  # relative to the beginning of the selected window, not the whole part.
  class DynamicMarkSchedule
    getter mark_index : Int32
    getter first_row : UInt64

    @tags : Array(UInt8)
    @ranks : Array(Int32?)
    @arm_counts : Array(UInt64)
    @arm_offsets : Array(UInt64)

    def initialize(
      @mark_index : Int32,
      @first_row : UInt64,
      tags : Array(UInt8),
      ranks : Array(Int32?),
      arm_counts : Array(UInt64),
      arm_offsets : Array(UInt64),
    )
      @tags = tags.dup
      @ranks = ranks.dup
      @arm_counts = arm_counts.dup
      @arm_offsets = arm_offsets.dup
    end

    def tags : Array(UInt8)
      @tags.dup
    end

    def ranks : Array(Int32?)
      @ranks.dup
    end

    def arm_counts : Array(UInt64)
      @arm_counts.dup
    end

    def arm_offsets : Array(UInt64)
      @arm_offsets.dup
    end

    # Scalar/index queries let aggregate codecs consume the schedule without
    # allocating detached row/roster snapshots for every arm or row.
    def row_count : Int32
      @tags.size
    end

    def rank_count : Int32
      @ranks.size
    end

    def variant_count : Int32
      @arm_counts.size
    end

    def tag_at(index : Int) : UInt8
      @tags[index]
    end

    def rank_at(index : Int) : Int32?
      @ranks[index]
    end

    def arm_count_at(index : Int) : UInt64
      @arm_counts[index]
    end
  end
end

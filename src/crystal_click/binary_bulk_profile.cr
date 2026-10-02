module CrystalClick
  enum BinaryBulkStringProfile
    SingleStream
    WithSizeStream
  end

  # Immutable selector for the admitted physical String layout. This is an
  # explicit caller choice; the codec never guesses a profile from a type.
  class BinaryBulkProfile
    getter string_profile : BinaryBulkStringProfile

    private def initialize(@string_profile : BinaryBulkStringProfile)
    end

    def self.single_stream : BinaryBulkProfile
      new(BinaryBulkStringProfile::SingleStream)
    end

    def self.with_size_stream : BinaryBulkProfile
      new(BinaryBulkStringProfile::WithSizeStream)
    end

    def self.string_size_stream : BinaryBulkProfile
      with_size_stream
    end

    def single_stream? : Bool
      @string_profile.single_stream?
    end

    def with_size_stream? : Bool
      @string_profile.with_size_stream?
    end

    def string_size_stream? : Bool
      with_size_stream?
    end

    def ==(other : BinaryBulkProfile) : Bool
      @string_profile == other.@string_profile
    end

    def_hash @string_profile
  end
end

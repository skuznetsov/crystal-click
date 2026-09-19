module CrystalClick
  class Error < Exception
  end

  class InvalidPartError < Error
  end

  class UnsupportedFormatError < Error
  end

  class CorruptPartError < Error
  end

  class BoundsError < Error
  end
end

module CrystalClick
  # Authenticated provenance for callback bytes and persisted Object mark
  # coordinates. Implementations keep their native coordinate domain; callers
  # ask only whether a pair belongs to one exact callback interval.
  abstract class ObjectSharedInlineCoordinateContext
    abstract def path_data_size : Int64

    abstract def validate_path_bytes!(relative_start : UInt64, bytes : Bytes, budget : BinaryCodecBudget) : Nil

    abstract def callback_position(
      pair : Tuple(UInt64, UInt64),
      relative_start : UInt64,
      relative_end : UInt64,
      allow_terminal : Bool,
    ) : Int64?

    abstract def same_path?(other : ObjectSharedInlineCoordinateContext) : Bool
  end
end

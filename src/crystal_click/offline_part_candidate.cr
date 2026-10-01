module CrystalClick
  # A physical on-disk part directory. This identity does not imply that the
  # ClickHouse server considers the part active or otherwise authoritative.
  struct OfflinePartCandidate
    getter name : String
    getter path : String
    getter info : MergeTreePartInfo
    getter row_count : UInt64

    def initialize(@name : String, @path : String, @info : MergeTreePartInfo, @row_count : UInt64)
    end
  end
end

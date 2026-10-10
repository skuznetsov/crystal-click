module CrystalClick
  module WidePartWriter
    # A typed, fully planned column owner. The closures retain the original
    # owner plan and values; callers cannot inject arbitrary physical files.
    # The public WidePartColumn factory retains this typed result behind its
    # preparation closure; its constructor remains an implementation detail.
    class WidePartPreparedColumn
      getter column_name : String
      getter declaration : String
      getter stream_names : Array(String)
      getter parent_rows : Array(Int32)

      @encode : Proc(Array(UInt64), BinaryCodecBudget, CompressedStreamBudget, Hash(String, CompressedMarkFiles))
      @validate : Proc(String, BinaryCodecBudget, CompressedStreamBudget, Nil)

      def initialize(
        @column_name : String,
        @declaration : String,
        stream_names : Array(String),
        @parent_rows : Array(Int32),
        @encode : Proc(Array(UInt64), BinaryCodecBudget, CompressedStreamBudget, Hash(String, CompressedMarkFiles)),
        @validate : Proc(String, BinaryCodecBudget, CompressedStreamBudget, Nil),
      )
        @stream_names = stream_names.dup
        @stream_names.sort!
        if @stream_names.empty?
          raise UnsupportedFormatError.new("Wide value column must plan at least one physical stream")
        end
      end

      def encode(
        rows_per_mark : Array(UInt64),
        codec_budget : BinaryCodecBudget,
        transport_budget : CompressedStreamBudget,
      ) : Hash(String, CompressedMarkFiles)
        files = @encode.call(rows_per_mark, codec_budget, transport_budget)
        unless files.size == @stream_names.size && files.keys.sort == @stream_names
          raise UnsupportedFormatError.new("encoded value files differ from the preflighted physical roster")
        end
        files
      end

      def validate(
        part_path : String,
        codec_budget : BinaryCodecBudget,
        transport_budget : CompressedStreamBudget,
      ) : Nil
        @validate.call(part_path, codec_budget, transport_budget)
      end
    end
  end
end

module CrystalClick
  # One-shot, operation-scoped access to one preflighted typed source part.
  # Batches borrow their value buffers and are valid only for the callback.
  # The handle is not a transaction or proof of what the caller computes.
  class OfflinePartTransformInput
    @reader : WidePartTable
    @column_names : Array(String)
    @column_types : Array(Tuple(String, String))
    @row_count : UInt64
    @batch_rows : Int32
    @state : Symbol = :fresh
    @protocol_invalid : Bool = false

    def initialize(
      @reader : WidePartTable,
      column_names : Array(String),
      column_types : Array(Tuple(String, String)),
      @row_count : UInt64,
      @batch_rows : Int32,
    )
      if column_names.empty? || column_names.size != column_types.size
        raise ArgumentError.new("transform input columns and declarations must be nonempty and aligned")
      end
      raise ArgumentError.new("transform input batch size must be positive") if @batch_rows <= 0

      @column_names = column_names.map { |name| String.new(name.to_slice) }
      @column_types = column_types.map do |name, declaration|
        {String.new(name.to_slice), String.new(declaration.to_slice)}
      end
      unless @column_names == @column_types.map(&.[0])
        raise ArgumentError.new("transform input declarations must preserve selected column order")
      end
    end

    def column_names : Array(String)
      @column_names.map { |name| String.new(name.to_slice) }
    end

    # Exact selected declarations in the requested order.
    def column_types : Array(Tuple(String, String))
      @column_types.map do |name, declaration|
        {String.new(name.to_slice), String.new(declaration.to_slice)}
      end
    end

    def row_count : UInt64
      @row_count
    end

    # Scans the complete source once. Completion is recorded only after the
    # reader returns normally and the independently counted rows match its
    # preflight count. An interrupted scan permanently poisons this handle.
    def each_batch(&block : WidePartTableBatch -> Nil) : Nil
      unless @state == :fresh && !@protocol_invalid
        @protocol_invalid = true
        raise UnsupportedFormatError.new("transform input scan is one-shot")
      end

      @state = :scanning
      observed_rows = 0_u64
      completed = false
      begin
        @reader.scan_typed(batch_rows: @batch_rows) do |batch|
          unless @state == :scanning && !@protocol_invalid
            @protocol_invalid = true
            raise UnsupportedFormatError.new("transform input scan protocol was interrupted")
          end

          count = batch.row_count || raise(CorruptPartError.new("typed source batch has no exact row count"))
          if observed_rows > @row_count || count > @row_count - observed_rows
            raise CorruptPartError.new("typed source scan exceeds its preflight row count")
          end
          observed_rows += count
          yield batch

          # A callback can catch the error from a nested or second scan. The
          # outer scan still must fail closed after that callback returns.
          unless @state == :scanning && !@protocol_invalid
            raise UnsupportedFormatError.new("transform input scan protocol was interrupted")
          end
        end

        unless observed_rows == @row_count
          raise CorruptPartError.new("typed source scan did not match its preflight row count")
        end
        @state = :complete
        completed = true
      ensure
        unless completed
          @state = :poisoned unless @state == :invalidated
        end
      end
      nil
    end

    # Internal coordinator check. A caller cannot make this true by delivering
    # the last batch and escaping before scan_typed itself returns.
    def complete_for_output? : Bool
      @state == :complete && !@protocol_invalid
    end

    # Invalidates escaped handles on every success and failure path.
    def invalidate! : Nil
      @state = :invalidated
      nil
    end
  end
end

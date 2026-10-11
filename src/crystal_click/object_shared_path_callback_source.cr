module CrystalClick
  # Exact-span callback source for an already framed tape. A future Compact
  # framer must establish the callback extent before using this contract;
  # an unlabelled mrk3 remainder is not an exact callback interval. Parser
  # failures must not commit cursor state, but do not roll back parser budgets.
  abstract class ObjectSharedPathCallbackSource
    @parser_active : Bool = false

    protected abstract def borrow_self_delimited(expected_name : String) : Bytes
    protected abstract def commit_self_delimited(expected_name : String, consumed : Int32) : Nil
    abstract def take_exact(expected_name : String, size : Int32) : Bytes
    abstract def finish! : Nil

    protected def ensure_no_active_parser! : Nil
      if @parser_active
        raise CorruptPartError.new("Object shared path callback source rejects re-entrant reads while reserved by a parser")
      end
      nil
    end

    # Keep the result polymorphism on a concrete template method. Crystal's
    # abstract dispatch surface stays non-generic, while parsing remains
    # transactional: parser exceptions or any non-exact extent never commit.
    def with_self_delimited(expected_name : String, &block : Bytes -> Tuple(T, Int32)) : T forall T
      ensure_no_active_parser!
      bytes = borrow_self_delimited(expected_name)
      @parser_active = true
      begin
        value, consumed = yield bytes
        unless consumed == bytes.size
          raise CorruptPartError.new("Object shared path parser did not consume its exact callback interval")
        end
        commit_self_delimited(expected_name, consumed)
        value
      ensure
        @parser_active = false
      end
    end
  end
end

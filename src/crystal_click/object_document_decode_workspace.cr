module CrystalClick
  # Scan-local staging storage for rows decoded through Compact Advanced root
  # Object. The hash is never exposed beyond its `with_fields` block; its
  # entries are cleared before the next row can reuse them.
  class ObjectDocumentDecodeWorkspace
    MAX_RETAINED_FIELDS = 16

    @fields : Hash(String, BinaryValue)?
    @active : Bool

    def initialize
      @fields = nil
      @active = false
    end

    private def prepare! : Nil
      @fields ||= Hash(String, BinaryValue).new(initial_capacity: MAX_RETAINED_FIELDS)
      nil
    end

    # Rows larger than the fixed hash capacity and reentrant use take the
    # ordinary ephemeral-hash route. The retained hash clears GC-traced
    # references on success and failure, and never grows past its bound.
    def with_fields(required_fields : UInt64, &block : Hash(String, BinaryValue) -> ObjectDocument) : ObjectDocument
      if required_fields <= MAX_RETAINED_FIELDS.to_u64 && !@active
        prepare!
        fields = @fields || raise(CorruptPartError.new("Compact Object decode workspace was not prepared"))
        @active = true
        begin
          yield fields
        ensure
          fields.clear
          @active = false
        end
      else
        fields = Hash(String, BinaryValue).new
        yield fields
      end
    end
  end
end

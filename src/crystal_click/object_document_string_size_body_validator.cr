module CrystalClick
  # Validates only the String-v1 size-lane grammar and its exact payload byte
  # extent. It deliberately does not infer row or nested-value occurrence counts.
  class ObjectDocumentStringSizeBodyValidator
    alias BodyBinding = ObjectDocumentInlineCallbackOrder::BodyLaneBinding

    STRING_SIZES_SUFFIX = ".string_sizes"
    DATA_SUFFIX         = ".data"

    def self.validate!(
      bindings : Array(BodyBinding),
      callbacks : Array(Tuple(String, Bytes)),
    ) : Nil
      unless bindings.size == callbacks.size
        raise CorruptPartError.new("String size validation roster differs from its callback bytes")
      end

      bindings.each_with_index do |binding, index|
        canonical_name, owner_kind, owner_path, role = binding
        callback_name, size_bytes = callbacks[index]
        unless canonical_name == callback_name
          raise CorruptPartError.new("String size validation callback differs from its canonical binding")
        end

        next unless ordinary_owner?(owner_kind)
        next unless role.ends_with?(STRING_SIZES_SUFFIX)

        unless size_bytes.size % 8 == 0
          raise CorruptPartError.new("String size lane is not a sequence of UInt64 values")
        end

        next_index = index + 1
        unless next_index < bindings.size
          raise CorruptPartError.new("String size lane has no adjacent data lane")
        end

        data_binding = bindings[next_index]
        data_name, data_owner_kind, data_owner_path, data_role = data_binding
        data_callback_name, data_bytes = callbacks[next_index]
        unless data_owner_kind == owner_kind &&
               data_owner_path == owner_path &&
               same_suffix_stem?(role, STRING_SIZES_SUFFIX, data_role, DATA_SUFFIX) &&
               data_name == data_callback_name
          raise CorruptPartError.new("String size lane is not followed by its matching data lane")
        end

        remaining = data_bytes.size.to_u64
        offset = 0
        while offset < size_bytes.size
          size = read_uint64_le(size_bytes, offset)
          if size > remaining
            raise CorruptPartError.new("String size exceeds its sibling data payload")
          end
          remaining -= size
          offset += 8
        end

        unless remaining == 0_u64
          raise CorruptPartError.new("String sizes do not cover their sibling data payload")
        end
      end
      nil
    end

    private def self.ordinary_owner?(owner_kind : Symbol) : Bool
      owner_kind == :typed || owner_kind == :typed_dynamic || owner_kind == :root_dynamic
    end

    private def self.same_suffix_stem?(
      left : String,
      left_suffix : String,
      right : String,
      right_suffix : String,
    ) : Bool
      return false unless left.ends_with?(left_suffix) && right.ends_with?(right_suffix)
      left_stem_size = left.bytesize - left_suffix.bytesize
      right_stem_size = right.bytesize - right_suffix.bytesize
      return false unless left_stem_size == right_stem_size
      # Logical role suffixes are not native callback spellings (.size/name).
      left.to_slice[0, left_stem_size] == right.to_slice[0, right_stem_size]
    end

    private def self.read_uint64_le(bytes : Bytes, offset : Int) : UInt64
      value = 0_u64
      8.times do |index|
        value |= bytes[offset + index].to_u64 << (index * 8)
      end
      value
    end
  end
end

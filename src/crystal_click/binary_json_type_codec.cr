module CrystalClick
  # Bounded JSON DataType descriptor codec. SKIP and regexp metadata are
  # deliberately refused until their independent semantics are qualified.
  module BinaryJsonTypeCodec
    VERSION = 0_u8

    def self.write(type : BinaryJsonType, context : BinaryCodecContext, depth : Int) : Nil
      count = type.typed_path_count.to_u64
      if count > 0_u64
        context.preflight_children(count) # path metadata records
        context.visit_metadata_nodes(count, depth)
        context.preflight_children(count) # declared child descriptors
        context.ensure_depth(depth + 1)

        path_wire_bytes = 0_u64
        type.typed_path_count.times do |index|
          path_wire_bytes = checked_add(path_wire_bytes, BinaryJsonType.path_wire_size(type.typed_path_byte_size(index).to_u64), context)
        end
        # Reject a too-small byte budget before any path accessor copies.
        context.ensure_output_bytes(path_wire_bytes)
      end

      context.write_byte(VERSION)
      context.write_var_uint(type.max_dynamic_paths.to_u64)
      context.write_byte(type.max_dynamic_types)
      context.write_var_uint(count)
      type.typed_path_count.times do |index|
        path_size = type.typed_path_byte_size(index)
        path = type.typed_path_at(index) # after aggregate preflight above
        context.write_var_uint(path_size.to_u64)
        context.ensure_output_bytes(path_size.to_u64)
        path_size.times { |byte_index| context.write_byte(path.to_slice[byte_index]) }
        BinaryDataTypeCodec.write_to(type.typed_type_at(index), context, depth + 1)
      end
      context.write_var_uint(0_u64) # unsupported path-to-skip roster is empty
      context.write_var_uint(0_u64) # unsupported regexp roster is empty
      nil
    end

    def self.read(context : BinaryCodecContext, depth : Int) : BinaryDataType
      version = context.read_byte
      unless version == VERSION
        context.corrupt!("JSON descriptor version is outside the supported v0 profile")
      end
      max_dynamic_paths = context.read_var_uint
      if max_dynamic_paths > BinaryJsonType::MAX_DYNAMIC_PATHS.to_u64
        context.corrupt!("JSON max_dynamic_paths is outside the supported range")
      end
      max_dynamic_types = context.read_byte
      if max_dynamic_types > BinaryJsonType::MAX_DYNAMIC_TYPES
        context.corrupt!("JSON max_dynamic_types is outside the supported range")
      end

      raw_count = context.read_var_uint
      count = context.preflight_metadata(
        raw_count,
        3_u64,
        BinaryJsonType::MAX_TYPED_PATHS.to_u64,
        "JSON typed path count",
      )
      context.visit_metadata_nodes(raw_count, depth) if raw_count > 0_u64
      context.preflight_children(raw_count) if raw_count > 0_u64
      context.ensure_depth(depth + 1) if raw_count > 0_u64

      typed_paths = Hash(String, BinaryDataType).new(initial_capacity: count)
      seen_paths = Set(String).new
      count.times do
        raw_path_size = context.read_var_uint
        if raw_path_size == 0_u64 || raw_path_size > BinaryJsonType::MAX_PATH_BYTES.to_u64
          context.unsupported!("JSON typed path is outside the admitted identifier profile")
        end
        raw_path = context.read_slice(raw_path_size)
        unless BinaryJsonType.valid_path_bytes?(raw_path)
          context.unsupported!("JSON typed path is outside the admitted identifier profile")
        end
        path = String.new(raw_path)
        unless seen_paths.add?(path)
          context.corrupt!("JSON descriptor contains a duplicate typed path")
        end
        path_type = BinaryDataTypeCodec.read_from(context, depth + 1)
        if path_type.tag == BinaryDataType::TAG_NOTHING
          context.unsupported!("Nothing is not admitted as a declared JSON typed path")
        end
        begin
          BinaryJsonType.validate_typed_type!(path_type)
        rescue ex : ArgumentError
          context.unsupported!("JSON typed path DataType is outside the admitted scalar/container profile")
        end
        typed_paths[path] = path_type
      end

      skip_count = context.read_var_uint
      if skip_count != 0_u64
        context.unsupported!("JSON SKIP path descriptors are outside the admitted profile")
      end
      regexp_count = context.read_var_uint
      if regexp_count != 0_u64
        context.unsupported!("JSON SKIP REGEXP descriptors are outside the admitted profile")
      end

      begin
        BinaryDataType.json(max_dynamic_paths.to_i, max_dynamic_types.to_i, typed_paths)
      rescue ex : ArgumentError
        context.unsupported!("JSON descriptor is outside the admitted JSON scalar profile")
      end
    end

    private def self.checked_add(left : UInt64, right : UInt64, context : BinaryCodecContext) : UInt64
      if left > UInt64::MAX - right
        context.unsupported!("JSON descriptor metadata size overflows UInt64")
      end
      left + right
    end
  end
end

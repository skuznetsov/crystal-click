require "json"

module CrystalClick
  # Bounded, selected-type view of Compact serialization metadata. Compact
  # keeps value streams in shared data.bin, but the serializer version flags
  # still determine how the recursive callback tape is interpreted.
  class CompactSerializationProfile
    CODEC_LZ4       = "CODEC(LZ4)"
    ENVELOPE_FIELDS = Set{
      "version",
      "columns",
      "types_serialization_versions",
      "propagate_types_serialization_versions_to_nested_types",
    }

    getter ordinary_profile : BinaryBulkProfile
    getter map_basic : Bool
    getter propagated_nested_versions : Bool

    private def initialize(
      @ordinary_profile : BinaryBulkProfile,
      @map_basic : Bool,
      @propagated_nested_versions : Bool,
    )
    end

    def self.open(
      part_path : String,
      columns : Array({String, String}),
      selected_column : String,
      selected_type : BinaryDataType,
      row_count : UInt64,
      budget : CompressedStreamBudget,
    ) : CompactSerializationProfile
      metadata = PartMetadataFileReader.new(part_path, budget)
      codec = metadata.read("default_compression_codec.txt", 64_i64)
      unless codec == CODEC_LZ4
        raise UnsupportedFormatError.new("only CODEC(LZ4) is supported for typed Compact parts")
      end

      text = metadata.read("serialization.json")
      parse(text, columns, selected_column, selected_type, row_count)
    end

    private def self.parse(
      text : String,
      columns : Array({String, String}),
      selected_column : String,
      selected_type : BinaryDataType,
      row_count : UInt64,
    ) : CompactSerializationProfile
      physical_types = Hash(String, String).new(initial_capacity: columns.size)
      columns.each do |name, type|
        raise CorruptPartError.new("duplicate Compact physical column") if physical_types.has_key?(name)
        physical_types[name] = type
      end
      canonical = selected_type.name
      unless physical_types[selected_column]? == canonical
        raise CorruptPartError.new("selected Compact type differs from columns.txt")
      end

      info = JSON.parse(text).as_h
      unless info.keys.to_set == ENVELOPE_FIELDS
        raise UnsupportedFormatError.new("unsupported Compact serialization.json fields")
      end

      version = info["version"]?.try(&.as_i) ||
                raise(CorruptPartError.new("serialization.json version is missing or malformed"))
      raise UnsupportedFormatError.new("only serialization.json version 1 is supported") unless version == 1

      propagated = info["propagate_types_serialization_versions_to_nested_types"]?.try(&.as_bool)
      raise CorruptPartError.new("serialization propagation flag is missing or malformed") if propagated.nil?

      raw_versions = info["types_serialization_versions"]?.try(&.as_h) ||
                     raise(CorruptPartError.new("serialization type versions are missing or malformed"))
      string_version = 0
      map_version = 0
      raw_versions.each do |name, raw_value|
        value = raw_value.as_i
        case name
        when "string"
          string_version = value
        when "map"
          map_version = value
        else
          raise UnsupportedFormatError.new("unsupported Compact serialization type version")
        end
      end

      has_string = contains_tag?(selected_type, BinaryDataType::TAG_STRING)
      has_map = contains_tag?(selected_type, BinaryDataType::TAG_MAP)
      if has_string && string_version != 0 && string_version != 1
        raise UnsupportedFormatError.new("Compact String serialization version must be 0 or 1")
      end
      map_basic = map_version == 0
      if has_map && !map_basic
        raise UnsupportedFormatError.new("only BASIC Compact Map serialization is supported")
      end

      serializers = info["columns"]?.try(&.as_a) ||
                    raise(CorruptPartError.new("serialization column metadata is missing or malformed"))
      if serializers.size > WidePart::MAX_METADATA_COLUMNS
        raise UnsupportedFormatError.new("Compact serialization column metadata exceeds limit")
      end
      records = prevalidate_records(serializers, physical_types, row_count)
      prevalidate_tuple_common_fields(records, physical_types, row_count, selected_column, selected_type)
      validate_record_shapes(records, physical_types, row_count, selected_column, selected_type)

      # A selected String root uses its declared version regardless of the
      # propagation flag. Child String serializers use v1 only when that flag
      # explicitly propagates the version; BinaryBulkProfile is global, so
      # mixed root/nested layouts are rejected rather than mis-normalized.
      nested_string = has_string && selected_type.tag != BinaryDataType::TAG_STRING
      if has_string && string_version == 1 && nested_string && !propagated
        raise UnsupportedFormatError.new("nested Compact String v1 requires propagated serialization versions")
      end
      string_v1 = has_string && string_version == 1
      if string_v1 && selected_type.tag == BinaryDataType::TAG_STRING ||
         string_v1 && propagated
        profile = BinaryBulkProfile.with_size_stream
      else
        profile = BinaryBulkProfile.single_stream
      end
      new(profile, map_basic, propagated)
    rescue ex : JSON::ParseException | TypeCastError | OverflowError
      raise CorruptPartError.new("serialization.json is malformed")
    end

    private def self.prevalidate_records(
      serializers : Array(JSON::Any),
      physical_types : Hash(String, String),
      row_count : UInt64,
    ) : Array({String, String, Hash(String, JSON::Any)})
      records = Array({String, String, Hash(String, JSON::Any)}).new(serializers.size)
      seen_names = Set(String).new
      # Validate common record fields for the whole bounded roster before
      # returning any unsupported kind/shape decision.
      serializers.each do |raw_entry|
        entry = raw_entry.as_h
        kind = entry["kind"]?.try(&.as_s) ||
               raise(CorruptPartError.new("serializer kind is missing or malformed"))
        name = entry["name"]?.try(&.as_s) ||
               raise(CorruptPartError.new("serializer name is missing or malformed"))
        defaults = entry["num_defaults"]?.try(&.as_i) ||
                   raise(CorruptPartError.new("serializer default count is missing or malformed"))
        rows = entry["num_rows"]?.try(&.as_i) ||
               raise(CorruptPartError.new("serializer row count is missing or malformed"))
        if exact = entry["exact_num_defaults"]?
          exact.as_bool
        end
        if name.empty? || name.bytesize > WidePart::MAX_METADATA_LINE_BYTES ||
           seen_names.includes?(name) || !physical_types.has_key?(name)
          raise CorruptPartError.new("serializer column name is invalid or duplicated")
        end
        unless defaults >= 0 && rows >= 0 && defaults <= rows &&
               rows.to_u64 <= WidePart::MAX_ROWS && rows.to_u64 == row_count
          raise CorruptPartError.new("serializer default or row count does not match the part")
        end
        seen_names << name
        records << {name, kind, entry}
      end
      records
    end

    private def self.prevalidate_tuple_common_fields(
      records : Array({String, String, Hash(String, JSON::Any)}),
      physical_types : Hash(String, String),
      row_count : UInt64,
      selected_column : String,
      selected_type : BinaryDataType,
    ) : Nil
      budget = BinaryCodecBudget.new(BinaryBulkCodec::DEFAULT_LIMITS)
      records.each do |name, _, entry|
        next unless subcolumns = entry["subcolumns"]?
        type = metadata_type_for(name, physical_types[name], selected_column, selected_type)
        next unless tuple_type?(type)
        prevalidate_tuple_children_common_fields!(subcolumns.as_a, type.not_nil!, row_count, budget, 1)
      end
      nil
    end

    private def self.validate_record_shapes(
      records : Array({String, String, Hash(String, JSON::Any)}),
      physical_types : Hash(String, String),
      row_count : UInt64,
      selected_column : String,
      selected_type : BinaryDataType,
    ) : Nil
      records.each do |name, kind, entry|
        type = metadata_type_for(name, physical_types[name], selected_column, selected_type)
        tuple = tuple_type?(type)
        has_subcolumns = entry.has_key?("subcolumns")
        if has_subcolumns && !tuple
          raise UnsupportedFormatError.new("Compact subcolumns metadata is only admitted for a Tuple serializer")
        end
        fields = entry.keys.to_set
        base = Set{"kind", "name", "num_defaults", "num_rows"}
        base_with_subcolumns = base.dup
        base_with_subcolumns << "subcolumns"
        extended = base.dup
        extended << "exact_num_defaults"
        extended_with_subcolumns = extended.dup
        extended_with_subcolumns << "subcolumns"
        unless fields == base || fields == extended ||
               has_subcolumns &&
               (fields == base_with_subcolumns || fields == extended_with_subcolumns)
          raise UnsupportedFormatError.new("unsupported Compact serialization column metadata shape")
        end
        unless kind == "Default"
          raise UnsupportedFormatError.new("only Default Compact serializers are supported")
        end
        if subcolumns = entry["subcolumns"]?
          validate_tuple_children_shapes!(subcolumns.as_a, type.not_nil!, row_count, 1)
        elsif tuple
          raise UnsupportedFormatError.new("Compact Tuple serializer metadata is incomplete")
        end
      end
      nil
    end

    # The first pass follows only known Tuple descriptor edges. It validates
    # common counts/flags for all schema-known child records before the later
    # shape pass can return Unsupported for an earlier sibling.
    private def self.prevalidate_tuple_children_common_fields!(
      values : Array(JSON::Any),
      tuple : BinaryDataType,
      row_count : UInt64,
      budget : BinaryCodecBudget,
      depth : Int,
    ) : Nil
      budget.ensure_depth(depth)
      budget.preflight_children(values.size.to_u64)
      tuple.child_count.times do |index|
        next if index >= values.size
        child_type = tuple.child_at(index)
        child = values[index].as_h
        validate_common_record_fields!(child, row_count)
        if tuple_type?(child_type) && (nested = child["subcolumns"]?)
          prevalidate_tuple_children_common_fields!(nested.as_a, child_type, row_count, budget, depth + 1)
        end
      end
      nil
    end

    private def self.validate_tuple_children_shapes!(
      values : Array(JSON::Any),
      tuple : BinaryDataType,
      row_count : UInt64,
      depth : Int,
    ) : Nil
      unless tuple_type?(tuple)
        raise UnsupportedFormatError.new("Compact subcolumns metadata does not match a Tuple declaration")
      end
      if depth > BinaryBulkCodec::DEFAULT_LIMITS.max_depth
        raise UnsupportedFormatError.new("Compact Tuple metadata depth exceeds its limit")
      end
      unless values.size == tuple.child_count
        raise UnsupportedFormatError.new("Compact Tuple serializer child count differs from its declaration")
      end
      tuple.child_count.times do |index|
        child = values[index].as_h
        child_type = tuple.child_at(index)
        is_tuple = tuple_type?(child_type)
        has_subcolumns = child.has_key?("subcolumns")
        if has_subcolumns && !is_tuple
          raise UnsupportedFormatError.new("Compact Tuple child subcolumns do not match its declaration")
        end
        base = Set{"kind", "num_defaults", "num_rows"}
        base_with_subcolumns = base.dup
        base_with_subcolumns << "subcolumns"
        extended = base.dup
        extended << "exact_num_defaults"
        extended_with_subcolumns = extended.dup
        extended_with_subcolumns << "subcolumns"
        unless child.keys.to_set == base || child.keys.to_set == extended ||
               has_subcolumns &&
               (child.keys.to_set == base_with_subcolumns || child.keys.to_set == extended_with_subcolumns)
          raise UnsupportedFormatError.new("unsupported Compact Tuple child metadata shape")
        end
        kind = validate_common_record_fields!(child, row_count)
        unless kind == "Default"
          raise UnsupportedFormatError.new("only Default Compact Tuple children are supported")
        end
        if nested = child["subcolumns"]?
          validate_tuple_children_shapes!(nested.as_a, child_type, row_count, depth + 1)
        elsif is_tuple
          raise UnsupportedFormatError.new("Compact nested Tuple metadata is incomplete")
        end
      end
      nil
    end

    private def self.validate_common_record_fields!(
      entry : Hash(String, JSON::Any),
      row_count : UInt64,
    ) : String
      kind = entry["kind"]?.try(&.as_s) ||
             raise(CorruptPartError.new("Tuple serializer kind is missing or malformed"))
      defaults = entry["num_defaults"]?.try(&.as_i) ||
                 raise(CorruptPartError.new("Tuple serializer default count is missing or malformed"))
      rows = entry["num_rows"]?.try(&.as_i) ||
             raise(CorruptPartError.new("Tuple serializer row count is missing or malformed"))
      unless defaults >= 0 && rows >= 0 && defaults <= rows &&
             rows.to_u64 <= WidePart::MAX_ROWS && rows.to_u64 == row_count
        raise CorruptPartError.new("Tuple serializer counts do not match the Compact row domain")
      end
      if exact = entry["exact_num_defaults"]?
        exact.as_bool
      end
      kind
    end

    private def self.metadata_type_for(
      name : String,
      type_name : String,
      selected_column : String,
      selected_type : BinaryDataType,
    ) : BinaryDataType?
      return selected_type if name == selected_column
      StaticBinaryBulkColumnDeclaration.parse(type_name)
    end

    private def self.tuple_type?(type : BinaryDataType?) : Bool
      !!type && tuple_type?(type.not_nil!)
    end

    private def self.tuple_type?(type : BinaryDataType) : Bool
      type.tag == BinaryDataType::TAG_NAMED_TUPLE || type.tag == BinaryDataType::TAG_UNNAMED_TUPLE
    end

    private def self.contains_tag?(type : BinaryDataType, tag : UInt8) : Bool
      return true if type.tag == tag
      type.child_count.times do |index|
        return true if contains_tag?(type.child_at(index), tag)
      end
      if type.tag == BinaryDataType::TAG_MAP
        return true if contains_tag?(type.child_at(0), tag) || contains_tag?(type.child_at(1), tag)
      end
      false
    end
  end
end

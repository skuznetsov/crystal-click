require "./spec_helper"

private def w180_json_limits(
  max_depth : Int = 64,
  max_nodes : Int = 4_096,
  max_elements : Int = 1_000_000,
  max_bytes : Int = 64 * 1024 * 1024,
) : CrystalClick::BinaryCodecLimits
  CrystalClick::BinaryCodecLimits.new(
    max_depth: max_depth,
    max_nodes: max_nodes,
    max_elements: max_elements,
    max_bytes: max_bytes,
  )
end

describe "W180 JSON binary profile guards and malformed boundaries" do
  it "refuses skip, regexp, future versions, out-of-range caps, and oversized metadata" do
    # Nonempty SKIP and SKIP REGEXP descriptors are valid ClickHouse metadata,
    # but this local JSON v0 profile deliberately does not interpret them.
    skip_wire = Bytes[0x30_u8, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0x78, 0x00]
    regexp_wire = Bytes[
      0x30_u8, 0x00, 0x00, 0x00, 0x00, 0x00,
      0x01, 0x03, 0x5e, 0x6b, 0x24, # one valid regexp: ^k$
    ]
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.decode(skip_wire)
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.decode(regexp_wire)
    end
    skip_typed_paths = Hash(String, CrystalClick::BinaryDataType).new
    skip_typed_paths["SKIP"] = CrystalClick::BinaryDataType.primitive("UInt8")
    skip_as_raw_typed_path = CrystalClick::BinaryDataType.json(typed_paths: skip_typed_paths)
    skip_as_raw_typed_path.json_type.not_nil!.typed_path_at(0).should eq("SKIP")
    skip_as_raw_typed_path.name.should eq("JSON(`SKIP` UInt8)")

    # Version 1 and limits above ClickHouse's current JSON v0 domain are
    # malformed descriptors, not silently widened local support.
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x30_u8, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00])
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x30_u8, 0x00, 0x91, 0x4e, 0x20, 0x00, 0x00, 0x00])
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x30_u8, 0x00, 0x80, 0x08, 0xff, 0x00, 0x00, 0x00])
    end

    # VarUInt(1001), the first count above the source limit of 1000 typed paths.
    # The decoder must reject this count before attempting a path allocation.
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x30_u8, 0x00, 0x80, 0x08, 0x20, 0xe9, 0x07])
    end

    # Duplicate typed metadata cannot be normalized through Hash overwrite.
    duplicate_typed_paths = Bytes[
      0x30_u8, 0x00, 0x80, 0x08, 0x20, 0x02,
      0x01, 0x78, 0x01, # x UInt8
      0x01, 0x78, 0x01, # x UInt8 again
      0x00, 0x00,
    ]
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(duplicate_typed_paths)
    end
  end

  it "rejects truncation, trailing bytes, duplicate row paths, and missing declared values" do
    json_type = CrystalClick::BinaryDataType.json

    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(Bytes[0x30_u8, 0x00])
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryDataTypeCodec.decode(
        Bytes[0x30_u8, 0x00, 0x80, 0x08, 0x20, 0x00, 0x00, 0x00, 0xff],
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(json_type, Bytes[0x01_u8])
    end

    # Two occurrences of x, with a Nothing runtime NULL first, are still a
    # duplicate wire key; dropping the first value cannot erase the evidence.
    duplicate_row = Bytes[
      0x02_u8,
      0x01, 0x78, 0x00,       # x: Nothing NULL
      0x01, 0x78, 0x01, 0x2a, # x: UInt8(42)
    ]
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode_value(json_type, duplicate_row)
    end

    typed_paths = Hash(String, CrystalClick::BinaryDataType).new
    typed_paths["n"] = CrystalClick::BinaryDataType.primitive("UInt8")
    typed_type = CrystalClick::BinaryDataType.json(typed_paths: typed_paths)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      # A missing declared non-nullable value is not synthesized from its
      # scalar default (zero) by this structured codec.
      CrystalClick::BinaryValueCodec.decode_value(typed_type, Bytes[0x00_u8])
    end
    expect_raises(ArgumentError) do
      CrystalClick::BinaryJsonRow.new(
        typed_type,
        [] of Tuple(String, CrystalClick::BinaryValue),
      )
    end

    uint8_type = CrystalClick::BinaryDataType.primitive("UInt8")
    expect_raises(ArgumentError) do
      # Duplicate construction keys are rejected even when the first value
      # would otherwise be omitted as a dynamic Nothing NULL.
      CrystalClick::BinaryJsonRow.new(json_type, [
        {"x", CrystalClick::BinaryValue.null},
        {"x", CrystalClick::BinaryValue.fixed(uint8_type, Bytes[0x2a_u8])},
      ] of Tuple(String, CrystalClick::BinaryValue))
    end
  end

  it "admits typed Nullable NULL but refuses a top-level Nullable runtime actual" do
    uint8_type = CrystalClick::BinaryDataType.primitive("UInt8")
    nullable_type = CrystalClick::BinaryDataType.nullable(uint8_type)
    typed_paths = Hash(String, CrystalClick::BinaryDataType).new
    typed_paths["typed"] = nullable_type
    typed_type = CrystalClick::BinaryDataType.json(typed_paths: typed_paths)
    typed_null_values = Array(Tuple(String, CrystalClick::BinaryValue)).new
    typed_null_values << {"typed", CrystalClick::BinaryValue.null(nullable_type)}
    typed_null = CrystalClick::BinaryValue.json(
      typed_type,
      CrystalClick::BinaryJsonRow.new(
        typed_type,
        typed_null_values,
      ),
    )
    typed_null_wire = Bytes[0x01_u8, 0x05, 0x74, 0x79, 0x70, 0x65, 0x64, 0x01]
    CrystalClick::BinaryValueCodec.encode_value(typed_null).should eq(typed_null_wire)
    CrystalClick::BinaryValueCodec.decode_value(typed_type, typed_null_wire)
      .json_row.value_at(0).is_null?.should be_true

    dynamic_type = CrystalClick::BinaryDataType.json(max_dynamic_paths: 0, max_dynamic_types: 0)
    runtime_null_values = Array(Tuple(String, CrystalClick::BinaryValue)).new
    runtime_null_values << {"runtime", CrystalClick::BinaryValue.null(nullable_type)}
    expect_raises(ArgumentError) do
      CrystalClick::BinaryJsonRow.new(
        dynamic_type,
        runtime_null_values,
      )
    end
  end

  it "admits scalar JSON wrappers without widening the physical, Object, or borrowed profiles" do
    json_type = CrystalClick::BinaryDataType.json(max_dynamic_paths: 0, max_dynamic_types: 0)
    empty_value = CrystalClick::BinaryValue.json(
      json_type,
      CrystalClick::BinaryJsonRow.new(
        json_type,
        [] of Tuple(String, CrystalClick::BinaryValue),
      ),
    )

    array_type = CrystalClick::BinaryDataType.array(json_type)
    nullable_type = CrystalClick::BinaryDataType.nullable(json_type)
    tuple_type = CrystalClick::BinaryDataType.tuple([json_type] of CrystalClick::BinaryDataType)
    array_type.child_at(0).should eq(json_type)
    nullable_type.child_at(0).should eq(json_type)
    tuple_type.child_at(0).should eq(json_type)

    # Legality is determined by each wrapper's actual child capability, not
    # by a blanket JSON ban. Array admits Nullable(JSON), but Array itself is
    # not legal under Nullable, and LC(JSON) remains outside the type profile.
    nullable_tuple_type = CrystalClick::BinaryDataType.nullable(tuple_type)
    nullable_tuple_type.child_at(0).should eq(tuple_type)
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.nullable(array_type) }
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.low_cardinality(json_type) }
    expect_raises(ArgumentError) { CrystalClick::BinaryDataType.aggregate_count(json_type) }
    nested_typed_paths = Hash(String, CrystalClick::BinaryDataType).new
    nested_typed_paths["nested"] = json_type
    nested_json_type = CrystalClick::BinaryDataType.json(typed_paths: nested_typed_paths)
    nested_json_type.json_type.not_nil!.typed_type_for("nested").should eq(json_type)
    nested_json_descriptor = CrystalClick::BinaryDataTypeCodec.encode(nested_json_type)
    CrystalClick::BinaryDataTypeCodec.decode(nested_json_descriptor).should eq(nested_json_type)

    dynamic_type = CrystalClick::BinaryDataType.dynamic(max_types: 0)
    dynamic_value = CrystalClick::BinaryValue.dynamic(dynamic_type, empty_value)
    dynamic_row = CrystalClick::BinaryValueCodec.encode_value(dynamic_value)
    decoded_dynamic = CrystalClick::BinaryValueCodec.decode_value(dynamic_type, dynamic_row)
    decoded_dynamic.child_at(0).type.should eq(json_type)
    decoded_dynamic.child_at(0).json_row.empty?.should be_true

    # Direct JSON is representable as Dynamic metadata, while its storage lane
    # remains unavailable until an Object child binding exists.
    json_structure = CrystalClick::DynamicStructure.new([json_type] of CrystalClick::BinaryDataType)
    json_structure.type_at(0).should eq(json_type)
    json_structure.canonical_variant_names.should contain(json_type.name)

    # W212 admits recursive JSON descriptors in representational metadata.
    # The value-ready ordinary arm still needs an exact Object leaf binding.
    wrapped_structure = CrystalClick::DynamicStructure.new([array_type] of CrystalClick::BinaryDataType)
    wrapped_structure.type_at(0).should eq(array_type)
    wrapped_plan_error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDynamicBulkPlan.new_with_budget(
        CrystalClick::BinaryDataType.dynamic(max_types: 1),
        {"root" => wrapped_structure},
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
      )
    end
    wrapped_plan_error.message.to_s.should contain("JSON")

    # An unused JSON arm must not slip through the bare Dynamic value codec.
    unused_rows = [
      [CrystalClick::BinaryValue.null] of CrystalClick::BinaryValue,
    ] of Array(CrystalClick::BinaryValue)
    value_error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicValueCodec.encode(json_structure, unused_rows)
    end
    value_error.message.to_s.should contain("JSON")

    empty_streams = CrystalClick::DynamicValueStreams.new(
      CrystalClick::DynamicDiscriminatorStream.new(Bytes.new(0), [] of CrystalClick::DynamicDiscriminatorMark),
      {} of String => CrystalClick::BinaryBulkStreams,
    )
    zero_window_error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::DynamicValueCodec.decode(
        json_structure,
        empty_streams,
        first_mark: 0,
        mark_count: 0,
      )
    end
    zero_window_error.message.to_s.should contain("JSON")

    # The metadata owner remains representational; the value-ready Object plan
    # rejects this unbound root Dynamic actual before making its lane plan.
    metadata_set = CrystalClick::ObjectDynamicStructureSet.new(
      CrystalClick::ObjectStructure.new(["doc"] of String),
      {"doc" => json_structure},
    )
    metadata_set.dynamic_for("doc").type_at(0).should eq(json_type)
    object_plan_error = expect_raises(ArgumentError) do
      CrystalClick::ObjectDocumentPlan.new(
        metadata_set,
        {} of String => CrystalClick::BinaryDataType,
      )
    end
    object_plan_error.message.to_s.should contain("JSON")

    object_error = expect_raises(ArgumentError) do
      # This schema-only probe is intentionally zero-row: persisted Object
      # declarations retain their narrower grammar than scalar RowBinary.
      CrystalClick::ObjectDocumentSchema.new({"nested" => array_type})
    end
    object_error.message.to_s.should contain("JSON")

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkTypePlan.new(array_type, CrystalClick::BinaryBulkProfile.single_stream)
    end
    bulk_error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryBulkCodec.encode(
        array_type,
        [] of Array(CrystalClick::BinaryValue),
      )
    end
    bulk_error.message.to_s.should contain("JSON")

    wrapped_empty = CrystalClick::BinaryValue.array(array_type, [empty_value] of CrystalClick::BinaryValue)
    full_wire = CrystalClick::BinaryValueCodec.encode(wrapped_empty)
    borrowed_encode_error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_borrowed(
        wrapped_empty,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default, true),
      )
    end
    borrowed_encode_error.message.to_s.should contain("JSON")
    borrowed_decode_error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.decode_borrowed(
        full_wire,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryCodecLimits.default),
      )
    end
    borrowed_decode_error.message.to_s.should contain("JSON")
    dynamic_bulk_encode_error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_dynamic_bulk_child(
        wrapped_empty,
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS, true),
        1,
      )
    end
    dynamic_bulk_encode_error.message.to_s.should contain("JSON")
    dynamic_bulk_decode_error = expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.decode_dynamic_bulk_child(
        CrystalClick::BinaryDataTypeCodec.encode(array_type),
        CrystalClick::BinaryCodecBudget.new(CrystalClick::BinaryBulkCodec::DEFAULT_LIMITS),
        1,
      )
    end
    dynamic_bulk_decode_error.message.to_s.should contain("JSON")
  end

  it "charges the full JSON descriptor and scalar together at exact and one-short limits" do
    json_type = CrystalClick::BinaryDataType.json
    value = CrystalClick::BinaryValue.json(
      json_type,
      CrystalClick::BinaryJsonRow.new(
        json_type,
        [] of Tuple(String, CrystalClick::BinaryValue),
      ),
    )
    descriptor = Bytes[0x30_u8, 0x00, 0x80, 0x08, 0x20, 0x00, 0x00, 0x00]
    row = Bytes[0x00_u8]
    full_wire = Bytes[0x30_u8, 0x00, 0x80, 0x08, 0x20, 0x00, 0x00, 0x00, 0x00]

    descriptor_exact = w180_json_limits(max_depth: 1, max_nodes: 1, max_elements: 0, max_bytes: 8)
    CrystalClick::BinaryDataTypeCodec.encode(json_type, descriptor_exact).should eq(descriptor)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.encode(
        json_type,
        w180_json_limits(max_depth: 1, max_nodes: 0, max_elements: 0, max_bytes: 8),
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryDataTypeCodec.encode(
        json_type,
        w180_json_limits(max_depth: 1, max_nodes: 1, max_elements: 0, max_bytes: 7),
      )
    end

    # Value-only RowBinary has one JSON value node and one byte for the empty
    # path roster. The full envelope must charge its descriptor and row to the
    # same operation: two nodes and nine bytes exactly, not two fresh budgets.
    value_exact = w180_json_limits(max_depth: 1, max_nodes: 2, max_elements: 0, max_bytes: 1)
    CrystalClick::BinaryValueCodec.encode_value(value, value_exact).should eq(row)
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_value(
        value,
        w180_json_limits(max_depth: 1, max_nodes: 1, max_elements: 0, max_bytes: 1),
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode_value(
        value,
        w180_json_limits(max_depth: 1, max_nodes: 2, max_elements: 0, max_bytes: 0),
      )
    end

    full_exact = w180_json_limits(max_depth: 1, max_nodes: 2, max_elements: 0, max_bytes: 9)
    CrystalClick::BinaryValueCodec.encode(value, full_exact).should eq(full_wire)
    CrystalClick::BinaryValueCodec.decode(full_wire, full_exact).json_row.empty?.should be_true
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode(
        value,
        w180_json_limits(max_depth: 1, max_nodes: 1, max_elements: 0, max_bytes: 9),
      )
    end
    expect_raises(CrystalClick::CorruptPartError) do
      CrystalClick::BinaryValueCodec.decode(
        full_wire,
        w180_json_limits(max_depth: 1, max_nodes: 1, max_elements: 0, max_bytes: 9),
      )
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::BinaryValueCodec.encode(
        value,
        w180_json_limits(max_depth: 1, max_nodes: 2, max_elements: 0, max_bytes: 8),
      )
    end
  end
end

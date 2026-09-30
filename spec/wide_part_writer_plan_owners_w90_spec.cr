require "./spec_helper"

alias W90PlanShadow = CrystalClick::WideTypePlan::WidePhysicalPlanShadow
alias W90PlanStream = W90PlanShadow::Stream
alias W90PlanAxis = W90PlanShadow::Axis
alias W90PlanAxisKind = W90PlanShadow::AxisKind
alias W90PlanRole = W90PlanShadow::StreamRole
alias W90PlanStorageMode = W90PlanShadow::StorageMode

def w90_mutate_plan_streams(
  streams : Array(W90PlanStream),
  index : Int32,
  mutation : Symbol,
) : Array(W90PlanStream)
  changed = streams.dup
  stream = changed[index]
  role = stream.role
  element_width = stream.element_width
  storage_mode = stream.storage_mode
  storage_axis = stream.storage_axis
  cardinality_parent_axis = stream.cardinality_parent_axis
  cardinality_child_axis = stream.cardinality_child_axis
  mark_row_axis = stream.mark_row_axis

  case mutation
  when :role
    role = W90PlanRole::NullMap
  when :width
    element_width += 1
  when :storage_mode
    storage_mode = W90PlanStorageMode::VariableBytes
  when :storage_axis
    storage_axis = W90PlanAxis.new("wrong-storage-axis", storage_axis.kind)
  when :cardinality_parent_axis
    axis = cardinality_parent_axis.not_nil!
    cardinality_parent_axis = W90PlanAxis.new("wrong-parent-axis", axis.kind)
  when :cardinality_child_axis
    axis = cardinality_child_axis.not_nil!
    child_kind = axis.kind == W90PlanAxisKind::ArrayElements ? W90PlanAxisKind::MapEntries : W90PlanAxisKind::ArrayElements
    cardinality_child_axis = W90PlanAxis.new("wrong-child-axis", child_kind)
  when :mark_row_axis
    mark_row_axis = W90PlanAxis.new("wrong-mark-axis", mark_row_axis.kind)
  else
    raise "unknown W90 plan mutation: #{mutation}"
  end

  changed[index] = W90PlanStream.new(
    stream.name,
    stream.semantic_type,
    stream.semantic_path,
    role,
    element_width,
    storage_mode,
    storage_axis,
    cardinality_parent_axis,
    cardinality_child_axis,
    mark_row_axis,
  )
  changed
end

module CrystalClick::WidePartWriter
  # These spec-only wrappers keep private physical-plan owners testable without
  # changing the production writer facade or exposing its nested types.
  def self.w90_owner_identities : Array(Tuple(String, Bool))
    w80 = ArrayMapStringUInt64PhysicalPlan.build("payload")
    w81 = ArrayMapNumericPhysicalPlan.build("payload", "UInt64", "UInt8", false, 1)
    w82 = ArrayMapStringPhysicalPlan.build("payload", "UInt64", false)
    w84 = ArrayMapArrayPhysicalPlan.build("payload", "UInt64", "String")
    w85 = ArrayMapArrayNumericPhysicalPlan.build("payload", "UInt64", "UInt8", 1)
    [
      {typeof(w80).name, {{ ArrayMapStringUInt64PhysicalPlan.struct? }}},
      {typeof(w81).name, {{ ArrayMapNumericPhysicalPlan.struct? }}},
      {typeof(w82).name, {{ ArrayMapStringPhysicalPlan.struct? }}},
      {typeof(w84).name, {{ ArrayMapArrayPhysicalPlan.struct? }}},
      {typeof(w85).name, {{ ArrayMapArrayNumericPhysicalPlan.struct? }}},
    ]
  end

  def self.w90_validate_w80(shadow : W90PlanShadow, streams : Array(W90PlanStream)) : Nil
    ArrayMapStringUInt64PhysicalPlan.build(shadow, streams, "payload")
    nil
  end

  def self.w90_validate_w81(
    shadow : W90PlanShadow,
    streams : Array(W90PlanStream),
    expected_leaf_width : Int32 = 1,
  ) : Nil
    ArrayMapNumericPhysicalPlan.build(shadow, streams, "payload", "UInt64", "UInt8", false, expected_leaf_width)
    nil
  end

  def self.w90_validate_w82(shadow : W90PlanShadow, streams : Array(W90PlanStream)) : Nil
    ArrayMapStringPhysicalPlan.build(shadow, streams, "payload", "UInt64", false)
    nil
  end

  def self.w90_validate_w84(shadow : W90PlanShadow, streams : Array(W90PlanStream)) : Nil
    ArrayMapArrayPhysicalPlan.build(shadow, streams, "payload", "UInt64", "String")
    nil
  end

  def self.w90_validate_w85(shadow : W90PlanShadow, streams : Array(W90PlanStream)) : Nil
    ArrayMapArrayNumericPhysicalPlan.build(shadow, streams, "payload", "UInt64", "UInt8", 1)
    nil
  end
end

describe "W90 writer physical-plan owners" do
  it "preserves all five nominal struct identities without adding a facade build method" do
    CrystalClick::WidePartWriter.w90_owner_identities.should eq([
      {"CrystalClick::WidePartWriter::ArrayMapStringUInt64PhysicalPlan", true},
      {"CrystalClick::WidePartWriter::ArrayMapNumericPhysicalPlan", true},
      {"CrystalClick::WidePartWriter::ArrayMapStringPhysicalPlan", true},
      {"CrystalClick::WidePartWriter::ArrayMapArrayPhysicalPlan", true},
      {"CrystalClick::WidePartWriter::ArrayMapArrayNumericPhysicalPlan", true},
    ])
    CrystalClick::WidePartWriter.responds_to?(:build).should be_false
  end

  it "rejects W80 stream count and serializer-order mutations at the owner boundary" do
    shadow = W90PlanShadow.for_type("Array(Map(String, UInt64))", "payload").not_nil!
    streams = shadow.streams

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::WidePartWriter.w90_validate_w80(shadow, streams[0...-1])
    end

    reordered = streams.dup
    reordered[2], reordered[3] = reordered[3], reordered[2]
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::WidePartWriter.w90_validate_w80(shadow, reordered)
    end
  end

  it "rejects W81 role, storage-mode/axis, and expected numeric-width mutations" do
    shadow = W90PlanShadow.for_type("Array(Map(UInt64, UInt8))", "payload").not_nil!
    streams = shadow.streams

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::WidePartWriter.w90_validate_w81(shadow, w90_mutate_plan_streams(streams, 3, :role))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::WidePartWriter.w90_validate_w81(shadow, w90_mutate_plan_streams(streams, 3, :storage_axis))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::WidePartWriter.w90_validate_w81(shadow, w90_mutate_plan_streams(streams, 3, :storage_mode))
    end
    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::WidePartWriter.w90_validate_w81(shadow, streams, 2)
    end
  end

  it "rejects W82 per-stream mark-axis mutations" do
    shadow = W90PlanShadow.for_type("Array(Map(UInt64, String))", "payload").not_nil!
    streams = shadow.streams

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::WidePartWriter.w90_validate_w82(shadow, w90_mutate_plan_streams(streams, 4, :mark_row_axis))
    end
  end

  it "rejects W84 nested-array cardinality-parent mutations" do
    shadow = W90PlanShadow.for_type("Array(Map(UInt64, Array(String)))", "payload").not_nil!
    streams = shadow.streams

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::WidePartWriter.w90_validate_w84(shadow, w90_mutate_plan_streams(streams, 3, :cardinality_parent_axis))
    end
  end

  it "rejects W84 nested-array cardinality-child-kind mutations" do
    shadow = W90PlanShadow.for_type("Array(Map(UInt64, Array(String)))", "payload").not_nil!
    streams = shadow.streams

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::WidePartWriter.w90_validate_w84(shadow, w90_mutate_plan_streams(streams, 3, :cardinality_child_axis))
    end
  end

  it "rejects W85 numeric leaf stream-width mutations" do
    shadow = W90PlanShadow.for_type("Array(Map(UInt64, Array(UInt8)))", "payload").not_nil!
    streams = shadow.streams

    expect_raises(CrystalClick::UnsupportedFormatError) do
      CrystalClick::WidePartWriter.w90_validate_w85(shadow, w90_mutate_plan_streams(streams, 4, :width))
    end
  end
end

require "./spec_helper"

describe "W262 offline Dynamic DDL lexical normalization" do
  it "admits native whitespace-only root, named Tuple, and Map declarations" do
    declarations = {
      {"Dynamic(max_types = 1)", "Dynamic(max_types=1)"},
      {
        "Tuple(root Dynamic(max_types = 1), nested Array(Dynamic(max_types = 1)))",
        "Tuple(root Dynamic(max_types=1), nested Array(Dynamic(max_types=1)))",
      },
      {"Map(String, Dynamic(max_types = 1))", "Map(String, Dynamic(max_types=1))"},
    }

    declarations.each do |source_type, selected_type|
      CrystalClick::OfflineTypedSelectionAdmission.admitted?(source_type, selected_type, false).should be_true
    end
  end

  it "keeps canonical declarations and the exact legacy Dynamic spelling admitted" do
    declarations = [
      "Dynamic(max_types=1)",
      "Tuple(root Dynamic(max_types=1), nested Array(Dynamic(max_types=1)))",
      "Map(String, Dynamic(max_types=1))",
    ]

    declarations.each do |declaration|
      CrystalClick::OfflineTypedSelectionAdmission.admitted?(declaration, declaration, false).should be_true
    end
    CrystalClick::OfflineTypedSelectionAdmission.admitted?("Dynamic", "Dynamic", false).should be_true
  end

  it "normalizes only whitespace outside quoted tokens" do
    source = "Tuple(`field  with space` Dynamic(max_types = 1), `field\\\\name` String)"
    expected = "Tuple(`field  with space` Dynamic(max_types=1), `field\\\\name` String)"
    candidate, parsed = CrystalClick::OfflineDynamicBulkColumnDeclaration.resolve(source)

    candidate.should be_true
    parsed.should_not be_nil
    parsed.not_nil!.name.should eq(expected)

    # The quoted field's repeated spaces and escaped backslash remain part of
    # the exact token spelling; only spaces around Dynamic punctuation vanish.
    quoted_space_source = "Tuple(`field  with space` Dynamic(max_types=1))"
    quoted_space_candidate, quoted_space = CrystalClick::OfflineDynamicBulkColumnDeclaration.resolve(quoted_space_source)
    quoted_space_candidate.should be_true
    quoted_space.not_nil!.name.should eq(quoted_space_source)
  end

  it "rejects renderer changes to Variant order and explicit default caps" do
    reordered_variant = "Tuple(v Variant(UInt64, String), d Dynamic(max_types = 1))"
    candidate, parsed = CrystalClick::OfflineDynamicBulkColumnDeclaration.resolve(reordered_variant)
    candidate.should be_true
    parsed.should be_nil

    explicit_default = "Tuple(d Dynamic(max_types = 32))"
    default_candidate, default_parsed = CrystalClick::OfflineDynamicBulkColumnDeclaration.resolve(explicit_default)
    default_candidate.should be_true
    default_parsed.should be_nil
  end

  it "refuses static, JSON, malformed, and over-budget declarations" do
    static_candidate, static_type = CrystalClick::OfflineDynamicBulkColumnDeclaration.resolve("UInt64")
    static_candidate.should be_false
    static_type.should be_nil

    json_candidate, json_type = CrystalClick::OfflineDynamicBulkColumnDeclaration.resolve("Tuple(doc JSON, value Dynamic(max_types=1))")
    json_candidate.should be_true
    json_type.should be_nil

    malformed_candidate, malformed_type = CrystalClick::OfflineDynamicBulkColumnDeclaration.resolve("Map(String, Dynamic(max_types = 1)")
    malformed_candidate.should be_false
    malformed_type.should be_nil

    depth_limits = CrystalClick::BinaryCodecLimits.new(max_depth: 1, max_nodes: 32, max_elements: 32, max_bytes: 128)
    depth_candidate, depth_type = CrystalClick::OfflineDynamicBulkColumnDeclaration.resolve(
      "Array(Dynamic(max_types=1))", limits: depth_limits)
    depth_candidate.should be_false
    depth_type.should be_nil

    byte_limits = CrystalClick::BinaryCodecLimits.new(max_depth: 64, max_nodes: 32, max_elements: 32, max_bytes: 8)
    byte_candidate, byte_type = CrystalClick::OfflineDynamicBulkColumnDeclaration.resolve(
      "Dynamic(max_types=1)", limits: byte_limits)
    byte_candidate.should be_false
    byte_type.should be_nil
  end

  it "does not widen the strict Dynamic bulk declaration grammar" do
    CrystalClick::DynamicBulkColumnDeclaration.parse("Dynamic(max_types = 1)").should be_nil
    CrystalClick::DynamicBulkColumnDeclaration.parse("Dynamic(max_types=32)").should be_nil
    CrystalClick::DynamicBulkColumnDeclaration.parse("Array(UInt64)").should be_nil
    CrystalClick::DynamicBulkColumnDeclaration.parse("JSON").should be_nil
    CrystalClick::DynamicBulkColumnDeclaration.parse("Array(JSON)").should be_nil
    CrystalClick::DynamicBulkColumnDeclaration.parse("Map(String, Dynamic(max_types=1)").should be_nil
  end
end

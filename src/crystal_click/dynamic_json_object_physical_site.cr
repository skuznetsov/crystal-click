module CrystalClick
  # One exact direct-JSON Dynamic arm bound to the existing Object physical
  # owner. The prefix is the full escaped actual-arm prefix, before any
  # Object-specific stream suffix; Array numbering is inherited unchanged.
  class DynamicJsonObjectPhysicalSite
    getter site_path : String
    getter canonical_arm_index : Int32
    getter escaped_prefix : String
    getter array_level : UInt64
    getter binding : DynamicJsonObjectBinding
    getter physical_plan : ObjectDocumentPhysicalPlan

    def initialize(
      site_path : String,
      @canonical_arm_index : Int32,
      escaped_prefix : String,
      @array_level : UInt64,
      @binding : DynamicJsonObjectBinding,
      @physical_plan : ObjectDocumentPhysicalPlan,
    )
      @site_path = String.new(site_path.to_slice)
      @escaped_prefix = String.new(escaped_prefix.to_slice)
    end
  end
end

module CrystalClick
  # :nodoc:
  # Publishes one Compact projection through the ordinary Compact writer
  # beneath its parent's unpublished staging directory.
  private class CompactPartPreparedProjection < ProjectionPreparedPart
    getter entry_name : String
    getter checksum_entry_count : Int32
    getter file_count : Int32

    @projection : CompactPartProjection
    @budgets : ProjectionWriterBudgets

    private def initialize(
      @entry_name : String,
      @projection : CompactPartProjection,
      @budgets : ProjectionWriterBudgets,
    )
      @checksum_entry_count = 5
      @file_count = 9 + (@projection.mark_format.mrk4? ? 1 : 0)
    end

    def self.prepare(
      parent_target : String,
      projection : CompactPartProjection,
      budgets : ProjectionWriterBudgets,
    ) : CompactPartPreparedProjection
      entry_name = "#{projection.name}.proj"
      child_path = File.join(parent_target, entry_name)
      if child_path.bytesize > WidePartTable::MAX_PART_PATH_BYTES
        raise ArgumentError.new("projection child path exceeds reader limit")
      end
      new(entry_name, projection, budgets)
    end

    def summary_sidecars : Array(String)
      if @projection.mark_format.mrk4?
        ProjectionPartSummary::MRK4_SIDECARS
      else
        ProjectionPartSummary::MRK3_SIDECARS
      end
    end

    def encode! : Nil
      # The Compact operation performs planning and encoding when the child
      # stage is created, using the parent's shared operation budgets.
      nil
    end

    def publish(parent_stage : String) : PartWriterInfrastructure::ChecksumRecord
      child_path = File.join(parent_stage, @entry_name)
      keys = @projection.keys
      CompactPartOperation.write_uint64_columns(
        child_path,
        @projection.key_name,
        keys.to_unsafe.to_slice(keys.size),
        @projection.columns,
        @projection.rows_per_mark,
        @projection.frame_bytes,
        @budgets.write_codec.limits,
        @budgets.write_transport.limits,
        @budgets.read_transport.limits,
        @projection.mark_format,
        @projection.variant_discriminator_mode,
        @projection.compress_marks,
        @projection.profile,
        schema_binding: @projection.schema_binding,
        projections: [] of WidePartProjection,
        projection_budgets: @budgets,
      )
      ProjectionPartSummary.record(@entry_name, child_path, summary_sidecars)
    end
  end
end

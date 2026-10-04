module CrystalClick
  # Thin schedule dispatcher: the occurrence owner validates and charges
  # full-mark shape lanes, while W142 still owns dictionary/index replay.
  module BinaryBulkLowCardinalitySiteDecoder
    def self.decode(
      type : BinaryDataType,
      sites : Array(BinaryBulkTypePlan::LowCardinalitySite),
      shape_roles : Array(String),
      schedule_grid_count : UInt64,
      streams : BinaryBulkStreams,
      rows_per_mark : Array(UInt64),
      budget : BinaryCodecBudget,
      first_mark : Int32,
      mark_count : Int32,
      dynamic_plan : BinaryDynamicBulkPlan? = nil,
    ) : Hash(String, Array(Array(BinaryValue)))
      decoded = Hash(String, Array(Array(BinaryValue))).new
      return decoded if sites.empty?

      occurrences = BinaryBulkLowCardinalityOccurrenceSchedule.build(
        type,
        shape_roles,
        schedule_grid_count,
        streams,
        rows_per_mark,
        budget,
        dynamic_plan
      )

      sites.each do |site|
        per_mark = occurrences[site.path]?
        unless per_mark
          raise CorruptPartError.new("binary bulk occurrence schedule is missing an LC site")
        end
        site_lanes = {
          BinaryLowCardinalityStorageStreams::DICTIONARY_ROLE => streams.stream(site.dictionary_role),
          BinaryLowCardinalityStorageStreams::INDEX_ROLE      => streams.stream(site.indexes_role),
        } of String => BinaryBulkStream
        site_streams = BinaryBulkStreams.new(streams.mark_count, site_lanes)
        decoded[site.path] = BinaryLowCardinalityStorageDecoder.decode_prevalidated(
          site.type,
          site_streams,
          per_mark.not_nil!,
          budget,
          first_mark,
          mark_count
        )
      end
      decoded
    end
  end
end

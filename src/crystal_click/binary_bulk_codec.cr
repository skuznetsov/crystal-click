module CrystalClick
  # Public paired codec for recursive logical values stored across exact
  # decompressed role lanes. It does not read/write a complete part or JSON.
  module BinaryBulkCodec
    DEFAULT_LIMITS = BinaryCodecLimits.new(
      max_depth: 64,
      max_nodes: 1_000_000,
      max_elements: 3_000_000,
      max_bytes: 64 * 1024 * 1024
    )

    def self.encode(
      type : BinaryDataType,
      granules : Array(Array(BinaryValue)),
      limits : BinaryCodecLimits = DEFAULT_LIMITS,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      json_object_writer : BinaryDynamicBulkJsonObjectWriter? = nil,
      json_leaf_key : BinaryDynamicJsonLeafKey? = nil,
      shared_value_depth_origin : Int = 1,
    ) : BinaryBulkStreams
      budget = BinaryCodecBudget.new(limits, true)
      encode_with_budget(
        type,
        granules,
        budget,
        profile: profile,
        json_object_writer: json_object_writer,
        json_leaf_key: json_leaf_key,
        shared_value_depth_origin: shared_value_depth_origin,
      )
    end

    def self.encode_with_budget(
      type : BinaryDataType,
      granules : Array(Array(BinaryValue)),
      budget : BinaryCodecBudget,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      json_object_writer : BinaryDynamicBulkJsonObjectWriter? = nil,
      json_leaf_key : BinaryDynamicJsonLeafKey? = nil,
      shared_value_depth_origin : Int = 1,
    ) : BinaryBulkStreams
      BinaryBulkEncoder.encode(
        type,
        granules,
        budget,
        profile,
        json_object_writer: json_object_writer,
        json_leaf_key: json_leaf_key,
        shared_value_depth_origin: shared_value_depth_origin,
      )
    end

    def self.decode(
      type : BinaryDataType,
      streams : BinaryBulkStreams,
      rows_per_mark : Array(UInt64),
      first_mark : Int = 0,
      mark_count : Int? = nil,
      limits : BinaryCodecLimits = DEFAULT_LIMITS,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      json_object_reader : BinaryDynamicBulkJsonObjectReader? = nil,
      json_leaf_key : BinaryDynamicJsonLeafKey? = nil,
      shared_value_depth_origin : Int = 1,
    ) : Array(Array(BinaryValue))
      budget = BinaryCodecBudget.new(limits)
      decode_with_budget(
        type,
        streams,
        rows_per_mark,
        budget,
        first_mark: first_mark,
        mark_count: mark_count,
        profile: profile,
        json_object_reader: json_object_reader,
        json_leaf_key: json_leaf_key,
        shared_value_depth_origin: shared_value_depth_origin,
      )
    end

    def self.decode_with_budget(
      type : BinaryDataType,
      streams : BinaryBulkStreams,
      rows_per_mark : Array(UInt64),
      budget : BinaryCodecBudget,
      first_mark : Int = 0,
      mark_count : Int? = nil,
      profile : BinaryBulkProfile = BinaryBulkProfile.single_stream,
      json_object_reader : BinaryDynamicBulkJsonObjectReader? = nil,
      json_leaf_key : BinaryDynamicJsonLeafKey? = nil,
      shared_value_depth_origin : Int = 1,
    ) : Array(Array(BinaryValue))
      BinaryBulkDecoder.decode(
        type,
        streams,
        rows_per_mark,
        budget,
        first_mark,
        mark_count,
        profile,
        json_object_reader: json_object_reader,
        json_leaf_key: json_leaf_key,
        shared_value_depth_origin: shared_value_depth_origin,
      )
    end
  end
end

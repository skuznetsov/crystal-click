module CrystalClick
  # Shared bounded grammar for Object path counts, Dynamic variant counts,
  # and opaque shared-name statistics.
  module StructureStatisticsCodec
    def self.read(context : BinaryCodecContext, positional_count : Int32) : StructureStatistics
      if positional_count < 0
        context.corrupt!("structure positional statistics count is negative")
      end

      count = positional_count.to_u64
      context.preflight_metadata(
        count,
        1_u64,
        Int32::MAX.to_u64,
        "structure positional statistics declared metadata count"
      )
      context.visit_metadata_nodes(count, 1)
      counts = Array(UInt64).new(positional_count)
      positional_count.times { counts << context.read_var_uint }

      raw_shared_count = context.read_var_uint
      shared_count = context.preflight_metadata(
        raw_shared_count,
        2_u64,
        Int32::MAX.to_u64,
        "shared statistics declared metadata count"
      )
      context.visit_metadata_nodes(raw_shared_count, 1)
      shared = Array(StructureStatistic).new(shared_count)
      shared_count.times do
        name_size = context.read_var_uint
        name = String.new(context.read_slice(name_size))
        value = context.read_var_uint
        shared << StructureStatistic.new(name, value)
      end

      begin
        StructureStatistics.new(counts, shared)
      rescue ex : ArgumentError
        context.corrupt!("invalid shared structure statistics: #{ex.message}")
      end
    end

    def self.write(
      statistics : StructureStatistics,
      context : BinaryCodecContext,
      positional_count : Int32,
      positional_order : Array(Int32)? = nil,
    ) : Nil
      unless positional_count >= 0 && statistics.count_count == positional_count
        raise ArgumentError.new("structure positional statistics count does not match its roster")
      end
      if order = positional_order
        unless order.size == positional_count
          raise ArgumentError.new("structure positional statistics order does not match its roster")
        end
      end

      count = positional_count.to_u64
      context.preflight_metadata(count, maximum_count: Int32::MAX.to_u64, label: "structure positional statistics count")
      context.visit_metadata_nodes(count, 1)
      positional_count.times do |index|
        source_index = index
        if order = positional_order
          source_index = order[index]
        end
        context.write_var_uint(statistics.count_at(source_index))
      end

      shared_count = statistics.shared_count
      context.preflight_metadata(
        shared_count.to_u64,
        maximum_count: Int32::MAX.to_u64,
        label: "shared statistics count"
      )
      context.visit_metadata_nodes(shared_count.to_u64, 1)
      context.write_var_uint(shared_count.to_u64)

      entries = statistics.shared
      entries.sort! { |left, right| compare_names(left, right) }
      entries.each do |entry|
        context.write_var_uint(entry.name_byte_size.to_u64)
        entry.name_byte_size.times do |index|
          context.write_byte(entry.name_byte_at(index))
        end
        context.write_var_uint(entry.count)
      end
      nil
    end

    private def self.compare_names(left : StructureStatistic, right : StructureStatistic) : Int32
      common_size = Math.min(left.name_byte_size, right.name_byte_size)
      common_size.times do |index|
        left_byte = left.name_byte_at(index)
        right_byte = right.name_byte_at(index)
        return -1 if left_byte < right_byte
        return 1 if left_byte > right_byte
      end
      left.name_byte_size <=> right.name_byte_size
    end
  end
end

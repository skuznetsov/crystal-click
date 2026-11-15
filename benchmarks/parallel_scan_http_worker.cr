require "http/server"
require "json"
require "option_parser"
require "set"
require "../src/crystal_click"

module ParallelScanHTTPWorker
  ROW_BATCH_SIZE   = CrystalClick::WidePartTable::DEFAULT_BATCH_ROWS
  AGGREGATE_PREFIX = "SELECT count(), sum(pk), sum(value), sum(bitXor(pk, value)), min(value), max(value) FROM bench.fixture"
  EXPORT_QUERY     = "SELECT pk, value FROM bench.fixture ORDER BY pk FORMAT RowBinary"

  record Aggregate, count : UInt64, sum_pk : UInt64, sum_value : UInt64,
    sum_xor : UInt64, min_value : UInt64, max_value : UInt64

  def self.scan(table : CrystalClick::TypedPartTable, workers : Int32, &block : CrystalClick::WidePartTableBatch -> Nil) : Nil
    {% if flag?(:parallel_scan_bench) %}
      table.scan_typed_parallel(workers: workers, batch_rows: ROW_BATCH_SIZE) do |batch|
        yield batch
      end
    {% else %}
      raise "baseline worker only supports workers=1" unless workers == 1
      table.scan_typed(batch_rows: ROW_BATCH_SIZE) do |batch|
        yield batch
      end
    {% end %}
  end

  def self.aggregate(table : CrystalClick::TypedPartTable, workers : Int32) : Aggregate
    count = 0_u64
    sum_pk = 0_u64
    sum_value = 0_u64
    sum_xor = 0_u64
    min_value = UInt64::MAX
    max_value = 0_u64

    scan(table, workers) do |batch|
      keys = batch.values_for("pk", UInt64)
      values = batch.values_for("value", UInt64)
      raise "selected column batch lengths differ" unless keys.size == values.size

      keys.each_with_index do |key, index|
        value = values[index]
        count &+= 1_u64
        sum_pk &+= key
        sum_value &+= value
        sum_xor &+= key ^ value
        min_value = value if value < min_value
        max_value = value if value > max_value
      end
    end

    Aggregate.new(count, sum_pk, sum_value, sum_xor, min_value, max_value)
  end

  def self.aggregate_rowbinary(aggregate : Aggregate) : Bytes
    io = IO::Memory.new(48)
    io.write_bytes(aggregate.count, IO::ByteFormat::LittleEndian)
    io.write_bytes(aggregate.sum_pk, IO::ByteFormat::LittleEndian)
    io.write_bytes(aggregate.sum_value, IO::ByteFormat::LittleEndian)
    io.write_bytes(aggregate.sum_xor, IO::ByteFormat::LittleEndian)
    io.write_bytes(aggregate.min_value, IO::ByteFormat::LittleEndian)
    io.write_bytes(aggregate.max_value, IO::ByteFormat::LittleEndian)
    io.to_slice
  end

  def self.export_rowbinary(table : CrystalClick::TypedPartTable, workers : Int32, output : HTTP::Server::Response) : Nil
    output.content_length = table.total_row_count * 16
    scan(table, workers) do |batch|
      keys = batch.values_for("pk", UInt64)
      values = batch.values_for("value", UInt64)
      raise "selected column batch lengths differ" unless keys.size == values.size

      buffer = IO::Memory.new(keys.size * 16)
      keys.each_with_index do |key, index|
        buffer.write_bytes(key, IO::ByteFormat::LittleEndian)
        buffer.write_bytes(values[index], IO::ByteFormat::LittleEndian)
      end
      output.write(buffer.to_slice)
    end
  end

  def self.read_request_body(context : HTTP::Server::Context) : String
    context.request.body.try(&.gets_to_end) || ""
  end

  def self.aggregate_sql(workers : Int32, layout : String) : String
    checksum_on_read = layout == "wide" ? 0 : 1
    String.build do |sql|
      sql << AGGREGATE_PREFIX << " SETTINGS max_threads=" << workers
      sql << ", checksum_on_read=" << checksum_on_read
      sql << ", use_query_cache=0, use_query_condition_cache=0, use_uncompressed_cache=0"
      sql << ", optimize_trivial_count_query=0, merge_tree_use_deserialization_prefixes_cache=0"
      sql << ", optimize_read_in_order=0, query_plan_read_in_order=0"
      sql << ", merge_tree_min_rows_for_concurrent_read=0, merge_tree_min_bytes_for_concurrent_read=0"
      sql << ", merge_tree_min_read_task_size=4"
      sql << ", log_queries=0, log_query_threads=0 FORMAT RowBinary"
    end
  end

  def self.isolated_contexts : Int32
    count = 0
    Fiber::ExecutionContext.each do |context|
      count += 1 if context.is_a?(Fiber::ExecutionContext::Isolated) && context.running?
    end
    count
  end

  def self.worker_witness(table : CrystalClick::TypedPartTable, workers : Int32) : String
    context_count = -1
    observed_rows = 0_u64
    observed_marks = Set(Int32).new
    rows_per_mark = Hash(Int32, UInt64).new(0_u64)
    caller_fiber_id = Fiber.current.object_id
    caller_thread_id = Thread.current.object_id
    scan(table, workers) do |batch|
      if context_count < 0
        context_count = isolated_contexts
      end
      raise "scan callback moved off the HTTP caller fiber" unless Fiber.current.object_id == caller_fiber_id
      raise "scan callback moved off the HTTP caller thread" unless Thread.current.object_id == caller_thread_id
      batch_rows = batch.row_count || batch.values_for("pk", UInt64).size.to_u64
      observed_rows += batch_rows
      observed_marks << batch.mark_index
      rows_per_mark[batch.mark_index] += batch_rows
      batch.values_for("pk", UInt64).each_with_index do |key, index|
        raise "worker witness found an out-of-order row" unless key == batch.source_row_offset + index.to_u64
      end
    end
    min_rows_per_mark = UInt64::MAX
    max_rows_per_mark = 0_u64
    rows_per_mark.each_value do |rows|
      min_rows_per_mark = rows if rows < min_rows_per_mark
      max_rows_per_mark = rows if rows > max_rows_per_mark
    end
    {
      "rows"                                => observed_rows,
      "distinct_data_marks"                 => observed_marks.size,
      "min_rows_per_mark"                   => min_rows_per_mark,
      "max_rows_per_mark"                   => max_rows_per_mark,
      "isolated_contexts_at_first_callback" => context_count,
      "callback_fiber_is_caller"            => true,
      "callback_thread_is_caller"           => true,
    }.to_json
  end

  def self.run(part_path : String, port : Int32, workers : Int32, layout : String) : Nil
    table = CrystalClick::TypedPartTable.open_selected_typed([part_path], ["pk", "value"])
    server = HTTP::Server.new do |context|
      begin
        request = context.request
        case request.path
        when "/ready"
          context.response.content_type = "text/plain"
          context.response.content_length = 2
          context.response.print "OK"
        when "/prepare"
          body = read_request_body(context)
          unless body == "PREPARE"
            context.response.status_code = 400
            context.response.print "unexpected prepare request"
            next
          end
          table = CrystalClick::TypedPartTable.open_selected_typed([part_path], ["pk", "value"])
          context.response.content_type = "text/plain"
          context.response.content_length = 5
          context.response.print "READY"
        when "/aggregate"
          body = read_request_body(context)
          unless body == aggregate_sql(workers, layout)
            context.response.status_code = 400
            context.response.print "unexpected aggregate request"
            next
          end
          row = aggregate_rowbinary(aggregate(table, workers))
          context.response.content_type = "application/octet-stream"
          context.response.content_length = row.size
          context.response.write(row)
        when "/witness"
          body = read_request_body(context)
          unless body == "WITNESS"
            context.response.status_code = 400
            context.response.print "unexpected witness request"
            next
          end
          witness = worker_witness(table, workers)
          context.response.content_type = "application/json"
          context.response.content_length = witness.bytesize
          context.response.print witness
        when "/export"
          body = read_request_body(context)
          unless body == EXPORT_QUERY
            context.response.status_code = 400
            context.response.print "unexpected export request"
            next
          end
          context.response.content_type = "application/octet-stream"
          export_rowbinary(table, workers, context.response)
        else
          context.response.status_code = 404
          context.response.print "not found"
        end
      rescue error
        context.response.status_code = 500
        context.response.content_type = "text/plain"
        context.response.print error.message || error.class.name
      end
    end
    server.bind_tcp("127.0.0.1", port)
    puts "READY port=#{port} workers=#{workers} rows=#{table.total_row_count} part=#{part_path}"
    STDOUT.flush
    server.listen
  end
end

part_path = ""
port = 0
workers = 1
layout = ""
OptionParser.parse do |parser|
  parser.banner = "Usage: parallel_scan_http_worker --part PATH --port PORT --layout LAYOUT [--workers N]"
  parser.on("--part PATH", "Native MergeTree part path") { |value| part_path = value }
  parser.on("--port PORT", "Loopback HTTP port") { |value| port = value.to_i }
  parser.on("--workers N", "Typed scan workers") { |value| workers = value.to_i }
  parser.on("--layout LAYOUT", "Native part layout: wide or compact") { |value| layout = value }
  parser.on("-h", "--help", "Show help") { puts parser; exit }
end
raise "--part is required" if part_path.empty?
raise "--port must be between 1 and 65535" unless (1..65535).includes?(port)
raise "--workers must be between 1 and 32" unless (1..32).includes?(workers)
raise "--layout must be wide or compact" unless {"wide", "compact"}.includes?(layout)

ParallelScanHTTPWorker.run(part_path, port, workers, layout)

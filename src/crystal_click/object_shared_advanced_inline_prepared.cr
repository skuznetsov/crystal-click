module CrystalClick
  # Validated, value-free state for decoding one inline Object shared mark.
  # This holder retains the exact prefix/physical owner and read budget, the
  # detached raw bucket and Copy lanes, and parser-observed chunk headers.
  class ObjectSharedAdvancedInlinePrepared
    @prefix : ObjectDocumentCallbackPrefix
    @physical_plan : ObjectDocumentPhysicalPlan
    @nested_context : ObjectSharedNestedSerializationContext
    @budget : BinaryCodecBudget
    @logical_row_count : UInt64
    @bucket_parents : Array(Array(ObjectSharedPhysicalParentMark))
    @structure_spans : Array(Array(ObjectSharedChunkStructureReadSpan))
    @copies : Array(ObjectSharedCopyStreams)

    # The only holder factory accepts authenticated source inputs. Raw decoder
    # artifacts are produced inside this operation and cannot be supplied by a
    # caller to bind bytes from another callback source to this prefix/owner.
    def self.prepare_from_source(
      prefix : ObjectDocumentCallbackPrefix,
      physical_plan : ObjectDocumentPhysicalPlan,
      grid : StorageOccurrenceGrid,
      budget : BinaryCodecBudget,
      role_bindings : Array(ObjectDocumentInlineCallbackOrder::BodyLaneBinding)? = nil,
      callback_pairs : Array(ObjectDocumentInlineCallbackOrder::CallbackPair)? = nil,
    ) : ObjectSharedAdvancedInlinePrepared
      artifacts = ObjectSharedAdvancedInlineDecoder.prepare_raw_inline(
        prefix,
        physical_plan,
        grid,
        budget,
        role_bindings,
        callback_pairs,
      )
      seal(
        prefix,
        physical_plan,
        prefix.nested_context,
        budget,
        artifacts[:logical_row_count],
        artifacts[:bucket_parents],
        artifacts[:structure_spans_by_bucket],
        artifacts[:copies],
      )
    end

    # Private artifact-to-holder boundary. Only prepare_from_source can call
    # this after the decoder has revalidated the source and built its artifacts.
    private def self.seal(
      prefix : ObjectDocumentCallbackPrefix,
      physical_plan : ObjectDocumentPhysicalPlan,
      nested_context : ObjectSharedNestedSerializationContext,
      budget : BinaryCodecBudget,
      logical_row_count : UInt64,
      bucket_parents : Array(Array(ObjectSharedPhysicalParentMark)),
      structure_spans : Array(Array(ObjectSharedChunkStructureReadSpan)),
      copies : Array(ObjectSharedCopyStreams),
    ) : ObjectSharedAdvancedInlinePrepared
      prefix.validate_physical_owner!(physical_plan)
      unless prefix.nested_context.same?(nested_context)
        raise CorruptPartError.new("prepared inline Object context differs from its retained prefix")
      end
      if budget.writing?
        raise ArgumentError.new("prepared inline Object state requires a read-direction budget")
      end

      bucket_count = physical_plan.shared_bucket_count
      unless bucket_count > 0 && bucket_parents.size == bucket_count && structure_spans.size == bucket_count
        raise CorruptPartError.new("prepared inline Object bucket artifacts differ from their physical owner")
      end
      unless bucket_count.to_u64 == prefix.plan.structures.object.bucket_count &&
             nested_context.shared_data_version == prefix.plan.structures.object.shared_data_version
        raise CorruptPartError.new("prepared inline Object layout differs from its retained structure prefix")
      end

      chunk_count = copies.size
      if chunk_count == 0
        raise CorruptPartError.new("prepared inline Object has no Copy chunks")
      end
      observed_rows = 0_u64
      unless bucket_parents.all? { |parents| parents.size == 1 }
        raise CorruptPartError.new("prepared inline Object requires one physical parent per bucket")
      end
      first_parent = bucket_parents[0][0]
      unless first_parent.chunk_count == chunk_count
        raise CorruptPartError.new("prepared inline Object Copy chunks differ from its bucket schedule")
      end

      bucket_parents.each_with_index do |parents, bucket_index|
        parent = parents[0]
        spans = structure_spans[bucket_index]
        unless parent.chunk_count == chunk_count && spans.size == chunk_count
          raise CorruptPartError.new("prepared inline Object bucket chunk spans differ from its Copy schedule")
        end
        chunk_count.times do |chunk_index|
          chunk = parent.chunk_at(chunk_index)
          span = spans[chunk_index]
          record = span.record
          unless span.prefix_start >= 0 && span.prefix_end >= span.prefix_start &&
                 record.row_count == chunk.row_count && record.path_count == chunk.path_count
            raise CorruptPartError.new("prepared inline Object chunk span differs from its parsed bucket chunk")
          end
          if bucket_index == 0
            if chunk.row_count > logical_row_count - observed_rows
              raise CorruptPartError.new("prepared inline Object chunks exceed their parent occurrence grid")
            end
            observed_rows += chunk.row_count
          else
            first_chunk = first_parent.chunk_at(chunk_index)
            unless chunk.row_count == first_chunk.row_count
              raise CorruptPartError.new("prepared inline Object bucket chunk rows disagree")
            end
          end
        end
      end
      unless observed_rows == logical_row_count
        raise CorruptPartError.new("prepared inline Object chunks disagree with their parent occurrence grid")
      end

      new(
        prefix,
        physical_plan,
        nested_context,
        budget,
        logical_row_count,
        bucket_parents,
        structure_spans,
        copies,
      )
    end

    private def initialize(
      @prefix : ObjectDocumentCallbackPrefix,
      @physical_plan : ObjectDocumentPhysicalPlan,
      @nested_context : ObjectSharedNestedSerializationContext,
      @budget : BinaryCodecBudget,
      @logical_row_count : UInt64,
      bucket_parents : Array(Array(ObjectSharedPhysicalParentMark)),
      structure_spans : Array(Array(ObjectSharedChunkStructureReadSpan)),
      copies : Array(ObjectSharedCopyStreams),
    )
      @bucket_parents = bucket_parents.map(&.dup)
      @structure_spans = structure_spans.map(&.dup)
      @copies = copies.dup
    end

    def logical_row_count : UInt64
      @logical_row_count
    end

    def bucket_count : Int32
      @bucket_parents.size
    end

    def chunk_count : Int32
      @copies.size
    end

    def chunk_structure_spans_at(bucket_index : Int) : Array(ObjectSharedChunkStructureReadSpan)
      @structure_spans[bucket_index].dup
    end

    # Logical retained-owner census for the parsed chunk schedule, detached
    # raw path lanes and detached Copy buffers. It also follows Compact
    # callback slices to their distinct coordinate contexts and retained
    # shards. This does not traverse the full parsed-prefix/physical-plan
    # metadata, hash, recursive-descriptor, or coordinate physical-source/grid
    # graph, nor estimate capacity, transient decoder allocations, or RSS.
    def retained_workspace_bytes : UInt64
      bytes = instance_sizeof(ObjectSharedAdvancedInlinePrepared).to_u64
      bytes = checked_add(bytes, sizeof(Pointer(ObjectDocumentCallbackPrefix)).to_u64)
      bytes = checked_add(bytes, sizeof(Pointer(ObjectDocumentPhysicalPlan)).to_u64)
      bytes = checked_add(bytes, sizeof(Pointer(ObjectSharedNestedSerializationContext)).to_u64)
      bytes = checked_add(bytes, sizeof(Pointer(BinaryCodecBudget)).to_u64)

      bytes = checked_add(bytes, instance_sizeof(Array(Array(ObjectSharedPhysicalParentMark))).to_u64)
      bytes = checked_add(bytes, checked_multiply(@bucket_parents.size.to_u64,
        sizeof(Pointer(Array(ObjectSharedPhysicalParentMark))).to_u64))
      @bucket_parents.each do |parents|
        bytes = checked_add(bytes, instance_sizeof(Array(ObjectSharedPhysicalParentMark)).to_u64)
        bytes = checked_add(bytes, checked_multiply(parents.size.to_u64,
          sizeof(Pointer(ObjectSharedPhysicalParentMark)).to_u64))
        parents.each do |parent|
          bytes = checked_add(bytes, instance_sizeof(ObjectSharedPhysicalParentMark).to_u64)
          bytes = checked_add(bytes, instance_sizeof(Array(ObjectSharedPhysicalChunk)).to_u64)
          bytes = checked_add(bytes, checked_multiply(parent.chunk_count.to_u64,
            sizeof(Pointer(ObjectSharedPhysicalChunk)).to_u64))
          parent.chunk_count.times do |chunk_index|
            chunk = parent.chunk_at(chunk_index)
            bytes = checked_add(bytes, instance_sizeof(ObjectSharedPhysicalChunk).to_u64)
            bytes = checked_add(bytes, instance_sizeof(Array(ObjectSharedPhysicalPath)).to_u64)
            bytes = checked_add(bytes, checked_multiply(chunk.path_count.to_u64,
              sizeof(Pointer(ObjectSharedPhysicalPath)).to_u64))
            chunk.path_count.times do |path_index|
              path = chunk.path_at(path_index)
              streams = path.streams
              bytes = checked_add(bytes, instance_sizeof(ObjectSharedPhysicalPath).to_u64)
              bytes = checked_add(bytes, string_owner_bytes(path.name_byte_size))
              bytes = checked_add(bytes, instance_sizeof(ObjectSharedPathStreams).to_u64)
              bytes = checked_add(bytes, checked_add(sizeof(Bytes).to_u64, streams.data_size.to_u64))
              bytes = checked_add(bytes, instance_sizeof(Array(ObjectSharedPathSubstreamEvent)).to_u64)
              bytes = checked_add(bytes, checked_multiply(streams.event_count.to_u64,
                sizeof(Pointer(ObjectSharedPathSubstreamEvent)).to_u64))
              streams.event_count.times do |event_index|
                event = streams.event_at(event_index)
                bytes = checked_add(bytes, instance_sizeof(ObjectSharedPathSubstreamEvent).to_u64)
                bytes = checked_add(bytes, string_owner_bytes(event.name_byte_size))
              end
              bytes = checked_add(bytes, instance_sizeof(Array(ObjectSharedInlineCallbackRelocation)).to_u64)
              bytes = checked_add(bytes, checked_multiply(streams.callback_relocation_count.to_u64,
                sizeof(Pointer(ObjectSharedInlineCallbackRelocation)).to_u64))
              streams.callback_relocation_count.times do |relocation_index|
                relocation = streams.callback_relocation_at(relocation_index)
                bytes = checked_add(bytes, instance_sizeof(ObjectSharedInlineCallbackRelocation).to_u64)
                bytes = checked_add(bytes, string_owner_bytes(relocation.source_callback_byte_size))
                bytes = checked_add(bytes, string_owner_bytes(relocation.target_callback_byte_size))
              end
            end
          end
        end
      end

      bytes = checked_add(bytes, instance_sizeof(Array(Array(ObjectSharedChunkStructureReadSpan))).to_u64)
      bytes = checked_add(bytes, checked_multiply(@structure_spans.size.to_u64,
        sizeof(Pointer(Array(ObjectSharedChunkStructureReadSpan))).to_u64))
      @structure_spans.each do |spans|
        bytes = checked_add(bytes, instance_sizeof(Array(ObjectSharedChunkStructureReadSpan)).to_u64)
        bytes = checked_add(bytes, checked_multiply(spans.size.to_u64,
          sizeof(ObjectSharedChunkStructureReadSpan).to_u64))
        spans.each do |span|
          structure = span.record
          bytes = checked_add(bytes, instance_sizeof(ObjectSharedChunkStructure).to_u64)
          bytes = checked_add(bytes, instance_sizeof(Array(String)).to_u64)
          bytes = checked_add(bytes, checked_multiply(structure.path_count.to_u64,
            sizeof(Pointer(String)).to_u64))
          structure.path_count.times do |path_index|
            bytes = checked_add(bytes, string_owner_bytes(structure.path_byte_size(path_index)))
          end
        end
      end

      bytes = checked_add(bytes, instance_sizeof(Array(ObjectSharedCopyStreams)).to_u64)
      bytes = checked_add(bytes, checked_multiply(@copies.size.to_u64,
        sizeof(Pointer(ObjectSharedCopyStreams)).to_u64))
      @copies.each do |copy|
        bytes = checked_add(bytes, instance_sizeof(ObjectSharedCopyStreams).to_u64)
        bytes = checked_add(bytes, checked_add(sizeof(Bytes).to_u64, copy.sizes_size.to_u64))
        bytes = checked_add(bytes, checked_add(sizeof(Bytes).to_u64, copy.indexes_size.to_u64))
        bytes = checked_add(bytes, checked_add(sizeof(Bytes).to_u64, copy.values_size.to_u64))
      end
      checked_add(bytes, compact_callback_capture_workspace_bytes)
    end

    # Decoder-only accessors return immutable raw owners. Their public byte
    # getters remain defensive snapshots, and no ObjectDocument/BinaryValue
    # is materialized during preparation.
    def parent_for_decode(bucket_index : Int) : ObjectSharedPhysicalParentMark
      @bucket_parents[bucket_index][0]
    end

    def copy_for_decode(chunk_index : Int) : ObjectSharedCopyStreams
      @copies[chunk_index]
    end

    def nested_context_for_decode : ObjectSharedNestedSerializationContext
      @nested_context
    end

    def validate_decode_operation!(budget : BinaryCodecBudget) : Nil
      if budget.writing?
        raise ArgumentError.new("prepared inline Object decode requires a read-direction budget")
      end
      unless @budget.same?(budget)
        raise ArgumentError.new("prepared inline Object decode requires the same budget operation")
      end
      @prefix.validate_physical_owner!(@physical_plan)
      unless @prefix.nested_context.same?(@nested_context) &&
             @physical_plan.shared_bucket_count == @bucket_parents.size &&
             @nested_context.shared_data_version == @prefix.plan.structures.object.shared_data_version
        raise CorruptPartError.new("prepared inline Object owner or context changed after preparation")
      end
      nil
    end

    private def string_owner_bytes(byte_size : Int32) : UInt64
      checked_add(instance_sizeof(String).to_u64, byte_size.to_u64 + 1_u64)
    end

    private def compact_callback_capture_workspace_bytes : UInt64
      slice_count = @prefix.body_callback_slice_count
      return 0_u64 if slice_count == 0

      bytes = 0_u64
      compact_slice_retained = false
      seen_contexts = Hash(UInt64, Bool).new
      slice_count.times do |index|
        slice = @prefix.body_callback_slice_at(index)
        next unless slice.authenticated_context?

        context = slice.context
        compact_bytes = if context.is_a?(CompactObjectSharedInlineCoordinateContext)
                          context.as(CompactObjectSharedInlineCoordinateContext).retained_workspace_bytes
                        elsif context.is_a?(CompactRecursiveObjectSharedInlineCoordinateContext)
                          context.as(CompactRecursiveObjectSharedInlineCoordinateContext).retained_workspace_bytes
                        else
                          next
                        end
        compact_slice_retained = true
        bytes = checked_add(bytes, instance_sizeof(ObjectSharedInlineCallbackReadSlice).to_u64)
        bytes = checked_add(bytes, string_owner_bytes(slice.canonical_name.bytesize))
        bytes = checked_add(bytes, string_owner_bytes(slice.callback_name.bytesize))
        # Count each borrowed callback extent as a logical retained view. The
        # backing shard bytes are also included by the coordinate-context
        # census; that overlap is conservative and does not imply a copy.
        bytes = checked_add(bytes, slice.byte_size.to_u64)

        identity = context.object_id
        unless seen_contexts.has_key?(identity)
          seen_contexts[identity] = true
          bytes = checked_add(bytes, compact_bytes)
        end
      end

      if compact_slice_retained
        bytes = checked_add(bytes, instance_sizeof(Array(ObjectSharedInlineCallbackReadSlice)).to_u64)
        bytes = checked_add(bytes,
          checked_multiply(slice_count.to_u64, sizeof(Pointer(ObjectSharedInlineCallbackReadSlice)).to_u64))
      end
      bytes
    end

    private def checked_add(left : UInt64, right : UInt64) : UInt64
      if right > UInt64::MAX - left
        raise CorruptPartError.new("prepared inline Object workspace estimate overflows")
      end
      left + right
    end

    private def checked_multiply(left : UInt64, right : UInt64) : UInt64
      if left > 0_u64 && right > UInt64::MAX // left
        raise CorruptPartError.new("prepared inline Object workspace estimate overflows")
      end
      left * right
    end
  end
end

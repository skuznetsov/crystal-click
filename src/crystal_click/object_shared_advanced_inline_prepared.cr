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
  end
end

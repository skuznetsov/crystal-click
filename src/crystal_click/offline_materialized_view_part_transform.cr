module CrystalClick
  # Runs one caller callback over one complete typed source scan, then
  # invalidates the escaped handle and revalidates catalog identity before the
  # caller's selected part writer prepares its detached output.
  class OfflineMaterializedViewPartTransform
    @input : OfflinePartTransformInput
    @revalidate : Proc(Nil)

    def initialize(@input : OfflinePartTransformInput, @revalidate : Proc(Nil))
    end

    def execute(&callback : OfflinePartTransformInput -> T) : T forall T
      begin
        output = yield @input
        unless @input.complete_for_output?
          raise UnsupportedFormatError.new("materialized-view transform did not complete one full source scan")
        end

        # The handle belongs to the outer callback only. Invalidate it before
        # metadata refresh or writer owner preparation begins; ensure below
        # covers callback exceptions and nonlocal exits as well.
        @input.invalidate!

        raise InvalidPartError.new("materialized-view transform output must not be empty") if output.empty?

        @revalidate.call
        output
      ensure
        @input.invalidate!
      end
    end
  end
end

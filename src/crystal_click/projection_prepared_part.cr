module CrystalClick
  # :nodoc:
  # Parent publishers share this contract while each child keeps its ordinary
  # layout-specific staged writer and readback validation.
  abstract class ProjectionPreparedPart
    abstract def entry_name : String
    abstract def checksum_entry_count : Int32
    abstract def file_count : Int32
    abstract def summary_sidecars : Array(String)
    abstract def encode! : Nil
    abstract def publish(parent_stage : String) : PartWriterInfrastructure::ChecksumRecord
  end
end

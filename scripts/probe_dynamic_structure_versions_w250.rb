#!/usr/bin/env ruby
# Thin V1/V2 reciprocal extension of the W249 Nested-Dynamic native proof.
# It keeps W249's stock SQL oracle and consumer helper, and adds an independent
# bounded audit of actual decompressed Dynamic structure streams.

require 'digest'
require 'json'
require 'optparse'
require_relative 'probe_dynamic_recursive_handoff_w249'

module ProbeDynamicStructureVersionsW250
  W249 = ProbeDynamicRecursiveHandoffW249
  FORMAT = 'dynamic_structure_versions_w250_native_capture_v1'.freeze
  PROBE_SOURCE = File.expand_path(__FILE__).freeze
  HELPER_SOURCE = File.expand_path('check_dynamic_structure_versions_w250.cr', __dir__).freeze

  class Probe < W249::Probe
    def initialize(binary:, helper:, structure_helper:, evidence_root:, string_profile:, helper_mode:, dynamic_version:)
      super(binary: binary, helper: helper, evidence_root: evidence_root,
            string_profile: string_profile, helper_mode: helper_mode)
      @structure_helper = File.expand_path(structure_helper)
      @dynamic_version = dynamic_version
      require_w250!(%w[v1 v2].include?(@dynamic_version), 'dynamic version must be v1 or v2')
      require_w250!(File.file?(@structure_helper) && File.executable?(@structure_helper) &&
                    !File.symlink?(@structure_helper), 'structure auditor executable is invalid')

      @input_table = "w250_#{@token}_#{@profile}_input"
      @write_table = "w250_#{@token}_#{@profile}_#{@dynamic_version}_stockwrite"
      @ruby_sources = W249::W248.ruby_closure(PROBE_SOURCE)
      @crystal_sources = W249::W248.crystal_closure(
        [W249::HELPER_SOURCE, W249::FIXTURE_SOURCE, HELPER_SOURCE], @repo
      )
    end

    def run
      prepare!
      make_library_part!
      create_input_table!
      attach_check_and_read!
      create_stock_write_table!
      stock_write_check_and_read!
      inspect_stock_part!
      stable!
      write_new(File.join(@root, 'summary.json'), JSON.pretty_generate(build_summary) + "\n")
      puts "W250 status=stock_dynamic_structure_#{@dynamic_version}_observed profile=#{@profile} helper_mode=#{@helper_mode} evidence=#{@root}"
      true
    rescue StandardError => error
      warn "W250 inconclusive: #{error.class}: #{error.message}"
      false
    end

    private

    def require_w250!(condition, message)
      raise W249::Failure, "W250: #{message}" unless condition
    end

    def prepare!
      super
      @structure_helper_sha = sha(@structure_helper)
    end

    def stable!
      super
      require_w250!(sha(@structure_helper) == @structure_helper_sha,
                    'structure auditor executable changed during capture')
      require_w250!(part_snapshot(@library_part) == @generated_inventory,
                    'library-generated PART changed after its pre-attach snapshot')
      require_w250!(part_snapshot(@stock_part_path) == @stock_inventory,
                    'stock-written PART changed after its native CHECK snapshot')
    end

    def create_table_sql(table)
      sql = super
      return sql unless table == @write_table

      string_profile = @profile == 'single' ? 'single_stream' : 'with_size_stream'
      needle = "string_serialization_version='#{string_profile}'"
      require_w250!(sql.scan(needle).size == 1, 'W249 CREATE TABLE template lost its exact String version setting')
      sql.sub(needle, "#{needle}, dynamic_serialization_version='#{@dynamic_version}'")
    end

    def make_library_part!
      @library_part = File.join(@root, 'generated', W249::PART_NAME)
      result, @write_report = invoke_w250_helper(
        'helper_write_versioned_library_part', 'write', @library_part, @profile, @dynamic_version
      )
      @generated_inventory = part_snapshot(@library_part)
      validate_helper_report!(@write_report, 'write')
      @helper_write_invocation = result.fetch(:record)

      audit_result, @library_structure_audit = invoke_w250_helper(
        'helper_audit_versioned_library_structures', 'audit', @library_part
      )
      validate_structure_audit!(@library_structure_audit, @library_part, 'library_generated')
      @library_structure_audit_invocation = audit_result.fetch(:record)
    end

    def invoke_w250_helper(label, *arguments)
      result = @runner.send(
        :run_process,
        label,
        [@structure_helper, *arguments],
        ''.b,
        'crystal-helper',
        expected_sha: @structure_helper_sha,
        binary_path: @structure_helper,
      )
      assert_process_success!(result, label, @structure_helper_sha)
      lines = result.fetch(:stdout).dup.force_encoding(Encoding::UTF_8).lines.map(&:chomp).reject(&:empty?)
      require_w250!(lines.size == 1, "#{label} helper must emit exactly one JSON report")
      [result, JSON.parse(lines.first)]
    end

    def inspect_stock_part!
      super
      result, @stock_structure_audit = invoke_w250_helper(
        'helper_audit_stock_dynamic_structures', 'audit', @stock_part_path
      )
      validate_structure_audit!(@stock_structure_audit, @stock_part_path, 'stock_written')
      @stock_structure_audit_invocation = result.fetch(:record)
    end

    def expected_actual_type_counts(column_name, site_index)
      all = W249.expected_type_rows.flat_map do |row|
        case column_name
        when 'root_nested' then row.fetch('root_nested')
        when 'array_nested' then row.fetch('array_nested').flatten
        when 'tuple_parent' then row.fetch('tuple_parent').flatten
        when 'recursive_nested'
          site_index.zero? ? row.fetch('recursive_nested') : row.fetch('recursive_child').flatten
        when 'map_parent' then row.fetch('map_parent').flatten
        else raise W249::Failure, "W250: unrostered Dynamic column #{column_name.inspect}"
        end
      end
      all.each_with_object(Hash.new(0)) do |type, counts|
        counts[type] += 1 unless type == 'NULL'
      end.sort.to_h
    end

    def validate_structure_audit!(report, part, origin)
      require_w250!(%w[library_generated stock_written].include?(origin),
                    "unknown Dynamic structure audit origin #{origin.inspect}")
      require_w250!(report.fetch('format') == 'dynamic_structure_versions_w250_audit_v1' &&
                    report.fetch('part_path') == File.expand_path(part),
                    'auditor report format or PART binding differs')
      columns = report.fetch('columns')
      require_w250!(columns.size == W249::COLUMNS.size, 'auditor Dynamic column roster differs')
      expected_version = @dynamic_version == 'v1' ? 1 : 2

      columns.each_with_index do |column, column_index|
        name = W249::COLUMNS[column_index]
        require_w250!(column.fetch('name') == name &&
                      column.fetch('nominal_type') == W249::COLUMN_TYPES.fetch(name),
                      "auditor nominal schema/order differs at #{column_index}")
        expected_sites = W249::DYNAMIC_SITE_PATHS.fetch(name)
        sites = column.fetch('sites')
        require_w250!(sites.map { |site| site.fetch('path') } == expected_sites,
                      "auditor site paths/order differ for #{name}")

        sites.each_with_index do |site, site_index|
          require_w250!(site.fetch('version') == expected_version,
                        "#{name} #{site.fetch('path')} has the wrong Dynamic wire version")
          decoded_types = site.fetch('types')
          observed_counts = expected_actual_type_counts(name, site_index)
          if origin == 'library_generated'
            require_w250!(decoded_types == ['Int64'],
                          "#{name} #{site.fetch('path')} library ordinary roster differs from the fixture registration")
          else
            require_w250!(decoded_types.is_a?(Array) && decoded_types.size == 1 &&
                          %w[Int64 String].include?(decoded_types.first) &&
                          observed_counts.key?(decoded_types.first),
                          "#{name} #{site.fetch('path')} stock ordinary roster is not one literal type within max_types=1")
          end
          raw = site.fetch('raw_header')
          require_w250!(raw.fetch('version') == expected_version && raw.fetch('types') == decoded_types,
                        "#{name} #{site.fetch('path')} raw header differs from decoded structure")
          expected_legacy = @dynamic_version == 'v1' ? decoded_types.size : nil
          require_w250!(site.fetch('legacy_max_dynamic_types') == expected_legacy &&
                        raw.fetch('legacy_max_dynamic_types') == expected_legacy,
                        "#{name} #{site.fetch('path')} legacy maximum differs")
          require_w250!(site.fetch('mandatory_statistics') == true,
                        "#{name} #{site.fetch('path')} lacks mandatory old-version statistics")
          require_w250!(site.fetch('canonical_variant_names') == (decoded_types + ['SharedVariant']).sort,
                        "#{name} #{site.fetch('path')} canonical statistics order differs")

          ordinary_names = decoded_types
          require_w250!((ordinary_names + site.fetch('statistics').fetch('shared').map { |entry| entry.fetch('name') }).sort == observed_counts.keys,
                        "#{name} #{site.fetch('path')} ordinary/shared roster differs from literal values")
          require_w250!(site.fetch('literal_actual_type_counts') == observed_counts,
                        "#{name} #{site.fetch('path')} literal type counts differ")

          expected_shared = observed_counts.reject { |type, _count| ordinary_names.include?(type) }
          expected_variant_counts = site.fetch('canonical_variant_names').map do |variant|
            variant == 'SharedVariant' ? expected_shared.values.sum : observed_counts.fetch(variant, 0)
          end
          statistics = site.fetch('statistics')
          require_w250!(statistics.fetch('variant_counts') == expected_variant_counts &&
                        statistics.fetch('shared').map { |entry| [entry.fetch('name'), entry.fetch('count')] }.sort == expected_shared.to_a.sort,
                        "#{name} #{site.fetch('path')} statistics differ from the independent literal census")

          offset = site.fetch('statistics_prefix_offset')
          grid = site.fetch('physical_grid')
          require_w250!(raw.fetch('statistics_prefix_offset') == offset &&
                        grid.fetch('prefix_size') == offset &&
                        grid.fetch('mark_row_counts') == W249::MARK_ROWS &&
                        grid.fetch('mark_positions') == [offset, offset, offset, grid.fetch('logical_size')] &&
                        grid.fetch('terminal_position') == grid.fetch('logical_size'),
                        "#{name} #{site.fetch('path')} physical marks do not certify the statistics suffix")
        end
      end
    end

    def build_summary
      summary = super
      summary['format'] = FORMAT
      summary['status'] = "stock_dynamic_structure_#{@dynamic_version}_observed"
      summary['dynamic_structure_version'] = @dynamic_version
      summary['dynamic_structure_audit'] = {
        'library_generated' => @library_structure_audit,
        'stock_written' => @stock_structure_audit,
      }
      summary['dynamic_structure_ordinary_type_rosters'] = {
        'library_generated' => ordinary_type_rosters(@library_structure_audit),
        'stock_written' => ordinary_type_rosters(@stock_structure_audit),
      }
      summary['helper']['structure_auditor'] = {
        'path' => @structure_helper, 'sha256' => @structure_helper_sha,
      }
      summary['helper']['versioned_writer'] = {
        'path' => @structure_helper, 'sha256' => @structure_helper_sha,
        'invocation' => @helper_write_invocation,
      }
      summary['helper_reports']['structure_audit_library'] = @library_structure_audit
      summary['helper_reports']['structure_audit_stock'] = @stock_structure_audit
      summary['native']['stock_dynamic_serialization_version'] = @dynamic_version
      summary['interpretation']['dynamic_structure_versions'] =
        "Both the library-generated and stock-written PARTs use Dynamic serialization #{@dynamic_version}; the library side passes explicitly versioned DynamicStructure values through WidePartColumn.dynamic_bulk, and each actual decompressed .structure stream is independently parsed and compared with its bounded decoder, mandatory positional/shared statistics, fixture value census, and mark suffix offset."
      summary['interpretation']['textual_descriptor_boundary'] =
        'The library-generated ordinary Dynamic roster is pinned to Int64. The stock-written per-site roster is reported separately and is limited to one type present in the independent W249 fixture census (Int64 or String, max_types=1); the fixture also exercises String spill. Recursive textual alternatives are separately covered by literal W250 codec fixtures, and this capture does not claim arbitrary Dynamic type closure.'
      summary['interpretation']['structure_auditor_identity'] =
        'The structure auditor executable SHA is observed and checked stable during capture; executable-to-source build provenance is supplied by the outer guarded build, not certified by this capture itself.'
      summary
    end

    def ordinary_type_rosters(report)
      report.fetch('columns').each_with_object({}) do |column, columns|
        columns[column.fetch('name')] = column.fetch('sites').each_with_object({}) do |site, sites|
          sites[site.fetch('path')] = site.fetch('types')
        end
      end
    end
  end

  def self.parse_options
    options = {}
    parser = OptionParser.new do |opts|
      opts.banner = 'Usage: probe_dynamic_structure_versions_w250.rb --binary PATH --helper W249_HELPER --structure-helper W250_HELPER --evidence-root DIR --string-profile single|sized --helper-mode debug|release --dynamic-version v1|v2'
      opts.on('--binary PATH') { |value| options[:binary] = value }
      opts.on('--helper PATH') { |value| options[:helper] = value }
      opts.on('--structure-helper PATH') { |value| options[:structure_helper] = value }
      opts.on('--evidence-root DIR') { |value| options[:evidence_root] = value }
      opts.on('--string-profile NAME') { |value| options[:string_profile] = value }
      opts.on('--helper-mode MODE') { |value| options[:helper_mode] = value }
      opts.on('--dynamic-version NAME') { |value| options[:dynamic_version] = value }
    end
    parser.parse!
    required = %i[binary helper structure_helper evidence_root string_profile helper_mode dynamic_version]
    raise OptionParser::MissingArgument, required.find { |key| !options[key] }.to_s unless required.all? { |key| options[key] }
    options
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    options = ProbeDynamicStructureVersionsW250.parse_options
    success = ProbeDynamicStructureVersionsW250::Probe.new(**options).run
    exit(success ? 0 : 1)
  rescue StandardError => error
    warn "W250 inconclusive: #{error.class}: #{error.message}"
    exit 1
  end
end

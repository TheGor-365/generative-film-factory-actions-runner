# frozen_string_literal: true

require "digest"
require "json"

module FactoryMvp
  module Runner
    module WaveDNoMediaGate
      module V01
        class Rejection < StandardError
          attr_reader :code

          def initialize(code, message = code.to_s)
            @code = code.to_s.freeze
            super(message)
          end
        end

        module Support
          module_function

          def reject!(code, message = code.to_s)
            raise Rejection.new(code, message)
          end

          def exact?(left, right)
            return false unless left.class == right.class

            case right
            when Hash
              left.keys.sort == right.keys.sort && right.all? { |key, value| exact?(left.fetch(key), value) }
            when Array
              left.length == right.length && left.each_index.all? { |index| exact?(left[index], right[index]) }
            else
              left.eql?(right)
            end
          end

          def require_exact!(actual, expected, code)
            reject!(code) unless exact?(actual, expected)
            true
          end

          def require_keys!(value, keys, code)
            reject!(code) unless value.class == Hash
            require_exact!(value.keys.sort, keys.sort, code)
          end

          def deep_freeze(value)
            case value
            when Hash
              value.each { |key, child| deep_freeze(key); deep_freeze(child) }
            when Array
              value.each { |child| deep_freeze(child) }
            end
            value.freeze
          end

          def canonical(value)
            case value
            when Hash
              value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
            when Array
              value.map { |item| canonical(item) }
            else
              value
            end
          end

          def canonical_sha256(value)
            Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
          end

          def git_blob_sha(bytes)
            Digest::SHA1.hexdigest("blob #{bytes.bytesize}\0#{bytes}")
          end
        end

        module StrictJson
          class DuplicateKeyDetector
            ARRAY_OPEN = "[".ord
            ARRAY_CLOSE = "]".ord
            OBJECT_OPEN = "{".ord
            OBJECT_CLOSE = "}".ord
            QUOTE = '"'.ord
            ESCAPE = "\\\\".ord
            COLON = ":".ord
            COMMA = ",".ord
            SLASH = "/".ord
            STAR = "*".ord
            WHITESPACE = [" ".ord, "\t".ord, "\n".ord, "\r".ord].freeze

            def initialize(text)
              @text = text
              @index = 0
            end

            def reject_duplicates!
              skip_insignificant
              scan_value
              skip_insignificant
              raise JSON::ParserError, "strict JSON scanner did not consume the document" unless current_byte.nil?

              true
            end

            private

            def scan_value
              skip_insignificant
              case current_byte
              when OBJECT_OPEN then scan_object
              when ARRAY_OPEN then scan_array
              when QUOTE then scan_string
              else scan_scalar
              end
            end

            def scan_object
              consume(OBJECT_OPEN)
              keys = {}
              skip_insignificant

              until current_byte == OBJECT_CLOSE
                key = scan_string(decode: true)
                Support.reject!("duplicate_json_key") if keys.key?(key)
                keys[key] = true

                skip_insignificant
                consume(COLON)
                scan_value
                skip_insignificant
                break if current_byte == OBJECT_CLOSE

                consume(COMMA)
                skip_insignificant
              end

              consume(OBJECT_CLOSE)
            end

            def scan_array
              consume(ARRAY_OPEN)
              skip_insignificant

              until current_byte == ARRAY_CLOSE
                scan_value
                skip_insignificant
                break if current_byte == ARRAY_CLOSE

                consume(COMMA)
                skip_insignificant
              end

              consume(ARRAY_CLOSE)
            end

            def scan_string(decode: false)
              start = @index
              consume(QUOTE)

              loop do
                case current_byte
                when QUOTE
                  @index += 1
                  break
                when ESCAPE
                  @index += 2
                else
                  @index += 1
                end
              end

              return unless decode

              JSON.parse(@text.byteslice(start, @index - start), create_additions: false)
            end

            def scan_scalar
              @index += 1 until scalar_delimiter?(current_byte)
            end

            def scalar_delimiter?(byte)
              byte.nil? || byte == COMMA || byte == ARRAY_CLOSE || byte == OBJECT_CLOSE || WHITESPACE.include?(byte) || comment_start?
            end

            def skip_insignificant
              loop do
                @index += 1 while WHITESPACE.include?(current_byte)

                if current_byte == SLASH && next_byte == SLASH
                  @index += 2
                  @index += 1 until current_byte.nil? || current_byte == "\n".ord || current_byte == "\r".ord
                elsif current_byte == SLASH && next_byte == STAR
                  @index += 2
                  @index += 1 until current_byte == STAR && next_byte == SLASH
                  @index += 2
                else
                  break
                end
              end
            end

            def comment_start?
              current_byte == SLASH && (next_byte == SLASH || next_byte == STAR)
            end

            def consume(expected)
              raise JSON::ParserError, "strict JSON scanner lost token alignment" unless current_byte == expected

              @index += 1
            end

            def current_byte
              @text.getbyte(@index)
            end

            def next_byte
              @text.getbyte(@index + 1)
            end
          end

          module_function

          def parse(text)
            parsed = JSON.parse(text, create_additions: false, allow_duplicate_key: true)
            DuplicateKeyDetector.new(detector_text(text)).reject_duplicates!
            parsed
          rescue JSON::ParserError
            Support.reject!("json_parse")
          end

          def detector_text(text)
            return text if text.encoding == Encoding::UTF_8

            if text.encoding == Encoding::ASCII_8BIT
              text.dup.force_encoding(Encoding::UTF_8)
            else
              text.encode(Encoding::UTF_8)
            end
          end

          private_constant :DuplicateKeyDetector
        end

        module ClosedSchema
          ALLOWED = %w[$schema title type additionalProperties required properties const enum minimum maximum minLength maxLength pattern minItems maxItems uniqueItems items].freeze
          TYPES = %w[object array string integer number boolean null].freeze
          module_function

          def verify_definition!(schema)
            walk_definition!(schema)
            true
          end

          def walk_definition!(node)
            Support.reject!("schema_definition") unless node.class == Hash
            Support.reject!("schema_unsupported_keyword") unless (node.keys - ALLOWED).empty?

            if node.key?("type")
              Support.reject!("schema_definition") unless node["type"].class == String && TYPES.include?(node["type"])
            end

            if node["type"] == "object"
              Support.reject!("schema_not_closed") unless node["additionalProperties"].equal?(false)
              properties = node.fetch("properties", {})
              required = node.fetch("required", [])
              Support.reject!("schema_definition") unless properties.class == Hash
              Support.reject!("schema_definition") unless required.class == Array && required.all? { |key| key.class == String } && required.uniq.length == required.length
              Support.reject!("schema_definition") unless (required - properties.keys).empty?
            end

            node.fetch("properties", {}).each_value { |child| walk_definition!(child) } if node.key?("properties")
            walk_definition!(node["items"]) if node.key?("items")
          end

          def validate!(value, schema)
            validate_type!(value, schema["type"]) if schema.key?("type")
            Support.require_exact!(value, schema["const"], "schema_const") if schema.key?("const")
            if schema.key?("enum")
              Support.reject!("schema_enum") unless schema["enum"].any? { |candidate| Support.exact?(value, candidate) }
            end

            if value.class == String
              Support.reject!("schema_min_length") if schema.key?("minLength") && value.length < schema["minLength"]
              Support.reject!("schema_max_length") if schema.key?("maxLength") && value.length > schema["maxLength"]
              Support.reject!("schema_pattern") if schema.key?("pattern") && !Regexp.new(schema["pattern"]).match?(value)
            end

            if value.class == Integer || value.class == Float
              Support.reject!("schema_minimum") if schema.key?("minimum") && value < schema["minimum"]
              Support.reject!("schema_maximum") if schema.key?("maximum") && value > schema["maximum"]
            end

            if value.class == Array
              Support.reject!("schema_min_items") if schema.key?("minItems") && value.length < schema["minItems"]
              Support.reject!("schema_max_items") if schema.key?("maxItems") && value.length > schema["maxItems"]
              if schema["uniqueItems"].equal?(true)
                duplicate = value.each_index.any? { |i| ((i + 1)...value.length).any? { |j| Support.exact?(value[i], value[j]) } }
                Support.reject!("schema_unique_items") if duplicate
              end
              value.each { |item| validate!(item, schema["items"]) } if schema.key?("items")
            end

            if value.class == Hash
              properties = schema.fetch("properties", {})
              schema.fetch("required", []).each { |key| Support.reject!("schema_required") unless value.key?(key) }
              Support.reject!("schema_additional_property") if schema["additionalProperties"].equal?(false) && !(value.keys - properties.keys).empty?
              properties.each { |key, child| validate!(value[key], child) if value.key?(key) }
            end
            true
          end

          def validate_type!(value, type)
            valid = case type
                    when "object" then value.class == Hash
                    when "array" then value.class == Array
                    when "string" then value.class == String
                    when "integer" then value.class == Integer
                    when "number" then value.class == Integer || value.class == Float
                    when "boolean" then value.class == TrueClass || value.class == FalseClass
                    when "null" then value.nil?
                    else false
                    end
            Support.reject!("schema_type") unless valid
          end
        end

        class Engine
          MANIFEST_KEYS = %w[$schema manifest_id schema_version control_repository control_main_sha frozen_private_source_sha content_hash_semantics authoritative_merge_set members closed_membership reverse_authority execution_authority].freeze
          MEMBER_KEYS = %w[lane_id contract_id schema_version repository merge_sha path git_blob_sha artifact_class required_for_gate content_sha256].freeze
          FIXTURE_KEYS = %w[$schema bundle_id schema_version classification records contains_private_material contains_media_bytes contains_provider_responses contains_secrets].freeze
          RECORD_KEYS = %w[fixture_id story_placeholder q0_placeholder structural_metadata zero_media expected_validation_outcome].freeze
          Q0_KEYS = %w[kind media_present production_media].freeze
          STRUCT_KEYS = %w[profile_id sequence_count scene_count shot_count generation_segment_count frame_rate raster].freeze
          ZERO_KEYS = %w[media_asset_count media_bytes_present external_asset_locators].freeze
          RECEIPT_KEYS = %w[$schema receipt_id schema_version validated_control_main_sha validated_public_runner_main_sha private_gate_manifest_sha256 fixture_bundle_sha256 checks negative_mutations workflow_dispatched public_runner_writes provider_calls paid_provider_calls media_execution private_media_in_git no_fake_green].freeze
          HANDOFF_KEYS = %w[$schema handoff_id schema_version private_gate_manifest_sha256 fixture_bundle_sha256 validation_receipt_sha256 public_runner_main_sha frozen_private_source_sha allowed_public_paths expected_public_validator expected_validation_semantics planning_only workflow_dispatch_authority media_execution_authority paid_execution_authority private_repository_write_authority reverse_authority sanitized_metadata_only].freeze
          CATALOG_KEYS = %w[catalog_id schema_version order_semantics mutations].freeze
          CATALOG_ROW_KEYS = %w[mutation_id expected error_code].freeze

          BAD_KEY = /(?:prompt|provider_response|raw_response|secret|token|api_key|password|private_story|real_story|asset_locator|data_url|base64|binary_media)/i
          SECRET_VALUE = /(?:\bsk-[A-Za-z0-9_-]{16,}|\bgh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16})/
          DATA_URL = /data:[^,]+;base64,/i
          MEDIA64 = /(?:iVBORw0KGgo|\/9j\/|R0lGOD|UklGR)/
          PRIVATE_PATH = %r{(?:\A/|\A[A-Za-z]:\\|/(?:home|Users|private|secrets?)/)}i

          def initialize(authority, root, expected)
            @authority = authority
            @root = root
            @expected = expected
          end

          def validate_files!
            actual_paths = Dir.glob("**/*", base: @root).select { |rel| File.file?(File.join(@root, rel)) }.sort
            Support.require_exact!(actual_paths, @authority.fetch("files").keys.sort, "package_member_set")

            bytes = {}
            actual_paths.each do |relative|
              content = File.binread(File.join(@root, relative))
              binding = @authority.fetch("files").fetch(relative)
              Support.require_exact!(Digest::SHA256.hexdigest(content), binding.fetch("sha256"), "package_sha256")
              Support.require_exact!(Support.git_blob_sha(content), binding.fetch("blob"), "package_blob_digest")
              bytes[relative] = content
            end

            docs, schemas = decode(bytes)
            validate_documents!(docs, schemas, bytes)
          end

          def decode(bytes)
            docs = {
              "manifest" => StrictJson.parse(bytes.fetch("wave2_private_gate_manifest_v01.json")),
              "fixture" => StrictJson.parse(bytes.fetch("sanitized_fixture_bundle_v01.json")),
              "receipt" => StrictJson.parse(bytes.fetch("wave2_private_validation_receipt_v01.json")),
              "handoff" => StrictJson.parse(bytes.fetch("public_runner_handoff_manifest_v01.json")),
              "catalog" => StrictJson.parse(bytes.fetch("mutation_catalog_v01.json"))
            }
            schemas = {
              "manifest" => StrictJson.parse(bytes.fetch("schemas/wave2_private_gate_manifest_v01.schema.json")),
              "fixture" => StrictJson.parse(bytes.fetch("schemas/sanitized_fixture_bundle_v01.schema.json")),
              "receipt" => StrictJson.parse(bytes.fetch("schemas/wave2_private_validation_receipt_v01.schema.json")),
              "handoff" => StrictJson.parse(bytes.fetch("schemas/public_runner_handoff_manifest_v01.schema.json"))
            }
            [docs, schemas]
          end

          def validate_documents!(docs, schemas, bytes = nil)
            schemas.each_value { |schema| ClosedSchema.verify_definition!(schema) }
            validate_catalog!(docs.fetch("catalog"))
            validate_manifest!(docs.fetch("manifest"))
            validate_fixture!(docs.fetch("fixture"))
            validate_receipt!(docs.fetch("receipt"), docs, bytes)
            validate_handoff!(docs.fetch("handoff"), docs, bytes)
            %w[manifest fixture receipt handoff].each { |name| ClosedSchema.validate!(docs.fetch(name), schemas.fetch(name)) }
            true
          end

          def validate_catalog!(catalog)
            Support.require_keys!(catalog, CATALOG_KEYS, "mutation_catalog_not_closed")
            Support.require_exact!(catalog["catalog_id"], "WAVE2_PRIVATE_GATE_MUTATIONS_V01", "mutation_catalog_id")
            Support.require_exact!(catalog["schema_version"], "1.0.0", "mutation_catalog_schema_version")
            Support.require_exact!(catalog["order_semantics"], "EXACT_ORDERED_MUTATION_ID_ERROR_CODE_V01", "mutation_matrix")
            catalog.fetch("mutations").each { |row| Support.require_keys!(row, CATALOG_ROW_KEYS, "mutation_matrix") }
            Support.require_exact!(catalog["mutations"], @expected.dig("docs", "catalog", "mutations"), "mutation_matrix")
          end

          def validate_manifest!(manifest)
            reference = @expected.dig("docs", "manifest")
            Support.require_keys!(manifest, MANIFEST_KEYS, "manifest_not_closed")
            %w[manifest_id schema_version control_repository control_main_sha frozen_private_source_sha content_hash_semantics authoritative_merge_set closed_membership reverse_authority execution_authority].each do |key|
              code = case key
                     when "control_main_sha" then "control_main_sha_drift"
                     when "frozen_private_source_sha" then "frozen_private_sha_drift"
                     when "reverse_authority" then "reverse_authority"
                     when "execution_authority" then "execution_authority"
                     else key
                     end
              Support.require_exact!(manifest[key], reference[key], code)
            end

            members = manifest["members"]
            Support.reject!("unexpected_member") unless members.class == Array
            lanes = members.select { |member| member.class == Hash }.map { |member| member["lane_id"] }
            required_lanes = reference["authoritative_merge_set"].keys
            Support.reject!("missing_lane") unless (required_lanes - lanes).empty?
            Support.reject!("unexpected_member") unless members.length == reference["members"].length

            members.each_with_index do |member, index|
              expected_member = reference["members"].fetch(index)
              Support.require_keys!(member, MEMBER_KEYS, "member_not_closed")
              body = member.reject { |key, _| key == "content_sha256" }
              Support.require_exact!(member["content_sha256"], Support.canonical_sha256(body), "member_content_sha256")
              Support.require_exact!(member.values_at("lane_id", "contract_id"), expected_member.values_at("lane_id", "contract_id"), "unexpected_member")
              foreign_paths = reference["members"].reject { |row| row["lane_id"] == expected_member["lane_id"] }.map { |row| row["path"] }
              Support.reject!("cross_lane_artifact_substitution") if foreign_paths.include?(member["path"])
              Support.require_exact!(member["merge_sha"], expected_member["merge_sha"], "wrong_merge_sha")
              Support.require_exact!(member["git_blob_sha"], expected_member["git_blob_sha"], "wrong_blob_sha")
              %w[repository path schema_version artifact_class required_for_gate].each do |key|
                Support.require_exact!(member[key], expected_member[key], key)
              end
            end
          end

          def validate_fixture!(fixture)
            reference = @expected.dig("docs", "fixture")
            Support.require_keys!(fixture, FIXTURE_KEYS, "fixture_bundle_not_closed")
            %w[bundle_id schema_version classification contains_private_material contains_media_bytes contains_provider_responses contains_secrets].each do |key|
              Support.require_exact!(fixture[key], reference[key], key)
            end
            Support.reject!("fixture_records_empty") unless fixture["records"].class == Array && !fixture["records"].empty?

            fixture["records"].each do |record|
              scan!(record)
              Support.require_keys!(record, RECORD_KEYS, "fixture_record_not_closed")
              Support.reject!("synthetic_story_placeholder") unless record["story_placeholder"].class == String && /\ASYNTHETIC_STORY_PLACEHOLDER_[0-9]+\z/.match?(record["story_placeholder"])
              Support.require_keys!(record["q0_placeholder"], Q0_KEYS, "q0_not_closed")
              Support.require_exact!(record.dig("q0_placeholder", "kind"), "Q0_PLACEHOLDER", "q0_kind")
              Support.require_exact!(record.dig("q0_placeholder", "media_present"), false, "q0_production_media")
              Support.require_exact!(record.dig("q0_placeholder", "production_media"), false, "q0_production_media")
              Support.require_keys!(record["structural_metadata"], STRUCT_KEYS, "structural_metadata_not_closed")
              Support.require_keys!(record["zero_media"], ZERO_KEYS, "zero_media_not_closed")
              Support.require_exact!(record.dig("zero_media", "media_asset_count"), 0, "media_asset_count")
              Support.require_exact!(record.dig("zero_media", "media_bytes_present"), false, "binary_or_base64_media")
              Support.require_exact!(record.dig("zero_media", "external_asset_locators"), [], "external_asset_locator")
              Support.require_exact!(record["expected_validation_outcome"], "PASS", "expected_validation_outcome")
            end
          end

          def scan!(value)
            case value
            when Hash
              value.each do |key, child|
                if key != "external_asset_locators" && BAD_KEY.match?(key)
                  code = case key
                         when /private_story|real_story/i then "private_story_material"
                         when /prompt/i then "prompt_material"
                         when /provider_response|raw_response/i then "provider_response_material"
                         when /secret|token|api_key|password/i then "secret_like_value"
                         when /data_url/i then "data_url"
                         when /base64|binary_media/i then "binary_or_base64_media"
                         else "absolute_or_private_path"
                         end
                  Support.reject!(code)
                end
                scan!(child)
              end
            when Array
              value.each { |item| scan!(item) }
            when String
              Support.reject!("secret_like_value") if SECRET_VALUE.match?(value)
              Support.reject!("data_url") if DATA_URL.match?(value)
              Support.reject!("binary_or_base64_media") if MEDIA64.match?(value) || value.include?("\0")
              Support.reject!("absolute_or_private_path") if PRIVATE_PATH.match?(value)
            end
          end

          def validate_receipt!(receipt, docs, bytes)
            reference = @expected.dig("docs", "receipt")
            Support.require_keys!(receipt, RECEIPT_KEYS, "receipt_not_closed")
            %w[receipt_id schema_version validated_control_main_sha].each { |key| Support.require_exact!(receipt[key], reference[key], key == "validated_control_main_sha" ? "control_main_sha_drift" : key) }
            Support.require_exact!(receipt["validated_public_runner_main_sha"], @authority.fetch("public_runner_main"), "public_runner_sha_drift")
            manifest_digest = bytes ? Digest::SHA256.hexdigest(bytes.fetch("wave2_private_gate_manifest_v01.json")) : @authority.dig("files", "wave2_private_gate_manifest_v01.json", "sha256")
            fixture_digest = bytes ? Digest::SHA256.hexdigest(bytes.fetch("sanitized_fixture_bundle_v01.json")) : @authority.dig("files", "sanitized_fixture_bundle_v01.json", "sha256")
            Support.require_exact!(receipt["private_gate_manifest_sha256"], manifest_digest, "manifest_file_digest")
            Support.require_exact!(receipt["fixture_bundle_sha256"], fixture_digest, "fixture_file_digest")
            Support.require_exact!(receipt["checks"], reference["checks"], "receipt_check_set")
            Support.require_exact!(receipt["negative_mutations"], reference["negative_mutations"], "mutation_matrix")
            {
              "workflow_dispatched" => [false, "workflow_dispatch_authority"],
              "public_runner_writes" => [0, "public_runner_writes"],
              "provider_calls" => [0, "provider_calls"],
              "paid_provider_calls" => [0, "paid_provider_calls"],
              "media_execution" => [0, "media_execution"],
              "private_media_in_git" => [false, "private_media_in_git"],
              "no_fake_green" => [true, "no_fake_green"]
            }.each { |key, (expected, code)| Support.require_exact!(receipt[key], expected, code) }
          end

          def validate_handoff!(handoff, docs, bytes)
            reference = @expected.dig("docs", "handoff")
            Support.require_keys!(handoff, HANDOFF_KEYS, "handoff_not_closed")
            %w[handoff_id schema_version].each { |key| Support.require_exact!(handoff[key], reference[key], key) }
            digests = {
              "private_gate_manifest_sha256" => bytes ? Digest::SHA256.hexdigest(bytes.fetch("wave2_private_gate_manifest_v01.json")) : @authority.dig("files", "wave2_private_gate_manifest_v01.json", "sha256"),
              "fixture_bundle_sha256" => bytes ? Digest::SHA256.hexdigest(bytes.fetch("sanitized_fixture_bundle_v01.json")) : @authority.dig("files", "sanitized_fixture_bundle_v01.json", "sha256"),
              "validation_receipt_sha256" => bytes ? Digest::SHA256.hexdigest(bytes.fetch("wave2_private_validation_receipt_v01.json")) : @authority.dig("files", "wave2_private_validation_receipt_v01.json", "sha256")
            }
            digests.each { |key, expected| Support.require_exact!(handoff[key], expected, key.sub("private_gate_", "").sub("validation_", "").sub("_sha256", "_file_digest")) }
            Support.require_exact!(handoff["public_runner_main_sha"], @authority.fetch("public_runner_main"), "public_runner_sha_drift")
            Support.require_exact!(handoff["frozen_private_source_sha"], @authority.fetch("frozen_private_source"), "frozen_private_sha_drift")
            Support.require_exact!(handoff["allowed_public_paths"], reference["allowed_public_paths"], "allowed_public_paths")
            handoff["allowed_public_paths"].each { |path| Support.reject!("absolute_or_private_path") if path.start_with?("/") || PRIVATE_PATH.match?(path) }
            Support.require_exact!(handoff["expected_public_validator"], "FactoryMvp::Runner::WaveDNoMediaGate::V01.validate!", "expected_public_validator")
            Support.require_exact!(handoff["expected_validation_semantics"], reference["expected_validation_semantics"], "handoff_validation_semantics")
            Support.require_exact!(handoff["planning_only"], true, "planning_only")
            {
              "workflow_dispatch_authority" => "workflow_dispatch_authority",
              "media_execution_authority" => "media_execution_authority",
              "paid_execution_authority" => "paid_execution_authority",
              "private_repository_write_authority" => "private_repository_write_authority",
              "reverse_authority" => "reverse_authority"
            }.each { |key, code| Support.require_exact!(handoff[key], false, code) }
            Support.require_exact!(handoff["sanitized_metadata_only"], true, "sanitized_metadata_only")
          end
        end

        package_root = File.expand_path("package", __dir__).freeze
        authority = Support.deep_freeze({
          "public_runner_main" => "f056424c1ba40c044cdc31ee38b6fe441e2ec8d3",
          "frozen_private_source" => "be76c8be95fa61d175c4c99ea16b4bf670510560",
          "files" => {
            "wave2_private_gate_manifest_v01.json" => {"sha256" => "d6a4ffa47d4ea72a05954b03deaf411bd86d68671be377add30b8b50e866d3ae", "blob" => "7464e001733b3eaba29d65bc2ee9c0f0f2f60dfd"},
            "sanitized_fixture_bundle_v01.json" => {"sha256" => "ba22a801b1ed87c959dbb451a4114d440a5881648237753faa6e12cafcf3d0a7", "blob" => "ac3a040ca9a606de6ffb7637ac091965d705a903"},
            "wave2_private_validation_receipt_v01.json" => {"sha256" => "7fcf4939bd899e31cf3b396e6ca8cf15d03cfcde9c05f8f1c9d1dc02f9ca1279", "blob" => "24e7b40f45af91fe096121e6cc7c20743c6de2d7"},
            "public_runner_handoff_manifest_v01.json" => {"sha256" => "fb1b71df72f261c4d146a1c979b6d2b84b5a83ac0007404efef48862fe194587", "blob" => "6f3012952c6453712d0aaa36b95f0501db930a54"},
            "mutation_catalog_v01.json" => {"sha256" => "c1f109fdd531190a42bd9ff327dda2ac127166ef768037f45e0465412016646b", "blob" => "d13e067480df3011993c7498c081c2bd195373fc"},
            "schemas/wave2_private_gate_manifest_v01.schema.json" => {"sha256" => "e4efb9d05d1e51dd44b6f06677a2e5015c20c0c076e8bcea4b75b18894da3e15", "blob" => "2ce5733ffa3f75880f85fbd718c5d5cea4ae5541"},
            "schemas/sanitized_fixture_bundle_v01.schema.json" => {"sha256" => "e9f99a5f29e85388143359007600f6467c362d6e0a5782f68dcb6e5314981888", "blob" => "7b39b8154f627077f03b421cf45b399d2c76c38f"},
            "schemas/wave2_private_validation_receipt_v01.schema.json" => {"sha256" => "0fa8c2931bda9875595d69254074be27d34e473ac1654aaa80c1b224e1a3dfa7", "blob" => "133e4684361eb8b080c834d058759a96ce95cf24"},
            "schemas/public_runner_handoff_manifest_v01.schema.json" => {"sha256" => "09850d0dc3b540b361b1c77df76192ff013d7ecf5cf151883d4b4f2c7d6809bf", "blob" => "45ba8f879715a88377ce9387f822479412c8d08f"}
          }
        })

        bootstrap = Engine.allocate
        bootstrap.send(:initialize, authority, package_root, {"docs" => {}})
        bytes = authority.fetch("files").keys.to_h { |relative| [relative, File.binread(File.join(package_root, relative))] }
        authority.fetch("files").each do |relative, binding|
          content = bytes.fetch(relative)
          Support.require_exact!(Digest::SHA256.hexdigest(content), binding.fetch("sha256"), "package_sha256")
          Support.require_exact!(Support.git_blob_sha(content), binding.fetch("blob"), "package_blob_digest")
        end
        docs, schemas = bootstrap.decode(bytes)
        expected = Support.deep_freeze({"docs" => docs, "schemas" => schemas})
        engine = Engine.new(authority, package_root, expected)

        define_singleton_method(:validate!) { engine.validate_files! }

        if defined?(Minitest)
          define_singleton_method(:__validate_documents_for_test__) { |documents, schema_documents| engine.validate_documents!(documents, schema_documents) }
          define_singleton_method(:__strict_parse_for_test__) { |text| StrictJson.parse(text) }
          define_singleton_method(:__expected_for_test__) { expected }
          define_singleton_method(:__schema_validate_for_test__) { |value, schema| ClosedSchema.validate!(value, schema) }
          define_singleton_method(:__schema_definition_for_test__) { |schema| ClosedSchema.verify_definition!(schema) }
          singleton_class.send(:private, :__validate_documents_for_test__, :__strict_parse_for_test__, :__expected_for_test__, :__schema_validate_for_test__, :__schema_definition_for_test__)
        end

        private_constant :Engine, :Support, :StrictJson, :ClosedSchema
      end
    end
  end
end

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CI_WORKFLOW="$ROOT_DIR/.github/workflows/ci.yml"
RELEASE_WORKFLOW="$ROOT_DIR/.github/workflows/release.yml"

ruby - "$CI_WORKFLOW" "$RELEASE_WORKFLOW" <<'RUBY'
require "open3"
require "yaml"

class ContractViolation < StandardError
end

def assert(condition, message)
  raise ContractViolation, message unless condition
end

def load_workflow(path)
  YAML.safe_load(File.read(path), aliases: true, filename: path)
end

def triggers(workflow)
  workflow.fetch("on") { workflow.fetch(true) }
end

def step(job, name)
  job.fetch("steps").find { |candidate| candidate["name"] == name } ||
    raise(ContractViolation, "Missing step: #{name}")
end

def step_index(job, name)
  job.fetch("steps").index { |candidate| candidate["name"] == name } ||
    raise(ContractViolation, "Missing step: #{name}")
end

def shell_lines(run)
  run.lines.map(&:strip).reject(&:empty?)
end

def all_strings(value)
  case value
  when Hash
    value.flat_map { |key, child| [key.to_s] + all_strings(child) }
  when Array
    value.flat_map { |child| all_strings(child) }
  when String
    [value]
  else
    []
  end
end

def deep_copy(value)
  Marshal.load(Marshal.dump(value))
end

def validate_contract(ci, release)
  ci_triggers = triggers(ci)
  assert(ci_triggers.dig("push", "branches") == ["main"], "CI must run on main pushes")
  ci_helpers = step(ci.fetch("jobs").fetch("test"), "Test release helpers")
  assert(
    shell_lines(ci_helpers.fetch("run")).include?("./script/tests/workflow_contract_test.sh"),
    "CI must gate changes on the release workflow contract"
  )
  assert(
    shell_lines(ci_helpers.fetch("run")).include?("./script/tests/remote_tag_test.sh"),
    "CI must test remote tag provenance"
  )
  assert(
    shell_lines(ci_helpers.fetch("run")).include?("./script/tests/swift_concurrency_compatibility_test.sh"),
    "CI must test Xcode 16 concurrency compatibility"
  )

  release_triggers = triggers(release)
  assert(
    release_triggers.keys.sort == ["push", "workflow_dispatch"],
    "Release workflow must have only tag push and manual triggers"
  )
  assert(release_triggers.fetch("push") == {"tags" => ["v*"]}, "Release tags must match only v*")
  inputs = release_triggers.fetch("workflow_dispatch").fetch("inputs")
  assert(
    inputs == {
      "signing_mode" => {
        "description" => "Signing mode for the manual package-only preflight",
        "required" => true,
        "type" => "choice",
        "options" => ["adhoc", "developer-id"],
        "default" => "adhoc"
      },
      "release_channel" => {
        "description" => "Channel constraint for the manual package-only preflight",
        "required" => true,
        "type" => "choice",
        "options" => ["prerelease", "stable"],
        "default" => "prerelease"
      }
    },
    "Manual preflight inputs must remain explicit closed choices"
  )

  assert(release.fetch("permissions") == {"contents" => "read"}, "Default permissions must be read-only")
  assert(
    release.fetch("concurrency") == {
      "group" => "release-${{ github.ref }}",
      "cancel-in-progress" => false
    },
    "Release concurrency must serialize a ref without cancellation"
  )

  jobs = release.fetch("jobs")
  assert(
    jobs.keys == ["metadata", "validate", "package_adhoc", "package_developer_id", "publish"],
    "Release job boundaries must remain explicit"
  )
  metadata = jobs.fetch("metadata")
  validation = jobs.fetch("validate")
  package_adhoc = jobs.fetch("package_adhoc")
  package_developer_id = jobs.fetch("package_developer_id")
  publish = jobs.fetch("publish")

  read_only_permissions = {"contents" => "read"}
  assert(metadata.fetch("permissions") == read_only_permissions, "Metadata must be read-only")
  assert(validation.fetch("permissions") == read_only_permissions, "Validation must be read-only")
  assert(package_adhoc.fetch("permissions") == read_only_permissions, "Ad-hoc packaging must be read-only")
  assert(package_developer_id.fetch("permissions") == read_only_permissions, "Developer ID packaging must be read-only")
  assert(publish.fetch("permissions") == {"contents" => "write"}, "Only publishing may write contents")

  assert(metadata.fetch("timeout-minutes").between?(1, 15), "Metadata timeout must be bounded")
  assert(validation.fetch("timeout-minutes").between?(1, 30), "Validation timeout must be bounded")
  assert(package_adhoc.fetch("timeout-minutes").between?(1, 60), "Ad-hoc package timeout must be bounded")
  assert(package_developer_id.fetch("timeout-minutes").between?(1, 60), "Developer ID package timeout must be bounded")
  assert(publish.fetch("timeout-minutes").between?(1, 15), "Publish timeout must be bounded")

  assert(validation.fetch("needs") == "metadata", "Validation must follow metadata")
  assert(Array(package_adhoc.fetch("needs")) == ["metadata", "validate"], "Ad-hoc packaging needs validation")
  assert(Array(package_developer_id.fetch("needs")) == ["metadata", "validate"], "Developer ID packaging needs validation")
  assert(Array(publish.fetch("needs")) == ["metadata", "package_adhoc"], "Publishing must depend only on tag ad-hoc packaging")
  assert(
    package_adhoc.fetch("if") == "${{ needs.metadata.result == 'success' && needs.validate.result == 'success' && needs.metadata.outputs.signing_mode == 'adhoc' }}",
    "Only the selected ad-hoc path may run"
  )
  assert(
    package_developer_id.fetch("if") == "${{ needs.metadata.result == 'success' && needs.validate.result == 'success' && needs.metadata.outputs.signing_mode == 'developer-id' }}",
    "Only the selected Developer ID path may run"
  )
  assert(
    publish.fetch("if") == "${{ always() && github.event_name == 'push' && needs.metadata.result == 'success' && needs.package_adhoc.result == 'success' && needs.metadata.outputs.signing_mode == 'adhoc' }}",
    "Publishing must fail closed for manual, failed, or skipped needs"
  )

  jobs.each do |job_name, job|
    if job_name == "package_developer_id"
      assert(job.fetch("environment") == "release", "Developer ID packaging must use the release Environment")
    else
      assert(!job.key?("environment"), "Only Developer ID packaging may reference an Environment")
    end
  end

  guard = step(metadata, "Validate release metadata and main ancestry")
  mode = step(metadata, "Select tag release or manual preflight mode")
  assert(
    step_index(metadata, "Validate release metadata and main ancestry") <
      step_index(metadata, "Select tag release or manual preflight mode"),
    "Metadata and ancestry checks must precede mode selection"
  )
  assert(
    guard.fetch("env") == {
      "EVENT_NAME" => "${{ github.event_name }}",
      "RELEASE_SHA" => "${{ github.sha }}",
      "RELEASE_TAG" => "${{ github.ref_name }}"
    },
    "Release context must enter metadata shell through env"
  )
  guard_lines = shell_lines(guard.fetch("run"))
  fetch_line = "git fetch --no-tags origin +refs/heads/main:refs/remotes/origin/main"
  tag_guard_line = './script/validate_release.sh "$RELEASE_TAG" "$RELEASE_SHA" refs/remotes/origin/main'
  remote_tag_guard_line = './script/validate_remote_tag.sh "$RELEASE_TAG" "$RELEASE_SHA" origin'
  manual_guard_line = './script/validate_release.sh "" "$RELEASE_SHA" refs/remotes/origin/main'
  assert(guard_lines.count(fetch_line) == 1, "Every trigger must fetch origin/main once")
  assert(guard_lines.count(tag_guard_line) == 1, "Tag metadata must validate tag, version, and main ancestry")
  assert(guard_lines.count(remote_tag_guard_line) == 1, "Tag metadata must validate the remote tag commit")
  assert(guard_lines.count(manual_guard_line) == 1, "Manual preflight commit must be on main")
  assert(guard_lines.index(fetch_line) < guard_lines.index(tag_guard_line), "Main fetch must precede tag validation")
  assert(guard_lines.index(fetch_line) < guard_lines.index(manual_guard_line), "Main fetch must precede manual validation")
  push_guard_index = guard_lines.index("push)")
  manual_guard_index = guard_lines.index("workflow_dispatch)")
  assert(
    guard_lines[push_guard_index, 4] == ["push)", tag_guard_line, remote_tag_guard_line, ";;"],
    "Tag metadata and remote provenance validation must remain inside the push branch"
  )
  assert(
    guard_lines[manual_guard_index, 3] == ["workflow_dispatch)", manual_guard_line, ";;"],
    "Main ancestry validation must remain inside the manual branch"
  )

  assert(
    mode.fetch("env") == {
      "EVENT_NAME" => "${{ github.event_name }}",
      "MANUAL_RELEASE_CHANNEL" => "${{ inputs.release_channel }}",
      "MANUAL_SIGNING_MODE" => "${{ inputs.signing_mode }}"
    },
    "Manual choices must enter mode selection through env"
  )
  mode_lines = shell_lines(mode.fetch("run"))
  %w[signing_mode=adhoc release_channel=prerelease].each do |line|
    assert(mode_lines.count(line) == 1, "Tag mode mapping is incomplete: #{line}")
  end
  assert(mode_lines.count('release_prerelease="true"') == 1, "Prerelease must map to true")
  assert(mode_lines.count('release_prerelease="false"') == 1, "Stable must map to false")
  assert(
    mode_lines.count('validate_release_channel "$signing_mode" "$release_prerelease"') == 1,
    "Selected mode and channel must be validated"
  )
  push_mode_index = mode_lines.index("push)")
  manual_mode_index = mode_lines.index("workflow_dispatch)")
  assert(
    mode_lines[push_mode_index, 4] == ["push)", "signing_mode=adhoc", "release_channel=prerelease", ";;"],
    "Every tag push must select ad-hoc prerelease"
  )
  assert(
    mode_lines[manual_mode_index, 4] == [
      "workflow_dispatch)",
      'signing_mode="$MANUAL_SIGNING_MODE"',
      'release_channel="$MANUAL_RELEASE_CHANNEL"',
      ";;"
    ],
    "Manual preflight must use only the explicit inputs"
  )

  assert(
    validation.fetch("steps").map { |candidate| candidate["name"] }.compact == [
      "Validate shell syntax",
      "Test release helpers",
      "Swift tests"
    ],
    "Release validation steps must remain centralized"
  )
  validation_helpers = step(validation, "Test release helpers")
  assert(
    shell_lines(validation_helpers.fetch("run")).include?("./script/tests/remote_tag_test.sh"),
    "Release validation must test remote tag provenance"
  )

  metadata_checkout = metadata.fetch("steps").first
  assert(
    metadata_checkout.fetch("with") == {
      "fetch-depth" => 0,
      "persist-credentials" => true
    },
    "Metadata checkout must retain its read-only token for the explicit main fetch"
  )
  [package_adhoc, publish].each do |job|
    checkout = job.fetch("steps").first
    assert(
      checkout.fetch("with") == {"persist-credentials" => true},
      "Tag revalidation jobs must retain credentials for remote fetch"
    )
  end
  [validation, package_developer_id].each do |job|
    checkout = job.fetch("steps").first
    assert(
      checkout.fetch("with") == {"persist-credentials" => false},
      "Jobs without remote revalidation must not persist checkout credentials"
    )
  end

  package_recheck = step(package_adhoc, "Revalidate remote tag before packaging")
  assert(package_recheck.fetch("if") == "github.event_name == 'push'", "Manual packaging must skip tag revalidation")
  assert(
    package_recheck.fetch("env") == {
      "RELEASE_SHA" => "${{ github.sha }}",
      "RELEASE_TAG" => "${{ github.ref_name }}"
    },
    "Package tag context must enter shell through env"
  )
  assert(
    shell_lines(package_recheck.fetch("run")) == [
      "set -euo pipefail",
      './script/validate_remote_tag.sh "$RELEASE_TAG" "$RELEASE_SHA" origin'
    ],
    "Tag provenance must be revalidated immediately before packaging"
  )
  adhoc_step = step(package_adhoc, "Package ad-hoc Universal 2 artifact")
  assert(
    step_index(package_adhoc, "Revalidate remote tag before packaging") <
      step_index(package_adhoc, "Package ad-hoc Universal 2 artifact"),
    "Remote tag revalidation must precede packaging"
  )
  assert(
    adhoc_step.fetch("env") == {
      "RELEASE_PRERELEASE" => "true",
      "SIGNING_MODE" => "adhoc"
    },
    "Ad-hoc packaging must use literal non-secret mode inputs"
  )
  assert(
    shell_lines(adhoc_step.fetch("run")) == ["set -euo pipefail", "./script/package_release.sh dist/release"],
    "Ad-hoc packaging must call only the package orchestrator"
  )

  developer_step = step(package_developer_id, "Sign, notarize, and package Developer ID preflight")
  expected_developer_env = {
    "APP_STORE_CONNECT_API_KEY_P8" => "${{ secrets.APP_STORE_CONNECT_API_KEY_P8 }}",
    "APP_STORE_CONNECT_ISSUER_ID" => "${{ secrets.APP_STORE_CONNECT_ISSUER_ID }}",
    "APP_STORE_CONNECT_KEY_ID" => "${{ secrets.APP_STORE_CONNECT_KEY_ID }}",
    "MACOS_CERTIFICATE_P12" => "${{ secrets.MACOS_CERTIFICATE_P12 }}",
    "MACOS_CERTIFICATE_PASSWORD" => "${{ secrets.MACOS_CERTIFICATE_PASSWORD }}",
    "RELEASE_PRERELEASE" => "${{ needs.metadata.outputs.release_prerelease }}",
    "SIGNING_MODE" => "developer-id"
  }
  assert(developer_step.fetch("env") == expected_developer_env, "Developer ID env must be explicit and complete")

  secret_references = all_strings(release).select { |value| value.include?("${{ secrets.") }
  assert(
    secret_references.sort == expected_developer_env.values.select { |value| value.include?("${{ secrets.") }.sort,
    "Only the five Developer ID secrets may be referenced"
  )
  release_without_developer = deep_copy(release)
  release_without_developer.fetch("jobs").delete("package_developer_id")
  assert(
    all_strings(release_without_developer).none? { |value| value.include?("${{ secrets.") },
    "Secrets must not escape the Developer ID job"
  )

  developer_run = developer_step.fetch("run")
  developer_lines = shell_lines(developer_run)
  %w[
    MACOS_CERTIFICATE_P12
    MACOS_CERTIFICATE_PASSWORD
    APP_STORE_CONNECT_API_KEY_P8
    APP_STORE_CONNECT_KEY_ID
    APP_STORE_CONNECT_ISSUER_ID
  ].each do |credential|
    credential_guard = ': "${' + credential + ':?Missing ' + credential + '}"'
    assert(
      developer_lines.count(credential_guard) == 1,
      "Missing #{credential} must fail closed"
    )
  end
  %w[
    set\ +e
    load_keychain_search_list\ "$original_keychains_path"
    restore_keychain_search_list
    security\ delete-keychain\ "$keychain_path"
  ].each do |escaped_line|
    line = escaped_line.gsub("\\ ", " ")
    assert(developer_lines.include?(line), "Cleanup is missing: #{line}")
  end
  assert(developer_lines.include?("trap cleanup EXIT"), "Cleanup must use an EXIT trap")
  assert(developer_lines.include?("umask 077"), "Secret files require a restrictive umask")
  assert(developer_lines.include?("security create-keychain -p \"$keychain_password\" \"$keychain_path\""), "A temporary keychain is required")
  assert(developer_lines.include?("security import \"$certificate_path\" \\"), "The Developer ID certificate must be imported")
  assert(developer_lines.include?("./script/package_release.sh dist/release"), "Developer ID preflight must package and notarize")
  assert(developer_lines.count('record_cleanup_status "$?"') >= 4, "Cleanup failures must be aggregated")
  assert(developer_lines.any? { |line| line.start_with?('rm -f "$certificate_path"') }, "Secret files must be removed")
  assert(!developer_run.include?("set -x"), "Secret-bearing steps must not enable tracing")

  [package_adhoc, package_developer_id].each do |package_job|
    upload = step(package_job, "Upload workflow artifact")
    assert(upload.fetch("with").fetch("retention-days") == 7, "Artifacts must expire after seven days")
    assert(upload.fetch("with").fetch("if-no-files-found") == "error", "Missing artifacts must fail closed")
  end

  assert(
    step_index(publish, "Download workflow artifact") < step_index(publish, "Publish GitHub release"),
    "Artifact download must precede publication"
  )
  publish_step = step(publish, "Publish GitHub release")
  assert(
    publish_step.fetch("env") == {
      "GH_TOKEN" => "${{ github.token }}",
      "RELEASE_PRERELEASE" => "${{ needs.metadata.outputs.release_prerelease }}",
      "RELEASE_SHA" => "${{ github.sha }}",
      "RELEASE_TAG" => "${{ github.ref_name }}",
      "RELEASE_VERSION" => "${{ needs.metadata.outputs.version }}",
      "SIGNING_MODE" => "adhoc"
    },
    "Publish env must be fixed to the validated tag ad-hoc path"
  )
  publish_lines = shell_lines(publish_step.fetch("run"))
  publish_recheck_line = './script/validate_remote_tag.sh "$RELEASE_TAG" "$RELEASE_SHA" origin'
  publish_call_line = "./script/publish_release.sh \\"
  assert(
    publish_lines.count(publish_recheck_line) == 1,
    "Publish must revalidate remote tag provenance"
  )
  assert(
    publish_lines.index(publish_call_line) == publish_lines.index(publish_recheck_line) + 1,
    "Remote tag revalidation must be adjacent to publish_release.sh"
  )

  expected_actions = {
    "actions/checkout" => ["9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0", 5],
    "actions/upload-artifact" => ["043fb46d1a93c77aae656e7c1c64a875d1fc6a0a", 2],
    "actions/download-artifact" => ["3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c", 1]
  }
  seen_actions = Hash.new(0)
  jobs.each_value do |job|
    job.fetch("steps").each do |candidate|
      if candidate.key?("run")
        assert(!candidate.fetch("run").include?("${{"), "GitHub expressions must enter shell through env")
        _stdout, stderr, status = Open3.capture3("/bin/bash", "-n", stdin_data: candidate.fetch("run"))
        assert(status.success?, "Invalid shell syntax in #{candidate.fetch("name", "unnamed step")}: #{stderr}")
      end
      next unless candidate.key?("uses")

      action, revision = candidate.fetch("uses").split("@", 2)
      expected_revision, = expected_actions.fetch(action) do
        raise ContractViolation, "Unexpected action: #{action}"
      end
      assert(revision == expected_revision, "Unexpected pin for #{action}")
      assert(revision.match?(/\A[0-9a-f]{40}\z/), "Action #{action} must use a full SHA")
      seen_actions[action] += 1
    end
  end
  expected_actions.each do |action, (_revision, count)|
    assert(seen_actions[action] == count, "Unexpected use count for #{action}")
  end
end

def expect_mutation_failure(name, ci, release)
  mutated_ci = deep_copy(ci)
  mutated_release = deep_copy(release)
  yield mutated_ci, mutated_release
  begin
    validate_contract(mutated_ci, mutated_release)
  rescue ContractViolation
    return
  end
  raise "Mutation survived contract validation: #{name}"
end

ci = load_workflow(ARGV.fetch(0))
release = load_workflow(ARGV.fetch(1))
validate_contract(ci, release)

expect_mutation_failure("manual main ancestry removed", ci, release) do |_mutated_ci, mutated_release|
  guard = step(mutated_release.fetch("jobs").fetch("metadata"), "Validate release metadata and main ancestry")
  guard["run"] = guard.fetch("run").sub(
    './script/validate_release.sh "" "$RELEASE_SHA" refs/remotes/origin/main',
    "./script/validate_release.sh"
  )
end

expect_mutation_failure("ad-hoc Environment added", ci, release) do |_mutated_ci, mutated_release|
  mutated_release.fetch("jobs").fetch("package_adhoc")["environment"] = "release"
end

expect_mutation_failure("ad-hoc secret added", ci, release) do |_mutated_ci, mutated_release|
  adhoc_step = step(mutated_release.fetch("jobs").fetch("package_adhoc"), "Package ad-hoc Universal 2 artifact")
  adhoc_step.fetch("env")["MACOS_CERTIFICATE_P12"] = "${{ secrets.MACOS_CERTIFICATE_P12 }}"
end

expect_mutation_failure("publish condition loosened", ci, release) do |_mutated_ci, mutated_release|
  mutated_release.fetch("jobs").fetch("publish")["if"] = "${{ github.event_name == 'push' }}"
end

expect_mutation_failure("cleanup restore removed", ci, release) do |_mutated_ci, mutated_release|
  developer_step = step(
    mutated_release.fetch("jobs").fetch("package_developer_id"),
    "Sign, notarize, and package Developer ID preflight"
  )
  original_run = developer_step.fetch("run")
  developer_step["run"] = original_run.sub("    restore_keychain_search_list\n", "")
  raise "Cleanup mutation did not apply" if developer_step.fetch("run") == original_run
end

expect_mutation_failure("package tag recheck removed", ci, release) do |_mutated_ci, mutated_release|
  package_job = mutated_release.fetch("jobs").fetch("package_adhoc")
  package_job.fetch("steps").reject! do |candidate|
    candidate["name"] == "Revalidate remote tag before packaging"
  end
end

expect_mutation_failure("publish tag recheck removed", ci, release) do |_mutated_ci, mutated_release|
  publish_step = step(mutated_release.fetch("jobs").fetch("publish"), "Publish GitHub release")
  original_run = publish_step.fetch("run")
  publish_step["run"] = original_run.sub(
    "./script/validate_remote_tag.sh \"$RELEASE_TAG\" \"$RELEASE_SHA\" origin\n",
    ""
  )
  raise "Publish tag mutation did not apply" if publish_step.fetch("run") == original_run
end
RUBY

grep -Fq "actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0" "$RELEASE_WORKFLOW"
grep -Fq "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1" "$RELEASE_WORKFLOW"
grep -Fq "actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1" "$RELEASE_WORKFLOW"

echo "workflow_contract_test: PASS"

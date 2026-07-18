#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CI_WORKFLOW="$ROOT_DIR/.github/workflows/ci.yml"
RELEASE_WORKFLOW="$ROOT_DIR/.github/workflows/release.yml"

ruby - "$CI_WORKFLOW" "$RELEASE_WORKFLOW" <<'RUBY'
require "yaml"
require "open3"

def assert(condition, message)
  raise message unless condition
end

def load_workflow(path)
  YAML.safe_load(File.read(path), aliases: true, filename: path)
end

def triggers(workflow)
  workflow.fetch("on") { workflow.fetch(true) }
end

def step(job, name)
  job.fetch("steps").find { |candidate| candidate["name"] == name } ||
    raise("Missing step: #{name}")
end

def step_index(job, name)
  job.fetch("steps").index { |candidate| candidate["name"] == name } ||
    raise("Missing step: #{name}")
end

ci = load_workflow(ARGV.fetch(0))
release = load_workflow(ARGV.fetch(1))

assert(triggers(ci).dig("push", "branches") == ["main"], "CI must run on main pushes")

release_triggers = triggers(release)
assert(release_triggers.dig("push", "tags") == ["v*"], "Release tags must match v*")
inputs = release_triggers.fetch("workflow_dispatch").fetch("inputs")
assert(
  inputs.dig("signing_mode", "type") == "choice" &&
    inputs.dig("signing_mode", "required") == true &&
    inputs.dig("signing_mode", "default") == "adhoc" &&
    inputs.dig("signing_mode", "options") == ["adhoc", "developer-id"],
  "Manual signing_mode must be an explicit closed choice"
)
assert(
  inputs.dig("release_channel", "type") == "choice" &&
    inputs.dig("release_channel", "required") == true &&
    inputs.dig("release_channel", "default") == "prerelease" &&
    inputs.dig("release_channel", "options") == ["prerelease", "stable"],
  "Manual release_channel must be an explicit closed choice"
)

assert(release.dig("permissions", "contents") == "read", "Default contents permission must be read")
assert(release.dig("concurrency", "cancel-in-progress") == false, "Release runs must not cancel each other")
assert(release.dig("concurrency", "group").to_s.start_with?("release-"), "Release concurrency group is required")

jobs = release.fetch("jobs")
metadata = jobs.fetch("metadata")
package = jobs.fetch("package")
publish = jobs.fetch("publish")

assert(metadata.fetch("timeout-minutes").between?(1, 15), "Metadata timeout must be bounded")
assert(package.fetch("timeout-minutes").between?(1, 60), "Package timeout must be bounded")
assert(publish.fetch("timeout-minutes").between?(1, 15), "Publish timeout must be bounded")
assert(package.fetch("needs") == "metadata", "Packaging must wait for metadata validation")
assert(Array(publish.fetch("needs")) == ["metadata", "package"], "Publishing must wait for metadata and packaging")
assert(publish.fetch("if").include?("github.event_name == 'push'"), "Only tag pushes may publish")
assert(publish.dig("permissions", "contents") == "write", "Publishing requires contents: write")
assert(metadata.dig("permissions", "contents") != "write", "Metadata must not have write permission")
assert(package.dig("permissions", "contents") != "write", "Packaging must not have write permission")

guard = step(metadata, "Validate release metadata")
mode = step(metadata, "Select release mode")
assert(
  step_index(metadata, "Validate release metadata") < step_index(metadata, "Select release mode"),
  "Tag, version, and ancestry checks must precede mode selection"
)
assert(guard.fetch("run").include?("./script/validate_release.sh"), "Metadata guard must call validate_release.sh")
assert(guard.fetch("run").include?("refs/remotes/origin/main"), "Tag releases must validate main ancestry")
assert(mode.fetch("run").include?("validate_release_channel"), "Mode selection must validate the channel")
assert(mode.fetch("run").include?("signing_mode=adhoc"), "Tag signing mode must be explicit")
assert(mode.fetch("run").include?("release_channel=prerelease"), "Tag release channel must be explicit")
assert(mode.fetch("run").include?('release_prerelease="true"'), "Prerelease must map to true")
assert(mode.fetch("run").include?('release_prerelease="false"'), "Stable must map to false")

adhoc = step(package, "Package ad-hoc Universal 2 release")
developer_id = step(package, "Package Developer ID Universal 2 release")
upload = step(package, "Upload workflow artifact")
assert(adhoc.fetch("run").include?("./script/package_release.sh"), "Ad-hoc packaging must use package_release.sh")
assert(developer_id.fetch("run").include?("./script/package_release.sh"), "Developer ID packaging must use package_release.sh")
assert(step_index(package, "Package ad-hoc Universal 2 release") < step_index(package, "Upload workflow artifact"), "Ad-hoc packaging must precede upload")
assert(step_index(package, "Package Developer ID Universal 2 release") < step_index(package, "Upload workflow artifact"), "Developer ID packaging must precede upload")
assert(upload.fetch("with").fetch("retention-days") == 7, "Artifacts must expire after seven days")
assert(upload.fetch("with").fetch("if-no-files-found") == "error", "Missing artifacts must fail closed")

developer_run = developer_id.fetch("run")
%w[
  MACOS_CERTIFICATE_P12
  MACOS_CERTIFICATE_PASSWORD
  APP_STORE_CONNECT_API_KEY_P8
  APP_STORE_CONNECT_KEY_ID
  APP_STORE_CONNECT_ISSUER_ID
].each do |credential|
  assert(developer_run.include?(": \"\${#{credential}:?"), "Missing #{credential} must fail closed")
end
assert(developer_run.include?("umask 077"), "Secret files require a restrictive umask")
assert(developer_run.include?("trap cleanup EXIT"), "Developer ID cleanup must use an EXIT trap")
assert(developer_run.include?("security create-keychain"), "Developer ID must use a temporary keychain")
assert(developer_run.include?("security import"), "Developer ID certificate must be imported")
assert(developer_run.include?("original-keychains"), "Original keychain search list must be captured")
assert(developer_run.scan("security list-keychains -d user -s").length >= 2, "Keychain search list must be set and restored")
assert(developer_run.include?("security delete-keychain"), "Temporary keychain must be deleted")
assert(developer_run.include?('rm -f "$certificate_path"'), "Certificate file must be removed")
assert(!developer_run.include?("set -x"), "Secret-bearing steps must not enable shell tracing")
assert(
  developer_run.index("trap cleanup EXIT") < developer_run.index("security create-keychain") &&
    developer_run.index("security create-keychain") < developer_run.index("./script/package_release.sh"),
  "Cleanup trap must cover keychain creation and packaging"
)
assert(
  developer_run.index('security list-keychains -d user > "$original_keychains_path"') <
    developer_run.index("security create-keychain"),
  "Original keychain search list must be captured before mutation"
)

download_index = step_index(publish, "Download workflow artifact")
publish_index = step_index(publish, "Publish GitHub release")
assert(download_index < publish_index, "Artifact download must precede publication")
assert(step(publish, "Publish GitHub release").fetch("run").include?("./script/publish_release.sh"), "Publishing must use publish_release.sh")

expected_actions = {
  "actions/checkout" => "9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0",
  "actions/upload-artifact" => "043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
  "actions/download-artifact" => "3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c"
}
seen_actions = []
jobs.each_value do |job|
  job.fetch("steps").each do |candidate|
    if candidate.key?("run")
      assert(!candidate.fetch("run").include?("${{"), "GitHub expressions must enter shell steps through env")
      _stdout, stderr, status = Open3.capture3("/bin/bash", "-n", stdin_data: candidate.fetch("run"))
      assert(status.success?, "Invalid shell syntax in #{candidate.fetch("name", "unnamed step")}: #{stderr}")
    end
    next unless candidate.key?("uses")

    action, revision = candidate.fetch("uses").split("@", 2)
    assert(revision&.match?(/\A[0-9a-f]{40}\z/), "Action #{action} must be pinned to a full SHA")
    assert(expected_actions[action] == revision, "Unexpected pin for #{action}")
    seen_actions << action
  end
end
assert((expected_actions.keys - seen_actions).empty?, "Checkout, upload, and download actions are required")
RUBY

grep -Fq "actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0" "$RELEASE_WORKFLOW"
grep -Fq "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1" "$RELEASE_WORKFLOW"
grep -Fq "actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1" "$RELEASE_WORKFLOW"

echo "workflow_contract_test: PASS"

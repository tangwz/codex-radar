#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREPARE_SCRIPT="$ROOT_DIR/script/prepare_appcast_inputs.sh"
VERIFY_SCRIPT="$ROOT_DIR/script/verify_update_artifacts.sh"
QUALIFY_SCRIPT="$ROOT_DIR/script/qualify_update.sh"
HALT_SCRIPT="$ROOT_DIR/script/halt_distribution.sh"
ACTIVATION_PR_VERIFY_SCRIPT="$ROOT_DIR/script/verify_activation_pr.sh"
SPARKLE_SOURCE="$ROOT_DIR/.build/checkouts/Sparkle"
SPARKLE_GENERATE_APPCAST="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
SPARKLE_NAMESPACE="http://www.andymatuschak.org/xml-namespaces/sparkle"
WORKFLOW_DIR="$ROOT_DIR/.github/workflows"
CI_WORKFLOW="$WORKFLOW_DIR/ci.yml"
CANDIDATE_WORKFLOW="$WORKFLOW_DIR/prepare-candidate.yml"
PUBLISH_WORKFLOW="$WORKFLOW_DIR/publish-update.yml"
CODEOWNERS_FILE="$ROOT_DIR/.github/CODEOWNERS"
RELEASING_DOC="$ROOT_DIR/docs/releasing.md"
README_FILE="$ROOT_DIR/README.md"

[[ -x "$PREPARE_SCRIPT" ]] || {
  echo "prepare_appcast_inputs.sh does not exist" >&2
  exit 1
}
[[ -x "$VERIFY_SCRIPT" ]] || {
  echo "verify_update_artifacts.sh does not exist" >&2
  exit 1
}
[[ -x "$QUALIFY_SCRIPT" ]] || {
  echo "qualify_update.sh does not exist" >&2
  exit 1
}
[[ -x "$HALT_SCRIPT" ]] || {
  echo "halt_distribution.sh does not exist" >&2
  exit 1
}
[[ -x "$ACTIVATION_PR_VERIFY_SCRIPT" ]] || {
  echo "verify_activation_pr.sh does not exist" >&2
  exit 1
}
[[ -d "$SPARKLE_SOURCE" ]] || {
  echo "Sparkle source checkout does not exist" >&2
  exit 1
}
[[ -x "$SPARKLE_GENERATE_APPCAST" ]] || {
  echo "Sparkle generate_appcast does not exist" >&2
  exit 1
}

fixture_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codex-radar-feed-tests.XXXXXX")"
sparkle_source_file="Vendor/ed25519-sparkle/src/fe.c"

cleanup() {
  /bin/rm -rf "$fixture_root"
}
trap cleanup EXIT

fail() {
  echo "$*" >&2
  exit 1
}

validate_workflow_policy() {
  local workflow_dir="${1:-$WORKFLOW_DIR}"
  local ci_workflow="${2:-$CI_WORKFLOW}"
  local codeowners_file="${3:-$CODEOWNERS_FILE}"
  local candidate_workflow="${4:-$CANDIDATE_WORKFLOW}"
  local releasing_doc="${5:-$RELEASING_DOC}"
  local publish_workflow="${6:-$PUBLISH_WORKFLOW}"

  /usr/bin/ruby - "$workflow_dir" "$ci_workflow" "$codeowners_file" \
    "$candidate_workflow" "$releasing_doc" "$publish_workflow" <<'RUBY'
require "yaml"

workflow_dir, ci_path, codeowners_path, candidate_path, releasing_path, publish_path = ARGV

def reject(message)
  warn(message)
  exit(1)
end

def fetch_key(mapping, name)
  return nil unless mapping.is_a?(Hash)

  pair = mapping.find do |key, _value|
    key.to_s == name || (name == "on" && key == true)
  end
  pair&.last
end

def each_mapping(value, &block)
  case value
  when Hash
    yield(value)
    value.each_value { |child| each_mapping(child, &block) }
  when Array
    value.each { |child| each_mapping(child, &block) }
  end
end

def secret_reference?(value)
  case value
  when Hash
    value.any? do |key, child|
      (key.to_s == "secrets" && child.to_s.strip == "inherit") || secret_reference?(child)
    end
  when Array
    value.any? { |child| secret_reference?(child) }
  when String
    value.match?(/\$\{\{.*?\bsecrets\b.*?\}\}/m)
  else
    false
  end
end

def protected_tag_deletion?(run)
  normalized = run.gsub(/\\\r?\n/, " ")
  normalized.lines.any? do |line|
    release_cleanup_tag = line.match?(
      /\bgh\s+release\s+delete\b.*(?:\A|\s)--cleanup-tag\b/
    )
    git_push = line.match?(/\bgit\s+push\b/)
    git_push_delete = git_push && (
      line.match?(/(?:\A|\s)(?:--delete|-d)\b/) ||
      line.match?(/(?:\A|\s)["']?\+?:refs\/tags\//)
    )
    git_push_unqualified_delete = git_push &&
      line.match?(/(?:\A|\s)["']?\+?:["']?[^\/\s"']+["']?(?=\s|\z)/)
    git_push_prune = git_push &&
      line.match?(/(?:\A|\s)--prune\b/) &&
      (
        line.match?(/refs\/tags\//) ||
        line.match?(/(?:\A|\s)--tags(?:\s|\z)/)
      )
    git_push_mirror = git_push &&
      line.match?(/(?:\A|\s)--mirror(?:\s|\z)/)
    tag_api_delete = line.match?(/git\/refs\/tags\//) &&
      line.match?(
        /(?:\A|\s)(?:--method(?:=|\s+)|--request(?:=|\s+)|-X\s*)DELETE(?:\s|\z)/
      )

    release_cleanup_tag || git_push_delete || git_push_unqualified_delete ||
      git_push_prune || git_push_mirror || tag_api_delete
  end
end

def workflow_runs(jobs)
  return [] unless jobs.is_a?(Hash)

  jobs.each_value.flat_map do |job|
    steps = fetch_key(job, "steps")
    next [] unless steps.is_a?(Array)

    steps.map do |step|
      run = fetch_key(step, "run")
      run if run.is_a?(String)
    end.compact
  end
end

def workflow_local_actions(jobs)
  return [] unless jobs.is_a?(Hash)

  jobs.each_value.flat_map do |job|
    job_action = fetch_key(job, "uses").to_s.strip
    actions = job_action.start_with?("./") ? [job_action] : []
    steps = fetch_key(job, "steps")
    next actions unless steps.is_a?(Array)

    actions + steps.map do |step|
      action = fetch_key(step, "uses").to_s.strip
      action if action.start_with?("./")
    end.compact
  end
end

unless File.file?(ci_path)
  reject("CI workflow does not exist")
end

workflows = Dir.glob(File.join(workflow_dir, "*.{yml,yaml}"), File::FNM_EXTGLOB).sort
reject("no workflows found") if workflows.empty?
approved_actions = {
  "actions/checkout" => "9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0",
  "actions/upload-artifact" => "043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
  "actions/download-artifact" => "3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c"
}

workflows.each do |workflow_path|
  begin
    document = YAML.safe_load(
      File.read(workflow_path, encoding: "UTF-8"),
      permitted_classes: [],
      permitted_symbols: [],
      aliases: true,
      filename: workflow_path
    ) || {}
  rescue Psych::Exception => error
    reject("#{File.basename(workflow_path)} is invalid YAML: #{error.message}")
  end
  reject("#{File.basename(workflow_path)} must contain a YAML mapping") unless document.is_a?(Hash)

  each_mapping(document) do |mapping|
    mapping.each do |key, value|
      next unless key.to_s == "uses"

      action = value.to_s.strip
      next if action.start_with?("./")
      reject("#{File.basename(workflow_path)} contains an unpinned action: #{action}") unless action.match?(/@[0-9a-fA-F]{40}\z/)
      action_name, revision = action.split("@", 2)
      approved_revision = approved_actions[action_name]
      reject("#{File.basename(workflow_path)} uses an unapproved external action: #{action_name}") if approved_revision.nil?
      if revision != approved_revision
        reject("#{File.basename(workflow_path)} uses an unapproved action revision: #{action}")
      end
    end
  end

  permissions = fetch_key(document, "permissions")
  write_all = permissions.is_a?(String) && permissions.strip == "write-all"
  contents = fetch_key(permissions, "contents")
  contents_write = contents.is_a?(String) && contents.strip == "write"
  reject("#{File.basename(workflow_path)} grants global contents: write") if write_all || contents_write

  concurrency = fetch_key(document, "concurrency")
  cancellation = fetch_key(concurrency, "cancel-in-progress")
  group = fetch_key(concurrency, "group")
  unless [true, false].include?(cancellation) && !group.to_s.strip.empty?
    reject("#{File.basename(workflow_path)} lacks explicit concurrency")
  end

  top_level = document.reject { |key, _value| key.to_s == "jobs" }
  if secret_reference?(top_level)
    reject("#{File.basename(workflow_path)} references a secret outside sign-candidate")
  end
  jobs = fetch_key(document, "jobs")
  if jobs.is_a?(Hash)
    jobs.each do |job_name, job|
      next if job_name.to_s == "sign-candidate"
      if secret_reference?(job)
        reject("#{File.basename(workflow_path)} references a secret outside sign-candidate")
      end
    end
  end
end

ci = File.read(ci_path, encoding: "UTF-8")
required_ci_snippets = [
  "permissions:\n  contents: read",
  "checks: write",
  "actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0",
  "pull_request_target:",
  "branches:\n      - main",
  "path: trusted-source",
  "path: target-source",
  '"repos/$GITHUB_REPOSITORY/check-runs"',
  "-f name=validate",
  "run: trusted-source/script/verify_activation_pr.sh",
  "swift build -c release -Xswiftc -strict-concurrency=complete",
  "swift test",
  "bash Tests/ScriptTests/release_common_tests.sh",
  "bash Tests/ScriptTests/package_verification_tests.sh",
  "bash Tests/ScriptTests/update_feed_tests.sh",
  "find script -name '*.sh' -print0 | xargs -0 -n1 bash -n",
  "find .github/workflows -type f \\( -name '*.yml' -o -name '*.yaml' \\) -print0",
  './script/package_app.sh --output dist/ci --configuration release --architectures "$(uname -m)" --updates-enabled false',
  "https://github.com/rhysd/actionlint/releases/download/v1.7.12/",
  "actionlint_1.7.12_darwin_arm64.tar.gz",
  "actionlint_1.7.12_darwin_amd64.tar.gz",
  "aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f",
  "5b44c3bc2255115c9b69e30efc0fecdf498fdb63c5d58e17084fd5f16324c644"
]
required_ci_snippets.each do |snippet|
  reject("ci.yml lacks required content: #{snippet}") unless ci.include?(snippet)
end
ci_document = YAML.safe_load(
  ci,
  permitted_classes: [],
  permitted_symbols: [],
  aliases: true,
  filename: ci_path
) || {}
ci_triggers = fetch_key(ci_document, "on")
pull_request_target = fetch_key(ci_triggers, "pull_request_target")
unless fetch_key(pull_request_target, "branches") == ["main"]
  reject("CI trusted pull_request_target policy must be restricted to main")
end
if ci_triggers.keys.any? { |key| key.to_s == "pull_request" }
  reject("CI must not execute a PR-owned workflow")
end
jobs = fetch_key(ci_document, "jobs")
start_job = fetch_key(jobs, "start-validation-check")
trusted_job = fetch_key(jobs, "trusted-policy")
target_job = fetch_key(jobs, "target-validation")
finalize_job = fetch_key(jobs, "finalize-validation")
start_steps = fetch_key(start_job, "steps")
trusted_steps = fetch_key(trusted_job, "steps")
target_steps = fetch_key(target_job, "steps")
finalize_steps = fetch_key(finalize_job, "steps")
unless start_steps.is_a?(Array) && trusted_steps.is_a?(Array) &&
    target_steps.is_a?(Array) && finalize_steps.is_a?(Array)
  reject("CI validation jobs are missing")
end
unless fetch_key(fetch_key(start_job, "permissions"), "checks") == "write" &&
    fetch_key(fetch_key(start_job, "permissions"), "contents").nil?
  reject("CI check creation job must have only checks:write")
end
unless fetch_key(fetch_key(trusted_job, "permissions"), "contents") == "read" &&
    fetch_key(fetch_key(trusted_job, "permissions"), "checks").nil?
  reject("CI trusted policy job must not have checks:write")
end
unless fetch_key(fetch_key(target_job, "permissions"), "contents") == "read" &&
    fetch_key(fetch_key(target_job, "permissions"), "checks").nil?
  reject("CI target validation job must not have checks:write")
end
unless fetch_key(fetch_key(finalize_job, "permissions"), "checks") == "write" &&
    fetch_key(fetch_key(finalize_job, "permissions"), "contents").nil?
  reject("CI finalize job must have only checks:write")
end
trusted_checkout = trusted_steps.find { |step| fetch_key(step, "name") == "Check out trusted validation policy" }
target_checkout = target_steps.find { |step| fetch_key(step, "name") == "Check out target revision" }
trusted_gate = trusted_steps.find { |step| fetch_key(step, "name") == "Enforce trusted activation policy" }
start_check = start_steps.find { |step| fetch_key(step, "name") == "Start required validation check" }
complete_check = finalize_steps.find { |step| fetch_key(step, "name") == "Complete required validation check" }
reject("CI trusted policy checkout is missing") unless fetch_key(fetch_key(trusted_checkout, "with"), "path") == "trusted-source"
unless fetch_key(fetch_key(trusted_checkout, "with"), "persist-credentials") == false
  reject("CI trusted policy checkout must not persist credentials")
end
unless fetch_key(fetch_key(trusted_checkout, "with"), "ref") == "${{ github.event.pull_request.base.sha || github.sha }}"
  reject("CI trusted policy must come from the immutable base SHA")
end
reject("CI target checkout is missing") unless fetch_key(fetch_key(target_checkout, "with"), "path") == "target-source"
unless fetch_key(fetch_key(target_checkout, "with"), "persist-credentials") == false
  reject("CI target checkout must not expose credentials to PR-owned code")
end
unless fetch_key(fetch_key(target_checkout, "with"), "ref") == "${{ github.event.pull_request.head.sha || github.sha }}"
  reject("CI target checkout must use the immutable PR head SHA")
end
unless fetch_key(trusted_gate, "run") == "trusted-source/script/verify_activation_pr.sh"
  reject("CI activation policy must execute from trusted-source")
end
unless fetch_key(start_check, "run").to_s.include?("-f head_sha=\"$TARGET_SHA\"") &&
    fetch_key(start_check, "run").to_s.include?("-f name=validate") &&
    fetch_key(start_check, "run").to_s.include?('[[ "$BASE_REF" == main ]]')
  reject("CI must create the required validate check on the immutable target SHA")
end
unless fetch_key(finalize_job, "if").to_s.include?("always()") &&
    fetch_key(complete_check, "run").to_s.include?("-f conclusion=\"$conclusion\"") &&
    fetch_key(complete_check, "run").to_s.include?('"$POLICY_RESULT" == success') &&
    fetch_key(complete_check, "run").to_s.include?('"$TARGET_RESULT" == success')
  reject("CI must complete the required validate check on every job outcome")
end
unless fetch_key(target_job, "needs") == "trusted-policy"
  reject("CI target-owned build and tests must wait for trusted policy")
end
unless fetch_key(trusted_job, "needs") == "start-validation-check"
  reject("CI trusted policy must run after the required check is created")
end
if target_steps.any? { |step| fetch_key(fetch_key(step, "env"), "GH_TOKEN") } ||
    start_steps.any? { |step| fetch_key(step, "uses") } ||
    finalize_steps.any? { |step| fetch_key(step, "uses") }
  reject("CI must isolate PR-owned execution from privileged checks API steps")
end

reject("prepare-candidate.yml does not exist") unless File.file?(candidate_path)
candidate_source = File.read(candidate_path, encoding: "UTF-8")
begin
  candidate = YAML.safe_load(
    candidate_source,
    permitted_classes: [],
    permitted_symbols: [],
    aliases: true,
    filename: candidate_path
  ) || {}
rescue Psych::Exception => error
  reject("prepare-candidate.yml is invalid YAML: #{error.message}")
end

trigger = fetch_key(candidate, "on")
push = fetch_key(trigger, "push")
tags = fetch_key(push, "tags")
dispatch = fetch_key(trigger, "workflow_dispatch")
reject("prepare-candidate.yml must run for v* tags") unless tags == ["v*"]
reject("prepare-candidate.yml must provide a manual dry run") unless dispatch.is_a?(Hash)

candidate_permissions = fetch_key(candidate, "permissions")
unless fetch_key(candidate_permissions, "contents").to_s == "read"
  reject("prepare-candidate.yml must be read-only by default")
end
candidate_concurrency = fetch_key(candidate, "concurrency")
unless fetch_key(candidate_concurrency, "group").to_s == "update-${{ github.repository }}" &&
    fetch_key(candidate_concurrency, "cancel-in-progress") == false &&
    fetch_key(candidate_concurrency, "queue").to_s == "max"
  reject("prepare-candidate.yml must queue repository release attempts")
end

candidate_jobs = fetch_key(candidate, "jobs")
build_job = fetch_key(candidate_jobs, "build-test-package")
sign_job = fetch_key(candidate_jobs, "sign-candidate")
reject("prepare-candidate.yml must define build-test-package") unless build_job.is_a?(Hash)
reject("prepare-candidate.yml must define sign-candidate") unless sign_job.is_a?(Hash)
unless fetch_key(fetch_key(build_job, "permissions"), "contents").to_s == "read"
  reject("build-test-package must grant only contents: read")
end
reject("build-test-package must not use an Environment") unless fetch_key(build_job, "environment").nil?
unless fetch_key(sign_job, "environment").to_s == "release"
  reject("sign-candidate must use the release Environment")
end
unless fetch_key(fetch_key(sign_job, "permissions"), "contents").to_s == "write"
  reject("sign-candidate must grant contents: write")
end
sign_condition = fetch_key(sign_job, "if").to_s
expected_sign_condition = (
  "github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v') && " \
    "github.run_attempt == 1"
)
unless sign_condition == expected_sign_condition
  reject("manual dry runs and rerun tag pushes must not enter sign-candidate")
end

secret_references = candidate_source.scan(/\$\{\{[^}]*\bsecrets(?:\.|\[)[^}]*\}\}/m)
unless secret_references == ["${{ secrets.SPARKLE_ED_PRIVATE_KEY }}"]
  reject("prepare-candidate.yml must contain exactly one private-key secret reference")
end

sign_steps = fetch_key(sign_job, "steps")
reject("sign-candidate must contain steps") unless sign_steps.is_a?(Array)
build_steps = fetch_key(build_job, "steps")
reject("build-test-package must contain steps") unless build_steps.is_a?(Array)
candidate_local_actions = workflow_local_actions(candidate_jobs)
unless candidate_local_actions.empty?
  reject(
    "#{File.basename(candidate_path)} contains a repo-local action: " \
      "#{candidate_local_actions.first}"
  )
end
if workflow_runs(candidate_jobs).any? { |run| protected_tag_deletion?(run) }
  reject("prepare-candidate.yml must never delete a protected release tag")
end
build_validation = build_steps.map { |step| fetch_key(step, "run").to_s }
  .find { |run| run.include?("validate_release_tag") }.to_s
push_branch = build_validation.index('if [[ "$GITHUB_EVENT_NAME" == "push" ]]; then')
attempt_guard = build_validation.index('[[ "$GITHUB_RUN_ATTEMPT" == 1 ]]')
tag_validation = build_validation.index('validate_release_tag "$GITHUB_REF_NAME"')
unless push_branch && attempt_guard && tag_validation &&
    push_branch < attempt_guard && attempt_guard < tag_validation
  reject("tag push reruns must fail before release validation")
end
candidate_validation = sign_steps.map { |step| fetch_key(step, "run").to_s }
  .find { |run| run.include?("git merge-base --is-ancestor") }.to_s
candidate_tag_regex = candidate_validation.index(
  '[[ "$GITHUB_REF_NAME" =~ ^v[0-9]+\\.[0-9]+\\.[0-9]+$ ]]'
)
candidate_fetch_main = candidate_validation.index("/usr/bin/git fetch --no-tags origin main")
candidate_tag_commit = candidate_validation.index('tag_commit="$(/usr/bin/git rev-parse --verify')
candidate_sha_match = candidate_validation.index('[[ "$tag_commit" == "$GITHUB_SHA" ]]')
candidate_ancestor = candidate_validation.index("/usr/bin/git merge-base --is-ancestor")
candidate_source_index = candidate_validation.index("source script/lib/release_common.sh")
unless [candidate_tag_regex, candidate_fetch_main, candidate_tag_commit, candidate_sha_match,
    candidate_ancestor, candidate_source_index].all? &&
    [candidate_tag_regex, candidate_fetch_main, candidate_tag_commit, candidate_sha_match,
      candidate_ancestor].all? { |index| index < candidate_source_index }
  reject("sign-candidate must trust tag ancestry before executing tag code")
end
secret_step_indexes = []
sign_steps.each_with_index do |step, index|
  secret_step_indexes << index if secret_reference?(step)
end
unless secret_step_indexes.length == 1
  reject("sign-candidate must expose the private key in exactly one step")
end
secret_index = secret_step_indexes.first
secret_step = sign_steps.fetch(secret_index)
secret_run = fetch_key(secret_step, "run").to_s
secret_env = fetch_key(secret_step, "env")
expected_secret_env = {
  "SPARKLE_ED_PRIVATE_KEY" => "${{ secrets.SPARKLE_ED_PRIVATE_KEY }}"
}
expected_secret_run = <<~'SHELL'.strip
  set +x
  printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$RUNNER_TEMP/sparkle-tools/bin/generate_appcast" --maximum-versions 1 --download-url-prefix "$PRODUCTION_DOWNLOAD_URL_PREFIX" --ed-key-file - dist/prepared-parent/inputs/production
  printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$RUNNER_TEMP/sparkle-tools/bin/generate_appcast" --maximum-versions 1 --download-url-prefix "$QUALIFICATION_DOWNLOAD_URL_PREFIX" --ed-key-file - dist/prepared-parent/inputs/qualification
SHELL
unless fetch_key(secret_step, "shell").to_s == "bash" &&
  secret_env == expected_secret_env &&
  secret_run.strip == expected_secret_run
  reject("private-key step must match the approved signing template")
end

before_secret = sign_steps[0...secret_index].to_s
after_secret = sign_steps[(secret_index + 1)..].to_s
prepare_inputs = sign_steps.map { |step| fetch_key(step, "run").to_s }
  .find { |run| run.include?("prepare_appcast_inputs.sh") }.to_s
prepare_identity = prepare_inputs.index(
  'validate_release_identity_against_tags "$GITHUB_REF_NAME"'
)
prepare_feed_branch = prepare_inputs.index(
  "if git cat-file -e origin/main:appcast.xml"
)
unless prepare_identity && prepare_feed_branch && prepare_identity < prepare_feed_branch
  reject("every Candidate must validate burned tag identities before signing")
end
[
  "Sparkle-2.9.4.tar.xz",
  "ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9",
  "refs/tags/v*:refs/tags/v*",
  "validate_release_identity_against_tags",
  "prepare_appcast_inputs.sh",
  "production-download-url-prefix",
  "qualification-download-url-prefix"
].each do |snippet|
  reject("sign-candidate must prepare tools and inputs before secret exposure") unless before_secret.include?(snippet)
end
[
  "verify_update_artifacts.sh",
  "gh release create",
  "--draft",
  "gh release download",
  "/usr/bin/cmp",
  "Draft"
].each do |snippet|
  reject("sign-candidate must validate and preserve a Draft after signing") unless after_secret.include?(snippet)
end

all_uses = []
each_mapping(candidate) do |mapping|
  mapping.each { |key, value| all_uses << value.to_s if key.to_s == "uses" }
end
[
  "actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0",
  "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
  "actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c"
].each do |action|
  reject("prepare-candidate.yml lacks required pinned action: #{action}") unless all_uses.include?(action)
end

qualification_upload = sign_steps.find do |step|
  fetch_key(step, "uses").to_s == "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
end
qualification_with = fetch_key(qualification_upload, "with")
unless fetch_key(qualification_with, "retention-days") == 7 &&
  fetch_key(qualification_with, "name").to_s.include?("qualification")
  reject("qualification Artifact must be retained for seven days")
end

[
  "validate_release_tag",
  "origin/main",
  "merge-base --is-ancestor",
  "MARKETING_VERSION",
  "BUILD_NUMBER",
  "package_release.sh --output",
  "--signing-mode adhoc"
].each do |snippet|
  reject("prepare-candidate.yml lacks release validation: #{snippet}") unless candidate_source.include?(snippet)
end
if candidate_source.include?("--draft=false") || candidate_source.include?("--draft false")
  reject("prepare-candidate.yml must leave the Candidate Release as Draft")
end

reject("publish-update.yml does not exist") unless File.file?(publish_path)
publish_source = File.read(publish_path, encoding: "UTF-8")
begin
  publish = YAML.safe_load(
    publish_source,
    permitted_classes: [],
    permitted_symbols: [],
    aliases: true,
    filename: publish_path
  ) || {}
rescue Psych::Exception => error
  reject("publish-update.yml is invalid YAML: #{error.message}")
end

publish_trigger = fetch_key(publish, "on")
reject("publish-update.yml must only use workflow_dispatch") unless
  publish_trigger.is_a?(Hash) && publish_trigger.keys.map(&:to_s) == ["workflow_dispatch"]
dispatch_inputs = fetch_key(fetch_key(publish_trigger, "workflow_dispatch"), "inputs")
reject("publish-update.yml must define exactly one tag input") unless
  dispatch_inputs.is_a?(Hash) && dispatch_inputs.keys.map(&:to_s) == ["tag"]
tag_input = fetch_key(dispatch_inputs, "tag")
unless fetch_key(tag_input, "required") == true && fetch_key(tag_input, "type").to_s == "string"
  reject("publish-update.yml tag input must be a required string")
end
reject("publish-update.yml must not reference secrets") if secret_reference?(publish)

publish_permissions = fetch_key(publish, "permissions")
unless fetch_key(publish_permissions, "contents").to_s == "read"
  reject("publish-update.yml must be read-only by default")
end
publish_concurrency = fetch_key(publish, "concurrency")
unless fetch_key(publish_concurrency, "group").to_s == "update-${{ github.repository }}" &&
    fetch_key(publish_concurrency, "cancel-in-progress") == false &&
    fetch_key(publish_concurrency, "queue").to_s == "max"
  reject("publish-update.yml must queue repository release attempts")
end

publish_jobs = fetch_key(publish, "jobs")
verify_job = fetch_key(publish_jobs, "publish-and-verify")
activate_job = fetch_key(publish_jobs, "activate-production-feed")
reject("publish-update.yml must define publish-and-verify") unless verify_job.is_a?(Hash)
reject("publish-update.yml must define activate-production-feed") unless activate_job.is_a?(Hash)
publish_local_actions = workflow_local_actions(publish_jobs)
unless publish_local_actions.empty?
  reject(
    "#{File.basename(publish_path)} contains a repo-local action: " \
      "#{publish_local_actions.first}"
  )
end
publish_job_runs = workflow_runs(publish_jobs)
if publish_job_runs.any? { |run| protected_tag_deletion?(run) }
  reject("publish-update.yml must never delete a protected release tag")
end
unless fetch_key(fetch_key(verify_job, "permissions"), "contents").to_s == "write"
  reject("publish-and-verify must grant contents: write")
end
unless fetch_key(fetch_key(activate_job, "permissions"), "contents").to_s == "write"
  reject("activate-production-feed must grant contents: write")
end
if fetch_key(fetch_key(activate_job, "permissions"), "pull-requests") ||
    fetch_key(fetch_key(activate_job, "permissions"), "actions")
  reject("activate-production-feed must not create PRs or dispatch workflows")
end
unless fetch_key(activate_job, "needs").to_s == "publish-and-verify"
  reject("feed activation must depend on public verification")
end

publish_steps = fetch_key(verify_job, "steps")
activate_steps = fetch_key(activate_job, "steps")
reject("publish-and-verify must contain steps") unless publish_steps.is_a?(Array)
reject("activate-production-feed must contain steps") unless activate_steps.is_a?(Array)
publish_run = publish_steps.map { |step| fetch_key(step, "run").to_s }.join("\n")
activate_run = activate_steps.map { |step| fetch_key(step, "run").to_s }.join("\n")
if activate_run.gsub(/\\\r?\n/, " ").match?(/\bgh\s+release\s+delete\b/)
  reject("feed activation must never delete a public Release or tag")
end
publish_checkout = publish_steps.find do |step|
  fetch_key(step, "uses").to_s ==
    "actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0"
end
activate_checkout = activate_steps.find do |step|
  fetch_key(step, "uses").to_s ==
    "actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0"
end
unless fetch_key(fetch_key(publish_checkout, "with"), "ref").to_s == "main"
  reject("publish job must initially check out trusted main")
end
unless fetch_key(fetch_key(activate_checkout, "with"), "ref").to_s == "main"
  reject("activation job must initially check out trusted main")
end

publish_validation = publish_steps.map { |step| fetch_key(step, "run").to_s }
  .find { |run| run.include?("tag_commit=") }.to_s
publish_ancestor = publish_validation.index("git merge-base --is-ancestor")
publish_checkout_tag = publish_validation.index("git checkout --detach")
publish_source = publish_validation.index("source script/lib/release_common.sh")
publish_tag_regex = publish_validation.index('[[ "$TAG" =~ ^v[0-9]+\\.[0-9]+\\.[0-9]+$ ]]')
unless [publish_tag_regex, publish_ancestor, publish_checkout_tag, publish_source].all? &&
    publish_tag_regex < publish_ancestor && publish_ancestor < publish_checkout_tag &&
    publish_checkout_tag < publish_source
  reject("publish job must trust tag ancestry before executing tag code")
end

activate_validation_index = activate_steps.index do |step|
  fetch_key(step, "run").to_s.include?("tag_commit=")
end
activate_validation = fetch_key(activate_steps.fetch(activate_validation_index), "run").to_s
activate_ancestor = activate_validation.index("git merge-base --is-ancestor")
activate_release = activate_validation.index("gh release view \"$TAG\"")
activate_integrity = activate_validation.index("gh release verify \"$TAG\"")
activate_checkout_tag = activate_validation.index("git checkout --detach")
activate_tag_regex = activate_validation.index('[[ "$TAG" =~ ^v[0-9]+\\.[0-9]+\\.[0-9]+$ ]]')
activate_source_index = activate_steps.index do |step|
  fetch_key(step, "run").to_s.include?("source script/lib/release_common.sh")
end
unless [activate_tag_regex, activate_ancestor, activate_release, activate_integrity,
    activate_checkout_tag, activate_source_index].all? &&
    activate_tag_regex < activate_ancestor &&
    [activate_ancestor, activate_release, activate_integrity].all? { |index| index < activate_checkout_tag } &&
    activate_validation_index < activate_source_index
  reject("activation job must trust the public Release and tag before executing tag code")
end

[
  "validate_release_tag \"$TAG\"",
  "git merge-base --is-ancestor",
  "gh release view \"$TAG\"",
  "isDraft",
  "targetCommitish",
  "gh release download \"$TAG\"",
  "--pattern",
  "verify_update_artifacts.sh",
  "gh release edit \"$TAG\" --draft=false --prerelease",
  "releases/download/$TAG",
  "gh release verify \"$TAG\"",
  "release_is_draft=",
  "gh release delete \"$TAG\" --yes"
].each do |snippet|
  reject("publish-update.yml lacks publish verification: #{snippet}") unless publish_run.include?(snippet)
end
draft_download = publish_run.index("gh release download \"$TAG\"")
draft_verify = publish_run.index("verify_update_artifacts.sh")
publish_release = publish_run.index("gh release edit \"$TAG\" --draft=false --prerelease")
public_download = publish_run.index("releases/download/$TAG")
public_verify = publish_run.rindex("verify_update_artifacts.sh")
unless [draft_download, draft_verify, publish_release, public_download, public_verify].all? &&
    draft_download < draft_verify && draft_verify < publish_release &&
    publish_release < public_download && public_download < public_verify
  reject("publish-update.yml must verify Draft and public bytes in order")
end
activation_upload = publish_steps.index do |step|
  fetch_key(step, "uses").to_s ==
    "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"
end
reject("publish-update.yml must upload activation inputs") unless activation_upload
activation_upload_step = publish_steps.fetch(activation_upload)
unless fetch_key(fetch_key(activation_upload_step, "with"), "overwrite") == true
  reject("activation input upload must overwrite a prior retry artifact")
end
unless activation_upload && activation_upload < publish_steps.index { |step|
  fetch_key(step, "run").to_s.include?("gh release edit \"$TAG\" --draft=false --prerelease")
}
  reject("activation inputs must upload while the Release is still Draft")
end

[
  "--mode cas",
  "--current-feed",
  "--current-absent",
  "--expected-previous-feed",
  "--expected-previous-absent",
  "cas_state=already-active",
  "cas_state=ready-bootstrap",
  "cas_state=ready",
  "current_blob_sha",
  'sha:$sha',
  'branch="release/appcast-$TAG-at-$main_short_sha"',
  "repos/$GITHUB_REPOSITORY/git/refs",
  'contents/appcast.xml?ref=$main_sha',
  "compare/main...$branch",
  '.files | length == 1 and .[0].filename == "appcast.xml"',
  'https://github.com/$GITHUB_REPOSITORY/compare/main...$branch?expand=1',
  "Production Feed activation PR",
  "409",
  "422",
  "releases?per_page=100",
  "releases/download/$TAG",
  "--mode published",
  "gh release verify \"$TAG\"",
  "Activation Pending",
  "raw.githubusercontent.com/tangwz/codex-radar/main/appcast.xml",
  "unknown Production Feed bytes"
].each do |snippet|
  reject("publish-update.yml lacks feed activation policy: #{snippet}") unless activate_run.include?(snippet)
end
fixed_bootstrap_guard = '[[ "$MARKETING_VERSION" == 0.1.0 && "$BUILD_NUMBER" == 1 ]]'
if publish_run.include?(fixed_bootstrap_guard) || activate_run.include?(fixed_bootstrap_guard)
  reject("bootstrap eligibility must depend on repository state, not a fixed version")
end
if activate_run.include?('branch:"main"')
  reject("feed activation must not write appcast.xml directly to main")
end
if activate_run.include?("repos/$GITHUB_REPOSITORY/pulls") ||
    activate_run.include?("gh workflow run")
  reject("feed activation must leave PR creation to the operator")
end
if activate_run.include?("gh release delete") || activate_run.include?("git push --delete")
  reject("feed activation must never delete a public Release or tag")
end
if publish_run.include?("ditto -x") || activate_run.include?("ditto -x")
  reject("publish workflow must not extract an archive before Ed25519 verification")
end

publish_uses = []
each_mapping(publish) do |mapping|
  mapping.each { |key, value| publish_uses << value.to_s if key.to_s == "uses" }
end
[
  "actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0",
  "actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
  "actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c"
].each do |action|
  reject("publish-update.yml lacks required pinned action: #{action}") unless publish_uses.include?(action)
end

reject("docs/releasing.md does not exist") unless File.file?(releasing_path)
releasing = File.read(releasing_path, encoding: "UTF-8")
[
  "./bin/generate_keys --account com.terence.codex-radar -p",
  "gh secret set SPARKLE_ED_PRIVATE_KEY --env release",
  "mktemp -d",
  "chmod 600",
  "trap",
  "best-effort",
  "encrypted offline backup",
  "burned",
  "bootstrap 0.1.0 (1)",
  "首装引导验收",
  "Protect immutable release tags",
  "gh release delete v0.2.0 --yes",
  "identity reservation",
  "--cleanup-tag",
  "git push --delete",
  "v<MARKETING_VERSION>",
  "README.md",
  "Production Feed activation PR",
  "Codex agent review"
].each do |snippet|
  reject("docs/releasing.md lacks required guidance: #{snippet}") unless releasing.include?(snippet)
end

checksum_index = ci.index("shasum -a 256 -c -")
extract_index = ci.index("tar -xzf")
if checksum_index.nil? || extract_index.nil? || checksum_index > extract_index
  reject("ci.yml must verify actionlint before extraction")
end

reject("CODEOWNERS does not exist") unless File.file?(codeowners_path)
expected_owners = [
  "/.github/workflows/ @tangwz",
  "/script/ @tangwz",
  "/config/update.env @tangwz",
  "/appcast.xml @tangwz"
]
actual_owners = File.readlines(codeowners_path, chomp: true, encoding: "UTF-8")
  .map(&:strip)
  .reject { |line| line.empty? || line.start_with?("#") }
reject("CODEOWNERS does not protect update supply-chain files") unless actual_owners == expected_owners
RUBY
}

expect_failure() {
  local expected_message="$1"
  shift
  local output_path="$fixture_root/failure-output"

  if "$@" >"$output_path" 2>&1; then
    fail "fixture unexpectedly succeeded: $expected_message"
  fi
  /usr/bin/grep -F "$expected_message" "$output_path" >/dev/null || {
    /bin/cat "$output_path" >&2
    fail "fixture did not report: $expected_message"
  }
}

expect_failure "invalid activation PR branch" \
  /usr/bin/env ACTIVATION_REF=release/appcast-vinvalid "$ACTIVATION_PR_VERIFY_SCRIPT"

activation_remote="$fixture_root/activation-policy-remote.git"
activation_target="$fixture_root/activation-policy-target"
git init --bare --initial-branch=main "$activation_remote" >/dev/null
git clone "$activation_remote" "$activation_target" >/dev/null
git -C "$activation_target" config user.name "Codex Radar Tests"
git -C "$activation_target" config user.email "tests@codex-radar.invalid"
printf '%s\n' "initial" >"$activation_target/README.md"
printf '%s\n' "previous feed" >"$activation_target/appcast.xml"
git -C "$activation_target" add README.md appcast.xml
git -C "$activation_target" commit -m "Add initial policy fixture" >/dev/null
git -C "$activation_target" push origin main >/dev/null
/usr/bin/env \
  ACTIVATION_REF=feature/example \
  ACTIVATION_TARGET_DIR="$activation_target" \
  "$ACTIVATION_PR_VERIFY_SCRIPT"
git -C "$activation_target" switch -c feature/appcast >/dev/null
printf '%s\n' "mutated feed" >"$activation_target/appcast.xml"
git -C "$activation_target" add appcast.xml
git -C "$activation_target" commit -m "Mutate feed outside activation policy" >/dev/null
expect_failure "appcast.xml may only change through a Production Feed activation PR" \
  /usr/bin/env \
    ACTIVATION_REF=feature/appcast \
    ACTIVATION_TARGET_DIR="$activation_target" \
    "$ACTIVATION_PR_VERIFY_SCRIPT"

git -C "$activation_target" reset --hard origin/main >/dev/null
git -C "$activation_target" mv appcast.xml archived.xml
git -C "$activation_target" commit -m "Rename feed outside activation policy" >/dev/null
expect_failure "appcast.xml may only change through a Production Feed activation PR" \
  /usr/bin/env \
    ACTIVATION_REF=feature/renamed-appcast \
    ACTIVATION_TARGET_DIR="$activation_target" \
    "$ACTIVATION_PR_VERIFY_SCRIPT"

for required_activation_verifier_text in \
  'rev-list --count' \
  'diff --no-renames --name-only' \
  'gh release verify "$tag"' \
  'verify_update_artifacts.sh' \
  '--feed "$target_dir/appcast.xml"' \
  '--mode published' \
  '--mode previous' \
  'origin/main:appcast.xml'; do
  /usr/bin/grep -F -- "$required_activation_verifier_text" \
    "$ACTIVATION_PR_VERIFY_SCRIPT" >/dev/null ||
    fail "verify_activation_pr.sh lacks required policy: $required_activation_verifier_text"
done
if /usr/bin/grep -F \
  '[[ "$MARKETING_VERSION" == 0.1.0 && "$BUILD_NUMBER" == 1 ]]' \
  "$ACTIVATION_PR_VERIFY_SCRIPT" >/dev/null; then
  fail "verify_activation_pr.sh must not restore a fixed bootstrap identity"
fi

expect_failure "usage:" "$HALT_SCRIPT"
expect_failure "usage:" "$HALT_SCRIPT" --previous-commit
expect_failure "previous commit must be a full Git commit SHA" \
  "$HALT_SCRIPT" --previous-commit not-a-commit

/usr/bin/python3 - "$README_FILE" <<'PYTHON'
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text()
zip_links = re.findall(
    r"releases/download/(v[0-9]+\.[0-9]+\.[0-9]+)/"
    r"(CodexRadar-v([0-9]+\.[0-9]+\.[0-9]+)-macos-universal\.zip)(?=>)",
    source,
)
checksum_links = re.findall(
    r"releases/download/(v[0-9]+\.[0-9]+\.[0-9]+)/"
    r"(CodexRadar-v([0-9]+\.[0-9]+\.[0-9]+)-macos-universal\.zip\.sha256)(?=>)",
    source,
)
if not zip_links and not checksum_links:
    if "当前尚无可下载的公开 Release。" not in source:
        raise SystemExit("README.md must identify the last public Release or state that none exists")
elif len(zip_links) != 1 or len(checksum_links) != 1:
    raise SystemExit("README.md must contain one immutable ZIP/checksum pair")
else:
    zip_tag, zip_name, zip_version = zip_links[0]
    checksum_tag, checksum_name, checksum_version = checksum_links[0]
    if not (
        zip_tag == checksum_tag == f"v{zip_version}"
        and zip_version == checksum_version
        and checksum_name == f"{zip_name}.sha256"
        and f"shasum -a 256 --check {checksum_name}" in source
    ):
        raise SystemExit("README.md immutable install links are inconsistent")
PYTHON
for required_readme_text in \
  'ad-hoc' \
  'Open Anyway'; do
  /usr/bin/grep -F "$required_readme_text" "$README_FILE" >/dev/null ||
    fail "README.md lacks first-install guidance: $required_readme_text"
done
for required_releasing_text in \
  'script/halt_distribution.sh --previous-commit' \
  'Distribution Halt Pending' \
  'already-halted' \
  '同一个 `--previous-commit`' \
  'commits?sha=main&path=appcast.xml&per_page=1' \
  'intervening Production Feed' \
  'already-upgraded installations are not downgraded' \
  'Acceptance status: Pending | Passed' \
  'appcast.xml'; do
  /usr/bin/grep -F "$required_releasing_text" "$RELEASING_DOC" >/dev/null ||
    fail "docs/releasing.md lacks halt or acceptance guidance: $required_releasing_text"
done

validate_workflow_policy

yaml_policy_dir="$fixture_root/workflow-policy-yaml"
/bin/mkdir -p "$yaml_policy_dir/workflows"
/bin/cp "$CI_WORKFLOW" "$yaml_policy_dir/workflows/ci.yml"
/bin/cp "$CODEOWNERS_FILE" "$yaml_policy_dir/CODEOWNERS"
{
  printf '%s\n' 'name: Unpinned YAML fixture'
  printf '%s\n' 'on: push'
  printf '%s\n' 'permissions: { contents: read }'
  printf '%s\n' 'concurrency:' '  group: fixture' '  cancel-in-progress: true'
  printf '%s\n' 'jobs:' '  validate:' '    runs-on: macos-15' '    steps:'
  printf '%s\n' '      - uses: actions/checkout@v4'
} >"$yaml_policy_dir/workflows/unpinned.yaml"
expect_failure "unpinned.yaml contains an unpinned action" validate_workflow_policy \
  "$yaml_policy_dir/workflows" "$yaml_policy_dir/workflows/ci.yml" "$yaml_policy_dir/CODEOWNERS"

quoted_permission_dir="$fixture_root/workflow-policy-quoted-permission"
/bin/mkdir -p "$quoted_permission_dir/workflows"
/bin/cp "$CI_WORKFLOW" "$quoted_permission_dir/workflows/ci.yml"
/bin/cp "$CODEOWNERS_FILE" "$quoted_permission_dir/CODEOWNERS"
{
  printf '%s\n' 'name: Quoted permission fixture' 'on: push'
  printf '%s\n' 'permissions:' '  contents: "write"'
  printf '%s\n' 'concurrency:' '  group: fixture' '  cancel-in-progress: true'
  printf '%s\n' 'jobs: {}'
} >"$quoted_permission_dir/workflows/quoted-write.yml"
expect_failure "quoted-write.yml grants global contents: write" validate_workflow_policy \
  "$quoted_permission_dir/workflows" "$quoted_permission_dir/workflows/ci.yml" "$quoted_permission_dir/CODEOWNERS"

bracket_secret_dir="$fixture_root/workflow-policy-bracket-secret"
/bin/mkdir -p "$bracket_secret_dir/workflows"
/bin/cp "$CI_WORKFLOW" "$bracket_secret_dir/workflows/ci.yml"
/bin/cp "$CODEOWNERS_FILE" "$bracket_secret_dir/CODEOWNERS"
{
  printf '%s\n' 'name: Bracket secret fixture' 'on: push' 'permissions: {}'
  printf '%s\n' 'concurrency:' '  group: fixture' '  cancel-in-progress: true'
  printf '%s\n' 'jobs:' '  validate:' '    runs-on: macos-15' '    env:'
  printf '%s\n' '      TOKEN: ${{ secrets['"'"'TOKEN'"'"'] }}'
} >"$bracket_secret_dir/workflows/bracket-secret.yml"
expect_failure "bracket-secret.yml references a secret outside sign-candidate" validate_workflow_policy \
  "$bracket_secret_dir/workflows" "$bracket_secret_dir/workflows/ci.yml" "$bracket_secret_dir/CODEOWNERS"

inherited_secret_dir="$fixture_root/workflow-policy-inherited-secret"
/bin/mkdir -p "$inherited_secret_dir/workflows"
/bin/cp "$CI_WORKFLOW" "$inherited_secret_dir/workflows/ci.yml"
/bin/cp "$CODEOWNERS_FILE" "$inherited_secret_dir/CODEOWNERS"
{
  printf '%s\n' 'name: Inherited secret fixture' 'on: push' 'permissions: {}'
  printf '%s\n' 'concurrency:' '  group: fixture' '  cancel-in-progress: true'
  printf '%s\n' 'jobs:' '  publish:' '    uses: ./.github/workflows/reusable.yml' '    secrets: inherit'
} >"$inherited_secret_dir/workflows/inherited-secret.yml"
expect_failure "inherited-secret.yml references a secret outside sign-candidate" validate_workflow_policy \
  "$inherited_secret_dir/workflows" "$inherited_secret_dir/workflows/ci.yml" "$inherited_secret_dir/CODEOWNERS"

wrong_action_dir="$fixture_root/workflow-policy-wrong-action-revision"
/bin/mkdir -p "$wrong_action_dir/workflows"
/bin/cp "$CI_WORKFLOW" "$wrong_action_dir/workflows/ci.yml"
/bin/cp "$CODEOWNERS_FILE" "$wrong_action_dir/CODEOWNERS"
{
  printf '%s\n' 'name: Wrong action revision fixture' 'on: push' 'permissions: {}'
  printf '%s\n' 'concurrency:' '  group: fixture' '  cancel-in-progress: true'
  printf '%s\n' 'jobs:' '  validate:' '    runs-on: macos-15' '    steps:'
  printf '%s\n' '      - uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0'
  printf '%s\n' '      - uses: actions/checkout@0000000000000000000000000000000000000000'
} >"$wrong_action_dir/workflows/wrong-action.yml"
expect_failure "wrong-action.yml uses an unapproved action revision" validate_workflow_policy \
  "$wrong_action_dir/workflows" "$wrong_action_dir/workflows/ci.yml" "$wrong_action_dir/CODEOWNERS"

leaking_candidate="$fixture_root/prepare-candidate-leaking.yml"
/usr/bin/python3 - "$CANDIDATE_WORKFLOW" "$leaking_candidate" <<'PYTHON'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
marker = "          set +x\n"
if source.count(marker) != 1:
    raise SystemExit("candidate signing marker is missing or ambiguous")
pathlib.Path(sys.argv[2]).write_text(source.replace(marker, marker + "          env\n"))
PYTHON
expect_failure "private-key step must match the approved signing template" validate_workflow_policy \
  "$WORKFLOW_DIR" "$CI_WORKFLOW" "$CODEOWNERS_FILE" "$leaking_candidate" "$RELEASING_DOC"

publish_secret="$fixture_root/publish-secret.yml"
/usr/bin/python3 - "$PUBLISH_WORKFLOW" "$publish_secret" <<'PYTHON'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
marker = "permissions:\n  contents: read\n"
if source.count(marker) != 1:
    raise SystemExit("publish permissions marker is missing or ambiguous")
pathlib.Path(sys.argv[2]).write_text(
    source.replace(marker, marker + "env:\n  LEAK: ${{ secrets.SPARKLE_ED_PRIVATE_KEY }}\n")
)
PYTHON
expect_failure "publish-update.yml must not reference secrets" validate_workflow_policy \
  "$WORKFLOW_DIR" "$CI_WORKFLOW" "$CODEOWNERS_FILE" "$CANDIDATE_WORKFLOW" \
  "$RELEASING_DOC" "$publish_secret"

publish_extra_input="$fixture_root/publish-extra-input.yml"
/usr/bin/python3 - "$PUBLISH_WORKFLOW" "$publish_extra_input" <<'PYTHON'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
marker = "      tag:\n"
if source.count(marker) != 1:
    raise SystemExit("publish tag marker is missing or ambiguous")
replacement = "      confirmation:\n        required: true\n        type: string\n" + marker
pathlib.Path(sys.argv[2]).write_text(source.replace(marker, replacement))
PYTHON
expect_failure "publish-update.yml must define exactly one tag input" validate_workflow_policy \
  "$WORKFLOW_DIR" "$CI_WORKFLOW" "$CODEOWNERS_FILE" "$CANDIDATE_WORKFLOW" \
  "$RELEASING_DOC" "$publish_extra_input"

publish_without_draft_download="$fixture_root/publish-without-draft-download.yml"
/usr/bin/python3 - "$PUBLISH_WORKFLOW" "$publish_without_draft_download" <<'PYTHON'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
needle = 'gh release download "$TAG"'
if source.count(needle) != 1:
    raise SystemExit("Draft download marker is missing or ambiguous")
pathlib.Path(sys.argv[2]).write_text(source.replace(needle, 'echo "Draft download disabled"'))
PYTHON
expect_failure 'publish-update.yml lacks publish verification: gh release download "$TAG"' \
  validate_workflow_policy "$WORKFLOW_DIR" "$CI_WORKFLOW" "$CODEOWNERS_FILE" \
  "$CANDIDATE_WORKFLOW" "$RELEASING_DOC" "$publish_without_draft_download"

publish_with_cleanup_tag="$fixture_root/publish-with-cleanup-tag.yml"
/usr/bin/python3 - "$PUBLISH_WORKFLOW" "$publish_with_cleanup_tag" <<'PYTHON'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
needle = 'gh release delete "$TAG" --yes'
if source.count(needle) != 1:
    raise SystemExit("Release-only cleanup marker is missing or ambiguous")
pathlib.Path(sys.argv[2]).write_text(
    source.replace(needle, needle + " --cleanup-tag")
)
PYTHON
expect_failure "publish-update.yml must never delete a protected release tag" \
  validate_workflow_policy "$WORKFLOW_DIR" "$CI_WORKFLOW" "$CODEOWNERS_FILE" \
  "$CANDIDATE_WORKFLOW" "$RELEASING_DOC" "$publish_with_cleanup_tag"

publish_with_tag_push_delete="$fixture_root/publish-with-tag-push-delete.yml"
/usr/bin/python3 - "$PUBLISH_WORKFLOW" "$publish_with_tag_push_delete" <<'PYTHON'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
needle = 'gh release delete "$TAG" --yes'
if source.count(needle) != 1:
    raise SystemExit("Release-only cleanup marker is missing or ambiguous")
replacement = needle + '\n                git push origin --delete "$TAG"'
pathlib.Path(sys.argv[2]).write_text(source.replace(needle, replacement))
PYTHON
expect_failure "publish-update.yml must never delete a protected release tag" \
  validate_workflow_policy "$WORKFLOW_DIR" "$CI_WORKFLOW" "$CODEOWNERS_FILE" \
  "$CANDIDATE_WORKFLOW" "$RELEASING_DOC" "$publish_with_tag_push_delete"

publish_with_continued_short_tag_push_delete="$fixture_root/publish-with-continued-short-tag-push-delete.yml"
/usr/bin/python3 - "$PUBLISH_WORKFLOW" "$publish_with_continued_short_tag_push_delete" <<'PYTHON'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
needle = 'gh release delete "$TAG" --yes'
if source.count(needle) != 1:
    raise SystemExit("Release-only cleanup marker is missing or ambiguous")
replacement = (
    needle
    + '\n                git push \\'
    + '\n                  origin -d "$TAG"'
)
pathlib.Path(sys.argv[2]).write_text(source.replace(needle, replacement))
PYTHON
expect_failure "publish-update.yml must never delete a protected release tag" \
  validate_workflow_policy "$WORKFLOW_DIR" "$CI_WORKFLOW" "$CODEOWNERS_FILE" \
  "$CANDIDATE_WORKFLOW" "$RELEASING_DOC" \
  "$publish_with_continued_short_tag_push_delete"

publish_with_forced_tag_delete_refspec="$fixture_root/publish-with-forced-tag-delete-refspec.yml"
/usr/bin/python3 - "$PUBLISH_WORKFLOW" "$publish_with_forced_tag_delete_refspec" <<'PYTHON'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
needle = 'gh release delete "$TAG" --yes'
if source.count(needle) != 1:
    raise SystemExit("Release-only cleanup marker is missing or ambiguous")
replacement = needle + '\n                git push origin +:refs/tags/$TAG'
pathlib.Path(sys.argv[2]).write_text(source.replace(needle, replacement))
PYTHON
expect_failure "publish-update.yml must never delete a protected release tag" \
  validate_workflow_policy "$WORKFLOW_DIR" "$CI_WORKFLOW" "$CODEOWNERS_FILE" \
  "$CANDIDATE_WORKFLOW" "$RELEASING_DOC" \
  "$publish_with_forced_tag_delete_refspec"

publish_with_shorthand_tag_delete_refspec="$fixture_root/publish-with-shorthand-tag-delete-refspec.yml"
/usr/bin/python3 - "$PUBLISH_WORKFLOW" "$publish_with_shorthand_tag_delete_refspec" <<'PYTHON'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
needle = 'gh release delete "$TAG" --yes'
if source.count(needle) != 1:
    raise SystemExit("Release-only cleanup marker is missing or ambiguous")
replacement = needle + "\n                git push origin :v0.2.0"
pathlib.Path(sys.argv[2]).write_text(source.replace(needle, replacement))
PYTHON
expect_failure "publish-update.yml must never delete a protected release tag" \
  validate_workflow_policy "$WORKFLOW_DIR" "$CI_WORKFLOW" "$CODEOWNERS_FILE" \
  "$CANDIDATE_WORKFLOW" "$RELEASING_DOC" \
  "$publish_with_shorthand_tag_delete_refspec"

publish_with_tag_prune="$fixture_root/publish-with-tag-prune.yml"
/usr/bin/python3 - "$PUBLISH_WORKFLOW" "$publish_with_tag_prune" <<'PYTHON'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
needle = 'gh release delete "$TAG" --yes'
if source.count(needle) != 1:
    raise SystemExit("Release-only cleanup marker is missing or ambiguous")
replacement = needle + "\n                git push --prune origin 'refs/tags/*:refs/tags/*'"
pathlib.Path(sys.argv[2]).write_text(source.replace(needle, replacement))
PYTHON
expect_failure "publish-update.yml must never delete a protected release tag" \
  validate_workflow_policy "$WORKFLOW_DIR" "$CI_WORKFLOW" "$CODEOWNERS_FILE" \
  "$CANDIDATE_WORKFLOW" "$RELEASING_DOC" "$publish_with_tag_prune"

publish_with_pruned_tags="$fixture_root/publish-with-pruned-tags.yml"
/usr/bin/python3 - "$PUBLISH_WORKFLOW" "$publish_with_pruned_tags" <<'PYTHON'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
needle = 'gh release delete "$TAG" --yes'
if source.count(needle) != 1:
    raise SystemExit("Release-only cleanup marker is missing or ambiguous")
replacement = needle + "\n                git push --prune --tags origin"
pathlib.Path(sys.argv[2]).write_text(source.replace(needle, replacement))
PYTHON
expect_failure "publish-update.yml must never delete a protected release tag" \
  validate_workflow_policy "$WORKFLOW_DIR" "$CI_WORKFLOW" "$CODEOWNERS_FILE" \
  "$CANDIDATE_WORKFLOW" "$RELEASING_DOC" "$publish_with_pruned_tags"

publish_with_tag_mirror="$fixture_root/publish-with-tag-mirror.yml"
/usr/bin/python3 - "$PUBLISH_WORKFLOW" "$publish_with_tag_mirror" <<'PYTHON'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
needle = 'gh release delete "$TAG" --yes'
if source.count(needle) != 1:
    raise SystemExit("Release-only cleanup marker is missing or ambiguous")
replacement = needle + '\n                git tag -d "$TAG"\n                git push --mirror origin'
pathlib.Path(sys.argv[2]).write_text(source.replace(needle, replacement))
PYTHON
expect_failure "publish-update.yml must never delete a protected release tag" \
  validate_workflow_policy "$WORKFLOW_DIR" "$CI_WORKFLOW" "$CODEOWNERS_FILE" \
  "$CANDIDATE_WORKFLOW" "$RELEASING_DOC" "$publish_with_tag_mirror"

publish_with_continued_tag_mirror="$fixture_root/publish-with-continued-tag-mirror.yml"
/usr/bin/python3 - "$PUBLISH_WORKFLOW" "$publish_with_continued_tag_mirror" <<'PYTHON'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
needle = 'gh release delete "$TAG" --yes'
if source.count(needle) != 1:
    raise SystemExit("Release-only cleanup marker is missing or ambiguous")
replacement = (
    needle
    + '\n                git tag -d "$TAG"'
    + '\n                git push \\'
    + '\n                  --mirror origin'
)
pathlib.Path(sys.argv[2]).write_text(source.replace(needle, replacement))
PYTHON
expect_failure "publish-update.yml must never delete a protected release tag" \
  validate_workflow_policy "$WORKFLOW_DIR" "$CI_WORKFLOW" "$CODEOWNERS_FILE" \
  "$CANDIDATE_WORKFLOW" "$RELEASING_DOC" "$publish_with_continued_tag_mirror"

publish_with_curl_tag_delete="$fixture_root/publish-with-curl-tag-delete.yml"
/usr/bin/python3 - "$PUBLISH_WORKFLOW" "$publish_with_curl_tag_delete" <<'PYTHON'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
needle = 'gh release delete "$TAG" --yes'
if source.count(needle) != 1:
    raise SystemExit("Release-only cleanup marker is missing or ambiguous")
replacement = (
    needle
    + '\n                curl \\'
    + '\n                  --request DELETE \\'
    + '\n                  "https://api.github.com/repos/$GITHUB_REPOSITORY/git/refs/tags/$TAG"'
)
pathlib.Path(sys.argv[2]).write_text(source.replace(needle, replacement))
PYTHON
expect_failure "publish-update.yml must never delete a protected release tag" \
  validate_workflow_policy "$WORKFLOW_DIR" "$CI_WORKFLOW" "$CODEOWNERS_FILE" \
  "$CANDIDATE_WORKFLOW" "$RELEASING_DOC" "$publish_with_curl_tag_delete"

publish_with_activation_tag_delete_refspec="$fixture_root/publish-with-activation-tag-delete-refspec.yml"
/usr/bin/python3 - "$PUBLISH_WORKFLOW" "$publish_with_activation_tag_delete_refspec" <<'PYTHON'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
marker = (
    "      - name: Validate public Release and tag ancestry\n"
    "        shell: bash\n"
    "        run: |\n"
    "          set -euo pipefail\n"
)
if source.count(marker) != 1:
    raise SystemExit("Activation validation marker is missing or ambiguous")
replacement = (
    marker
    + "          git push origin \\"
    + '\n            :refs/tags/"$TAG"\n'
)
pathlib.Path(sys.argv[2]).write_text(source.replace(marker, replacement))
PYTHON
expect_failure "publish-update.yml must never delete a protected release tag" \
  validate_workflow_policy "$WORKFLOW_DIR" "$CI_WORKFLOW" "$CODEOWNERS_FILE" \
  "$CANDIDATE_WORKFLOW" "$RELEASING_DOC" \
  "$publish_with_activation_tag_delete_refspec"

publish_with_activation_release_delete="$fixture_root/publish-with-activation-release-delete.yml"
/usr/bin/python3 - "$PUBLISH_WORKFLOW" "$publish_with_activation_release_delete" <<'PYTHON'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
marker = (
    "      - name: Validate public Release and tag ancestry\n"
    "        shell: bash\n"
    "        run: |\n"
    "          set -euo pipefail\n"
)
if source.count(marker) != 1:
    raise SystemExit("Activation validation marker is missing or ambiguous")
replacement = marker + '          gh release delete "$TAG" --yes\n'
pathlib.Path(sys.argv[2]).write_text(source.replace(marker, replacement))
PYTHON
expect_failure "feed activation must never delete a public Release or tag" \
  validate_workflow_policy "$WORKFLOW_DIR" "$CI_WORKFLOW" "$CODEOWNERS_FILE" \
  "$CANDIDATE_WORKFLOW" "$RELEASING_DOC" \
  "$publish_with_activation_release_delete"

publish_with_tag_api_method_delete="$fixture_root/publish-with-tag-api-method-delete.yml"
publish_with_tag_api_method_equals_delete="$fixture_root/publish-with-tag-api-method-equals-delete.yml"
publish_with_tag_api_short_delete="$fixture_root/publish-with-tag-api-short-delete.yml"
publish_with_tag_api_compact_short_delete="$fixture_root/publish-with-tag-api-compact-short-delete.yml"
/usr/bin/python3 - "$PUBLISH_WORKFLOW" \
  "$publish_with_tag_api_method_delete" \
  "$publish_with_tag_api_method_equals_delete" \
  "$publish_with_tag_api_short_delete" \
  "$publish_with_tag_api_compact_short_delete" <<'PYTHON'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
methods = (
    ("--method", "DELETE"),
    ("--method=DELETE",),
    ("-X", "DELETE"),
    ("-XDELETE",),
)
for path, method in zip(sys.argv[2:], methods):
    command_lines = ["          gh api \\"]
    command_lines.extend(f"            {argument} \\" for argument in method)
    command_lines.append(
        '            "repos/$GITHUB_REPOSITORY/git/refs/tags/$TAG"'
    )
    job = "\n".join(
        (
            "",
            "  adversarial-tag-api-delete:",
            "    runs-on: macos-15",
            "    steps:",
            "      - name: Delete protected tag through API",
            "        shell: bash",
            "        run: |",
            *command_lines,
            "",
        )
    )
    pathlib.Path(path).write_text(source + job)
PYTHON
for publish_with_tag_api_delete in \
  "$publish_with_tag_api_method_delete" \
  "$publish_with_tag_api_method_equals_delete" \
  "$publish_with_tag_api_short_delete" \
  "$publish_with_tag_api_compact_short_delete"; do
  expect_failure "publish-update.yml must never delete a protected release tag" \
    validate_workflow_policy "$WORKFLOW_DIR" "$CI_WORKFLOW" "$CODEOWNERS_FILE" \
    "$CANDIDATE_WORKFLOW" "$RELEASING_DOC" "$publish_with_tag_api_delete"
done

candidate_with_tag_mirror="$fixture_root/prepare-candidate-with-tag-mirror.yml"
/usr/bin/python3 - "$CANDIDATE_WORKFLOW" "$candidate_with_tag_mirror" <<'PYTHON'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
needle = '          gh release create "$tag" \\\n'
if source.count(needle) != 1:
    raise SystemExit("Candidate Release creation marker is missing or ambiguous")
replacement = (
    '          git tag -d "$tag"\n'
    '          git push --mirror origin\n'
    + needle
)
pathlib.Path(sys.argv[2]).write_text(source.replace(needle, replacement))
PYTHON
expect_failure "prepare-candidate.yml must never delete a protected release tag" \
  validate_workflow_policy "$WORKFLOW_DIR" "$CI_WORKFLOW" "$CODEOWNERS_FILE" \
  "$candidate_with_tag_mirror" "$RELEASING_DOC"

candidate_with_bypassed_sign_gate="$fixture_root/prepare-candidate-with-bypassed-sign-gate.yml"
/usr/bin/python3 - "$CANDIDATE_WORKFLOW" "$candidate_with_bypassed_sign_gate" <<'PYTHON'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
needle = (
    "    if: github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v')"
    " && github.run_attempt == 1"
)
if source.count(needle) != 1:
    raise SystemExit("Candidate signing gate is missing or ambiguous")
pathlib.Path(sys.argv[2]).write_text(source.replace(needle, needle + " || always()"))
PYTHON
expect_failure "manual dry runs and rerun tag pushes must not enter sign-candidate" \
  validate_workflow_policy "$WORKFLOW_DIR" "$CI_WORKFLOW" "$CODEOWNERS_FILE" \
  "$candidate_with_bypassed_sign_gate" "$RELEASING_DOC"

candidate_with_local_action="$fixture_root/prepare-candidate-with-local-action.yml"
/usr/bin/python3 - "$CANDIDATE_WORKFLOW" "$candidate_with_local_action" <<'PYTHON'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
sign_marker = "  sign-candidate:\n"
if source.count(sign_marker) != 1:
    raise SystemExit("Candidate signing job is missing or ambiguous")
sign_offset = source.index(sign_marker)
steps_marker = "    steps:\n"
steps_offset = source.find(steps_marker, sign_offset)
if steps_offset < 0:
    raise SystemExit("Candidate signing steps are missing")
injected_steps = (
    steps_marker
    + "      - name: Delete tag through local action\n"
    + "        uses: ./.github/actions/delete-tag\n\n"
)
source = source[:steps_offset] + source[steps_offset:].replace(
    steps_marker,
    injected_steps,
    1,
)
pathlib.Path(sys.argv[2]).write_text(source)
PYTHON
expect_failure "prepare-candidate-with-local-action.yml contains a repo-local action" \
  validate_workflow_policy "$WORKFLOW_DIR" "$CI_WORKFLOW" "$CODEOWNERS_FILE" \
  "$candidate_with_local_action" "$RELEASING_DOC"

candidate_with_local_workflow="$fixture_root/prepare-candidate-with-local-workflow.yml"
/usr/bin/python3 - "$CANDIDATE_WORKFLOW" "$candidate_with_local_workflow" <<'PYTHON'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
job = """
  delete-tag:
    permissions:
      contents: write
    uses: ./.github/workflows/delete-tag.yml
"""
pathlib.Path(sys.argv[2]).write_text(source + job)
PYTHON
expect_failure "prepare-candidate-with-local-workflow.yml contains a repo-local action" \
  validate_workflow_policy "$WORKFLOW_DIR" "$CI_WORKFLOW" "$CODEOWNERS_FILE" \
  "$candidate_with_local_workflow" "$RELEASING_DOC"

write_version_config() {
  local path="$1" version="$2" build="$3"

  printf 'MARKETING_VERSION=%s\nBUILD_NUMBER=%s\n' "$version" "$build" >"$path"
}

write_update_config() {
  local path="$1" public_key="$2"

  {
    printf 'SPARKLE_VERSION=2.9.4\n'
    printf 'SPARKLE_PUBLIC_ED_KEY=%s\n' "$public_key"
    printf 'PRODUCTION_FEED_URL=https://raw.githubusercontent.com/tangwz/codex-radar/main/appcast.xml\n'
  } >"$path"
}

build_test_signer() {
  local source_dir="$SPARKLE_SOURCE/Vendor/ed25519-sparkle/src"

  /usr/bin/xcrun clang -std=c11 -Wall -Wextra -Werror \
    -I "$source_dir" \
    "$source_dir/fe.c" \
    "$source_dir/ge.c" \
    "$source_dir/sc.c" \
    "$source_dir/sha512.c" \
    "$source_dir/keypair.c" \
    "$source_dir/sign.c" \
    -x c - -o "$fixture_root/test-signer" <<'C'
#include "ed25519.h"

#include <stdio.h>
#include <stdlib.h>

static unsigned char *read_file(const char *path, size_t *length) {
    FILE *file = fopen(path, "rb");
    long size;
    unsigned char *bytes;

    if (file == NULL || fseek(file, 0, SEEK_END) != 0 || (size = ftell(file)) < 0 ||
        fseek(file, 0, SEEK_SET) != 0) {
        return NULL;
    }
    bytes = malloc((size_t)size + 1);
    if (bytes == NULL || fread(bytes, 1, (size_t)size, file) != (size_t)size ||
        fclose(file) != 0) {
        free(bytes);
        return NULL;
    }
    *length = (size_t)size;
    return bytes;
}

static int write_file(const char *path, const unsigned char *bytes, size_t length) {
    FILE *file = fopen(path, "wb");
    int result;

    if (file == NULL) {
        return 0;
    }
    result = fwrite(bytes, 1, length, file) == length && fclose(file) == 0;
    return result;
}

int main(int argc, char **argv) {
    unsigned char seed[32];
    unsigned char public_key[32];
    unsigned char private_key[64];
    unsigned char signature[64];
    unsigned char *message;
    size_t seed_length;
    size_t message_length;
    unsigned char *seed_bytes;

    if (argc != 5) {
        return 2;
    }
    seed_bytes = read_file(argv[1], &seed_length);
    message = read_file(argv[2], &message_length);
    if (seed_bytes == NULL || message == NULL || seed_length != sizeof(seed)) {
        free(seed_bytes);
        free(message);
        return 1;
    }
    for (size_t index = 0; index < sizeof(seed); index++) {
        seed[index] = seed_bytes[index];
    }
    free(seed_bytes);
    ed25519_create_keypair(public_key, private_key, seed);
    ed25519_sign(signature, message, message_length, public_key, private_key);
    free(message);
    if (!write_file(argv[3], public_key, sizeof(public_key)) ||
        !write_file(argv[4], signature, sizeof(signature))) {
        return 1;
    }
    return 0;
}
C
}

sign_file() {
  local input_path="$1"

  "$fixture_root/test-signer" "$fixture_root/test-seed" "$input_path" \
    "$fixture_root/public-key.raw" "$fixture_root/signature.raw"
  /usr/bin/base64 <"$fixture_root/signature.raw" | /usr/bin/tr -d '\n'
}

write_info_plist() {
  local path="$1" version="$2" build="$3" minimum_system="$4" public_key="$5"

  /bin/mkdir -p "$(/usr/bin/dirname "$path")"
  {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
    printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    printf '%s\n' '<plist version="1.0"><dict>'
    printf '%s\n' '<key>CFBundleIdentifier</key><string>com.terence.codex-radar</string>'
    printf '<key>CFBundleShortVersionString</key><string>%s</string>\n' "$version"
    printf '<key>CFBundleVersion</key><string>%s</string>\n' "$build"
    printf '<key>LSMinimumSystemVersion</key><string>%s</string>\n' "$minimum_system"
    printf '%s\n' '<key>SUFeedURL</key><string>https://raw.githubusercontent.com/tangwz/codex-radar/main/appcast.xml</string>'
    printf '<key>SUPublicEDKey</key><string>%s</string>\n' "$public_key"
    printf '%s\n' '<key>SUEnableAutomaticChecks</key><true/>'
    printf '%s\n' '<key>SUAutomaticallyUpdate</key><true/>'
    printf '%s\n' '<key>SUVerifyUpdateBeforeExtraction</key><true/>'
    printf '%s\n' '<key>SURequireSignedFeed</key><true/>'
    printf '%s\n' '<key>CodexRadarUpdatesEnabled</key><true/>'
    printf '%s\n' '</dict></plist>'
  } >"$path"
  /usr/bin/plutil -lint "$path" >/dev/null
}

make_release_fixture() {
  local directory="$1" version="$2" build="$3" minimum_system="$4"
  local archive_name="CodexRadar-v${version}-macos-universal.zip"
  local app_path="$directory/app/CodexRadar.app"
  local archive_path="$directory/$archive_name"
  local manifest_path="$archive_path.manifest"
  local info_plist="$directory/final-Info.plist"
  local archive_sha archive_length

  /bin/mkdir -p "$app_path/Contents/MacOS"
  write_info_plist "$info_plist" "$version" "$build" "$minimum_system" "$PUBLIC_KEY"
  /bin/cp "$info_plist" "$app_path/Contents/Info.plist"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$app_path/Contents/MacOS/CodexRadar"
  /bin/chmod 755 "$app_path/Contents/MacOS/CodexRadar"
  /usr/bin/ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl \
    "$app_path" "$archive_path"
  archive_sha="$(/usr/bin/shasum -a 256 "$archive_path" | /usr/bin/awk '{print $1}')"
  archive_length="$(/usr/bin/stat -f '%z' "$archive_path")"
  {
    printf 'archive_name=%s\n' "$archive_name"
    printf 'version=%s\n' "$version"
    printf 'build=%s\n' "$build"
    printf 'byte_length=%s\n' "$archive_length"
    printf 'sha256=%s\n' "$archive_sha"
    printf 'signing_mode=adhoc\n'
    printf 'distribution_trust=locally-signed-not-developer-id-not-notarized-not-gatekeeper-trusted\n'
  } >"$manifest_path"
}

make_feed() {
  local output_path="$1" version="$2" build="$3" minimum_system="$4"
  local enclosure_url="$5" enclosure_length="$6" archive_signature="$7"
  local extra_item_xml="${8:-}" second_entry="${9:-false}"
  local channel_title="${10:-CodexRadar}"
  local content_path="$output_path.content" feed_signature content_length

  {
    printf '%s\n' '<?xml version="1.0" encoding="utf-8"?>'
    printf '<rss xmlns:sparkle="%s" version="2.0">\n' "$SPARKLE_NAMESPACE"
    printf '<channel><title>%s</title><item>\n' "$channel_title"
    printf '<title>%s</title>\n' "$version"
    printf '<sparkle:version>%s</sparkle:version>\n' "$build"
    printf '<sparkle:shortVersionString>%s</sparkle:shortVersionString>\n' "$version"
    printf '<sparkle:minimumSystemVersion>%s</sparkle:minimumSystemVersion>\n' "$minimum_system"
    printf '%s\n' "$extra_item_xml"
    if [[ "$archive_signature" == absent ]]; then
      printf '<enclosure url="%s" length="%s" type="application/octet-stream"/>\n' \
        "$enclosure_url" "$enclosure_length"
    else
      printf '<enclosure url="%s" length="%s" type="application/octet-stream" sparkle:edSignature="%s"/>\n' \
        "$enclosure_url" "$enclosure_length" "$archive_signature"
    fi
    printf '%s\n' '</item>'
    if [[ "$second_entry" == true ]]; then
      printf '%s\n' '<item><sparkle:version>1</sparkle:version></item>'
    fi
    printf '%s' '</channel></rss>'
  } >"$content_path"
  feed_signature="$(sign_file "$content_path")"
  content_length="$(/usr/bin/stat -f '%z' "$content_path")"
  /bin/cp "$content_path" "$output_path"
  printf '<!-- sparkle-signatures:\nedSignature: %s\nlength: %s\n-->\n' \
    "$feed_signature" "$content_length" >>"$output_path"
  /bin/rm -f "$content_path"
}

prepare_command() {
  local output_path="$1" version_config="$2" update_config="$3"
  local archive_path="$4" manifest_path="$5" info_plist="$6"
  shift 6

  "$PREPARE_SCRIPT" \
    --output "$output_path" \
    --archive "$archive_path" \
    --manifest "$manifest_path" \
    --final-info-plist "$info_plist" \
    --version-config "$version_config" \
    --update-config "$update_config" \
    --sparkle-source "$SPARKLE_SOURCE" \
    "$@"
}

verify_artifacts() {
  verify_artifacts_with_sparkle "$SPARKLE_SOURCE" "$@"
}

verify_artifacts_with_sparkle() {
  local sparkle_source="$1"
  shift
  local inputs_path="$1" archive_path="$2" manifest_path="$3" info_plist="$4"
  local version_config="$5" update_config="$6"

  "$VERIFY_SCRIPT" --mode artifacts \
    --inputs "$inputs_path" \
    --archive "$archive_path" \
    --manifest "$manifest_path" \
    --final-info-plist "$info_plist" \
    --version-config "$version_config" \
    --update-config "$update_config" \
    --sparkle-source "$sparkle_source"
}

verify_published() {
  local feed_path="$1" archive_path="$2" manifest_path="$3"
  local version_config="$4" update_config="$5"

  "$VERIFY_SCRIPT" --mode published \
    --feed "$feed_path" \
    --archive "$archive_path" \
    --manifest "$manifest_path" \
    --version-config "$version_config" \
    --update-config "$update_config" \
    --sparkle-source "$SPARKLE_SOURCE"
}

verify_halt() {
  local current_feed="$1" previous_feed="$2" update_config="$3"
  local intervening_feed="${4:-}"
  local arguments=(
    --mode halt
    --current-feed "$current_feed"
    --previous-feed "$previous_feed"
    --update-config "$update_config"
    --sparkle-source "$SPARKLE_SOURCE"
  )

  if [[ -n "$intervening_feed" ]]; then
    arguments+=(--intervening-feed "$intervening_feed")
  fi
  "$VERIFY_SCRIPT" "${arguments[@]}"
}

printf '01234567890123456789012345678901' >"$fixture_root/test-seed"
build_test_signer
: >"$fixture_root/empty"
sign_file "$fixture_root/empty" >/dev/null
PUBLIC_KEY="$(/usr/bin/base64 <"$fixture_root/public-key.raw" | /usr/bin/tr -d '\n')"

candidate_dir="$fixture_root/candidate"
previous_dir="$fixture_root/previous"
/bin/mkdir -p "$candidate_dir" "$previous_dir"
write_version_config "$candidate_dir/version.env" 0.2.0 2
write_update_config "$candidate_dir/update.env" "$PUBLIC_KEY"
make_release_fixture "$candidate_dir" 0.2.0 2 14.0
candidate_archive="$candidate_dir/CodexRadar-v0.2.0-macos-universal.zip"
candidate_manifest="$candidate_archive.manifest"
candidate_info="$candidate_dir/final-Info.plist"
archive_length="$(/usr/bin/stat -f '%z' "$candidate_archive")"
archive_signature="$(sign_file "$candidate_archive")"
previous_url="https://github.com/tangwz/codex-radar/releases/download/v0.1.0/CodexRadar-v0.1.0-macos-universal.zip"
make_feed "$previous_dir/appcast.xml" 0.1.0 1 14.0 "$previous_url" 123 "$archive_signature"
printf '[]\n' >"$fixture_root/empty-history.json"
printf '[{"tag_name":"v0.0.1"}]\n' >"$fixture_root/nonempty-history.json"

inputs_dir="$fixture_root/inputs"
prepare_command "$inputs_dir" "$candidate_dir/version.env" "$candidate_dir/update.env" \
  "$candidate_archive" "$candidate_manifest" "$candidate_info" \
  --production-feed "$previous_dir/appcast.xml"

archive_name="CodexRadar-v0.2.0-macos-universal.zip"
/usr/bin/cmp -s "$candidate_archive" "$inputs_dir/production/$archive_name" ||
  fail "production archive bytes changed during preparation"
/usr/bin/cmp -s "$candidate_archive" "$inputs_dir/qualification/$archive_name" ||
  fail "qualification archive bytes changed during preparation"
/usr/bin/cmp -s "$inputs_dir/production/$archive_name" "$inputs_dir/qualification/$archive_name" ||
  fail "production and qualification archives differ"
/usr/bin/cmp -s "$candidate_manifest" "$inputs_dir/manifest" ||
  fail "manifest bytes changed during preparation"
/usr/bin/cmp -s "$candidate_info" "$inputs_dir/Info.plist" ||
  fail "Info.plist bytes changed during preparation"
/usr/bin/cmp -s "$previous_dir/appcast.xml" "$inputs_dir/previous-appcast.xml" ||
  fail "previous signed feed bytes changed during preparation"
/usr/bin/cmp -s "$previous_dir/appcast.xml" "$inputs_dir/production/appcast.xml" ||
  fail "production seed feed bytes changed during preparation"
/usr/bin/cmp -s "$previous_dir/appcast.xml" "$inputs_dir/qualification/appcast.xml" ||
  fail "qualification seed feed bytes changed during preparation"
[[ "$(<"$inputs_dir/production-download-url-prefix")" == \
  "https://github.com/tangwz/codex-radar/releases/download/v0.2.0/" ]] ||
  fail "production URL prefix is not version-fixed"
[[ "$(<"$inputs_dir/qualification-download-url-prefix")" == "./" ]] ||
  fail "qualification URL prefix is not relative"
if /usr/bin/find "$inputs_dir" -type f \( -name '*.html' -o -name '*.md' -o -name '*.markdown' -o -name '*.txt' \) | /usr/bin/grep . >/dev/null; then
  fail "preparation unexpectedly created release notes"
fi

missing_feed_output="$fixture_root/missing-feed-output"
expect_failure "existing Production Feed is required" prepare_command \
  "$missing_feed_output" "$candidate_dir/version.env" "$candidate_dir/update.env" \
  "$candidate_archive" "$candidate_manifest" "$candidate_info"

non_increasing_previous="$fixture_root/non-increasing.xml"
make_feed "$non_increasing_previous" 0.2.0 2 14.0 \
  "https://github.com/tangwz/codex-radar/releases/download/v0.2.0/$archive_name" \
  "$archive_length" "$archive_signature"
expect_failure "candidate build must be greater than Production Feed build" prepare_command \
  "$fixture_root/non-increasing-output" "$candidate_dir/version.env" "$candidate_dir/update.env" \
  "$candidate_archive" "$candidate_manifest" "$candidate_info" \
  --production-feed "$non_increasing_previous"

lower_minimum_previous="$fixture_root/lower-minimum.xml"
make_feed "$lower_minimum_previous" 0.1.0 1 13.0 "$previous_url" 123 "$archive_signature"
expect_failure "minimum system version must match the Production Feed" prepare_command \
  "$fixture_root/lower-minimum-output" "$candidate_dir/version.env" "$candidate_dir/update.env" \
  "$candidate_archive" "$candidate_manifest" "$candidate_info" \
  --production-feed "$lower_minimum_previous"

bootstrap_dir="$fixture_root/bootstrap"
/bin/mkdir -p "$bootstrap_dir"
write_version_config "$bootstrap_dir/version.env" 0.1.0 1
write_update_config "$bootstrap_dir/update.env" "$PUBLIC_KEY"
make_release_fixture "$bootstrap_dir" 0.1.0 1 14.0
bootstrap_archive="$bootstrap_dir/CodexRadar-v0.1.0-macos-universal.zip"
bootstrap_inputs="$fixture_root/bootstrap-inputs"
prepare_command "$bootstrap_inputs" "$bootstrap_dir/version.env" "$bootstrap_dir/update.env" \
  "$bootstrap_archive" "$bootstrap_archive.manifest" "$bootstrap_dir/final-Info.plist" \
  --bootstrap --release-history "$fixture_root/empty-history.json"
[[ -f "$bootstrap_inputs/bootstrap" ]] || fail "bootstrap marker is missing"
[[ ! -e "$bootstrap_inputs/previous-appcast.xml" ]] ||
  fail "bootstrap preparation created a previous feed"
[[ ! -e "$bootstrap_inputs/production/appcast.xml" ]] ||
  fail "bootstrap preparation seeded a production feed"

burned_bootstrap_inputs="$fixture_root/burned-bootstrap-inputs"
prepare_command \
  "$burned_bootstrap_inputs" "$candidate_dir/version.env" "$candidate_dir/update.env" \
  "$candidate_archive" "$candidate_manifest" "$candidate_info" \
  --bootstrap --release-history "$fixture_root/empty-history.json"
[[ -f "$burned_bootstrap_inputs/bootstrap" ]] ||
  fail "a higher version did not remain eligible after a burned bootstrap tag"
expect_failure "bootstrap requires an absent Production Feed" prepare_command \
  "$fixture_root/bootstrap-with-feed" "$bootstrap_dir/version.env" "$bootstrap_dir/update.env" \
  "$bootstrap_archive" "$bootstrap_archive.manifest" "$bootstrap_dir/final-Info.plist" \
  --bootstrap --production-feed "$previous_dir/appcast.xml" \
  --release-history "$fixture_root/empty-history.json"
expect_failure "bootstrap requires empty GitHub Release history" prepare_command \
  "$fixture_root/bootstrap-with-history" "$bootstrap_dir/version.env" "$bootstrap_dir/update.env" \
  "$bootstrap_archive" "$bootstrap_archive.manifest" "$bootstrap_dir/final-Info.plist" \
  --bootstrap --release-history "$fixture_root/nonempty-history.json"

bad_trust_manifest="$fixture_root/bad-trust.manifest"
/usr/bin/sed \
  's/distribution_trust=locally-signed-not-developer-id-not-notarized-not-gatekeeper-trusted/distribution_trust=developer-id-notarized/' \
  "$candidate_manifest" >"$bad_trust_manifest"
expect_failure "invalid manifest signing trust" prepare_command \
  "$fixture_root/bad-trust-inputs" "$candidate_dir/version.env" "$candidate_dir/update.env" \
  "$candidate_archive" "$bad_trust_manifest" "$candidate_info" \
  --production-feed "$previous_dir/appcast.xml"

production_url="https://github.com/tangwz/codex-radar/releases/download/v0.2.0/$archive_name"
make_feed "$inputs_dir/production/appcast.xml" 0.2.0 2 14.0 \
  "$production_url" "$archive_length" "$archive_signature"
make_feed "$inputs_dir/qualification/appcast.xml" 0.2.0 2 14.0 \
  "./$archive_name" "$archive_length" "$archive_signature"

production_feed_sha="$(/usr/bin/shasum -a 256 "$inputs_dir/production/appcast.xml" | /usr/bin/awk '{print $1}')"
qualification_feed_sha="$(/usr/bin/shasum -a 256 "$inputs_dir/qualification/appcast.xml" | /usr/bin/awk '{print $1}')"
verify_artifacts "$inputs_dir" "$candidate_archive" "$candidate_manifest" "$candidate_info" \
  "$candidate_dir/version.env" "$candidate_dir/update.env"

generated_inputs="$fixture_root/generated-inputs"
prepare_command "$generated_inputs" "$candidate_dir/version.env" "$candidate_dir/update.env" \
  "$candidate_archive" "$candidate_manifest" "$candidate_info" \
  --production-feed "$previous_dir/appcast.xml"
generator_home="$fixture_root/generator-home"
/bin/mkdir -p "$generator_home"
test_seed_base64="$(/usr/bin/base64 <"$fixture_root/test-seed" | /usr/bin/tr -d '\n')"
for channel in production qualification; do
  printf '%s' "$test_seed_base64" |
    /usr/bin/env HOME="$generator_home" CFFIXED_USER_HOME="$generator_home" \
      "$SPARKLE_GENERATE_APPCAST" \
      --maximum-versions 1 \
      --download-url-prefix "$(<"$generated_inputs/$channel-download-url-prefix")" \
      --ed-key-file - \
      "$generated_inputs/$channel"
done
generated_qualification_url="$(
  /usr/bin/xmllint --nonet --xpath \
    "string(/*[local-name()='rss']/*[local-name()='channel']/*[local-name()='item']/*[local-name()='enclosure']/@url)" \
    "$generated_inputs/qualification/appcast.xml"
)"
case "$generated_qualification_url" in
  "$archive_name" | "./$archive_name") ;;
  *) fail "real Sparkle generated an unexpected qualification enclosure URL: $generated_qualification_url" ;;
esac
verify_artifacts "$generated_inputs" "$candidate_archive" "$candidate_manifest" "$candidate_info" \
  "$candidate_dir/version.env" "$candidate_dir/update.env"

verify_published "$inputs_dir/production/appcast.xml" "$candidate_archive" \
  "$candidate_manifest" "$candidate_dir/version.env" \
  "$candidate_dir/update.env"
published_wrong_archive_feed="$fixture_root/published-wrong-archive.xml"
published_wrong_signature="$(sign_file "$fixture_root/empty")"
make_feed "$published_wrong_archive_feed" 0.2.0 2 14.0 \
  "$production_url" "$archive_length" "$published_wrong_signature"
expect_failure "published archive failed Ed25519 verification" verify_published \
  "$published_wrong_archive_feed" "$candidate_archive" "$candidate_manifest" \
  "$candidate_dir/version.env" "$candidate_dir/update.env"
corrupt_published_dir="$fixture_root/corrupt-published"
/bin/mkdir -p "$corrupt_published_dir"
corrupt_published_archive="$corrupt_published_dir/$archive_name"
printf 'not a zip archive\n' >"$corrupt_published_archive"
corrupt_published_length="$(/usr/bin/stat -f '%z' "$corrupt_published_archive")"
corrupt_published_sha="$(/usr/bin/shasum -a 256 "$corrupt_published_archive" | /usr/bin/awk '{print $1}')"
{
  printf 'archive_name=%s\n' "$archive_name"
  printf 'version=0.2.0\n'
  printf 'build=2\n'
  printf 'byte_length=%s\n' "$corrupt_published_length"
  printf 'sha256=%s\n' "$corrupt_published_sha"
  printf 'signing_mode=adhoc\n'
  printf 'distribution_trust=locally-signed-not-developer-id-not-notarized-not-gatekeeper-trusted\n'
} >"$corrupt_published_archive.manifest"
corrupt_published_feed="$corrupt_published_dir/appcast.xml"
make_feed "$corrupt_published_feed" 0.2.0 2 14.0 \
  "$production_url" "$corrupt_published_length" "$published_wrong_signature"
expect_failure "published archive failed Ed25519 verification" verify_published \
  "$corrupt_published_feed" "$corrupt_published_archive" \
  "$corrupt_published_archive.manifest" "$candidate_dir/version.env" \
  "$candidate_dir/update.env"

halt_current_feed="$inputs_dir/production/appcast.xml"
halt_previous_feed="$previous_dir/appcast.xml"
halt_verify_output="$fixture_root/halt-verify-output"
verify_halt "$halt_current_feed" "$halt_previous_feed" \
  "$candidate_dir/update.env" >"$halt_verify_output"
for expected_line in \
  'halt_state=ready' \
  'current_tag=v0.2.0' \
  'current_version=0.2.0' \
  'current_build=2' \
  'previous_version=0.1.0' \
  'previous_build=1'; do
  /usr/bin/grep -Fx "$expected_line" "$halt_verify_output" >/dev/null ||
    fail "halt verifier did not report $expected_line"
done

expect_failure "already-halted verification requires an intervening Production Feed" \
  verify_halt "$halt_previous_feed" "$halt_previous_feed" "$candidate_dir/update.env"
verify_halt "$halt_previous_feed" "$halt_previous_feed" \
  "$candidate_dir/update.env" "$halt_current_feed" >"$halt_verify_output"
/usr/bin/grep -Fx 'halt_state=already-halted' "$halt_verify_output" >/dev/null ||
  fail "halt verifier did not report the already-halted state"
expect_failure "intervening Production Feed is only valid for already-halted verification" \
  verify_halt "$halt_current_feed" "$halt_previous_feed" \
  "$candidate_dir/update.env" "$halt_current_feed"

halt_invalid_signature="$fixture_root/halt-invalid-signature.xml"
/bin/cp "$halt_previous_feed" "$halt_invalid_signature"
/usr/bin/python3 - "$halt_invalid_signature" "$published_wrong_signature" <<'PYTHON'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
signature = sys.argv[2].encode("ascii")
data = path.read_bytes()
prefix = b"edSignature: "
start = data.rfind(prefix)
end = data.find(b"\n", start)
if start < 0 or end < 0:
    raise SystemExit("fixture feed signature block is missing")
path.write_bytes(data[:start] + prefix + signature + data[end:])
PYTHON
expect_failure "previous Production Feed failed Ed25519 verification" verify_halt \
  "$halt_current_feed" "$halt_invalid_signature" "$candidate_dir/update.env"

halt_equal_build="$fixture_root/halt-equal-build.xml"
make_feed "$halt_equal_build" 0.2.0 2 14.0 "$production_url" \
  "$archive_length" "$archive_signature" '' false CodexRadarEqualBuild
expect_failure "previous Production Feed build must be lower than current Production Feed build" \
  verify_halt "$halt_current_feed" "$halt_equal_build" "$candidate_dir/update.env"

halt_moving_url="$fixture_root/halt-moving-url.xml"
make_feed "$halt_moving_url" 0.1.0 1 14.0 \
  "https://github.com/tangwz/codex-radar/releases/latest/download/CodexRadar-v0.1.0-macos-universal.zip" \
  123 "$archive_signature"
expect_failure "previous Production Feed enclosure URL must be version-fixed" verify_halt \
  "$halt_current_feed" "$halt_moving_url" "$candidate_dir/update.env"

halt_wrong_minimum="$fixture_root/halt-wrong-minimum.xml"
make_feed "$halt_wrong_minimum" 0.1.0 1 13.0 "$previous_url" 123 "$archive_signature"
expect_failure "Production Feed minimum system versions must match" verify_halt \
  "$halt_current_feed" "$halt_wrong_minimum" "$candidate_dir/update.env"

halt_fixture_dir="$fixture_root/halt-fixture"
/bin/mkdir -p "$halt_fixture_dir"
halt_fake_gh="$halt_fixture_dir/gh"
halt_fake_http="$halt_fixture_dir/http"
halt_fake_swift="$halt_fixture_dir/swift"

/usr/bin/tee "$halt_fake_gh" >/dev/null <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$HALT_FIXTURE_DIR/gh.log"

emit_contents() {
  /usr/bin/python3 - "$1" "$2" <<'PYTHON'
import base64
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
print(json.dumps({
    "type": "file",
    "sha": sys.argv[2],
    "encoding": "base64",
    "content": base64.b64encode(path.read_bytes()).decode("ascii"),
}))
PYTHON
}

if [[ "$#" -eq 2 && "$1" == auth && "$2" == status ]]; then
  exit 0
fi
[[ "$#" -ge 2 && "$1" == api ]] || exit 2
shift
method=GET
include=false
input=""
target=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --method)
      method="$2"
      shift 2
      ;;
    --include)
      include=true
      shift
      ;;
    --input)
      input="$2"
      shift 2
      ;;
    *)
      target="$1"
      shift
      ;;
  esac
done

if [[ "$method" == GET && "$target" == *"?ref=main" ]]; then
  if [[ "$HALT_FIXTURE_MODE" == current-read-failure && ! -e "$HALT_FIXTURE_DIR/put-complete" ]]; then
    exit 1
  fi
  if [[ -e "$HALT_FIXTURE_DIR/put-complete" ]]; then
    if [[ "$HALT_FIXTURE_MODE" == repository-mismatch ]]; then
      emit_contents "$HALT_FIXTURE_UNKNOWN_FEED" 3333333333333333333333333333333333333333
    else
      emit_contents "$HALT_FIXTURE_PREVIOUS_FEED" 2222222222222222222222222222222222222222
    fi
  else
    emit_contents "$HALT_FIXTURE_CURRENT_FEED" 1111111111111111111111111111111111111111
  fi
  exit 0
fi

if [[ "$method" == GET && "$target" == *"?ref=$HALT_FIXTURE_PREVIOUS_COMMIT" ]]; then
  emit_contents "$HALT_FIXTURE_PREVIOUS_FEED" 0000000000000000000000000000000000000000
  exit 0
fi

if [[ "$method" == GET && "$target" == \
  "repos/tangwz/codex-radar/compare/$HALT_FIXTURE_PREVIOUS_COMMIT...main" ]]; then
  case "$HALT_FIXTURE_MODE" in
    ancestry-read-failure)
      exit 1
      ;;
    ancestry-malformed)
      printf '{"status":"ahead"}\n'
      ;;
    non-ancestor)
      printf '{"status":"diverged","base_commit":{"sha":"%s"},"merge_base_commit":{"sha":"7777777777777777777777777777777777777777"}}\n' \
        "$HALT_FIXTURE_PREVIOUS_COMMIT"
      ;;
    *)
      printf '{"status":"ahead","base_commit":{"sha":"%s"},"merge_base_commit":{"sha":"%s"}}\n' \
        "$HALT_FIXTURE_PREVIOUS_COMMIT" "$HALT_FIXTURE_PREVIOUS_COMMIT"
      ;;
  esac
  exit 0
fi

if [[ "$method" == GET && "$target" == \
  "repos/tangwz/codex-radar/commits?sha=main&path=appcast.xml&per_page=1" ]]; then
  case "$HALT_FIXTURE_MODE" in
    provenance-read-failure)
      exit 1
      ;;
    provenance-malformed)
      printf '{"not":"an array"}\n'
      exit 0
      ;;
    provenance-missing-parent)
      printf '[{"sha":"4444444444444444444444444444444444444444","parents":[]}]\n'
      exit 0
      ;;
  esac
  printf '[{"sha":"4444444444444444444444444444444444444444","parents":[{"sha":"5555555555555555555555555555555555555555"}]}]\n'
  exit 0
fi

if [[ "$method" == GET && "$target" == *"?ref=5555555555555555555555555555555555555555" ]]; then
  if [[ "$HALT_FIXTURE_MODE" == provenance-lower ]]; then
    emit_contents "$HALT_FIXTURE_LOWER_FEED" 6666666666666666666666666666666666666666
  else
    emit_contents "$HALT_FIXTURE_CURRENT_FEED" 6666666666666666666666666666666666666666
  fi
  exit 0
fi

if [[ "$method" == PUT && "$target" == "repos/tangwz/codex-radar/contents/appcast.xml" ]]; then
  [[ "$include" == true && -f "$input" ]] || exit 2
  /bin/cp "$input" "$HALT_FIXTURE_DIR/put-body.json"
  case "$HALT_FIXTURE_MODE" in
    put-response-lost)
      : >"$HALT_FIXTURE_DIR/put-complete"
      printf 'HTTP/2.0 500 Internal Server Error\r\n\r\n'
      exit 1
      ;;
    put-409)
      printf 'HTTP/2.0 409 Conflict\r\n\r\n'
      exit 1
      ;;
    put-422)
      printf 'HTTP/2.0 422 Unprocessable Entity\r\n\r\n'
      exit 1
      ;;
  esac
  : >"$HALT_FIXTURE_DIR/put-complete"
  printf 'HTTP/2.0 200 OK\r\n\r\n{}\n'
  exit 0
fi

exit 2
FAKE_GH

/usr/bin/tee "$halt_fake_http" >/dev/null <<'FAKE_HTTP'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$HALT_FIXTURE_DIR/http.log"
count=0
if [[ -f "$HALT_FIXTURE_DIR/http-count" ]]; then
  count="$(<"$HALT_FIXTURE_DIR/http-count")"
fi
count=$((count + 1))
printf '%s\n' "$count" >"$HALT_FIXTURE_DIR/http-count"
case "$HALT_FIXTURE_MODE" in
  raw-unknown)
    /bin/cat "$HALT_FIXTURE_UNKNOWN_FEED"
    ;;
  raw-timeout)
    /bin/cat "$HALT_FIXTURE_CURRENT_FEED"
    ;;
  raw-current-then-previous)
    if [[ "$count" -eq 1 ]]; then
      /bin/cat "$HALT_FIXTURE_CURRENT_FEED"
    else
      /bin/cat "$HALT_FIXTURE_PREVIOUS_FEED"
    fi
    ;;
  raw-intervening-then-previous)
    if [[ "$count" -eq 1 ]]; then
      /bin/cat "$HALT_FIXTURE_CURRENT_FEED"
    else
      /bin/cat "$HALT_FIXTURE_PREVIOUS_FEED"
    fi
    ;;
  *)
    /bin/cat "$HALT_FIXTURE_PREVIOUS_FEED"
    ;;
esac
FAKE_HTTP

/usr/bin/tee "$halt_fake_swift" >/dev/null <<'FAKE_SWIFT'
#!/usr/bin/env bash
set -euo pipefail

working_root="$(pwd -P)"
expected_root="$(cd "$HALT_FIXTURE_PACKAGE_ROOT" && pwd -P)"
printf '%s|%s\n' "$working_root" "$*" >>"$HALT_FIXTURE_DIR/swift.log"
[[ "$working_root" == "$expected_root" ]] || {
  echo "unexpected SwiftPM package root: $working_root" >&2
  exit 2
}
[[ "$#" -eq 2 && "$1" == package && "$2" == resolve ]] || {
  echo "unexpected SwiftPM arguments: $*" >&2
  exit 2
}
/bin/mkdir -p "$(/usr/bin/dirname "$HALT_TEST_SPARKLE_SOURCE")"
/usr/bin/ditto "$HALT_FIXTURE_REAL_SPARKLE_SOURCE" "$HALT_TEST_SPARKLE_SOURCE"
FAKE_SWIFT
/bin/chmod 755 "$halt_fake_gh" "$halt_fake_http" "$halt_fake_swift"

halt_previous_commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
halt_unknown_feed="$fixture_root/halt-unknown.xml"
make_feed "$halt_unknown_feed" 9.9.9 999 14.0 \
  "https://github.com/tangwz/codex-radar/releases/download/v9.9.9/CodexRadar-v9.9.9-macos-universal.zip" \
  99 "$archive_signature"

production_halt_script="$HALT_SCRIPT"
halt_harness_root="$fixture_root/halt-harness"
halt_harness_script="$halt_harness_root/script/halt_distribution.sh"
/bin/mkdir -p "$halt_harness_root/script/lib"
/usr/bin/sed -e 's/^TEST_HARNESS=false/TEST_HARNESS=true/' \
  "$production_halt_script" >"$halt_harness_script"
/bin/cp "$VERIFY_SCRIPT" "$halt_harness_root/script/verify_update_artifacts.sh"
/bin/cp "$ROOT_DIR/script/lib/release_common.sh" \
  "$halt_harness_root/script/lib/release_common.sh"
/bin/chmod 755 "$halt_harness_script" \
  "$halt_harness_root/script/verify_update_artifacts.sh"

run_production_halt_with_test_overrides() {
  printf '%s\n' v0.2.0 | env \
    HALT_GH_EXECUTABLE="$halt_fake_gh" \
    HALT_HTTP_EXECUTABLE="$halt_fake_http" \
    HALT_TEST_UPDATE_CONFIG="$candidate_dir/update.env" \
    HALT_TEST_SPARKLE_SOURCE="$SPARKLE_SOURCE" \
    HALT_TEST_POLL_ATTEMPTS=3 \
    HALT_TEST_POLL_INTERVAL_SECONDS=0 \
    HALT_FIXTURE_DIR="$halt_fixture_dir" \
    HALT_FIXTURE_MODE=default \
    HALT_FIXTURE_CURRENT_FEED="$halt_current_feed" \
    HALT_FIXTURE_PREVIOUS_FEED="$halt_previous_feed" \
    HALT_FIXTURE_LOWER_FEED="$halt_previous_feed" \
    HALT_FIXTURE_UNKNOWN_FEED="$halt_unknown_feed" \
    HALT_FIXTURE_PREVIOUS_COMMIT="$halt_previous_commit" \
    "$production_halt_script" --previous-commit "$halt_previous_commit"
}

expect_failure "HALT_* overrides are only available in the test harness" \
  run_production_halt_with_test_overrides

HALT_SCRIPT="$halt_harness_script"

run_halt_fixture() {
  local mode="$1" previous_feed="${2:-$halt_previous_feed}" confirmation="${3:-v0.2.0}"
  local preserve_server_state="${4:-false}"
  local sparkle_source="${5:-$SPARKLE_SOURCE}"

  if [[ "$preserve_server_state" == false ]]; then
    /bin/rm -f "$halt_fixture_dir/put-complete"
  fi
  /bin/rm -f "$halt_fixture_dir/put-body.json" "$halt_fixture_dir/http-count" \
    "$halt_fixture_dir/gh.log" "$halt_fixture_dir/http.log" "$halt_fixture_dir/swift.log"
  printf '%s\n' "$confirmation" | env \
    HALT_GH_EXECUTABLE="$halt_fake_gh" \
    HALT_HTTP_EXECUTABLE="$halt_fake_http" \
    HALT_SWIFT_EXECUTABLE="$halt_fake_swift" \
    HALT_TEST_UPDATE_CONFIG="$candidate_dir/update.env" \
    HALT_TEST_SPARKLE_SOURCE="$sparkle_source" \
    HALT_TEST_POLL_ATTEMPTS=3 \
    HALT_TEST_POLL_INTERVAL_SECONDS=0 \
    HALT_FIXTURE_DIR="$halt_fixture_dir" \
    HALT_FIXTURE_MODE="$mode" \
    HALT_FIXTURE_CURRENT_FEED="$halt_current_feed" \
    HALT_FIXTURE_PREVIOUS_FEED="$previous_feed" \
    HALT_FIXTURE_LOWER_FEED="$halt_previous_feed" \
    HALT_FIXTURE_UNKNOWN_FEED="$halt_unknown_feed" \
    HALT_FIXTURE_PREVIOUS_COMMIT="$halt_previous_commit" \
    HALT_FIXTURE_PACKAGE_ROOT="$halt_harness_root" \
    HALT_FIXTURE_REAL_SPARKLE_SOURCE="$SPARKLE_SOURCE" \
    "$HALT_SCRIPT" --previous-commit "$halt_previous_commit"
}

expect_failure "unable to fetch current Production Feed" run_halt_fixture current-read-failure
for ancestry_mode in ancestry-read-failure ancestry-malformed non-ancestor; do
  case "$ancestry_mode" in
    ancestry-read-failure)
      expected_ancestry_error="unable to verify previous commit ancestry"
      ;;
    ancestry-malformed)
      expected_ancestry_error="invalid commit ancestry response"
      ;;
    non-ancestor)
      expected_ancestry_error="previous commit is not an ancestor of current main"
      ;;
  esac
  expect_failure "$expected_ancestry_error" run_halt_fixture "$ancestry_mode"
  if /usr/bin/grep -F 'api --include --method PUT' "$halt_fixture_dir/gh.log" >/dev/null; then
    fail "halt command performed PUT after rejecting commit ancestry: $ancestry_mode"
  fi
done
expect_failure "previous Production Feed failed Ed25519 verification" run_halt_fixture \
  default "$halt_invalid_signature"
expect_failure "previous Production Feed build must be lower than current Production Feed build" \
  run_halt_fixture default "$halt_equal_build"
expect_failure "confirmation did not match current tag v0.2.0" run_halt_fixture \
  default "$halt_previous_feed" v0.1.0
expect_failure "intervening Production Feed build must be higher than halted Production Feed build" \
  run_halt_fixture provenance-lower "$halt_current_feed" ''
if /usr/bin/grep -F 'Distribution Halt completed' "$fixture_root/failure-output" >/dev/null; then
  fail "halt command accepted a lower-build provenance parent"
fi
if /usr/bin/grep -F 'api --include --method PUT' "$halt_fixture_dir/gh.log" >/dev/null; then
  fail "halt command performed PUT after rejecting a lower-build provenance parent"
fi

halt_missing_sparkle_source="$halt_harness_root/.build/checkouts/Sparkle"
halt_fresh_checkout_output="$fixture_root/halt-fresh-checkout-output"
run_halt_fixture default "$halt_previous_feed" v0.2.0 false \
  "$halt_missing_sparkle_source" >"$halt_fresh_checkout_output"
/usr/bin/grep -E '^/.*\|package resolve$' "$halt_fixture_dir/swift.log" >/dev/null ||
  fail "halt command did not resolve SwiftPM dependencies from a fresh checkout"
/usr/bin/grep -F 'Distribution Halt completed' "$halt_fresh_checkout_output" >/dev/null ||
  fail "halt command did not complete from a fresh checkout"

halt_success_output="$fixture_root/halt-success-output"
run_halt_fixture default >"$halt_success_output"
/usr/bin/grep -F 'Distribution Halt completed' "$halt_success_output" >/dev/null ||
  fail "halt command did not report success"
/usr/bin/grep -F 'already-upgraded installations are not downgraded' "$halt_success_output" >/dev/null ||
  fail "halt command did not state the no-downgrade guarantee"
/usr/bin/python3 - "$halt_fixture_dir/put-body.json" "$halt_previous_feed" <<'PYTHON'
import base64
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
expected = pathlib.Path(sys.argv[2]).read_bytes()
if base64.b64decode(payload.get("content", ""), validate=True) != expected:
    raise SystemExit("halt PUT did not contain the exact previous feed bytes")
if payload.get("sha") != "1111111111111111111111111111111111111111":
    raise SystemExit("halt PUT did not contain the current blob SHA")
if payload.get("branch") != "main":
    raise SystemExit("halt PUT did not target main")
PYTHON
if /usr/bin/grep -E 'release delete|git push --delete|refs/tags' "$halt_fixture_dir/gh.log" >/dev/null; then
  fail "halt command attempted to delete or mutate a Release or tag"
fi
/usr/bin/grep -F -- '--proto =https' "$halt_fixture_dir/http.log" >/dev/null ||
  fail "halt HTTP transport did not restrict redirects to HTTPS"
/usr/bin/grep -F -- '--tlsv1.2' "$halt_fixture_dir/http.log" >/dev/null ||
  fail "halt HTTP transport did not require TLS 1.2 or newer"

expect_failure "CAS conflict while writing Production Feed (HTTP 409)" run_halt_fixture put-409
expect_failure "CAS conflict while writing Production Feed (HTTP 422)" run_halt_fixture put-422
expect_failure "repository Production Feed bytes differ after Distribution Halt PUT" \
  run_halt_fixture repository-mismatch
run_halt_fixture raw-current-then-previous >"$halt_success_output"
[[ "$(<"$halt_fixture_dir/http-count")" == 2 ]] ||
  fail "halt command did not retry current raw feed bytes before convergence"
expect_failure "raw Production Feed returned unknown bytes" run_halt_fixture raw-unknown
expect_failure "unable to write halted Production Feed" run_halt_fixture put-response-lost
if /usr/bin/grep -F 'Distribution Halt completed' "$fixture_root/failure-output" >/dev/null; then
  fail "halt command claimed success after a lost PUT response"
fi
run_halt_fixture default "$halt_previous_feed" '' true >"$halt_success_output"
/usr/bin/grep -F 'resuming verification without another PUT' "$halt_success_output" >/dev/null ||
  fail "halt command did not report resume after a lost PUT response"
if /usr/bin/grep -F 'api --include --method PUT' "$halt_fixture_dir/gh.log" >/dev/null; then
  fail "halt retry repeated PUT after a lost response"
fi

expect_failure "Distribution Halt Pending" run_halt_fixture raw-timeout
if /usr/bin/grep -F 'Distribution Halt completed' "$fixture_root/failure-output" >/dev/null; then
  fail "halt command claimed success before raw feed convergence"
fi
run_halt_fixture default "$halt_previous_feed" '' true >"$halt_success_output"
/usr/bin/grep -F 'resuming verification without another PUT' "$halt_success_output" >/dev/null ||
  fail "halt command did not report resume after Distribution Halt Pending"
if /usr/bin/grep -F 'api --include --method PUT' "$halt_fixture_dir/gh.log" >/dev/null; then
  fail "halt retry repeated PUT after Distribution Halt Pending"
fi
run_halt_fixture raw-intervening-then-previous \
  "$halt_previous_feed" '' true >"$halt_success_output"
[[ "$(<"$halt_fixture_dir/http-count")" == 2 ]] ||
  fail "already-halted retry did not allow the verified intervening feed during raw convergence"
if /usr/bin/grep -F 'api --include --method PUT' "$halt_fixture_dir/gh.log" >/dev/null; then
  fail "already-halted raw convergence performed PUT"
fi
expect_failure "raw Production Feed returned unknown bytes" run_halt_fixture \
  raw-unknown "$halt_previous_feed" '' true
if /usr/bin/grep -F 'api --include --method PUT' "$halt_fixture_dir/gh.log" >/dev/null; then
  fail "already-halted verification performed PUT before rejecting unknown raw bytes"
fi
for provenance_mode in provenance-read-failure provenance-malformed provenance-missing-parent; do
  case "$provenance_mode" in
    provenance-read-failure)
      expected_provenance_error="unable to fetch Production Feed commit history"
      ;;
    *)
      expected_provenance_error="invalid Production Feed commit history"
      ;;
  esac
  expect_failure "$expected_provenance_error" run_halt_fixture \
    "$provenance_mode" "$halt_previous_feed" '' true
  if /usr/bin/grep -F 'api --include --method PUT' "$halt_fixture_dir/gh.log" >/dev/null; then
    fail "halt provenance failure performed PUT: $provenance_mode"
  fi
done

[[ "$production_feed_sha" == "$(/usr/bin/shasum -a 256 "$inputs_dir/production/appcast.xml" | /usr/bin/awk '{print $1}')" ]] ||
  fail "verification changed signed production feed bytes"
[[ "$qualification_feed_sha" == "$(/usr/bin/shasum -a 256 "$inputs_dir/qualification/appcast.xml" | /usr/bin/awk '{print $1}')" ]] ||
  fail "verification changed signed qualification feed bytes"

assert_artifact_failure() {
  local expected_message="$1"

  expect_failure "$expected_message" verify_artifacts \
    "$inputs_dir" "$candidate_archive" "$candidate_manifest" "$candidate_info" \
    "$candidate_dir/version.env" "$candidate_dir/update.env"
}

make_feed "$inputs_dir/production/appcast.xml" 0.2.0 3 14.0 \
  "$production_url" "$archive_length" "$archive_signature"
assert_artifact_failure "sparkle:version does not match version.env"

make_feed "$inputs_dir/production/appcast.xml" 0.2.0 2 14.0 \
  "https://github.com/tangwz/codex-radar/releases/latest/download/$archive_name" \
  "$archive_length" "$archive_signature"
assert_artifact_failure "production enclosure URL must be version-fixed"

make_feed "$inputs_dir/production/appcast.xml" 0.2.0 2 14.0 \
  "$production_url" "$((archive_length + 1))" "$archive_signature"
assert_artifact_failure "enclosure length does not match archive"

make_feed "$inputs_dir/production/appcast.xml" 0.2.0 2 14.0 \
  "$production_url" "$archive_length" absent
assert_artifact_failure "enclosure is missing an Ed25519 signature"

make_feed "$inputs_dir/production/appcast.xml" 0.2.0 2 14.0 \
  "$production_url" "$archive_length" "$archive_signature"
printf ' ' >>"$inputs_dir/production/appcast.xml"
assert_artifact_failure "invalid signed feed block"

make_feed "$inputs_dir/production/appcast.xml" 0.2.0 2 14.0 \
  "$production_url" "$archive_length" "$archive_signature"
/usr/bin/perl -0pi -e \
  's/<!-- sparkle-signatures:/<!-- sparkle-signaturex:/' \
  "$inputs_dir/production/appcast.xml"
assert_artifact_failure "invalid signed feed block"

make_feed "$inputs_dir/production/appcast.xml" 0.2.0 2 14.0 \
  "$production_url" "$archive_length" "$archive_signature"
/usr/bin/tail -n 4 "$inputs_dir/production/appcast.xml" >"$fixture_root/original-feed-block"
/usr/bin/python3 - "$inputs_dir/production/appcast.xml" <<'PYTHON'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = path.read_bytes()
marker = b"<!-- sparkle-signatures:\n"
content, block = data.rsplit(marker, 1)
if b"CodexRadar" not in content:
    raise SystemExit("fixture feed does not contain a mutable signed byte")
path.write_bytes(content.replace(b"CodexRadar", b"CodexQadar", 1) + marker + block)
PYTHON
/usr/bin/tail -n 4 "$inputs_dir/production/appcast.xml" >"$fixture_root/mutated-feed-block"
/usr/bin/cmp -s "$fixture_root/original-feed-block" "$fixture_root/mutated-feed-block" ||
  fail "signed feed mutation changed the signature block"
assert_artifact_failure "production signed feed failed Ed25519 verification"

wrong_signature="$(sign_file "$fixture_root/empty")"
make_feed "$inputs_dir/production/appcast.xml" 0.2.0 2 14.0 \
  "$production_url" "$archive_length" "$wrong_signature"
make_feed "$inputs_dir/qualification/appcast.xml" 0.2.0 2 14.0 \
  "$archive_name" "$archive_length" "$wrong_signature"
assert_artifact_failure "production archive failed Ed25519 verification"

make_feed "$inputs_dir/production/appcast.xml" 0.2.0 2 14.0 \
  "$production_url" "$archive_length" "$archive_signature"
wrong_signature="$(sign_file "$fixture_root/empty")"
/usr/bin/python3 - "$inputs_dir/production/appcast.xml" "$wrong_signature" <<'PYTHON'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
signature = sys.argv[2].encode("ascii")
data = path.read_bytes()
prefix = b"edSignature: "
start = data.rfind(prefix)
end = data.find(b"\n", start)
if start < 0 or end < 0:
    raise SystemExit("fixture feed signature block is missing")
path.write_bytes(data[:start] + prefix + signature + data[end:])
PYTHON
assert_artifact_failure "production signed feed failed Ed25519 verification"

make_feed "$inputs_dir/production/appcast.xml" 0.2.0 2 14.0 \
  "$production_url" "$archive_length" "$archive_signature"
make_feed "$inputs_dir/qualification/appcast.xml" 0.2.0 2 14.0 \
  "$archive_name" "$archive_length" "$archive_signature"

make_feed "$inputs_dir/production/appcast.xml" 0.2.0 2 14.0 \
  "$production_url" "$archive_length" "$archive_signature"
make_feed "$inputs_dir/qualification/appcast.xml" 0.2.0 2 14.0 \
  "https://example.invalid/$archive_name" "$archive_length" "$archive_signature"
assert_artifact_failure "qualification enclosure URL must be relative"

make_feed "$inputs_dir/qualification/appcast.xml" 0.2.0 2 15.0 \
  "$archive_name" "$archive_length" "$archive_signature"
assert_artifact_failure "minimum system version does not match final Info.plist"

make_feed "$inputs_dir/qualification/appcast.xml" 0.2.0 2 14.0 \
  "$archive_name" "$archive_length" "$archive_signature" \
  '<sparkle:deltas><enclosure sparkle:deltaFrom="1"/></sparkle:deltas>'
assert_artifact_failure "feed must not contain deltas"

make_feed "$inputs_dir/qualification/appcast.xml" 0.2.0 2 14.0 \
  "$archive_name" "$archive_length" "$archive_signature" \
  '<sparkle:channel>beta</sparkle:channel>'
assert_artifact_failure "feed must not contain a channel"

make_feed "$inputs_dir/qualification/appcast.xml" 0.2.0 2 14.0 \
  "$archive_name" "$archive_length" "$archive_signature" \
  '<description>Changed</description>'
assert_artifact_failure "feed must not contain release notes"

make_feed "$inputs_dir/qualification/appcast.xml" 0.2.0 2 14.0 \
  "$archive_name" "$archive_length" "$archive_signature" '' true
assert_artifact_failure "feed must contain exactly one entry"

make_feed "$inputs_dir/qualification/appcast.xml" 0.2.0 2 14.0 \
  "$archive_name" "$archive_length" "$archive_signature"
bad_manifest="$fixture_root/bad.manifest"
/bin/cp "$candidate_manifest" "$bad_manifest"
printf 'unexpected=true\n' >>"$bad_manifest"
expect_failure "manifest bytes differ from prepared inputs" verify_artifacts \
  "$inputs_dir" "$candidate_archive" "$bad_manifest" "$candidate_info" \
  "$candidate_dir/version.env" "$candidate_dir/update.env"

different_info="$fixture_root/different-Info.plist"
/bin/cp "$candidate_info" "$different_info"
printf '\n' >>"$different_info"
expect_failure "Info.plist bytes differ from prepared inputs" verify_artifacts \
  "$inputs_dir" "$candidate_archive" "$candidate_manifest" "$different_info" \
  "$candidate_dir/version.env" "$candidate_dir/update.env"

unknown_feed="$fixture_root/unknown-feed.xml"
make_feed "$unknown_feed" 9.9.9 999 14.0 \
  "https://github.com/tangwz/codex-radar/releases/download/v9.9.9/unknown.zip" \
  99 "$archive_signature"

cas_output="$fixture_root/cas-output"
"$VERIFY_SCRIPT" --mode cas \
  --current-feed "$inputs_dir/previous-appcast.xml" \
  --expected-previous-feed "$inputs_dir/previous-appcast.xml" \
  --candidate-feed "$inputs_dir/production/appcast.xml" >"$cas_output"
/usr/bin/grep -Fx 'cas_state=ready' "$cas_output" >/dev/null || fail "CAS ready state was not reported"

"$VERIFY_SCRIPT" --mode cas \
  --current-feed "$inputs_dir/production/appcast.xml" \
  --expected-previous-feed "$inputs_dir/previous-appcast.xml" \
  --candidate-feed "$inputs_dir/production/appcast.xml" >"$cas_output"
/usr/bin/grep -Fx 'cas_state=already-active' "$cas_output" >/dev/null ||
  fail "CAS already-active state was not reported"

expect_failure "CAS conflict: current feed is neither expected nor candidate" \
  "$VERIFY_SCRIPT" --mode cas \
  --current-feed "$unknown_feed" \
  --expected-previous-feed "$inputs_dir/previous-appcast.xml" \
  --candidate-feed "$inputs_dir/production/appcast.xml"

"$VERIFY_SCRIPT" --mode cas --current-absent --expected-previous-absent \
  --candidate-feed "$inputs_dir/production/appcast.xml" >"$cas_output"
/usr/bin/grep -Fx 'cas_state=ready-bootstrap' "$cas_output" >/dev/null ||
  fail "CAS bootstrap state was not reported"

expect_failure "CAS conflict: expected an absent current feed" \
  "$VERIFY_SCRIPT" --mode cas \
  --current-feed "$inputs_dir/previous-appcast.xml" \
  --expected-previous-absent \
  --candidate-feed "$inputs_dir/production/appcast.xml"

expect_failure "CAS conflict: current feed is absent" \
  "$VERIFY_SCRIPT" --mode cas --current-absent \
  --expected-previous-feed "$inputs_dir/previous-appcast.xml" \
  --candidate-feed "$inputs_dir/production/appcast.xml"

mutable_sparkle_source="$fixture_root/mutable-Sparkle"
/usr/bin/git clone --quiet --no-local "$SPARKLE_SOURCE" "$mutable_sparkle_source"
/usr/bin/git -c advice.detachedHead=false -C "$mutable_sparkle_source" checkout --quiet --detach \
  b6496a74a087257ef5e6da1c5b29a447a60f5bd7
mutable_sparkle_source_path="$mutable_sparkle_source/$sparkle_source_file"
mutable_sparkle_injected_header="$mutable_sparkle_source/Vendor/ed25519-sparkle/src/stdlib.h"

printf '#include_next <stdlib.h>\n' >"$mutable_sparkle_injected_header"
expect_failure "Sparkle source checkout is dirty" verify_artifacts_with_sparkle \
  "$mutable_sparkle_source" \
  "$inputs_dir" "$candidate_archive" "$candidate_manifest" "$candidate_info" \
  "$candidate_dir/version.env" "$candidate_dir/update.env"
/bin/rm -f "$mutable_sparkle_injected_header"

/bin/cp "$mutable_sparkle_source_path" "$fixture_root/original-fe.c"
printf '\n' >>"$mutable_sparkle_source_path"
expect_failure "Sparkle source checkout is dirty" verify_artifacts_with_sparkle \
  "$mutable_sparkle_source" \
  "$inputs_dir" "$candidate_archive" "$candidate_manifest" "$candidate_info" \
  "$candidate_dir/version.env" "$candidate_dir/update.env"
/bin/cp "$fixture_root/original-fe.c" "$mutable_sparkle_source_path"

/usr/bin/git -C "$mutable_sparkle_source" update-index --assume-unchanged "$sparkle_source_file"
expect_failure "Sparkle source checkout has hidden index flags" verify_artifacts_with_sparkle \
  "$mutable_sparkle_source" \
  "$inputs_dir" "$candidate_archive" "$candidate_manifest" "$candidate_info" \
  "$candidate_dir/version.env" "$candidate_dir/update.env"
/usr/bin/git -C "$mutable_sparkle_source" update-index --no-assume-unchanged "$sparkle_source_file"

/usr/bin/git -C "$mutable_sparkle_source" update-index --skip-worktree "$sparkle_source_file"
expect_failure "Sparkle source checkout has hidden index flags" verify_artifacts_with_sparkle \
  "$mutable_sparkle_source" \
  "$inputs_dir" "$candidate_archive" "$candidate_manifest" "$candidate_info" \
  "$candidate_dir/version.env" "$candidate_dir/update.env"
/usr/bin/git -C "$mutable_sparkle_source" update-index --no-skip-worktree "$sparkle_source_file"

qualification_bundle="$fixture_root/qualification-bundle"
/usr/bin/ditto "$inputs_dir" "$qualification_bundle"
/bin/mkdir -p "$qualification_bundle/bin" \
  "$qualification_bundle/Frameworks/Sparkle.framework/Versions/A/Resources"
printf '#!/usr/bin/env bash\n[[ -z "${QUALIFY_TEST_CLI_LOG:-}" ]] || printf "cli\\n" >>"$QUALIFY_TEST_CLI_LOG"\nexit 0\n' >"$qualification_bundle/bin/sparkle"
/bin/chmod 755 "$qualification_bundle/bin/sparkle"
write_info_plist \
  "$qualification_bundle/Frameworks/Sparkle.framework/Versions/A/Resources/Info.plist" \
  2.9.4 1 14.0 "$PUBLIC_KEY"
/bin/ln -s A "$qualification_bundle/Frameworks/Sparkle.framework/Versions/Current"
/bin/ln -s Versions/Current/Resources "$qualification_bundle/Frameworks/Sparkle.framework/Resources"

previous_app="$fixture_root/previous-app/CodexRadar.app"
write_info_plist "$previous_app/Contents/Info.plist" 0.1.0 1 14.0 "$PUBLIC_KEY"
/bin/mkdir -p "$previous_app/Contents/MacOS"
printf '#!/usr/bin/env bash\nexit 0\n' >"$previous_app/Contents/MacOS/CodexRadar"
/bin/chmod 755 "$previous_app/Contents/MacOS/CodexRadar"

app_tree_manifest() {
  /usr/bin/python3 - "$1" <<'PYTHON'
import hashlib, os, stat, sys

root = os.path.realpath(sys.argv[1])
records = []
for base, dirs, files in os.walk(root, topdown=True, followlinks=False):
    names = sorted(dirs + files, key=os.fsencode)
    dirs[:] = [name for name in dirs if not os.path.islink(os.path.join(base, name))]
    for name in names:
        path = os.path.join(base, name)
        rel = os.path.relpath(path, root)
        mode = stat.S_IMODE(os.lstat(path).st_mode)
        if os.path.islink(path):
            records.append((rel, 'L', str(mode), os.readlink(path)))
        elif os.path.isfile(path):
            digest = hashlib.sha256()
            with open(path, 'rb') as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b''):
                    digest.update(chunk)
            records.append((rel, 'F', str(mode), digest.hexdigest()))
        elif os.path.isdir(path):
            records.append((rel, 'D', str(mode), ''))
        else:
            raise SystemExit('unsupported file type: ' + rel)
print(hashlib.sha256(repr(sorted(records)).encode()).hexdigest())
PYTHON
}

previous_tree_manifest="$(app_tree_manifest "$previous_app")"

qualification_python="$fixture_root/qualification-python"
qualification_runner="$fixture_root/qualification-runner"
qualification_python_log="$fixture_root/qualification-python.log"
qualification_runner_arguments="$fixture_root/qualification-runner.arguments"
qualification_cli_log="$fixture_root/qualification-cli.log"
qualification_server_pid="$fixture_root/qualification-server.pid"
qualification_harness_pid="$fixture_root/qualification-harness.pid"
cat >"$qualification_python" <<'PYTHON_WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
printf 'python\n' >>"$QUALIFY_TEST_PYTHON_LOG"
if [[ "${QUALIFY_TEST_PYTHON_MODE:-}" == server-exits && "$#" -eq 4 && "$1" == - && "$4" == *.port ]]; then
  printf '49152\n' >"$4"
  exit 0
fi
exec /usr/bin/python3 "$@"
PYTHON_WRAPPER
cat >"$qualification_runner" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$@" >"$QUALIFY_TEST_RUNNER_ARGUMENTS"
[[ "$#" -eq 9 ]]
[[ "$(/usr/bin/basename "$1")" == sparkle-cli ]]
[[ "$1" != "$QUALIFY_TEST_BUNDLE_CLI" ]]
[[ "$3" == --application ]]
[[ "$4" == "$2" ]]
[[ "$5" == --check-immediately ]]
[[ "$6" == --feed-url ]]
[[ "$7" =~ ^http://127\.0\.0\.1:[1-9][0-9]*/appcast\.xml$ ]]
[[ "$8" == --interactive ]]
[[ "$9" == --verbose ]]
/usr/bin/curl --fail --silent "$7" >/dev/null

case "${QUALIFY_TEST_RUNNER_MODE:-success}" in
  success)
    /bin/cp "$QUALIFY_TEST_CANDIDATE_INFO" "$2/Contents/Info.plist"
    ;;
  mutate-source)
    printf 'mutated source bundle\n' >"$QUALIFY_TEST_SOURCE_BUNDLE/qualification/appcast.xml"
    /usr/bin/curl --fail --silent "$7" | /usr/bin/cmp -s - "$QUALIFY_TEST_EXPECTED_FEED"
    /bin/cp "$QUALIFY_TEST_CANDIDATE_INFO" "$2/Contents/Info.plist"
    ;;
  install-info)
    /bin/cp "$QUALIFY_TEST_INSTALLED_INFO" "$2/Contents/Info.plist"
    ;;
  wait-for-signal)
    : >"$QUALIFY_TEST_RUNNER_READY"
    while [[ ! -e "$QUALIFY_TEST_RUNNER_RELEASE" ]]; do /bin/sleep .05; done
    ;;
  failure)
    exit 17
    ;;
  signal-int)
    /bin/kill -INT "$(<"$QUALIFY_TEST_HARNESS_PID_FILE")"
    exit 0
    ;;
  signal-term)
    /bin/kill -TERM "$(<"$QUALIFY_TEST_HARNESS_PID_FILE")"
    exit 0
    ;;
  *)
    exit 2
    ;;
esac
RUNNER
qualification_ditto="$fixture_root/qualification-ditto"
cat >"$qualification_ditto" <<'DITTO'
#!/usr/bin/env bash
set -euo pipefail

case "${QUALIFY_TEST_DITTO_MODE:-copy}" in
  copy)
    ;;
  mutate)
    /usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 99' "$1/Contents/Info.plist"
    ;;
  replace)
    replacement="$1.replacement"
    original="$1.original"
    /usr/bin/ditto "$1" "$replacement"
    /bin/mv "$1" "$original"
    /bin/mv "$replacement" "$1"
    ;;
  *)
    exit 2
    ;;
esac

exec /usr/bin/ditto "$@"
DITTO
/bin/chmod 755 "$qualification_python" "$qualification_runner" "$qualification_ditto"

qualification_fetch="$fixture_root/qualification-fetch"
qualification_harness="$fixture_root/qualify-update-harness.sh"
qualification_tools_root="$fixture_root/qualification-tools"
qualification_tools_archive="$fixture_root/Sparkle-2.9.4-test.tar.xz"
/bin/mkdir -p "$qualification_tools_root/bin"
printf 'fixture\n' >"$qualification_tools_root/bin/placeholder"
/usr/bin/tar -cJf "$qualification_tools_archive" -C "$qualification_tools_root" .
qualification_tools_sha="$(/usr/bin/shasum -a 256 "$qualification_tools_archive" | /usr/bin/awk '{print $1}')"
{
  printf '#!/usr/bin/env bash\nset -euo pipefail\n'
  printf '[[ "$1" == "https://raw.githubusercontent.com/tangwz/codex-radar/main/appcast.xml" ]]\n'
  printf '/bin/cp "$QUALIFY_TEST_CURRENT_FEED" "$2"\n'
} >"$qualification_fetch"
/bin/chmod 755 "$qualification_fetch"
/usr/bin/sed \
  -e "s/^EXPECTED_TOOLS_SHA256=.*/EXPECTED_TOOLS_SHA256=\"$qualification_tools_sha\"/" \
  -e 's/^TEST_HARNESS=false/TEST_HARNESS=true/' \
  "$QUALIFY_SCRIPT" >"$qualification_harness"
/bin/chmod 755 "$qualification_harness"

run_qualification() {
  local bundle_path="${1:-$qualification_bundle}"
  local app_path="${2:-$previous_app}"
  local current_feed="${3:-$previous_dir/appcast.xml}"

  env \
    QUALIFY_PYTHON_EXECUTABLE="$qualification_python" \
    QUALIFY_TEST_CLI="$qualification_bundle/bin/sparkle" \
    QUALIFY_RUNNER="$qualification_runner" \
    QUALIFY_FETCH_EXECUTABLE="$qualification_fetch" \
    QUALIFY_VERIFY_SCRIPT="$VERIFY_SCRIPT" \
    QUALIFY_VERSION_CONFIG="$candidate_dir/version.env" \
    QUALIFY_UPDATE_CONFIG="$candidate_dir/update.env" \
    QUALIFY_SPARKLE_SOURCE="$SPARKLE_SOURCE" \
    QUALIFY_TEST_PYTHON_LOG="$qualification_python_log" \
    QUALIFY_TEST_RUNNER_ARGUMENTS="$qualification_runner_arguments" \
    QUALIFY_TEST_BUNDLE_CLI="$qualification_bundle/bin/sparkle" \
    QUALIFY_TEST_CANDIDATE_INFO="$candidate_info" \
    QUALIFY_TEST_CURRENT_FEED="$current_feed" \
    QUALIFY_TEST_SOURCE_BUNDLE="$bundle_path" \
    QUALIFY_TEST_EXPECTED_FEED="$qualification_expected_feed" \
    QUALIFY_TEST_DITTO="$qualification_ditto" \
    QUALIFY_TEST_SERVER_PID_FILE="$qualification_server_pid" \
    QUALIFY_TEST_HARNESS_PID_FILE="$qualification_harness_pid" \
    QUALIFY_TEST_DITTO_MODE="${QUALIFY_TEST_DITTO_MODE:-copy}" \
    QUALIFY_TEST_PYTHON_MODE="${QUALIFY_TEST_PYTHON_MODE:-}" \
    QUALIFY_TEST_RUNNER_MODE="${QUALIFY_TEST_RUNNER_MODE:-success}" \
    QUALIFY_TEST_INSTALLED_INFO="${QUALIFY_TEST_INSTALLED_INFO:-}" \
    QUALIFY_TEST_RUNNER_READY="${QUALIFY_TEST_RUNNER_READY:-}" \
    QUALIFY_TEST_RUNNER_RELEASE="${QUALIFY_TEST_RUNNER_RELEASE:-}" \
    "$qualification_harness" --bundle "$bundle_path" --previous-app "$app_path" \
    --tools-archive "$qualification_tools_archive"
}

run_qualification_without_runner() {
  local bundle_path="$1" app_path="$2" current_feed="$3"

  env \
    QUALIFY_PYTHON_EXECUTABLE="$qualification_python" \
    QUALIFY_TEST_CLI="$qualification_bundle/bin/sparkle" \
    QUALIFY_RUNNER="" \
    QUALIFY_FETCH_EXECUTABLE="$qualification_fetch" \
    QUALIFY_VERIFY_SCRIPT="$VERIFY_SCRIPT" \
    QUALIFY_VERSION_CONFIG="$candidate_dir/version.env" \
    QUALIFY_UPDATE_CONFIG="$candidate_dir/update.env" \
    QUALIFY_SPARKLE_SOURCE="$SPARKLE_SOURCE" \
    QUALIFY_TEST_PYTHON_LOG="$qualification_python_log" \
    QUALIFY_TEST_CLI_LOG="$qualification_cli_log" \
    QUALIFY_TEST_CURRENT_FEED="$current_feed" \
    QUALIFY_TEST_DITTO="$qualification_ditto" \
    QUALIFY_TEST_SERVER_PID_FILE="$qualification_server_pid" \
    QUALIFY_TEST_HARNESS_PID_FILE="$qualification_harness_pid" \
    QUALIFY_TEST_DITTO_MODE="${QUALIFY_TEST_DITTO_MODE:-copy}" \
    QUALIFY_TEST_PYTHON_MODE="${QUALIFY_TEST_PYTHON_MODE:-}" \
    "$qualification_harness" --bundle "$bundle_path" --previous-app "$app_path" \
    --tools-archive "$qualification_tools_archive"
}

assert_preflight_did_not_run_update() {
  [[ ! -s "$qualification_runner_arguments" ]] || fail "qualification invoked runner before rejecting input"
  [[ ! -s "$qualification_cli_log" ]] || fail "qualification invoked CLI before rejecting input"
}

expect_preflight_failure() {
  local expected_message="$1"
  shift
  : >"$qualification_runner_arguments"
  : >"$qualification_cli_log"
  : >"$qualification_python_log"
  expect_failure "$expected_message" run_qualification_without_runner "$@"
  assert_preflight_did_not_run_update
}

expect_preflight_rejection() {
  local bundle_path="$1" app_path="$2" current_feed="$3"
  local output_path="$fixture_root/preflight-output"

  : >"$qualification_runner_arguments"
  : >"$qualification_cli_log"
  : >"$qualification_python_log"
  if run_qualification_without_runner "$bundle_path" "$app_path" "$current_feed" >"$output_path" 2>&1; then
    /bin/cat "$output_path" >&2
    fail "qualification accepted invalid preflight input"
  fi
  assert_preflight_did_not_run_update
}

expect_installed_rejection() {
  local key="$1" installed_info="$2"
  local output_path="$fixture_root/installed-output"

  : >"$qualification_runner_arguments"
  if QUALIFY_TEST_RUNNER_MODE=install-info QUALIFY_TEST_INSTALLED_INFO="$installed_info" \
    run_qualification >"$output_path" 2>&1; then
    /bin/cat "$output_path" >&2
    fail "qualification accepted an installed application with invalid $key"
  fi
  /usr/bin/grep -F "installed application $key does not match qualification bundle" "$output_path" >/dev/null || {
    /bin/cat "$output_path" >&2
    fail "qualification did not reject invalid installed $key"
  }
  [[ -s "$qualification_runner_arguments" ]] || fail "qualification did not run the fixture installer"
}

qualification_expected_feed="$fixture_root/expected-qualification-appcast.xml"
/bin/cp "$qualification_bundle/qualification/appcast.xml" "$qualification_expected_feed"

: >"$qualification_python_log"
run_qualification
[[ -s "$qualification_runner_arguments" ]] || fail "qualification did not invoke runner"
[[ ! -e "$(/usr/bin/dirname "$(/usr/bin/sed -n '2p' "$qualification_runner_arguments")")" ]] ||
  fail "qualification did not clean copied application"
[[ "$previous_tree_manifest" == "$(app_tree_manifest "$previous_app")" ]] ||
  fail "qualification changed original previous application"

replaced_source_app="$fixture_root/replaced-source/CodexRadar.app"
/usr/bin/ditto "$previous_app" "$replaced_source_app"
replaced_source_tree="$(app_tree_manifest "$replaced_source_app")"
QUALIFY_TEST_DITTO_MODE=replace expect_preflight_failure "previous application directory changed while being copied" \
  "$qualification_bundle" "$replaced_source_app" "$previous_dir/appcast.xml"
[[ "$replaced_source_tree" == "$(app_tree_manifest "$replaced_source_app")" ]] ||
  fail "source replacement did not preserve the original whole-tree fixture"

mutated_source_app="$fixture_root/mutated-source/CodexRadar.app"
/usr/bin/ditto "$previous_app" "$mutated_source_app"
mutated_source_tree="$(app_tree_manifest "$mutated_source_app")"
QUALIFY_TEST_DITTO_MODE=mutate expect_preflight_failure "previous application changed while being copied" \
  "$qualification_bundle" "$mutated_source_app" "$previous_dir/appcast.xml"
[[ "$mutated_source_tree" != "$(app_tree_manifest "$mutated_source_app")" ]] ||
  fail "copy mutation fixture did not alter the source application"

current_feed_mismatch="$fixture_root/current-production-feed-mismatch.xml"
make_feed "$current_feed_mismatch" 0.1.0 1 14.0 "$previous_url" 123 "$archive_signature" \
  '' false CodexRadarCurrent
expect_preflight_failure "bundled previous Production Feed is stale" \
  "$qualification_bundle" "$previous_app" "$current_feed_mismatch"

escaping_contents_app="$fixture_root/escaping-contents/CodexRadar.app"
escaping_target="$fixture_root/escaping-target"
/usr/bin/ditto "$previous_app" "$escaping_contents_app"
/bin/mkdir -p "$escaping_target"
/bin/mv "$escaping_contents_app/Contents" "$escaping_contents_app/RealContents"
/bin/ln -s "$escaping_target" "$escaping_contents_app/Contents"
expect_preflight_failure "application contains an unresolved or escaping symlink: Contents" \
  "$qualification_bundle" "$escaping_contents_app" "$previous_dir/appcast.xml"

internal_symlink_app="$fixture_root/internal-symlink/CodexRadar.app"
/usr/bin/ditto "$previous_app" "$internal_symlink_app"
/bin/ln -s MacOS "$internal_symlink_app/Contents/InternalExecutableDirectory"
internal_symlink_tree="$(app_tree_manifest "$internal_symlink_app")"
run_qualification "$qualification_bundle" "$internal_symlink_app" "$previous_dir/appcast.xml"
[[ "$internal_symlink_tree" == "$(app_tree_manifest "$internal_symlink_app")" ]] ||
  fail "qualification changed the internal-symlink source application"

snapshot_mutation_bundle="$fixture_root/snapshot-mutation-bundle"
/usr/bin/ditto "$qualification_bundle" "$snapshot_mutation_bundle"
QUALIFY_TEST_RUNNER_MODE=mutate-source run_qualification \
  "$snapshot_mutation_bundle" "$previous_app" "$previous_dir/appcast.xml"
[[ ! -s "$qualification_runner_arguments" ]] && fail "qualification did not run the snapshot mutation fixture"
/usr/bin/cmp -s "$snapshot_mutation_bundle/qualification/appcast.xml" "$qualification_expected_feed" &&
  fail "source bundle mutation did not change the source feed"

QUALIFY_TEST_PYTHON_MODE=server-exits expect_preflight_failure \
  "qualification HTTP server exited after publishing its port" \
  "$qualification_bundle" "$previous_app" "$previous_dir/appcast.xml"

for key in CFBundleShortVersionString CFBundleVersion SUFeedURL SUPublicEDKey; do
  invalid_installed_info="$fixture_root/invalid-installed-$key.plist"
  /bin/cp "$candidate_info" "$invalid_installed_info"
  /usr/libexec/PlistBuddy -c "Set :$key invalid" "$invalid_installed_info"
  expect_installed_rejection "$key" "$invalid_installed_info"
done
for key in SUEnableAutomaticChecks SUAutomaticallyUpdate SUVerifyUpdateBeforeExtraction SURequireSignedFeed CodexRadarUpdatesEnabled; do
  invalid_installed_info="$fixture_root/invalid-installed-$key.plist"
  /bin/cp "$candidate_info" "$invalid_installed_info"
  /usr/libexec/PlistBuddy -c "Set :$key false" "$invalid_installed_info"
  expect_installed_rejection "$key" "$invalid_installed_info"
done

for key in CFBundleShortVersionString CFBundleVersion SUFeedURL SUPublicEDKey; do
  invalid_bundle="$fixture_root/invalid-bundle-$key"
  /usr/bin/ditto "$qualification_bundle" "$invalid_bundle"
  /usr/libexec/PlistBuddy -c "Set :$key invalid" "$invalid_bundle/Info.plist"
  expect_preflight_rejection "$invalid_bundle" "$previous_app" "$previous_dir/appcast.xml"
done
for key in SUEnableAutomaticChecks SUAutomaticallyUpdate SUVerifyUpdateBeforeExtraction SURequireSignedFeed CodexRadarUpdatesEnabled; do
  invalid_bundle="$fixture_root/invalid-bundle-$key"
  /usr/bin/ditto "$qualification_bundle" "$invalid_bundle"
  /usr/libexec/PlistBuddy -c "Set :$key false" "$invalid_bundle/Info.plist"
  expect_preflight_rejection "$invalid_bundle" "$previous_app" "$previous_dir/appcast.xml"
done

bad_manifest_bundle="$fixture_root/bad-manifest-qualification-bundle"
/usr/bin/ditto "$qualification_bundle" "$bad_manifest_bundle"
printf 'unexpected=true\n' >>"$bad_manifest_bundle/manifest"
: >"$qualification_python_log"
if env \
  QUALIFY_PYTHON_EXECUTABLE="$qualification_python" \
  QUALIFY_TEST_CLI="$bad_manifest_bundle/bin/sparkle" \
  QUALIFY_RUNNER="$qualification_runner" \
  QUALIFY_FETCH_EXECUTABLE="$qualification_fetch" \
  QUALIFY_VERIFY_SCRIPT="$VERIFY_SCRIPT" \
  QUALIFY_VERSION_CONFIG="$candidate_dir/version.env" \
  QUALIFY_UPDATE_CONFIG="$candidate_dir/update.env" \
  QUALIFY_SPARKLE_SOURCE="$SPARKLE_SOURCE" \
  QUALIFY_TEST_PYTHON_LOG="$qualification_python_log" \
  QUALIFY_TEST_RUNNER_ARGUMENTS="$qualification_runner_arguments" \
  QUALIFY_TEST_BUNDLE_CLI="$bad_manifest_bundle/bin/sparkle" \
  QUALIFY_TEST_CANDIDATE_INFO="$candidate_info" \
  QUALIFY_TEST_CURRENT_FEED="$previous_dir/appcast.xml" \
  "$qualification_harness" --bundle "$bad_manifest_bundle" --previous-app "$previous_app" \
  --tools-archive "$qualification_tools_archive"; then
  fail "qualification accepted an invalid manifest"
fi
[[ ! -s "$qualification_python_log" ]] || fail "qualification started a server before manifest validation"

forged_bundle_cli="$qualification_bundle/bin/sparkle"
printf '#!/usr/bin/env bash\necho forged\n' >"$forged_bundle_cli"
/bin/chmod 755 "$forged_bundle_cli"
run_qualification
[[ "$(/usr/bin/sed -n '1p' "$qualification_runner_arguments")" != "$forged_bundle_cli" ]] ||
  fail "qualification executed a forged bundle CLI"

: >"$qualification_python_log"
if QUALIFY_TEST_RUNNER_MODE=failure run_qualification; then
  fail "qualification accepted a failed Sparkle command"
fi
[[ ! -e "$(/usr/bin/dirname "$(/usr/bin/sed -n '2p' "$qualification_runner_arguments")")" ]] ||
  fail "qualification did not clean copied application after runner failure"

for signal_mode in signal-int signal-term; do
  : >"$qualification_server_pid"
  : >"$qualification_python_log"
  if QUALIFY_TEST_RUNNER_MODE="$signal_mode" run_qualification; then
    fail "qualification accepted $signal_mode"
  else
    signal_status="$?"
  fi
  [[ "$signal_status" == "$([[ "$signal_mode" == signal-int ]] && echo 130 || echo 143)" ]] ||
    fail "qualification returned $signal_status after $signal_mode"
  [[ -s "$qualification_server_pid" ]] || fail "qualification did not record server PID for $signal_mode"
  server_pid="$(<"$qualification_server_pid")"
  /bin/kill -0 "$server_pid" 2>/dev/null && fail "qualification left server $server_pid alive after $signal_mode"
  [[ ! -e "$(/usr/bin/dirname "$(/usr/bin/sed -n '2p' "$qualification_runner_arguments")")" ]] ||
    fail "qualification did not clean copied application after $signal_mode"
done

echo "update feed fixtures passed"

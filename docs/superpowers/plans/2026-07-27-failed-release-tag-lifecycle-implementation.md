# Failed Release Tag Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make failed release recovery delete only the failed GitHub Release while permanently retaining every pushed `v*` tag, then require a higher version and build under a new tag for the next attempt.

**Architecture:** Keep the existing Candidate, publication, public reverification, and Production Feed activation pipeline. Narrow the pre-activation cleanup trap to Release-only cleanup, enforce the protected-tag invariant in the repository workflow-policy test, and align every operator-facing or normative release document with the same state machine.

**Tech Stack:** GitHub Actions YAML, Bash, embedded Ruby and Python policy fixtures, GitHub CLI, Markdown

**Design Spec:** `docs/superpowers/specs/2026-07-27-failed-release-tag-lifecycle-design.md`

## Global Constraints

- Every pushed `v<MARKETING_VERSION>` tag is permanent: never delete, move, overwrite, or recreate it.
- Keep the `Protect immutable release tags` ruleset active for `refs/tags/v*`, with update and deletion blocked and no bypass actor.
- A pushed tag immediately burns its App Version, build number, and tag, even if failure occurs before Draft Release creation.
- A retry must commit a higher unused `MARKETING_VERSION`, a strictly increasing `BUILD_NUMBER`, and a matching new `v<MARKETING_VERSION>` tag.
- Do not use Candidate or retry suffixes to reuse an App Version.
- Candidate qualification failure deletes only the Draft Release; public reverification failure deletes only the public Release.
- Do not configure a user, repository role, GitHub App, or GitHub Actions ruleset bypass.
- Do not split Candidate and final Release tags.
- Do not change Sparkle signing, qualification, public verification, Production Feed compare-and-swap, Activation Pending, or Distribution Halt semantics.
- Do not add automatic cleanup to `.github/workflows/prepare-candidate.yml`.
- All code, identifiers, comments, commit messages, and code blocks remain English.

---

## File Responsibility Map

- `.github/workflows/publish-update.yml`: owns publication, public reverification, and the pre-activation failure trap. It may delete a failed Release but must never mutate or delete its tag.
- `Tests/ScriptTests/update_feed_tests.sh`: owns the static workflow and operator-document policy contract, including adversarial fixtures that prove protected-tag deletion is rejected.
- `docs/releasing.md`: owns executable Release Operator recovery instructions for failure before Draft creation, Candidate qualification failure, and public reverification failure.
- `docs/superpowers/specs/2026-07-19-automatic-updates-design.md`: remains the broad automatic-update architecture document and must not contradict the newer failed-tag lifecycle spec.
- `docs/superpowers/plans/2026-07-19-secure-automatic-updates-implementation.md`: is retained as implementation history, but its actionable release cleanup statements must describe the repository's final invariant accurately.
- `.github/workflows/prepare-candidate.yml`: no change. Candidate qualification occurs after this workflow completes, so the operator owns Draft Release cleanup.
- GitHub repository rulesets: no change. The active `v*` update/deletion protection without bypass is the invariant this implementation accommodates.

---

### Task 1: Enforce Release-only cleanup in the publication workflow

**Files:**
- Modify: `Tests/ScriptTests/update_feed_tests.sh:460-530`
- Modify: `Tests/ScriptTests/update_feed_tests.sh:742-755`
- Modify: `.github/workflows/publish-update.yml:155-166`

**Interfaces:**
- Consumes: the existing `publish_run` string assembled from every `run` block in `publish-and-verify`, the existing `validate_workflow_policy` helper, and the `TAG` workflow environment variable.
- Produces: the exact cleanup command `gh release delete "$TAG" --yes`, the policy error `publish-update.yml must never delete a protected release tag`, and a trap that exits with the original public-verification failure status.

- [ ] **Step 1: Change the workflow-policy assertion to require Release-only cleanup and reject remote tag deletion**

In the required publish-verification snippet list, replace the existing cleanup entry with:

```ruby
"gh release delete \"$TAG\" --yes"
```

Immediately after that required-snippet loop, add a line-oriented protected-tag policy:

```ruby
forbidden_tag_delete = publish_run.lines.any? do |line|
  line.include?("--cleanup-tag") ||
    line.match?(/\bgit push\b.*\s--delete(?:\s|$)/) ||
    line.match?(/\bgit push\b.*:refs\/tags\//) ||
    (
      line.match?(/\bgh api\b.*git\/refs\/tags\//) &&
      line.match?(/(?:--method|-X)\s+DELETE\b/)
    )
end
if forbidden_tag_delete
  reject("publish-update.yml must never delete a protected release tag")
end
```

Keep the existing activation-stage prohibition unchanged. It has a narrower responsibility: after activation starts, neither the Release nor tag may be deleted.

- [ ] **Step 2: Add adversarial fixtures for both supported tag-deletion forms**

After the `publish_without_draft_download` fixture, add a fixture proving that `--cleanup-tag` is rejected:

```bash
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
```

Add a second fixture proving that a direct remote tag deletion is rejected:

```bash
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
```

- [ ] **Step 3: Run the policy test and verify the new contract fails against the current workflow**

Run:

```bash
bash Tests/ScriptTests/update_feed_tests.sh
```

Expected: FAIL before the artifact-verification fixtures run, with:

```text
publish-update.yml must never delete a protected release tag
```

The failure is caused by the current `--cleanup-tag` argument. Do not weaken the new assertion to make the current workflow pass.

- [ ] **Step 4: Make the public-reverification trap delete only the Release**

In `cleanup_failed_publication`, preserve the existing status capture, release-state check, trap placement, and final `exit "$status"`. Replace only the public-failure branch with:

```bash
if [[ "$release_is_draft" == false ]]; then
  echo "Public verification failed; deleting the Release and retaining burned tag $TAG." >&2
  if ! gh release delete "$TAG" --yes; then
    echo "Automatic Release cleanup failed; Release Operator must delete the Release without deleting tag $TAG." >&2
  fi
elif [[ "$release_is_draft" != true ]]; then
  echo "Release state is unknown; Release Operator intervention is required." >&2
fi
```

Do not add `git push`, `git tag`, `gh api DELETE`, or ruleset-bypass behavior. A cleanup failure remains secondary to the original public-verification failure, so the trap must still exit with the captured `status`.

- [ ] **Step 5: Run focused syntax and policy verification**

Run:

```bash
bash -n Tests/ScriptTests/update_feed_tests.sh
ruby -e 'require "yaml"; YAML.safe_load_file(".github/workflows/publish-update.yml", aliases: true)'
bash Tests/ScriptTests/update_feed_tests.sh
```

Expected:

- Bash syntax check exits `0`.
- YAML safe load exits `0`.
- The complete update-feed test exits `0`.
- Both adversarial workflows fail inside `expect_failure` with the protected-tag policy error, so the enclosing test continues and passes.

- [ ] **Step 6: Review the workflow diff for cleanup scope**

Run:

```bash
git diff --check
git diff -- .github/workflows/publish-update.yml Tests/ScriptTests/update_feed_tests.sh
```

Expected: the workflow diff changes only the cleanup log and `gh release delete` arguments. The test diff adds the Release-only requirement and adversarial protected-tag fixtures; it does not alter signing, verification, CAS, or Activation Pending assertions.

- [ ] **Step 7: Commit the workflow and policy contract**

```bash
git add .github/workflows/publish-update.yml Tests/ScriptTests/update_feed_tests.sh
git commit -m "ci: retain failed release tags"
```

---

### Task 2: Align operator recovery and retained release architecture documents

**Files:**
- Modify: `Tests/ScriptTests/update_feed_tests.sh:548-563`
- Modify: `docs/releasing.md:35-70`
- Modify: `docs/superpowers/specs/2026-07-19-automatic-updates-design.md:241-288`
- Modify: `docs/superpowers/plans/2026-07-19-secure-automatic-updates-implementation.md:686`
- Modify: `docs/superpowers/plans/2026-07-19-secure-automatic-updates-implementation.md:699-733`

**Interfaces:**
- Consumes: the permanent-tag state machine from `docs/superpowers/specs/2026-07-27-failed-release-tag-lifecycle-design.md` and the Release-only workflow contract from Task 1.
- Produces: executable operator recovery guidance using `gh release delete v0.2.0 --yes`, explicit prohibitions for `--cleanup-tag` and `git push --delete`, and no retained document instructing an operator or workflow to delete a failed `v*` tag.

- [ ] **Step 1: Extend the releasing-document contract with stable command and policy markers**

Append these English command and configuration markers to the `releasing` required-snippet array:

```ruby
"Protect immutable release tags",
"gh release delete v0.2.0 --yes",
"--cleanup-tag",
"git push --delete",
"v<MARKETING_VERSION>"
```

These snippets intentionally test stable identifiers and executable commands rather than coupling the test to an entire Chinese paragraph. Workflow tests from Task 1 separately ensure `--cleanup-tag` and tag deletion cannot appear in executable workflow code.

- [ ] **Step 2: Run the policy test and verify the handbook contract fails**

Run:

```bash
bash Tests/ScriptTests/update_feed_tests.sh
```

Expected: FAIL with the first absent handbook marker:

```text
docs/releasing.md lacks required guidance: Protect immutable release tags
```

- [ ] **Step 3: Document the unchanged GitHub ruleset boundary**

Under `docs/releasing.md` → “GitHub 配置”, add this exact bullet:

> - 保持 `Protect immutable release tags` ruleset 对 `refs/tags/v*` 的 update 与 deletion 禁止规则，且不配置 bypass actor。

This is an external repository prerequisite, not an instruction to mutate GitHub settings during implementation.

- [ ] **Step 4: Document when a version becomes burned**

Immediately after the numbered Candidate preparation steps, add:

> `v<MARKETING_VERSION>` tag 一经推送，App Version、build number 和 tag 就永久被该次尝试占用。即使 workflow 在创建 Draft Release 前失败，也不删除或重跑该 tag；修复必须同时提高 `MARKETING_VERSION` 和 `BUILD_NUMBER`，合入 `main` 后创建匹配的新 tag。

Keep the bootstrap exception and manual dry-run sections unchanged.

- [ ] **Step 5: Replace the public-reverification failure paragraph**

Replace the paragraph that says the workflow deletes both Release and tag with:

> 公开资产复验失败时，workflow 会尝试只删除刚公开的 Release，永久保留已经 burned 的 tag，且 Production Feed 不得推进。如果自动清理失败，停止发布并由 Release Operator 执行下文相同的 Release-only cleanup。无论自动清理是否成功，后续发布都必须使用更高且从未使用的 App Version、严格递增的 build number 和匹配的新 tag。

Do not change the following CAS and Activation Pending paragraphs.

- [ ] **Step 6: Replace Candidate failure guidance with the three explicit recovery states**

Under “失败与密钥事件”, replace the current Candidate cleanup paragraph with the following prose and command:

> tag 推送后、Draft Release 创建前失败时，不存在需要清理的 Release。保留 tag，不重新运行该 tag；提高 App Version 和 build number 后创建新 tag。
>
> Candidate 资格测试失败或证据不足时，只删除不可见的 Draft Release。以下示例中的 tag 必须替换为本次失败的实际 tag：

```bash
gh release delete v0.2.0 --yes
```

> 公开复验失败时，workflow 执行同一个 Release-only cleanup；自动清理失败时，Release Operator 手动执行上述命令。失败 tag 永久保留，且 App Version、build number 和 tag 均视为 burned。
>
> 任何失败恢复都不得使用 `--cleanup-tag`、`git push --delete`、移动 tag 或重新推送旧 tag。新尝试必须同时提高 `MARKETING_VERSION` 和 `BUILD_NUMBER`，并创建新的 `v<MARKETING_VERSION>` tag；不得添加 Candidate 或 retry 后缀来复用相同 App Version。

Keep the subsequent private-key incident procedure unchanged.

- [ ] **Step 7: Update the broad automatic-update design so it no longer requires tag cleanup**

In `docs/superpowers/specs/2026-07-19-automatic-updates-design.md`, replace the combined failure paragraph with:

> `v*` tag 一经推送即永久保留。Candidate Release 资格失败时，Release Operator 运行受控清理命令，只删除不可见的 Draft Release；公开后的 Immutable Pre-release 若未通过第 12 步，workflow 只删除该 Release。两种失败都会永久作废对应 App Version、build number 和 tag，修复必须同时提高版本和 build number，并使用匹配的新 tag；任何阶段都不得用相同版本标识重新构建或重试。Release 自动删除或公开复验失败时停止 workflow 并要求 Release Operator 介入，不激活 Production Feed。

Replace the historical-transition paragraph with:

> 本协议在自动更新启用后取代早期 GitHub Release 设计中的 Draft 复用规则；已经公开并成功进入 Production Feed 的 Release 仍然不可删除、替换或复用。

Expand the existing version-allocation bullet to:

> - 一旦 `v*` tag 触发发布，App Version、build number 和 tag 即被该次构建占用；无论失败发生在 Draft 创建前、Draft 资格测试还是公开复验阶段，都必须永久作废这组三个标识并保留原 tag。下一次尝试必须同时提高版本和 build number，并创建匹配的新 tag。

Do not change the numbered publication order, feed CAS rules, or Activation Pending rules.

- [ ] **Step 8: Correct the retained secure-update implementation history**

In `docs/superpowers/plans/2026-07-19-secure-automatic-updates-implementation.md`, replace the failed-Candidate sentence with:

```text
The same repository/tag concurrency group is later used by `publish-update`. A failed candidate keeps its burned tag permanently; the operator deletes only an existing Draft Release, then retries with a higher version, build number, and matching new tag.
```

Replace item 6 under the publish workflow requirements with:

```text
6. on public-verification failure, delete only the Release, retain the burned tag and leave Production Feed unchanged;
```

The document remains historical; make no other retroactive changes.

- [ ] **Step 9: Run documentation, syntax, and workflow verification**

Run:

```bash
bash -n Tests/ScriptTests/update_feed_tests.sh
bash Tests/ScriptTests/update_feed_tests.sh
ruby -e 'require "yaml"; YAML.safe_load_file(".github/workflows/publish-update.yml", aliases: true)'
git diff --check
rg -n 'gh release delete|git push --delete|cleanup-tag' \
  .github/workflows/publish-update.yml \
  Tests/ScriptTests/update_feed_tests.sh \
  docs/releasing.md \
  docs/superpowers/specs/2026-07-19-automatic-updates-design.md \
  docs/superpowers/specs/2026-07-27-failed-release-tag-lifecycle-design.md \
  docs/superpowers/plans/2026-07-19-secure-automatic-updates-implementation.md
```

Expected:

- Bash syntax, complete update-feed tests, YAML parsing, and diff checking all succeed.
- `.github/workflows/publish-update.yml` contains only `gh release delete "$TAG" --yes`; it contains no tag-deletion command.
- Test fixtures contain deliberately forbidden `--cleanup-tag` and `git push --delete` strings and prove the validator rejects them.
- `docs/releasing.md` contains the Release-only command plus explicit prohibitions.
- The lifecycle spec may mention `--cleanup-tag` only as a prohibition.
- The broad automatic-update design and retained implementation history no longer direct anyone to delete a failed tag.

- [ ] **Step 10: Review the complete change against the approved lifecycle spec**

Run:

```bash
git diff --check
git status --short
git diff -- .github/workflows/publish-update.yml \
  Tests/ScriptTests/update_feed_tests.sh \
  docs/releasing.md \
  docs/superpowers/specs/2026-07-19-automatic-updates-design.md \
  docs/superpowers/plans/2026-07-19-secure-automatic-updates-implementation.md
```

Confirm every outcome:

- Failure before Draft creation performs no cleanup and burns the identifiers.
- Candidate qualification failure deletes only the Draft Release.
- Public reverification failure deletes only the public Release and never activates the feed.
- Cleanup failure preserves the original workflow failure and requires operator intervention.
- Every failed tag remains permanent.
- The next attempt requires a higher App Version, strictly increasing build number, and matching new tag.
- CAS, Activation Pending, Distribution Halt, Sparkle signing, and Candidate/final tag topology are unchanged.

- [ ] **Step 11: Commit the operator and architecture documentation**

```bash
git add Tests/ScriptTests/update_feed_tests.sh \
  docs/releasing.md \
  docs/superpowers/specs/2026-07-19-automatic-updates-design.md \
  docs/superpowers/plans/2026-07-19-secure-automatic-updates-implementation.md
git commit -m "docs: align failed release recovery"
```

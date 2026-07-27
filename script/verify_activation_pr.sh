#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/lib/release_common.sh"

activation_ref="${ACTIVATION_REF:-}"
target_dir="${ACTIVATION_TARGET_DIR:-$ROOT_DIR}"
[[ -d "$target_dir/.git" || -f "$target_dir/.git" ]] ||
  die "activation policy target is not a Git worktree"

git -C "$target_dir" fetch --no-tags origin main
head_sha="$(git -C "$target_dir" rev-parse HEAD)"
main_sha="$(git -C "$target_dir" rev-parse origin/main)"
[[ "$head_sha" =~ ^[0-9a-f]{40}$ && "$main_sha" =~ ^[0-9a-f]{40}$ ]] ||
  die "invalid activation PR commit identity"

if [[ "$activation_ref" =~ ^release/appcast-(v[0-9]+\.[0-9]+\.[0-9]+)-at-([0-9a-f]{12})$ ]]; then
  tag="${BASH_REMATCH[1]}"
  base_prefix="${BASH_REMATCH[2]}"
elif [[ "$activation_ref" == release/appcast-* ]]; then
  die "invalid activation PR branch"
else
  if git -C "$target_dir" diff --name-only "$main_sha...$head_sha" |
    /usr/bin/grep -Fx appcast.xml >/dev/null; then
    die "appcast.xml may only change through a Production Feed activation PR"
  fi
  exit 0
fi

load_version_config "$ROOT_DIR/version.env"
validate_release_tag "$tag"

work_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codex-radar-activation-pr.XXXXXX")"
cleanup() {
  /bin/rm -rf "$work_dir"
}
trap cleanup EXIT

[[ "$main_sha" == "$base_prefix"* ]] ||
  die "activation PR branch does not identify the current main commit"
git -C "$target_dir" fetch --force origin "refs/tags/$tag:refs/tags/$tag"
tag_sha="$(git -C "$target_dir" rev-parse "$tag^{commit}")"
[[ "$tag_sha" =~ ^[0-9a-f]{40}$ ]] || die "invalid activation PR tag identity"
git -C "$target_dir" merge-base --is-ancestor "$tag_sha" "$main_sha" ||
  die "release tag is not an ancestor of main"

commit_count="$(git -C "$target_dir" rev-list --count "$main_sha..$head_sha")"
[[ "$commit_count" == 1 ]] || die "activation PR must contain exactly one commit"
[[ "$(git -C "$target_dir" rev-parse "$head_sha^")" == "$main_sha" ]] ||
  die "activation PR must be based on the current main commit"
changed_files="$(git -C "$target_dir" diff --name-only "$main_sha...$head_sha")"
[[ "$changed_files" == appcast.xml ]] ||
  die "activation PR must change only appcast.xml"
[[ -f "$target_dir/appcast.xml" && ! -L "$target_dir/appcast.xml" ]] ||
  die "activation PR appcast.xml must be a real file"

gh release view "$tag" --repo "$GITHUB_REPOSITORY" \
  --json isDraft,isPrerelease,tagName >"$work_dir/release.json"
[[ "$(jq -r .isDraft "$work_dir/release.json")" == false ]] ||
  die "activation PR requires a public Release"
[[ "$(jq -r .isPrerelease "$work_dir/release.json")" == true ]] ||
  die "activation PR requires the immutable pre-release"
[[ "$(jq -r .tagName "$work_dir/release.json")" == "$tag" ]] ||
  die "activation PR Release tag mismatch"
gh release verify "$tag" --repo "$GITHUB_REPOSITORY"

archive_name="$(release_asset_basename).zip"
mkdir -p "$work_dir/public"
gh release download "$tag" --repo "$GITHUB_REPOSITORY" \
  --dir "$work_dir/public" --pattern '*'
[[ "$(find "$work_dir/public" -type f | wc -l | tr -d ' ')" == 4 ]] ||
  die "activation PR Release must contain exactly four assets"
for asset in "$archive_name" "$archive_name.sha256" "$archive_name.manifest" appcast.xml; do
  [[ -f "$work_dir/public/$asset" && ! -L "$work_dir/public/$asset" ]] ||
    die "activation PR Release asset is missing: $asset"
done
(cd "$work_dir/public" && /usr/bin/shasum -a 256 --check "$archive_name.sha256")
/usr/bin/cmp -s "$target_dir/appcast.xml" "$work_dir/public/appcast.xml" ||
  die "activation PR appcast.xml differs from the immutable Release asset"

swift package --package-path "$ROOT_DIR" resolve
sparkle_source="$ROOT_DIR/.build/checkouts/Sparkle"
[[ "$(git -C "$sparkle_source" rev-parse HEAD)" == \
  b6496a74a087257ef5e6da1c5b29a447a60f5bd7 ]] ||
  die "Sparkle source revision mismatch"
"$ROOT_DIR/script/verify_update_artifacts.sh" \
  --mode published \
  --feed "$target_dir/appcast.xml" \
  --archive "$work_dir/public/$archive_name" \
  --manifest "$work_dir/public/$archive_name.manifest" \
  --version-config "$ROOT_DIR/version.env" \
  --update-config "$ROOT_DIR/config/update.env" \
  --sparkle-source "$sparkle_source"

if git -C "$target_dir" cat-file -e origin/main:appcast.xml 2>/dev/null; then
  git -C "$target_dir" show origin/main:appcast.xml >"$work_dir/previous-appcast.xml"
  "$ROOT_DIR/script/verify_update_artifacts.sh" \
    --mode previous \
    --feed "$work_dir/previous-appcast.xml" \
    --version-config "$ROOT_DIR/version.env" \
    --update-config "$ROOT_DIR/config/update.env" \
    --sparkle-source "$sparkle_source"
else
  [[ "$MARKETING_VERSION" == 0.1.0 && "$BUILD_NUMBER" == 1 ]] ||
    die "only bootstrap 0.1.0 (1) may activate without a previous Production Feed"
  gh api "repos/$GITHUB_REPOSITORY/releases?per_page=100" \
    --jq "[.[] | select(.tag_name != \"$tag\")] | length == 0" |
    /usr/bin/grep -Fx true >/dev/null ||
    die "bootstrap activation requires no other Release history"
fi

printf 'Verified Production Feed activation PR for %s at %s.\n' "$tag" "$head_sha"

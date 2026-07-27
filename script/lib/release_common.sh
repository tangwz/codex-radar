#!/usr/bin/env bash

APP_NAME="CodexRadar"
BUNDLE_ID="com.terence.codex-radar"
MIN_SYSTEM_VERSION="14.0"
RESOURCE_BUNDLE_NAME="CodexRadar_CodexRadar.bundle"

die() { echo "$*" >&2; return 1; }

load_version_config() {
  local config_path="$1" key value
  MARKETING_VERSION=""
  BUILD_NUMBER=""
  while IFS='=' read -r key value || [[ -n "$key$value" ]]; do
    [[ -z "$key$value" ]] && continue
    case "$key" in
      MARKETING_VERSION)
        [[ -z "$MARKETING_VERSION" ]] || die "duplicate MARKETING_VERSION" || return 1
        MARKETING_VERSION="$value"
        ;;
      BUILD_NUMBER)
        [[ -z "$BUILD_NUMBER" ]] || die "duplicate BUILD_NUMBER" || return 1
        BUILD_NUMBER="$value"
        ;;
      *) die "unknown version key: $key" || return 1 ;;
    esac
  done <"$config_path"
  [[ "$MARKETING_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid MARKETING_VERSION" || return 1
  [[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || die "invalid BUILD_NUMBER" || return 1
}

validate_release_tag() {
  [[ "$1" == "v$MARKETING_VERSION" ]] || die "tag must equal v$MARKETING_VERSION"
}

normalize_decimal() {
  local value="$1"

  while [[ "${#value}" -gt 1 && "$value" == 0* ]]; do
    value="${value#0}"
  done
  printf '%s\n' "$value"
}

decimal_is_greater() {
  local left right

  left="$(normalize_decimal "$1")"
  right="$(normalize_decimal "$2")"
  if [[ "${#left}" -ne "${#right}" ]]; then
    [[ "${#left}" -gt "${#right}" ]]
  else
    [[ "$left" > "$right" ]]
  fi
}

semantic_version_is_greater() {
  local left="$1" right="$2"
  local left_major left_minor left_patch right_major right_minor right_patch

  IFS=. read -r left_major left_minor left_patch <<<"$left"
  IFS=. read -r right_major right_minor right_patch <<<"$right"
  if [[ "$(normalize_decimal "$left_major")" != "$(normalize_decimal "$right_major")" ]]; then
    decimal_is_greater "$left_major" "$right_major"
    return
  fi
  if [[ "$(normalize_decimal "$left_minor")" != "$(normalize_decimal "$right_minor")" ]]; then
    decimal_is_greater "$left_minor" "$right_minor"
    return
  fi
  decimal_is_greater "$left_patch" "$right_patch"
}

validate_release_identity_against_tags() {
  local candidate_tag="$1" repository="${2:-.}"
  local candidate_version="$MARKETING_VERSION" candidate_build="$BUILD_NUMBER"
  local ref tag tag_version config tagged_build

  [[ "$candidate_tag" == "v$candidate_version" ]] ||
    die "release tag must equal v$candidate_version" || return 1
  git -C "$repository" rev-parse --git-dir >/dev/null 2>&1 ||
    die "release tag history requires a Git repository" || return 1
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    tag="${ref#refs/tags/}"
    [[ "$tag" == "$candidate_tag" ]] && continue
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    tag_version="${tag#v}"
    semantic_version_is_greater "$candidate_version" "$tag_version" ||
      die "release App Version must be greater than burned tag $tag" || return 1
    config="$(git -C "$repository" show "$ref:version.env" 2>/dev/null)" || continue
    tagged_build="$(
      load_version_config <(printf '%s\n' "$config") >/dev/null 2>&1 &&
        printf '%s\n' "$BUILD_NUMBER"
    )" || continue
    # The protected tag name is the canonical historical App Version. Valid
    # metadata contributes only the build consumed by that failed attempt.
    decimal_is_greater "$candidate_build" "$tagged_build" ||
      die "release build number must be greater than burned tag $tag" || return 1
  done < <(git -C "$repository" for-each-ref --format='%(refname)' 'refs/tags/v*')
}

release_asset_basename() {
  printf '%s-v%s-macos-universal' "$APP_NAME" "$MARKETING_VERSION"
}

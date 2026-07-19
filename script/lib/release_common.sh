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

release_asset_basename() {
  printf '%s-v%s-macos-universal' "$APP_NAME" "$MARKETING_VERSION"
}

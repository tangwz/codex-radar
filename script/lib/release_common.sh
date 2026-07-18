#!/usr/bin/env bash
set -euo pipefail

CODEX_RADAR_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_NAME="CodexRadar"
BUNDLE_ID="com.terence.codex-radar"
MIN_SYSTEM_VERSION="14.0"
RESOURCE_BUNDLE_NAME="CodexRadar_CodexRadar.bundle"

codex_radar_die() {
  echo "ERROR: $*" >&2
  return 1
}

load_version() {
  local version_file="${1:-$CODEX_RADAR_ROOT_DIR/version.env}"
  local key=""
  local value=""
  local extra=""

  MARKETING_VERSION=""
  BUILD_NUMBER=""
  [[ -f "$version_file" ]] \
    || {
      codex_radar_die "Missing version file: $version_file"
      return 1
    }

  while IFS='=' read -r key value extra || [[ -n "$key" ]]; do
    [[ -z "$key" ]] && continue
    [[ -z "$extra" ]] \
      || {
        codex_radar_die "Invalid version line for key: $key"
        return 1
      }
    case "$key" in
      MARKETING_VERSION)
        [[ -z "$MARKETING_VERSION" ]] \
          || {
            codex_radar_die "Duplicate MARKETING_VERSION"
            return 1
          }
        MARKETING_VERSION="$value"
        ;;
      BUILD_NUMBER)
        [[ -z "$BUILD_NUMBER" ]] \
          || {
            codex_radar_die "Duplicate BUILD_NUMBER"
            return 1
          }
        BUILD_NUMBER="$value"
        ;;
      *)
        codex_radar_die "Unexpected version key: $key"
        return 1
        ;;
    esac
  done < "$version_file"

  [[ "$MARKETING_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || {
      codex_radar_die "Invalid MARKETING_VERSION: $MARKETING_VERSION"
      return 1
    }
  [[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] \
    || {
      codex_radar_die "Invalid BUILD_NUMBER: $BUILD_NUMBER"
      return 1
    }

  export MARKETING_VERSION BUILD_NUMBER
}

validate_release_tag() {
  local tag="$1"
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || {
      codex_radar_die "Invalid release tag: $tag"
      return 1
    }
  [[ "$tag" == "v${MARKETING_VERSION}" ]] \
    || {
      codex_radar_die "Tag $tag does not match v${MARKETING_VERSION}"
      return 1
    }
}

assert_commit_on_main() {
  local repository="$1"
  local commit="$2"
  local main_ref="$3"
  git -C "$repository" cat-file -e "${commit}^{commit}" 2>/dev/null \
    || {
      codex_radar_die "Unknown release commit: $commit"
      return 1
    }
  git -C "$repository" cat-file -e "${main_ref}^{commit}" 2>/dev/null \
    || {
      codex_radar_die "Unknown main ref: $main_ref"
      return 1
    }
  git -C "$repository" merge-base --is-ancestor "$commit" "$main_ref" \
    || {
      codex_radar_die "Release commit $commit is not contained in $main_ref"
      return 1
    }
}

validate_release_channel() {
  local signing_mode="$1"
  local prerelease="$2"
  [[ "$prerelease" == "true" || "$prerelease" == "false" ]] \
    || {
      codex_radar_die "RELEASE_PRERELEASE must be true or false"
      return 1
    }
  case "$signing_mode" in
    adhoc)
      [[ "$prerelease" == "true" ]] \
        || {
          codex_radar_die "Ad-hoc builds must remain pre-releases"
          return 1
        }
      ;;
    developer-id)
      ;;
    *)
      codex_radar_die "Unsupported SIGNING_MODE: $signing_mode"
      return 1
      ;;
  esac
}

require_developer_id_environment() {
  local variable=""
  for variable in \
    MACOS_SIGNING_IDENTITY \
    APP_STORE_CONNECT_API_KEY_P8 \
    APP_STORE_CONNECT_KEY_ID \
    APP_STORE_CONNECT_ISSUER_ID; do
    [[ -n "${!variable:-}" ]] \
      || {
        codex_radar_die "Missing $variable"
        return 1
      }
  done
}

release_asset_name() {
  printf '%s\n' "${APP_NAME}-v${MARKETING_VERSION}-macos-universal.zip"
}

release_checksum_name() {
  printf '%s\n' "$(release_asset_name).sha256"
}

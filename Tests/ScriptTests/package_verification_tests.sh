#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACKAGE_SCRIPT="$ROOT_DIR/script/package_app.sh"

fail() {
  echo "$*" >&2
  exit 1
}

[[ -f "$PACKAGE_SCRIPT" ]] || fail "package_app.sh does not exist"

fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT

setup_fixture() {
  local name="$1" fixture_root="$fixture_dir/$1"

  mkdir -p "$fixture_root/script/lib" "$fixture_root/config" "$fixture_root/Tests" "$fixture_root/bin"
  cp "$PACKAGE_SCRIPT" "$fixture_root/script/package_app.sh"
  cp "$ROOT_DIR/script/lib/release_common.sh" "$fixture_root/script/lib/release_common.sh"
  cp "$ROOT_DIR/Package.swift" "$ROOT_DIR/Package.resolved" "$fixture_root/"
  printf 'MARKETING_VERSION=0.1.0\nBUILD_NUMBER=1\n' >"$fixture_root/version.env"
  printf '%s\n' "$fixture_root"
}

write_update_config() {
  local fixture_root="$1" sparkle_version="$2" public_key="$3"

  printf '%s\n' \
    "SPARKLE_VERSION=$sparkle_version" \
    "SPARKLE_PUBLIC_ED_KEY=$public_key" \
    "PRODUCTION_FEED_URL=https://raw.githubusercontent.com/tangwz/codex-radar/main/appcast.xml" \
    >"$fixture_root/config/update.env"
}

install_mock_swift() {
  local fixture_root="$1"

  cat >"$fixture_root/bin/swift" <<'MOCK_SWIFT'
#!/usr/bin/env bash
set -euo pipefail

scratch_path=""
target_triple=""
show_bin_path=false
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --scratch-path)
      scratch_path="$2"
      shift 2
      ;;
    --triple)
      target_triple="$2"
      shift 2
      ;;
    --show-bin-path)
      show_bin_path=true
      shift
      ;;
    *) shift ;;
  esac
done

[[ -n "$scratch_path" && -n "$target_triple" ]]
architecture="${target_triple%%-*}"
bin_path="$scratch_path/products"
if [[ "$show_bin_path" == true ]]; then
  printf '%s\n' "$bin_path"
  exit 0
fi

resource_bundle="$bin_path/CodexRadar_CodexRadar.bundle"
mkdir -p "$resource_bundle/en.lproj" "$resource_bundle/zh-hans.lproj"
printf 'fixture binary\n' >"$bin_path/CodexRadar"
chmod +x "$bin_path/CodexRadar"
printf 'shared resource\n' >"$resource_bundle/en.lproj/Localizable.strings"
printf 'shared resource\n' >"$resource_bundle/zh-hans.lproj/Localizable.strings"
if [[ "${PACKAGE_TEST_RESOURCE_MISMATCH:-false}" == true && "$architecture" == x86_64 ]]; then
  printf 'different resource\n' >"$resource_bundle/x86-only.txt"
fi
MOCK_SWIFT
  chmod +x "$fixture_root/bin/swift"
}

assert_rejected() {
  local expected_message="$1" fixture_root="$2"
  shift 2

  if output="$(PATH="$fixture_root/bin:$PATH" "$fixture_root/script/package_app.sh" "$@" 2>&1)"; then
    fail "package fixture unexpectedly succeeded: $expected_message"
  fi
  [[ "$output" == *"$expected_message"* ]] || {
    echo "$output" >&2
    fail "package fixture did not report: $expected_message"
  }
}

architecture_fixture="$(setup_fixture architectures)"
write_update_config "$architecture_fixture" "2.9.4" ""
assert_rejected "duplicate architecture: arm64" "$architecture_fixture" \
  --output "$architecture_fixture/dist" --configuration debug \
  --architectures "arm64 arm64" --updates-enabled false
assert_rejected "unknown architecture: ppc64" "$architecture_fixture" \
  --output "$architecture_fixture/dist" --configuration debug \
  --architectures "arm64 ppc64" --updates-enabled false

key_fixture="$(setup_fixture missing-key)"
write_update_config "$key_fixture" "2.9.4" ""
assert_rejected "invalid SPARKLE_PUBLIC_ED_KEY" "$key_fixture" \
  --output "$key_fixture/dist" --configuration release \
  --architectures "arm64 x86_64" --updates-enabled true

version_fixture="$(setup_fixture wrong-sparkle-version)"
write_update_config "$version_fixture" "2.9.3" ""
assert_rejected "SPARKLE_VERSION must equal 2.9.4" "$version_fixture" \
  --output "$version_fixture/dist" --configuration debug \
  --architectures arm64 --updates-enabled false

resource_fixture="$(setup_fixture resource-mismatch)"
write_update_config "$resource_fixture" "2.9.4" "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA="
install_mock_swift "$resource_fixture"
export PACKAGE_TEST_RESOURCE_MISMATCH=true
assert_rejected "resource sets differ between architectures" "$resource_fixture" \
  --output "$resource_fixture/dist" --configuration release \
  --architectures "arm64 x86_64" --updates-enabled true
[[ ! -e "$resource_fixture/dist" ]] || fail "failed package fixture polluted the output path"
unset PACKAGE_TEST_RESOURCE_MISMATCH

echo "package verification fixtures passed"

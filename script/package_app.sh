#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$ROOT_DIR/script/lib/release_common.sh"

CONFIGURATION="${1:-}"
OUTPUT_APP="${2:-}"
shift 2 || true
ARCHES=("$@")

[[ "$CONFIGURATION" == "debug" || "$CONFIGURATION" == "release" ]] \
  || codex_radar_die "Usage: package_app.sh debug|release OUTPUT_APP ARCH..."
[[ -n "$OUTPUT_APP" && ${#ARCHES[@]} -gt 0 ]] \
  || codex_radar_die "Usage: package_app.sh debug|release OUTPUT_APP ARCH..."

case "$OUTPUT_APP" in
  /*) ;;
  *) OUTPUT_APP="$ROOT_DIR/$OUTPUT_APP" ;;
esac

OUTPUT_PARENT="$(dirname "$OUTPUT_APP")"
OUTPUT_BASENAME="$(basename "$OUTPUT_APP")"
[[ "$OUTPUT_BASENAME" == "${APP_NAME}.app" ]] \
  || codex_radar_die "Output app must be named ${APP_NAME}.app"

if [[ "$OUTPUT_PARENT" == "$ROOT_DIR" ]]; then
  OUTPUT_RELATIVE_PARENT=""
elif [[ "$OUTPUT_PARENT" == "$ROOT_DIR/"* ]]; then
  OUTPUT_RELATIVE_PARENT="${OUTPUT_PARENT#"$ROOT_DIR"/}"
else
  codex_radar_die "Output app must remain inside the repository"
fi

OUTPUT_PARENT_PATH="$ROOT_DIR"
if [[ -n "$OUTPUT_RELATIVE_PARENT" ]]; then
  IFS='/' read -r -a OUTPUT_PATH_COMPONENTS <<< "$OUTPUT_RELATIVE_PARENT"
  for component in "${OUTPUT_PATH_COMPONENTS[@]}"; do
    [[ -n "$component" && "$component" != "." && "$component" != ".." ]] \
      || codex_radar_die "Output app path must not contain traversal components"
    OUTPUT_PARENT_PATH="$OUTPUT_PARENT_PATH/$component"
    [[ ! -L "$OUTPUT_PARENT_PATH" ]] \
      || codex_radar_die "Output app parent must not contain symbolic links"
    [[ ! -e "$OUTPUT_PARENT_PATH" || -d "$OUTPUT_PARENT_PATH" ]] \
      || codex_radar_die "Output app parent contains a non-directory path"
  done
fi

mkdir -p "$OUTPUT_PARENT"
OUTPUT_PARENT="$(cd "$OUTPUT_PARENT" && pwd -P)"
[[ "$OUTPUT_PARENT" == "$ROOT_DIR" || "$OUTPUT_PARENT" == "$ROOT_DIR/"* ]] \
  || codex_radar_die "Output app must remain inside the repository"
OUTPUT_APP="$OUTPUT_PARENT/$OUTPUT_BASENAME"

load_version "$ROOT_DIR/version.env"

APP_CONTENTS="$OUTPUT_APP/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON_SOURCE="$ROOT_DIR/Sources/CodexRadar/Resources/AppIcon.icns"
MENU_BAR_ICON_SOURCE="$ROOT_DIR/Sources/CodexRadar/Resources/MenuBarIcon.png"
COPYRIGHT="© 2026 Terence Tang. All rights reserved."

mkdir -p "$ROOT_DIR/tmp"
MANIFEST_DIR="$(mktemp -d "$ROOT_DIR/tmp/package-manifest.XXXXXX")"
trap 'rm -rf "$MANIFEST_DIR"' EXIT

resource_manifest() {
  local bundle="$1"
  local output="$2"
  (
    cd "$bundle"
    find . -type f -print | LC_ALL=C sort | while IFS= read -r file; do
      /usr/bin/shasum -a 256 "$file"
    done
  ) > "$output"
}

BINARIES=()
RESOURCE_BUNDLES=()
SEEN_ARCHES=" "

cd "$ROOT_DIR"
for arch in "${ARCHES[@]}"; do
  [[ "$arch" == "arm64" || "$arch" == "x86_64" ]] \
    || codex_radar_die "Unsupported architecture: $arch"
  [[ "$SEEN_ARCHES" != *" $arch "* ]] \
    || codex_radar_die "Duplicate architecture: $arch"
  SEEN_ARCHES="${SEEN_ARCHES}${arch} "

  scratch_path="$ROOT_DIR/.build/package/$CONFIGURATION/$arch"
  build_args=(
    swift build
    -c "$CONFIGURATION"
    --product "$APP_NAME"
    --arch "$arch"
    --scratch-path "$scratch_path"
  )
  "${build_args[@]}"
  bin_dir="$("${build_args[@]}" --show-bin-path)"
  binary="$bin_dir/$APP_NAME"
  resource_bundle="$bin_dir/$RESOURCE_BUNDLE_NAME"
  [[ -x "$binary" ]] || codex_radar_die "Missing binary for $arch: $binary"
  [[ -d "$resource_bundle" ]] \
    || codex_radar_die "Missing resource bundle for $arch: $resource_bundle"
  BINARIES+=("$binary")
  RESOURCE_BUNDLES+=("$resource_bundle")
done

base_manifest="$MANIFEST_DIR/${ARCHES[0]}.txt"
resource_manifest "${RESOURCE_BUNDLES[0]}" "$base_manifest"
for ((index = 1; index < ${#RESOURCE_BUNDLES[@]}; index++)); do
  candidate_manifest="$MANIFEST_DIR/${ARCHES[$index]}.txt"
  resource_manifest "${RESOURCE_BUNDLES[$index]}" "$candidate_manifest"
  cmp -s "$base_manifest" "$candidate_manifest" \
    || codex_radar_die "Resource bundles differ between architectures"
done

rm -rf "$OUTPUT_APP"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
if [[ ${#BINARIES[@]} -eq 1 ]]; then
  cp "${BINARIES[0]}" "$APP_BINARY"
else
  /usr/bin/lipo -create "${BINARIES[@]}" -output "$APP_BINARY"
fi
chmod +x "$APP_BINARY"

BASE_RESOURCE_BUNDLE="${RESOURCE_BUNDLES[0]}"
cp -R "$BASE_RESOURCE_BUNDLE" "$APP_RESOURCES/$RESOURCE_BUNDLE_NAME"
cp "$APP_ICON_SOURCE" "$APP_RESOURCES/AppIcon.icns"
cp "$MENU_BAR_ICON_SOURCE" "$APP_RESOURCES/MenuBarIcon.png"
cp -R "$BASE_RESOURCE_BUNDLE/en.lproj" "$APP_RESOURCES/en.lproj"
ZH_HANS_RESOURCES="$(
  find "$BASE_RESOURCE_BUNDLE" -maxdepth 1 -type d -iname 'zh-hans.lproj' -print -quit
)"
[[ -n "$ZH_HANS_RESOURCES" ]] \
  || codex_radar_die "Missing zh-Hans localization resources"
cp -R "$ZH_HANS_RESOURCES" "$APP_RESOURCES/zh-Hans.lproj"

cat > "$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>zh-Hans</string>
  </array>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$MARKETING_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>NSHumanReadableCopyright</key>
  <string>$COPYRIGHT</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

/usr/bin/plutil -lint "$INFO_PLIST"
echo "Created $OUTPUT_APP"

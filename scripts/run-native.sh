#!/bin/zsh
set -euo pipefail
repo_root="${0:A:h:h}"
app_root="$repo_root/.build/DBSync.app"
version="${DBSYNC_VERSION#v}"
build="${DBSYNC_BUILD:-}"
architecture="${DBSYNC_ARCH:-}"
mkdir -p "$app_root/Contents/MacOS"
mkdir -p "$app_root/Contents/Resources"
export CLANG_MODULE_CACHE_PATH="$repo_root/.build/clang-cache"
export SWIFT_MODULECACHE_PATH="$repo_root/.build/swift-cache"
build_args=(--disable-sandbox --package-path "$repo_root" --configuration release)
if [[ -n "$architecture" ]]; then
  build_args+=(--arch "$architecture")
fi
swift build "${build_args[@]}" --product DatabaseSyncNative
bin_path="$(swift build "${build_args[@]}" --show-bin-path)"
cp "$bin_path/DatabaseSyncNative" "$app_root/Contents/MacOS/DBSync"
cp "$repo_root/AppAssets/AppIcon.icns" "$app_root/Contents/Resources/AppIcon.icns"
cp "$repo_root/AppAssets/Info.plist" "$app_root/Contents/Info.plist"
if [[ -n "$version" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app_root/Contents/Info.plist"
fi
if [[ -n "$build" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$app_root/Contents/Info.plist"
fi
for locale in en; do
  mkdir -p "$app_root/Contents/Resources/$locale.lproj"
  cp "$repo_root/AppAssets/$locale.lproj/Localizable.strings" "$app_root/Contents/Resources/$locale.lproj/Localizable.strings"
done
touch "$app_root"
if [[ "${1:-}" != "--no-open" ]]; then
  open "$app_root"
fi

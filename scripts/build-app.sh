#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
cd "$project_root"

swift build -c release --product PhotosIndexApp
swift build -c release --product photosindex

binary_dir=$(swift build -c release --show-bin-path)
app_dir="$project_root/.build/PhotosIndex.app"

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/PhotosIndexApp" "$app_dir/Contents/MacOS/PhotosIndex"
cp "$project_root/AppBundle/Info.plist" "$app_dir/Contents/Info.plist"

"$project_root/scripts/sign-app.sh" \
  "$app_dir" \
  "$project_root/AppBundle/PhotosIndex.entitlements"

plutil -lint "$app_dir/Contents/Info.plist"
codesign --verify --deep --strict "$app_dir"
print -r -- "$app_dir"

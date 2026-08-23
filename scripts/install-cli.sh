#!/bin/zsh
set -euo pipefail

project_root=${0:A:h:h}
binary_dir=$(cd "$project_root" && swift build -c release --show-bin-path)
install_dir="$HOME/.local/bin"
app_install_dir="$HOME/Applications"
source_app="$project_root/.build/PhotosIndex.app"
installed_app="$app_install_dir/PhotosIndex.app"

mkdir -p "$install_dir" "$app_install_dir"
cp "$binary_dir/photosindex" "$install_dir/photosindex"
chmod 0755 "$install_dir/photosindex"
/usr/bin/ditto "$source_app" "$installed_app"
codesign --verify --deep --strict "$installed_app"
print -r -- "$install_dir/photosindex"
print -r -- "$installed_app"

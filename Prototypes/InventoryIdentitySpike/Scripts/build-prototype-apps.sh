#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
package_dir=${script_dir:h}
apps_dir="$package_dir/.build/apps"

cd "$package_dir"
swift build

assemble_app() {
  local app_name=$1
  local executable_name=$2
  local bundle_identifier=$3
  local info_plist=$4
  local app_path="$apps_dir/$app_name.app"
  local contents_path="$app_path/Contents"
  local executable_path="$contents_path/MacOS/$executable_name"

  if [[ -e "$app_path" ]]; then
    /bin/rm -rf -- "$app_path"
  fi

  /bin/mkdir -p "$contents_path/MacOS"
  /bin/cp "$package_dir/.build/debug/$executable_name" "$executable_path"
  /bin/cp "$info_plist" "$contents_path/Info.plist"
  /bin/chmod 755 "$executable_path"

  /usr/bin/plutil -lint "$contents_path/Info.plist"
  /usr/bin/codesign \
    --force \
    --sign - \
    --identifier "$bundle_identifier" \
    "$app_path"
  /usr/bin/codesign --verify --deep --strict "$app_path"

  print -r -- "$app_path"
}

/bin/mkdir -p "$apps_dir"

assemble_app \
  "TrayNook Inventory Spike" \
  "traynook-inventory-spike" \
  "io.github.mahenzon.TrayNook.dev.InventorySpike" \
  "$package_dir/Support/InventorySpike-Info.plist"

assemble_app \
  "TrayNook Boundary Spike" \
  "traynook-boundary-spike" \
  "io.github.mahenzon.TrayNook.dev.BoundarySpike" \
  "$package_dir/Support/BoundarySpike-Info.plist"

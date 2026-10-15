#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  printf 'Usage: install-update.sh SOURCE_APP TARGET_APP PARENT_PID VERSION\n' >&2
  exit 2
fi

source_app=$1
target_app=$2
parent_pid=$3
version=$4

[[ "$(basename "$source_app")" == GrandeBar.app ]] || exit 2
[[ "$(basename "$target_app")" == GrandeBar.app ]] || exit 2
[[ "$parent_pid" =~ ^[0-9]+$ ]] || exit 2
[[ "$version" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]] || exit 2
[[ -d "$source_app" && -d "$target_app" ]] || exit 2
[[ ! -L "$target_app" && ! -L "$source_app" ]] || exit 2

parent_dir=$(cd "$(dirname "$target_app")" && pwd -P)
[[ -w "$parent_dir" ]] || {
  printf 'Installation directory is not writable: %s\n' "$parent_dir" >&2
  exit 1
}

actual_version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$source_app/Contents/Info.plist")
actual_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$source_app/Contents/Info.plist")
[[ "$actual_version" == "$version" && "$actual_id" == co.grande.grandebar ]] || exit 2
/usr/bin/codesign --verify --deep --strict "$source_app"

incoming=$(mktemp -d "$parent_dir/.grandebar-incoming.XXXXXX")
backup=
installed=false
cleanup() {
  status=$?
  if [[ $status -ne 0 && -n "$backup" && -d "$backup" ]]; then
    if [[ -e "$target_app" ]]; then
      rm -rf "$target_app"
    fi
    mv "$backup" "$target_app"
  fi
  if [[ -d "$incoming" ]]; then
    rm -rf "$incoming"
  fi
  if [[ "$installed" == true && -n "$backup" && -d "$backup" ]]; then
    rm -rf "$backup"
  fi
  exit "$status"
}
trap cleanup EXIT

/usr/bin/ditto --noextattr "$source_app" "$incoming/GrandeBar.app"
/usr/bin/codesign --verify --deep --strict "$incoming/GrandeBar.app"

for ((attempt=0; attempt<100; attempt++)); do
  if ! kill -0 "$parent_pid" 2>/dev/null; then break; fi
  sleep 0.2
done
if kill -0 "$parent_pid" 2>/dev/null; then
  printf 'GrandeBar did not exit; update cancelled.\n' >&2
  exit 1
fi

backup=$(mktemp -d "$parent_dir/.grandebar-backup.XXXXXX")
rmdir "$backup"
mv "$target_app" "$backup"
mv "$incoming/GrandeBar.app" "$target_app"
/usr/bin/codesign --verify --deep --strict "$target_app"
installed=true
/usr/bin/open "$target_app"

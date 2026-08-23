#!/bin/zsh
set -euo pipefail

if (( $# != 2 )); then
  print -u2 -r -- "Usage: $0 <app-path> <entitlements-path>"
  exit 64
fi

app_path=$1
entitlements_path=$2
signing_mode=${PHOTOSINDEX_SIGNING_MODE:-development}
codesign_command=${PHOTOSINDEX_CODESIGN_COMMAND:-/usr/bin/codesign}
security_command=${PHOTOSINDEX_SECURITY_COMMAND:-/usr/bin/security}
signing_identifier=dev.pray.PhotosIndex

case "$signing_mode" in
  development)
    signing_identity=${PHOTOSINDEX_DEVELOPMENT_IDENTITY:-}
    if [[ -z "$signing_identity" ]]; then
      signing_identity=$(
        "$security_command" find-identity -v -p codesigning \
          | awk -F '"' '$2 ~ /^Apple Development:/ { print $2; exit }'
      )
    fi
    if [[ -z "$signing_identity" ]]; then
      print -u2 -r -- \
        "No Apple Development signing identity found. Create one in Xcode Settings > Accounts > Manage Certificates, or set PHOTOSINDEX_DEVELOPMENT_IDENTITY."
      exit 78
    fi
    if [[ "$signing_identity" != "Apple Development:"* ]]; then
      print -u2 -r -- \
        "PHOTOSINDEX_DEVELOPMENT_IDENTITY must start with 'Apple Development:'."
      exit 64
    fi
    ;;
  adhoc)
    signing_identity=-
    print -u2 -r -- \
      "warning: ad-hoc signing is intended for disposable CI artifacts; rebuilding can reset macOS TCC grants"
    ;;
  *)
    print -u2 -r -- \
      "Unsupported PHOTOSINDEX_SIGNING_MODE '$signing_mode'; expected 'development' or 'adhoc'."
    exit 64
    ;;
esac

"$codesign_command" \
  --force \
  --options runtime \
  --identifier "$signing_identifier" \
  --sign "$signing_identity" \
  --entitlements "$entitlements_path" \
  "$app_path"

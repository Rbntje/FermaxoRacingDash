#!/bin/bash
set -euo pipefail

APP_PATH="${1:-}"
if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "Usage: $0 \"/path/to/Fermaxo Racing.app\" [output.ipa]" >&2
  exit 2
fi

if [[ ! -f "$APP_PATH/embedded.mobileprovision" ]]; then
  echo "This app has no embedded provisioning profile. Build it in Xcode with your Apple ID and a connected iPhone first." >&2
  exit 3
fi

OUTPUT_PATH="${2:-$(dirname "$APP_PATH")/FermaxoRacing-signed.ipa}"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
mkdir -p "$TEMP_DIR/Payload"
ditto "$APP_PATH" "$TEMP_DIR/Payload/$(basename "$APP_PATH")"
(cd "$TEMP_DIR" && /usr/bin/zip -qry "$OUTPUT_PATH" Payload)
echo "Created signed IPA: $OUTPUT_PATH"

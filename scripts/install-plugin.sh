#!/bin/sh
# Copy a plugin folder (one with a manifest.json) into cubi's plugins directory, replacing what
# was there. Data the plugin keeps elsewhere (e.g. ~/Library/Application Support/cubi/sprint) is untouched.
#   scripts/install-plugin.sh docs/plugins/sprint
set -eu
src="${1:?usage: install-plugin.sh <plugin dir>}"
[ -f "$src/manifest.json" ] || { echo "error: $src has no manifest.json" >&2; exit 1; }
id="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$src/manifest.json")"
dest="$HOME/Library/Application Support/cubi/plugins/$id"
mkdir -p "$dest"
rsync -a --delete --exclude 'tests' --exclude '__pycache__' "$src/" "$dest/"
echo "installed ${id} → ${dest}（設定頁按「重新載入」或重啟 Cubi）"

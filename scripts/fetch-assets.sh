#!/usr/bin/env bash
set -euo pipefail

version="b1.7.3"
manifest_url="https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
assets_dir="$script_dir/../assets"

echo "Looking up Minecraft ${version} in Mojang's official version manifest..."
version_url="$(curl -fsSL "$manifest_url" | jq -r --arg v "$version" '.versions[] | select(.id == $v) | .url')"
if [ -z "$version_url" ]; then
    echo "error: version $version not found in Mojang's manifest" >&2
    exit 1
fi

client_json="$(curl -fsSL "$version_url")"
client_url="$(echo "$client_json" | jq -r '.downloads.client.url')"
expected_sha1="$(echo "$client_json" | jq -r '.downloads.client.sha1')"

tmp_jar="$(mktemp)"
trap 'rm -f "$tmp_jar"' EXIT

echo "Downloading the official ${version} client jar from Mojang..."
curl -fSL "$client_url" -o "$tmp_jar"

actual_sha1="$(sha1sum "$tmp_jar" | cut -d' ' -f1)"
if [ "$actual_sha1" != "$expected_sha1" ]; then
    echo "error: checksum mismatch (expected $expected_sha1, got $actual_sha1)" >&2
    exit 1
fi
echo "Checksum verified ($actual_sha1)."

echo "Extracting assets to $assets_dir..."
mkdir -p "$assets_dir"
unzip -o -q "$tmp_jar" terrain.png -d "$assets_dir"
unzip -o -q "$tmp_jar" 'mob/*' -d "$assets_dir"
unzip -o -q "$tmp_jar" 'gui/*' -d "$assets_dir"
unzip -o -q "$tmp_jar" 'font/*' -d "$assets_dir"

echo "Done. Assets are in $assets_dir"

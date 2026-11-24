#!/usr/bin/env bash
# Turns verified candidates into release packages. Each candidate's unmodified
# CEF --minimal archive is imported with the pinned cef-rs exporter, and the
# resulting CEF_PATH directory (Release and Resources flattened, archive.json
# written) is checked and packed as cef-<upstream version>-<target>.tar.gz.
#
# Usage: package.sh <verified> <targets json> <cef-rs checkout> <output> <epoch>
#   verified: publish.ps1 output (candidate archives and manifest-<target>.json)
#   epoch:    file modification time stored in the packages, for reproducibility
set -euo pipefail
if [ $# -ne 5 ]; then
  echo "usage: $0 <verified> <targets json> <cef-rs checkout> <output> <epoch>" >&2
  exit 2
fi
verified=$(cd "$1" && pwd)
targets=$2
cef_rs=$(cd "$3" && pwd)
output=$4
epoch=$5
pins="$(cd "$(dirname "$0")/.." && pwd)/pins.json"
version=$(jq -er .cef_version "$pins")
exporter=$(jq -er .cef_rs_commit "$pins")
upstream=${version%%+*}
if [ -e "$output" ]; then echo "Output already exists: $output" >&2; exit 1; fi
mkdir -p "$output"
output=$(cd "$output" && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

for target in $(echo "$targets" | jq -r '.[]'); do
  case "$target" in
    linux-x64) rust_target=x86_64-unknown-linux-gnu; library=libcef.so; expected='ELF 64-bit.*x86-64' ;;
    linux-arm64) rust_target=aarch64-unknown-linux-gnu; library=libcef.so; expected='ELF 64-bit.*aarch64' ;;
    windows-x64) rust_target=x86_64-pc-windows-msvc; library=libcef.dll; expected='PE32\+.*x86-64' ;;
    windows-arm64) rust_target=aarch64-pc-windows-msvc; library=libcef.dll; expected='PE32\+.*(aarch64|arm64)' ;;
    macos-x64) rust_target=x86_64-apple-darwin; library='Chromium Embedded Framework.framework/Chromium Embedded Framework'; expected='Mach-O 64-bit.*x86_64' ;;
    macos-arm64) rust_target=aarch64-apple-darwin; library='Chromium Embedded Framework.framework/Chromium Embedded Framework'; expected='Mach-O 64-bit.*arm64' ;;
    *) echo "Unsupported target: $target" >&2; exit 1 ;;
  esac
  manifest="$verified/manifest-$target.json"
  archive="$verified/$(jq -er .archive "$manifest")"
  name="cef-$upstream-$target"
  dir="$work/$name"
  cargo run --quiet --manifest-path "$cef_rs/Cargo.toml" -p export-cef-dir -- \
    --archive "$archive" --target "$rust_target" "$dir"

  # The exported directory is what cef-rs builds against as CEF_PATH.
  test -f "$dir/$library"
  file -Lb "$dir/$library" | tee /dev/stderr | grep -iE "$expected" >/dev/null
  test -f "$dir/include/cef_app.h"
  case "$target" in
    linux-*) test -f "$dir/chrome-sandbox"; test -f "$dir/icudtl.dat" ;;
    windows-*) test -f "$dir/bootstrap.exe"; test -f "$dir/bootstrapc.exe"; test -f "$dir/icudtl.dat" ;;
    # CEF's distribution ships a flat framework; -f also follows a versioned layout's links.
    macos-*) test -f "$dir/Chromium Embedded Framework.framework/Resources/Info.plist"
      test -f "$dir/Chromium Embedded Framework.framework/Resources/icudtl.dat" ;;
  esac
  sha1=$(sha1sum "$archive" | cut -d' ' -f1)
  jq -e --arg name "$(basename "$archive")" --arg sha1 "$sha1" \
    '.type == "minimal" and .name == $name and .sha1 == $sha1' "$dir/archive.json" >/dev/null

  tar --sort=name --format=gnu --owner=0 --group=0 --numeric-owner --mtime="@$epoch" \
    -C "$work" -cf - "$name" | gzip -9n > "$output/$name.tar.gz"
  sha256=$(sha256sum "$output/$name.tar.gz" | cut -d' ' -f1)
  jq --arg name "$name.tar.gz" --arg sha256 "$sha256" --arg exporter "$exporter" \
    '. + {package: {name: $name, sha256: $sha256, cef_rs_commit: $exporter}}' \
    "$manifest" > "$output/manifest-$target.json"
  echo "$sha256  $name.tar.gz" >> "$output/SHA256SUMS"
  echo "$target: $name.tar.gz ($(du -h "$output/$name.tar.gz" | cut -f1)) from $(basename "$archive")"
  rm -rf -- "$dir"
done

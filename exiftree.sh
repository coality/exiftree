#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <SOURCE_DIR> <DEST_DIR>"
  exit 1
fi

SRC="$1"
DST="$2"
DB="${DST}/.imported_sha256.txt"

[[ ! -d "$SRC" ]] && { echo "Source does not exist: $SRC"; exit 1; }
mkdir -p "$DST"
touch "$DB"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Photo/video formats (case-insensitive)
REGEX='.*\.(jpe?g|png|gif|webp|heic|heif|tif|tiff|bmp|cr2|mp4|mov|m4v|mkv|avi|3gp|wmv|flv|webm|mts|m2ts|ts|vob|mpg|mpeg|mpe|asf|ogv|mxf)$'

# Load deduplication database
declare -A seen
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  seen["${line%% *}"]=1
done < "$DB"

mapfile -d '' files < <(
  find "$SRC" -type f -regextype posix-extended -iregex "$REGEX" -print0
)

total="${#files[@]}"
(( total == 0 )) && { echo "No files to process."; exit 0; }

start_epoch="$(date +%s)"

processed=0
imported=0
skip_dup=0
skip_convfail=0
skip_invalid=0
converted=0
nodate=0

pick_datetime() {
  exiftool -api QuickTimeUTC=1 -s -s -s \
    -d '%Y/%m/%d %Y%m%d_%H%M%S' \
    -DateTimeOriginal -MediaCreateDate -CreateDate -TrackCreateDate "$1" 2>/dev/null \
  | awk 'NF{print; exit}'
}

show_progress() {
  printf "\r[%3d%%] %d/%d imported:%d dup:%d convFail:%d invalid:%d noEXIF:%d %s" \
    $((processed*100/total)) "$processed" "$total" \
    "$imported" "$skip_dup" "$skip_convfail" "$skip_invalid" "$nodate" "$1"
}

import_one() {
  local f="$1" input="$1" lower="${f,,}"

  # CR2 -> JPEG (darktable, quality 95, TMP) without touching originals
  if [[ "$lower" == *.cr2 ]]; then
    local sha_src jpg
    sha_src="$(sha256sum "$f" | awk '{print $1}')"
    jpg="${TMP}/${sha_src}.jpg"
    if [[ ! -f "$jpg" ]]; then
      if ! darktable-cli "$f" "$jpg" --core \
           --conf "plugins/imageio/format/jpeg/quality=95" >/dev/null 2>&1; then
        skip_convfail=$((skip_convfail+1))
        return
      fi
      exiftool -q -q -overwrite_original -TagsFromFile "$f" -all:all "$jpg" || true
      converted=$((converted+1))
    fi
    input="$jpg"
  fi

  # Deduplication (hash on the imported file)
  local sha
  sha="$(sha256sum "$input" | awk '{print $1}')"
  if [[ -n "${seen[$sha]+x}" ]]; then
    skip_dup=$((skip_dup+1))
    return
  fi

  # Date fallback: EXIF/QuickTime otherwise mtime
  local dt dir base
  dt="$(pick_datetime "$input" || true)"
  if [[ -z "$dt" ]]; then
    nodate=$((nodate+1))
    dt="$(date -d "@$(stat -c '%Y' "$input")" '+%Y/%m/%d %Y%m%d_%H%M%S')"
  fi

  dir="${DST}/${dt%% *}"
  base="${dt#* }"
  mkdir -p "$dir"

  # Filename + collision counter
  local ext out i=0
  ext="${input##*.}"; ext="${ext,,}"
  out="${dir}/${base}.${ext}"
  while [[ -e "$out" ]]; do
    i=$((i+1))
    out="${dir}/${base}-${i}.${ext}"
  done

  # Copy to final path
  if ! exiftool -P -m -q -q -api QuickTimeUTC=1 -o "$out" "$input"; then
    skip_invalid=$((skip_invalid+1))
    return
  fi

  echo "$sha  $f" >> "$DB"
  seen["$sha"]=1
  imported=$((imported+1))
}

echo "Files detected: $total"
for f in "${files[@]}"; do
  processed=$((processed+1))
  show_progress "$f"
  import_one "$f"
done

echo
echo "Summary:"
echo "  Total                     : $total"
echo "  Imported                  : $imported"
echo "  Skipped (Duplicate)       : $skip_dup"
echo "  Skipped (ConversionFailed): $skip_convfail"
echo "  Skipped (InvalidFile)     : $skip_invalid"
echo "  CR2 converted             : $converted"
echo "  No EXIF (mtime fallback)  : $nodate"

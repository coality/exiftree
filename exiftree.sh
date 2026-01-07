#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: exiftree.sh [options] <SOURCE_DIR> <DEST_DIR>

Options:
  --month-name         Use month name folders instead of numeric month (e.g. January).
  --day-name           Use day folders like "Monday 03 March".
  --lang <fr|en>       Locale for month/day names (default: en).
  -h, --help           Show this help message.
EOF
}

MONTH_NAME=0
DAY_NAME=0
LANGUAGE="en"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --month-name)
      MONTH_NAME=1
      shift
      ;;
    --day-name)
      DAY_NAME=1
      shift
      ;;
    --lang)
      LANGUAGE="${2:-}"
      shift 2
      ;;
    --lang=*)
      LANGUAGE="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -ne 2 ]]; then
  usage
  exit 1
fi

case "$LANGUAGE" in
  en) LOCALE="en_US.UTF-8" ;;
  fr) LOCALE="fr_FR.UTF-8" ;;
  *) echo "Unsupported language: $LANGUAGE (use fr or en)"; exit 1 ;;
esac

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

find_takeout_json() {
  local f="$1" dir name base ext stripped
  dir="$(dirname "$f")"
  name="$(basename "$f")"
  base="${name%.*}"
  ext="${name##*.}"

  local candidates=(
    "$dir/$name.json"
    "$dir/$name.supplemental-metadata.json"
    "$dir/$base.json"
    "$dir/$base.supplemental-metadata.json"
  )

  if [[ "$base" == *-edited* ]]; then
    stripped="${base%-edited*}"
    candidates+=(
      "$dir/$stripped.${ext}.json"
      "$dir/$stripped.${ext}.supplemental-metadata.json"
      "$dir/$stripped.json"
      "$dir/$stripped.supplemental-metadata.json"
    )
  fi

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

json_exif_args() {
  local json="$1"
  python3 - "$json" <<'PY'
import json
import sys
from datetime import datetime, timezone

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)

def emit(tag, value):
    if value is None:
        return
    if isinstance(value, str):
        value = value.strip()
        if not value:
            return
    print(f"-{tag}={value}")

def get_timestamp(*keys):
    for key in keys:
        block = data.get(key) or {}
        ts = block.get("timestamp")
        if ts:
            try:
                return int(ts)
            except ValueError:
                continue
    return None

ts = get_timestamp("photoTakenTime", "creationTime", "photoLastModifiedTime")
if ts is not None:
    dt = datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y:%m:%d %H:%M:%S")
    for tag in (
        "DateTimeOriginal",
        "CreateDate",
        "ModifyDate",
        "MediaCreateDate",
        "TrackCreateDate",
    ):
        emit(tag, dt)

title = data.get("title")
description = data.get("description")
emit("Title", title)
emit("ObjectName", title)
emit("XMP:Title", title)
emit("Description", description)
emit("ImageDescription", description)
emit("Caption-Abstract", description)
emit("XMP:Description", description)

make = data.get("cameraMake")
model = data.get("cameraModel")
lens = data.get("lensModel")
emit("Make", make)
emit("Model", model)
emit("LensModel", lens)

focal = data.get("focalLength")
aperture = data.get("apertureFNumber")
iso = data.get("isoEquivalent")
exposure = data.get("exposureTime")
emit("FocalLength", focal)
emit("FNumber", aperture)
emit("ISO", iso)
emit("ExposureTime", exposure)

def pick_geo():
    for key in ("geoDataExif", "geoData"):
        geo = data.get(key) or {}
        lat = geo.get("latitude")
        lon = geo.get("longitude")
        alt = geo.get("altitude")
        try:
            lat_f = float(lat)
            lon_f = float(lon)
        except (TypeError, ValueError):
            continue
        if abs(lat_f) < 1e-6 and abs(lon_f) < 1e-6:
            continue
        return lat_f, lon_f, alt
    return None

geo = pick_geo()
if geo:
    lat, lon, alt = geo
    emit("GPSLatitude", lat)
    emit("GPSLongitude", lon)
    if alt is not None:
        emit("GPSAltitude", alt)

people = data.get("people") or []
for person in people:
    name = None
    if isinstance(person, dict):
        name = person.get("name")
    elif isinstance(person, str):
        name = person
    if name:
        print(f"-Keywords+={name}")

software = data.get("software")
emit("Software", software)
PY
}

show_progress() {
  printf "\r[%3d%%] %d/%d imported:%d dup:%d convFail:%d invalid:%d noEXIF:%d %s" \
    $((processed*100/total)) "$processed" "$total" \
    "$imported" "$skip_dup" "$skip_convfail" "$skip_invalid" "$nodate" "$1"
}

build_dir() {
  local date_part="$1"
  local date_input="${date_part//\//-}"
  local year month day

  year="$(date -d "$date_input" +%Y)"
  if (( MONTH_NAME )); then
    if [[ "$LANGUAGE" == "fr" ]]; then
      local month_num
      month_num="$(date -d "$date_input" +%m)"
      case "$month_num" in
        01) month="janvier" ;;
        02) month="fevrier" ;;
        03) month="mars" ;;
        04) month="avril" ;;
        05) month="mai" ;;
        06) month="juin" ;;
        07) month="juillet" ;;
        08) month="aout" ;;
        09) month="septembre" ;;
        10) month="octobre" ;;
        11) month="novembre" ;;
        12) month="decembre" ;;
      esac
    else
      month="$(LC_TIME="$LOCALE" date -d "$date_input" +%B)"
    fi
  else
    month="$(date -d "$date_input" +%m)"
  fi

  if (( DAY_NAME )); then
    if [[ "$LANGUAGE" == "fr" ]]; then
      local day_num weekday_num weekday month_num month_fr
      day_num="$(date -d "$date_input" +%d)"
      weekday_num="$(date -d "$date_input" +%u)"
      month_num="$(date -d "$date_input" +%m)"
      case "$weekday_num" in
        1) weekday="lundi" ;;
        2) weekday="mardi" ;;
        3) weekday="mercredi" ;;
        4) weekday="jeudi" ;;
        5) weekday="vendredi" ;;
        6) weekday="samedi" ;;
        7) weekday="dimanche" ;;
      esac
      case "$month_num" in
        01) month_fr="janvier" ;;
        02) month_fr="fevrier" ;;
        03) month_fr="mars" ;;
        04) month_fr="avril" ;;
        05) month_fr="mai" ;;
        06) month_fr="juin" ;;
        07) month_fr="juillet" ;;
        08) month_fr="aout" ;;
        09) month_fr="septembre" ;;
        10) month_fr="octobre" ;;
        11) month_fr="novembre" ;;
        12) month_fr="decembre" ;;
      esac
      day="${weekday} ${day_num} ${month_fr}"
    else
      day="$(LC_TIME="$LOCALE" date -d "$date_input" '+%A %d %B')"
    fi
  else
    day="$(date -d "$date_input" +%d)"
  fi

  echo "${DST}/${year}/${month}/${day}"
}

import_one() {
  local f="$1" input="$1" lower="${f,,}"
  local json

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

  json="$(find_takeout_json "$f" || true)"
  if [[ -n "$json" ]]; then
    exiftool -q -q -m -overwrite_original -@ <(json_exif_args "$json") "$input" || true
  fi

  # Date fallback: EXIF/QuickTime otherwise mtime
  local dt dir base date_part
  dt="$(pick_datetime "$input" || true)"
  if [[ -z "$dt" ]]; then
    nodate=$((nodate+1))
    dt="$(date -d "@$(stat -c '%Y' "$input")" '+%Y/%m/%d %Y%m%d_%H%M%S')"
  fi

  date_part="${dt%% *}"
  dir="$(build_dir "$date_part")"
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

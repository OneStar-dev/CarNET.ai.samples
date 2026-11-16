#!/usr/bin/env bash
#
# carnet-folder.sh: recognizes the cars in every photo of a folder with the CarNET API.
#
# It keeps to your key's limits by reading them from the API's own answers, so you never have to tell it your plan.
# When the key's daily or monthly limit runs out, it stops and tells you when the limit renews (or, with --wait,
# waits and carries on). Running it again picks up where it stopped: photos that already have an answer are skipped.
#
# Needs bash 3.2 or later (the one macOS ships is fine), curl and jq.
# Part of https://github.com/OneStar-dev/CarNET.ai.samples (MIT licence).

set -u

API_URL=${CARNET_API_URL:-https://api.carnet.ai/v2/mmg/detect}
API_KEY=${CARNET_API_KEY:-}
FEATURES=mmg,color,angle
MAX_BYTES=$((12 * 1024 * 1024)) # the Cloud API takes photos up to 12 MB

usage() {
  cat <<'EOF'
Usage: carnet-folder.sh [options] FOLDER

Sends every photo in FOLDER (JPEG, PNG, WEBP, GIF, BMP, TIFF) to the CarNET API
and saves the answers. Run it again to carry on: photos that already have an
answer are skipped.

Options:
  -o, --out DIR       where the answers go (default: FOLDER/carnet-results)
  -r, --recursive     include photos in subfolders
  -w, --wait          when the key's daily or monthly limit runs out, wait until
                      it renews and carry on (default: stop)
      --region NA     use the North America network (default: worldwide)
      --params QUERY  other API parameters, e.g. "box_select=all"
      --api URL       API address (default: https://api.carnet.ai/v2/mmg/detect;
                      CarNET Server: http://YOUR-SERVER:50052/detect)
  -h, --help          show this help

The API key is read from the CARNET_API_KEY environment variable.
CarNET Server needs no key.

Results: one answer per photo (DIR/<photo>.json) and DIR/results.csv with one
row per car.

Exit codes: 0 finished (photos over 12 MB are skipped and listed), 1 some photos
got no answer, a folder could not be read or an error stopped it, 2 wrong
options, 3 stopped because the key's limit ran out.
EOF
}

CSV_READY=''
die() { # a fatal error; once answers may exist, results.csv is rebuilt first
  echo "carnet-folder: $*" >&2
  [ -z "$CSV_READY" ] || write_csv
  exit 1
}
usage_error() { echo "carnet-folder: $*" >&2; echo "Try: carnet-folder.sh --help" >&2; exit 2; }

DIR='' OUT='' REGION='' PARAMS='' WAIT=0 RECURSIVE=0
while [ $# -gt 0 ]; do
  case $1 in
    -o | --out | --region | --params | --api)
      [ $# -ge 2 ] || usage_error "$1 needs a value"
      case $1 in
        -o | --out) OUT=$2 ;;
        --region) REGION=$2 ;;
        --params) PARAMS=$2 ;;
        --api) API_URL=$2 ;;
      esac
      shift 2 ;;
    -r | --recursive) RECURSIVE=1; shift ;;
    -w | --wait) WAIT=1; shift ;;
    -h | --help) usage; exit 0 ;;
    -*) usage_error "unknown option: $1" ;;
    *) [ -z "$DIR" ] || usage_error "give one folder only"; DIR=$1; shift ;;
  esac
done
[ -n "$DIR" ] || { usage; exit 2; }
[ -d "$DIR" ] || usage_error "no such folder: $DIR"

for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 ||
    die "needs $tool. Install it first (macOS: brew install $tool; Debian or Ubuntu: sudo apt install $tool)."
done

if [ -z "$API_KEY" ]; then
  case $API_URL in
    https://api.carnet.ai/*)
      die "set your API key first: export CARNET_API_KEY=your-key (get a free trial key at https://carnet.ai)" ;;
  esac
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/carnet-folder.XXXXXX") || die "could not make a temporary folder"
trap 'rm -rf "$TMP"' EXIT

# The key goes to curl from a file, so it doesn't show in the list of running programs.
KEY_HEADER=()
if [ -n "$API_KEY" ]; then
  (umask 077 && printf 'api-key: %s\n' "$API_KEY" >"$TMP/key-header") || die "could not write a temporary file"
  KEY_HEADER=(-H "@$TMP/key-header")
fi

query=''
case $PARAMS in *features=*) ;; *) query="features=$FEATURES" ;; esac
[ -z "$REGION" ] || query="${query:+$query&}region=$REGION"
[ -z "$PARAMS" ] || query="${query:+$query&}$PARAMS"
case $API_URL in *\?*) URL="$API_URL&$query" ;; *) URL="$API_URL?$query" ;; esac

# ---------------------------------------------------------------------------------------------------------------
# Limits. Every answer says how many requests the key has left and when each count starts again:
#   X-Rate-Limit-Remaining / X-Rate-Limit-Reset   requests per second
#   X-Quota-Remaining / X-Quota-Reset             requests per day or month (the plan's limit)
# Reset times are Unix times in milliseconds. A header is missing when the plan has no such limit.

R_LEFT='' R_RESET='' Q_LIMIT='' Q_LEFT='' Q_RESET=''

header() { # the last value of one answer header
  [ -f "$TMP/head" ] || return 0
  tr -d '\r' <"$TMP/head" | awk -v want="$1" '
    BEGIN { want = tolower(want) }
    { i = index($0, ":"); if (i && tolower(substr($0, 1, i - 1)) == want) { v = substr($0, i + 1); sub(/^[ \t]+/, "", v) } }
    END { print v }'
}

remember_limits() {
  R_LEFT=$(header X-Rate-Limit-Remaining)
  R_RESET=$(header X-Rate-Limit-Reset)
  local q
  q=$(header X-Quota-Remaining)
  if [ -n "$q" ]; then
    Q_LEFT=$q
    Q_LIMIT=$(header X-Quota-Limit)
    Q_RESET=$(header X-Quota-Reset)
  fi
}

# Waits until the per-second count starts again. The wait is kept between 0.1 and 1.1 seconds, so a computer
# clock that is a little off can't make it wait long.
wait_for_rate() {
  sleep "$(jq -n --arg r "$R_RESET" '
    if $r == "" then 1 else ((($r | tonumber) - now * 1000) as $ms | [[$ms, 100] | max, 1100] | min / 1000) end')"
}

renew_time() {
  jq -rn --arg r "$Q_RESET" '
    ($r | tonumber? // 0) as $ms
    | if $ms > 0 then $ms / 1000 | floor | strftime("%Y-%m-%d %H:%M UTC") else "a time the API did not give" end'
}

# The daily or monthly limit is used up: stop, or with --wait sleep until it renews. The wait is at least 10 seconds
# (a minute when the API gave no renewal time), so a computer clock that is off can't make it send in a tight loop.
limit_used_up() {
  local when
  when=$(renew_time)
  if [ "$WAIT" = 1 ]; then
    echo "The key's limit${Q_LIMIT:+ of $(plural "$Q_LIMIT" request)} is used up. Waiting until it renews at $when..."
    sleep "$(jq -n --arg r "$Q_RESET" '
      ($r | tonumber? // 0) as $ms
      | if $ms > 0 then ($ms - now * 1000) / 1000 + 2 | if . < 10 then 10 else floor end else 60 end')"
    Q_LEFT=''
    return 0
  fi
  finish limit
  echo "The key's limit${Q_LIMIT:+ of $(plural "$Q_LIMIT" request)} is used up. It renews at $when."
  echo "Run the same command again then to carry on, or add --wait to let it wait."
  exit 3
}

# ---------------------------------------------------------------------------------------------------------------
# One photo. Returns 0 when the answer is saved, 1 when there is no answer to save (ERROR says why).

ERROR=''

recognize() { # $1 photo, $2 where its answer goes
  local status reason tries=0 rate_waits=0
  while :; do
    rm -f "$TMP/head" "$TMP/body"
    status=$(curl -sS -o "$TMP/body" -D "$TMP/head" -w '%{http_code}' -X POST \
      ${KEY_HEADER[@]+"${KEY_HEADER[@]}"} -H 'Content-Type: application/octet-stream' -H 'Expect:' \
      --data-binary @"$1" --connect-timeout 15 --max-time 120 "$URL" 2>"$TMP/curl-error")
    remember_limits

    # Wrong parameters would fail every photo the same way, so stop at the first.
    if jq -e '.error.code == 12 or .error.code == 15' "$TMP/body" >/dev/null 2>&1; then
      die "the API did not accept the parameters: $(jq -r '.error.message' "$TMP/body")"
    fi

    case $status in
      200)
        if ! jq -e 'type == "object"' "$TMP/body" >/dev/null 2>&1; then
          reason='an answer that is not JSON'
        elif jq -e '.is_success != true and .error.code == 2' "$TMP/body" >/dev/null; then
          reason='an error on the API side'
        else
          mkdir -p "${2%/*}" && cp "$TMP/body" "$2.part" && mv "$2.part" "$2" && return 0
          die "could not save the answer to $2"
        fi ;;
      429)
        if grep -q 'Quota exceeded' "$TMP/body" 2>/dev/null; then
          limit_used_up # comes back only with --wait
          continue
        fi
        rate_waits=$((rate_waits + 1)) # too fast: wait for the next second and send again
        [ $rate_waits -le 60 ] || die "the API keeps saying the key is over its per-second limit. Is another program using the same key?"
        wait_for_rate
        continue ;;
      401 | 403) die "the API refused the key (HTTP $status). Check CARNET_API_KEY." ;;
      413) ERROR='larger than the API accepts'; return 1 ;;
      000) reason=$(head -c 300 "$TMP/curl-error" | tr '\n' ' ') ;;
      5??) reason="HTTP $status" ;;
      *) ERROR="HTTP $status: $(head -c 300 "$TMP/body" | tr '\n' ' ')"; return 1 ;;
    esac

    tries=$((tries + 1)) # a network or server problem: try again after 2, 8 and 18 seconds
    if [ $tries -ge 4 ]; then
      ERROR="$reason (tried 4 times)"
      return 1
    fi
    [ "$Q_LEFT" != 0 ] || limit_used_up # the failed try used the last request: don't send one the API will refuse
    sleep $((tries * tries * 2))
  done
}

# A saved answer in one line: "car<TAB>Porsche Taycan I facelift (2024-) 99.7%, Black, front-right",
# "nocar<TAB>..." or "error<TAB>...". A car is a detection that comes with a make and model.
DESCRIBE='
def car_text: (.mmg[0] // .mm[0]) as $m
  | ([$m.make_name, $m.model_name, $m.generation_name, (if $m.years then "(\($m.years))" else null end)]
     | map(select(. != null and . != "")) | join(" "))
    + " \(($m.probability * 1000 | round) / 10)%"
    + (if (.color | length) > 0 then ", \(.color[0].name)" else "" end)
    + (if (.angle | length) > 0 then ", \(.angle[0].name)" else "" end);
if .is_success != true then "error\t\(.error.message // "the API could not process the photo")"
else [.detections[]? | select((.mmg // .mm // []) | length > 0)] as $cars
  | if ($cars | length) == 0 then "nocar\tno car recognized"
    else "car\t" + ($cars | map(car_text) | join("; ")) end
end'

# All answers in the folder as one CSV, one row per car (a photo without a car gets one row too).
CSV='
(input_filename | ltrimstr($out) | rtrimstr(".json")) as $photo
| if .is_success != true then
    [$photo, null, "error", null, null, null, null, null, null, null, null, null, null, null,
     (.error.message // "the API could not process the photo")]
  else [.detections[]? | select((.mmg // .mm // []) | length > 0)] as $cars
    | if ($cars | length) == 0 then
        [$photo, null, "no car", null, null, null, null, null, null, null, null, null, null, null, null]
      else range($cars | length) as $i | $cars[$i] as $c | ($c.mmg[0] // $c.mm[0]) as $m
        | [$photo, $i + 1, "recognized", $m.make_name, $m.model_name, $m.generation_name, $m.years, $m.probability,
           $c.color[0].name, $c.angle[0].name, $c.box.tl_x, $c.box.tl_y, $c.box.br_x, $c.box.br_y, null]
      end
  end
| @csv'

write_csv() {
  {
    echo 'photo,car,status,make,model,generation,years,probability,color,angle,box_left,box_top,box_right,box_bottom,error'
    find "$OUT" -type f -name '*.json' -print0 | LC_ALL=C sort -z | xargs -0 -r jq -r --arg out "$OUT/" "$CSV"
  } >"$OUT/results.csv.part" && mv "$OUT/results.csv.part" "$OUT/results.csv"
}

SENT=0 CARS=0 NOCAR=0 UNREADABLE=0 FAILED=0 BEFORE=0 BIG=0

plural() { if [ "$1" -eq 1 ]; then echo "$1 $2"; else echo "$1 ${2}s"; fi; }

finish() { # $1 is "limit" when stopping because the key's limit is used up
  write_csv
  echo
  local found=''
  [ $CARS -eq 0 ] || found="$found, $CARS with a car"
  [ $NOCAR -eq 0 ] || found="$found, $NOCAR without a car"
  [ $UNREADABLE -eq 0 ] || found="$found, $UNREADABLE the API could not read"
  echo "Sent $(plural $SENT photo)${found:+:${found#,}}."
  [ $FAILED -eq 0 ] || echo "$(plural $FAILED photo) got no answer; running the command again sends them again."
  [ $BIG -eq 0 ] || echo "$(plural $BIG photo) skipped: larger than 12 MB."
  [ $BEFORE -eq 0 ] || echo "$(plural $BEFORE photo) already had an answer from an earlier run."
  echo "Answers: $OUT (results.csv has one row per car)"
  [ -z "$Q_LEFT" ] || [ "${1:-}" = limit ] || echo "The key has $Q_LEFT of ${Q_LIMIT:-?} requests left until $(renew_time)."
}

trap 'echo; finish; echo "Stopped. Run the same command again to carry on."; exit 130' INT TERM

# ---------------------------------------------------------------------------------------------------------------
# The photos to send, sorted by name, skipping ones that already have an answer.

[ "$DIR" = / ] || DIR=${DIR%/}
OUT=${OUT:-$DIR/carnet-results}
OUT=${OUT%/}
mkdir -p "$OUT" || die "could not make the folder $OUT"

DEPTH=(-maxdepth 1)
[ "$RECURSIVE" = 0 ] || DEPTH=()
find "$DIR" ${DEPTH[@]+"${DEPTH[@]}"} -type f ! -name '._*' \( -iname '*.jpg' -o -iname '*.jpeg' \
  -o -iname '*.png' -o -iname '*.webp' -o -iname '*.gif' -o -iname '*.bmp' -o -iname '*.tif' -o -iname '*.tiff' \) \
  -print0 | LC_ALL=C sort -z >"$TMP/photos"
FIND_STATUS=${PIPESTATUS[0]} # not 0 when find could not read some folders (it says which above)
unread_folders() {
  [ "$FIND_STATUS" -eq 0 ] && return 1
  echo "Some folders could not be read (see the messages above); their photos were not sent."
}

TODO=()
ALL=0
while IFS= read -r -d '' f; do
  ALL=$((ALL + 1))
  rel=${f#"$DIR"/}
  if [ -s "$OUT/$rel.json" ]; then
    BEFORE=$((BEFORE + 1))
  else
    TODO+=("$f")
  fi
done <"$TMP/photos"

if [ $ALL -eq 0 ]; then
  echo "No photos in $DIR (JPEG, PNG, WEBP, GIF, BMP or TIFF).${DEPTH[0]+ Add -r to include subfolders.}"
  unread_folders && exit 1
  exit 0
fi
TOTAL=${#TODO[@]}
if [ "$TOTAL" -eq 0 ]; then
  write_csv
  echo "All $ALL photos already have an answer. Results: $OUT/results.csv"
  unread_folders && exit 1
  exit 0
fi
[ $BEFORE -eq 0 ] || echo "$BEFORE of $ALL photos already have an answer; sending the other $TOTAL."

CSV_READY=1
n=0
for photo in "${TODO[@]}"; do
  n=$((n + 1))
  rel=${photo#"$DIR"/}
  [ "$Q_LEFT" != 0 ] || limit_used_up

  if [ ! -r "$photo" ]; then
    FAILED=$((FAILED + 1))
    echo "[$n/$TOTAL] $rel: no answer, the file can't be read"
    continue
  fi
  size=$(wc -c <"$photo" | tr -d ' ')
  if [ "$size" -gt $MAX_BYTES ]; then
    BIG=$((BIG + 1))
    echo "[$n/$TOTAL] $rel: skipped, larger than 12 MB"
    continue
  fi

  if recognize "$photo" "$OUT/$rel.json"; then
    SENT=$((SENT + 1))
    line=$(jq -r "$DESCRIBE" "$OUT/$rel.json")
    case ${line%%$'\t'*} in
      car) CARS=$((CARS + 1)) ;;
      nocar) NOCAR=$((NOCAR + 1)) ;;
      *) UNREADABLE=$((UNREADABLE + 1)) ;;
    esac
    echo "[$n/$TOTAL] $rel: ${line#*$'\t'}"
  else
    FAILED=$((FAILED + 1))
    echo "[$n/$TOTAL] $rel: no answer, $ERROR"
  fi

  # Keep to the per-second limit: when this second's requests are used up, wait for the next second.
  [ "$n" -eq "$TOTAL" ] || [ "$R_LEFT" != 0 ] || wait_for_rate
done

finish
unread_folders && exit 1
[ $FAILED -eq 0 ] || exit 1
exit 0

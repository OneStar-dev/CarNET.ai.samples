#!/usr/bin/env bash
# Tests carnet-folder.sh against fake_api.py, a local stand-in for the API: no real requests are sent.
# Needs python3 besides what the script needs. Run: shell/test/run-tests.sh
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$HERE/../carnet-folder.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/carnet-test.XXXXXX")
PORT=$((20000 + RANDOM % 20000))
SERVER_PID=''
PASSED=0 FAILED=0 CODE=0

stop_server() {
  if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; fi
  SERVER_PID=''
}
trap 'stop_server; rm -rf "$WORK"' EXIT

start_server() { # fake_api.py options
  stop_server
  python3 "$HERE/fake_api.py" "$PORT" "$@" >"$WORK/server.log" 2>&1 &
  SERVER_PID=$!
  local i
  for i in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$PORT/" && return 0
    sleep 0.1
  done
  echo "the stand-in API did not start" >&2
  exit 1
}

run() { # carnet-folder.sh options; output in $WORK/out.txt, exit code in CODE
  CARNET_API_KEY=${KEY-test-key} "$SCRIPT" --api "http://127.0.0.1:$PORT/detect" "$@" >"$WORK/out.txt" 2>&1
  CODE=$?
}

check() { # description, then a test command
  local what=$1
  shift
  if "$@"; then
    PASSED=$((PASSED + 1))
    echo "ok   $what"
  else
    FAILED=$((FAILED + 1))
    echo "FAIL $what"
    sed 's/^/     | /' "$WORK/out.txt"
  fi
}
says() { grep -qF -- "$1" "$WORK/out.txt"; }
code_is() { [ "$CODE" -eq "$1" ]; }
lacks() { ! says "$1"; }
missing() { local f; for f in "$@"; do [ ! -e "$f" ] || return 1; done; }
present() { local f; for f in "$@"; do [ -s "$f" ] || return 1; done; }
server_said() { grep -c -- "$1" "$WORK/server.log" | tr -d ' '; }

photo() { # path, first bytes (CAR, NOCAR, BAD or FLAKY); the path makes each photo's bytes different
  mkdir -p "$(dirname "$1")"
  printf '%s %s' "$2" "$1" >"$1"
}

# --- a mixed folder ------------------------------------------------------------------------------------------
P=$WORK/photos
photo "$P/a.jpg" CAR
photo "$P/b.JPG" NOCAR
photo "$P/c.png" BAD
photo "$P/d.jpeg" FLAKY
photo "$P/with space.webp" CAR
photo "$P/sub/e.jpg" CAR
photo "$P/notes.txt" CAR
photo "$P/._a.jpg" CAR

start_server --rate 10
run "$P"
check "a mixed folder finishes with exit 0" code_is 0
check "it counts cars, no cars and unreadable photos" says "Sent 5 photos: 3 with a car, 1 without a car, 1 the API could not read."
check "it says what it found" says "a.jpg: Porsche Taycan I facelift (2024-) 98.7%, Black, front-left"
check "a server error is sent again" [ "$(server_said '^500')" = 1 ]
check "results.csv has a header and one row per photo" [ "$(wc -l <"$P/carnet-results/results.csv" | tr -d ' ')" = 6 ]
check "a name with a space works" grep -q '^"with space.webp",1,"recognized","Porsche"' "$P/carnet-results/results.csv"
check "an unreadable photo has an error row" grep -q '^"c.png",,"error",.*"Failed to decode image"$' "$P/carnet-results/results.csv"
check "subfolders are left out without -r" [ ! -e "$P/carnet-results/sub/e.jpg.json" ]
check "other files and ._ files are left out" missing "$P/carnet-results/notes.txt.json" "$P/carnet-results/._a.jpg.json"
check "the key's limit is reported" says "The key has 994 of 1000 requests left until"

before=$(wc -l <"$WORK/server.log")
run "$P"
check "a second run sends nothing" [ "$(wc -l <"$WORK/server.log")" = "$before" ]
check "a second run says all are done" says "All 5 photos already have an answer."

run -r "$P"
check "-r sends only the new photo in the subfolder" says "5 of 6 photos already have an answer; sending the other 1."
check "-r saves it under the same subfolder" [ -s "$P/carnet-results/sub/e.jpg.json" ]

# --- the per-second limit ------------------------------------------------------------------------------------
R=$WORK/rate
for i in 1 2 3 4 5 6 7; do photo "$R/$i.jpg" CAR; done
start_server --rate 2
run "$R"
check "at 2 a second, 7 photos all get an answer" says "Sent 7 photos: 7 with a car"
check "and the API never had to refuse one" [ "$(server_said '^429')" = 0 ]

# --- the daily limit ------------------------------------------------------------------------------------------
Q=$WORK/quota
for i in 1 2 3 4 5; do photo "$Q/$i.jpg" CAR; done
start_server --rate 10 --quota 3 --quota-seconds 300
run "$Q"
check "when the limit is used up it stops with exit 3" code_is 3
check "it says when the limit renews" says "The key's limit of 3 requests is used up. It renews at"
check "it stops before the API refuses" [ "$(server_said 'Quota exceeded')" = 0 ]
check "the answers so far are kept" [ "$(ls "$Q/carnet-results" | grep -c '\.json$')" = 3 ]

Q2=$WORK/quota-refused
photo "$Q2/1.jpg" CAR
photo "$Q2/2.jpg" CAR
start_server --rate 10 --quota 1 --quota-seconds 300
curl -s -o /dev/null -H 'api-key: test-key' --data-binary 'CAR used elsewhere' "http://127.0.0.1:$PORT/detect"
run "$Q2"
check "a limit used up elsewhere: the refusal stops it with exit 3" code_is 3
check "and it says so" says "The key's limit of 1 request is used up."

W=$WORK/wait
for i in 1 2 3; do photo "$W/$i.jpg" CAR; done
start_server --rate 10 --quota 2 --quota-seconds 3
run --wait "$W"
check "--wait waits for the limit to renew and finishes" code_is 0
check "--wait says it is waiting" says "Waiting until it renews at"
check "--wait gets all 3 answers" says "Sent 3 photos: 3 with a car"

# --- refusals and wrong options -------------------------------------------------------------------------------
start_server --rate 10
K=$WORK/key
photo "$K/1.jpg" CAR
KEY=wrong run "$K"
check "a wrong key stops it with exit 1" code_is 1
check "a wrong key is explained" says "the API refused the key (HTTP 403)"
KEY='' CARNET_API_KEY='' "$SCRIPT" "$K" >"$WORK/out.txt" 2>&1
CODE=$?
check "no key for the Cloud API: exit 1 before sending" code_is 1
check "no key for the Cloud API is explained" says "set your API key first"

run --params box_select=bogus "$K"
check "wrong parameters stop it at the first photo" code_is 1
check "wrong parameters are explained" says "the API did not accept the parameters: Unsupported parameter values: box_select"

run --bogus "$K"
check "an unknown option gives exit 2" code_is 2

B=$WORK/big
photo "$B/small.jpg" CAR
dd if=/dev/zero of="$B/big.jpg" bs=1048576 count=13 2>/dev/null
run "$B"
check "a photo over 12 MB is skipped" says "big.jpg: skipped, larger than 12 MB"
check "the other photos still get answers" says "Sent 1 photo: 1 with a car."

O=$WORK/custom-out
run --out "$O/" "$K"
check "--out with a trailing slash works" present "$O/1.jpg.json" "$O/results.csv"

# --- CarNET Server: no key, no limits ------------------------------------------------------------------------
S=$WORK/server
photo "$S/1.jpg" CAR
photo "$S/2.jpg" NOCAR
start_server --no-key
KEY='' run "$S"
check "CarNET Server without a key works" code_is 0
check "CarNET Server: no limit line" lacks "The key has"

echo
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]

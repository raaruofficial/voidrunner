#!/usr/bin/env bash
# GATE STAGING janitor — fixture-handle hygiene against the server's
# own store (PostgREST), for the R-1/R-2 composition runs.
#
# The staging server runs the production bundle, whose data plane is
# the production store; the gate flow's writes are confined to the
# ONE fixture handle. This script is the confinement proof:
#   mode=assert-clean  — exit 1 unless profiles / bind_challenges /
#                        sessions hold ZERO rows for the handle
#                        (run BEFORE the cell: a dirty slate aborts).
#   mode=sweep         — delete the handle's rows (sessions, then
#                        bind_challenges, then profiles), re-read,
#                        and print the residual counts (run AFTER the
#                        cell, if: always()).
# The store key is extracted from the production module copy at
# runtime into an env var; it is never printed.
set -u
MODE="${1:-}"
HANDLE="${VR_GATE_FIXTURE_HANDLE:-}"
MODULE="${2:-}" # path to the production bundle copy (release asset); store config is read from it

if [ -z "$HANDLE" ] || { [ "$MODE" != "assert-clean" ] && [ "$MODE" != "sweep" ]; }; then
  echo "usage: janitor.sh assert-clean|sweep  (VR_GATE_FIXTURE_HANDLE required)" >&2
  exit 2
fi

SB_URL="$(grep -o 'https://[a-z0-9]*\.supabase\.co' "$MODULE" | head -1)"
SB_KEY="$(grep -o 'sb_secret_[A-Za-z0-9_-]\{20,\}' "$MODULE" | head -1)"
if [ -z "$SB_URL" ] || [ -z "$SB_KEY" ]; then
  echo "janitor: could not locate store config in $MODULE" >&2
  exit 2
fi

count_rows() { # $1 = table; echoes count or "absent" when the table is not provisioned
  local body code
  body="$(curl -s -w $'\n%{http_code}' "$SB_URL/rest/v1/$1?skr=eq.$HANDLE&select=skr" \
    -H "apikey: $SB_KEY" -H "Authorization: Bearer $SB_KEY" 2>/dev/null)"
  code="${body##*$'\n'}"
  if [ "$code" = "200" ]; then
    printf '%s' "${body%$'\n'*}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'
  else
    echo "absent"
  fi
}

delete_rows() { # $1 = table
  curl -s -o /dev/null -w '%{http_code}' -X DELETE "$SB_URL/rest/v1/$1?skr=eq.$HANDLE" \
    -H "apikey: $SB_KEY" -H "Authorization: Bearer $SB_KEY" -H "Prefer: return=minimal" 2>/dev/null
}

P="$(count_rows profiles)"
C="$(count_rows bind_challenges)"
S="$(count_rows sessions)"
echo "janitor[$MODE] handle=$HANDLE pre: profiles=$P bind_challenges=$C sessions=$S"

if [ "$MODE" = "assert-clean" ]; then
  if [ "$P" = "0" ] && [ "$C" = "0" ] && { [ "$S" = "0" ] || [ "$S" = "absent" ]; }; then
    echo "janitor: slate clean"
    exit 0
  fi
  echo "janitor: SLATE NOT CLEAN — aborting before the cell" >&2
  exit 1
fi

for t in sessions bind_challenges profiles; do
  echo "janitor: delete $t -> HTTP $(delete_rows "$t")"
done
P2="$(count_rows profiles)"
C2="$(count_rows bind_challenges)"
S2="$(count_rows sessions)"
echo "janitor[$MODE] handle=$HANDLE post: profiles=$P2 bind_challenges=$C2 sessions=$S2"
if [ "$P2" = "0" ] && [ "$C2" = "0" ] && { [ "$S2" = "0" ] || [ "$S2" = "absent" ]; }; then
  echo "janitor: zero residue verified"
  exit 0
fi
echo "janitor: RESIDUE REMAINS" >&2
exit 1

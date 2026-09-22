#!/bin/bash
# probe-password.sh — find out which password an UNO Q board is currently on.
#
# Both "password did not change" and "Cannot run apt remediation: sudo
# unavailable" mean the same thing: nothing we tried authenticates for sudo.
# This tells you what does.
#
# Usage:
#   ./probe-password.sh                      # probe every attached board
#   ./probe-password.sh SERIAL               # probe one board
#   CANDIDATES="pw1,pw2" ./probe-password.sh # add your own guesses
#
# Once you find the match, put it in .env as:
#   UNOQ_CURRENT_PASSWORD=thematch

set -uo pipefail

# Defaults: factory password, plus whatever is already configured in .env.
DEFAULT_LIST="arduino"
if [ -f .env ]; then
    for key in UNOQ_DEFAULT_PASSWORD UNOQ_CURRENT_PASSWORD; do
        v=$(grep -E "^${key}=" .env 2>/dev/null | head -1 | cut -d= -f2- | sed 's/^["'"'"']//;s/["'"'"']$//')
        [ -n "${v:-}" ] && DEFAULT_LIST="$DEFAULT_LIST,$v"
    done
fi
CANDIDATES="${CANDIDATES:-$DEFAULT_LIST}"

command -v adb >/dev/null || { echo "ERROR: adb not on PATH."; exit 1; }

if [ $# -ge 1 ]; then
    SERIALS="$1"
else
    SERIALS=$(adb devices | awk 'NR>1 && $2=="device" {print $1}')
fi
[ -z "$SERIALS" ] && { echo "No boards in 'device' state. Check 'adb devices'."; exit 1; }

for SERIAL in $SERIALS; do
    echo "════════════════════════════════════════"
    echo "Board: $SERIAL"

    USER_ON_BOARD=$(adb -s "$SERIAL" shell 'whoami' 2>/dev/null | tr -d '\r\n')
    echo "  adb shell user: ${USER_ON_BOARD:-<unknown>}"

    # If sudo needs no password at all, nothing else matters.
    if adb -s "$SERIAL" shell 'sudo -n true >/dev/null 2>&1 && echo YES' 2>/dev/null | grep -q YES; then
        echo "  → passwordless sudo is available; no password needed."
        continue
    fi

    FOUND=""
    IFS=',' read -ra LIST <<< "$CANDIDATES"
    for C in "${LIST[@]}"; do
        [ -z "$C" ] && continue
        # Single-quote the candidate for the remote shell, escaping any quotes.
        ESC=${C//\'/\'\\\'\'}
        RES=$(adb -s "$SERIAL" shell "printf '%s\n' '$ESC' | sudo -S -k -p '' true >/dev/null 2>&1 && echo MATCH || echo no" 2>/dev/null | tr -d '\r')
        if echo "$RES" | grep -q MATCH; then
            printf "  %-24s MATCH\n" "$C"
            FOUND="$C"
            break
        fi
        printf "  %-24s no\n" "$C"
    done

    if [ -n "$FOUND" ]; then
        echo "  → Put this in .env:  UNOQ_CURRENT_PASSWORD=$FOUND"
    else
        echo "  → No candidate matched. Add guesses with CANDIDATES=\"a,b,c\","
        echo "    or reflash this board to reset it to the factory password."
    fi
done

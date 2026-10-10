#!/bin/sh
#
# Tests the sudo module (NotchSudo/pam_notch.c) against a fake helper:
# it must say yes only to a helper that matches the code requirement, and
# fall through to the password prompt in every other case.
#
# Usage: Tools/pam_notch-tests/run.sh
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
work="$(mktemp -d /tmp/pam_notch-tests.XXXXXX)"
trap 'rm -rf "$work"' EXIT

# A short fake home: the socket path has to fit in 104 bytes.
home="$work/h"
socket="$home/Library/Application Support/theboringteam.boringnotch/sudo.sock"
mkdir -p "$(dirname "$socket")"

clang -Wall -Wextra -Werror -I "$repo/NotchSudo" -o "$work/harness" \
    "$here/harness.c" "$repo/NotchSudo/pam_notch.c" -lpam -framework Security -framework CoreFoundation
clang -Wall -o "$work/fake_helper" "$here/fake_helper.c"
codesign --force --sign - "$work/fake_helper" 2>/dev/null

# The requirement that matches the fake helper, and one that doesn't.
codesign -d -r- "$work/fake_helper" 2>&1 | sed -n 's/^# //; s/^designated => //p' > "$work/matching.req"
echo 'identifier "theboringteam.boringnotch.BoringNotchXPCHelper" and anchor apple generic' > "$work/other.req"

failures=0
check() {
    description=$1 mode=$2 requirement=$3 expected=$4
    if [ "$mode" != none ]; then
        "$work/fake_helper" "$socket" "$mode" &
        sleep 0.3
    fi
    if "$work/harness" "$home" "$requirement" "$expected"; then
        echo "ok    $description"
    else
        echo "FAIL  $description"
        failures=$((failures + 1))
    fi
    wait 2>/dev/null || true
}

check "allows when the helper says allow" allow "$work/matching.req" allow
check "denies when the helper says deny" deny "$work/matching.req" deny
check "won't trust a helper with the wrong signature" allow "$work/other.req" unavailable
check "falls through when nothing is listening" none "$work/matching.req" unavailable
check "falls through on a garbled answer" garbage "$work/matching.req" unavailable
check "falls through without a requirement file" none "$work/missing.req" unavailable

[ "$failures" = 0 ] && echo "All passed." || { echo "$failures failed."; exit 1; }

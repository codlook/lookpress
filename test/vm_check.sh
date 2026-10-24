#!/usr/bin/env bash
# LookPress runs on LOOK's bytecode VM: every route, no interpreter fallback.
#
# LOOK falls back to the slower tree-walk interpreter quietly — for the whole program (a
# compile or VM setup error) or for one route (it reaches a builtin the VM lacks) — and only
# says so in its log. The pages still work, so the smoke suite cannot see it.
# Usage: test/vm_check.sh <container>
set -u
C="${1:?usage: $0 <container>}"
log="$(docker logs "$C" 2>&1)"
fail=0
if echo "$log" | grep -q "VM dispatch ready"; then
    echo "  OK   $(echo "$log" | grep -o 'VM dispatch ready — [0-9]* route' | tail -1)"
else
    echo "  FAIL no 'VM dispatch ready' line: the app is not running on the VM"; fail=1
fi
bad="$(echo "$log" | grep -E "runs on the interpreter|WHOLE application|VM setup error|interpreter fallback")"
if [ -n "$bad" ]; then echo "  FAIL interpreter fallback:"; echo "$bad" | sed 's/^/       /'; fail=1
else echo "  OK   no interpreter fallback"; fi
[ "$fail" = 0 ] && echo "PASS: LookPress runs on the VM" || echo "FAIL: LookPress does not run fully on the VM"
exit "$fail"

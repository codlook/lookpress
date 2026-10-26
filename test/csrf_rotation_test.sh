#!/usr/bin/env bash
# Changing LOOK_SECRET does not break the forms that are open: LOOK_SECRET_PREVIOUS is still
# accepted for checking, and the cookie is signed again with the new secret.
# Usage: csrf_rotation_test.sh <image>   (starts its own containers on ports 7451 and 7452)
set -u
IMG="${1:-lookpress:ci}"
T=$(mktemp -d); trap 'docker rm -f lprotA lprotB >/dev/null 2>&1; rm -rf "$T"' EXIT
OLD=old-secret-0123456789abcdef0123456789ab; NEW=new-secret-0123456789abcdef0123456789ab
fail=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; fail=1; }
up() {   # up <name> <port> <env...>
    local n="$1" p="$2"; shift 2
    docker rm -f "$n" >/dev/null 2>&1
    docker run -d --name "$n" -p "$p:7400" -e ADMIN_PASSWORD=lookpress-dev -e LOOK_SESSION_SECURE=0 "$@" "$IMG" >/dev/null
    for i in $(seq 1 60); do curl -s -o /dev/null --max-time 1 "http://localhost:$p/" && return 0; sleep 0.5; done
    echo "FAIL: $n did not start"; docker logs "$n" | tail -5; exit 1
}
post() {   # post <port> <jar> <token> → status
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 -b "$2" -c "$2" -X POST "http://localhost:$1/forms/contact" \
        --data-urlencode "name=rotation" --data-urlencode "email=r@example.com" --data-urlencode "message=hi" \
        --data-urlencode "_csrf=$3"
}
up lprotA 7451 -e LOOK_SECRET=$OLD
curl -s -c "$T/j" -o "$T/f.html" "http://localhost:7451/contact"
tok=$(grep -o 'name="_csrf" value="[^"]*"' "$T/f.html" | head -1 | sed 's/.*value="//; s/"$//')
old_cookie=$(awk '/lp_csrf/{print $7}' "$T/j")
[ -n "$tok" ] && [ -n "$old_cookie" ] && ok "a form and its cookie under the old secret" || bad "no form/cookie under the old secret"

up lprotB 7452 -e LOOK_SECRET=$NEW
cp "$T/j" "$T/j1"
c=$(post 7452 "$T/j1" "$tok"); [ "$c" = 403 ] && ok "new secret only: the open form is refused (403)" || bad "new secret only: $c (want 403)"

up lprotB 7452 -e LOOK_SECRET=$NEW -e LOOK_SECRET_PREVIOUS=$OLD
cp "$T/j" "$T/j2"
c=$(post 7452 "$T/j2" "$tok"); [ "$c" != 403 ] && ok "with LOOK_SECRET_PREVIOUS the open form still works ($c)" || bad "with LOOK_SECRET_PREVIOUS: 403"
curl -s -b "$T/j2" -c "$T/j2" -o /dev/null "http://localhost:7452/contact"
new_cookie=$(awk '/lp_csrf/{print $7}' "$T/j2")
[ -n "$new_cookie" ] && [ "${new_cookie%%.*}" = "${old_cookie%%.*}" ] && [ "$new_cookie" != "$old_cookie" ] \
    && ok "the cookie is signed again with the new secret (same base)" || bad "the cookie was not re-signed ('$old_cookie' → '$new_cookie')"

[ $fail = 0 ] && echo "PASS: changing LOOK_SECRET keeps open forms working with LOOK_SECRET_PREVIOUS" || echo "FAIL: secret rotation"
exit $fail

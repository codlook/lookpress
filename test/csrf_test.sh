#!/usr/bin/env bash
# CSRF: visitors who never log in store nothing on the server, and forged requests are refused.
#
# The CSRF token lived in the session: every visitor who saw a form (contact, cart, checkout)
# created a session file on the server, and nothing ever removed it — requests without a cookie
# could fill the disk without logging in. Now the token is kept in a signed cookie
# (lp_csrf = base.HMAC(LOOK_SECRET, "csrf|base|session id")), the form carries a per-render value
# (nonce.HMAC(base, nonce)), and nothing is stored for the visitor.
# Usage: csrf_test.sh <base url> <container>   (the app runs in a Docker container, as in CI)
set -u
BASE="${1:-http://localhost:7400}"; CT="${2:-lp}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0; ok() { echo "  ok   $1"; }; bad() { echo "  FAIL $1"; fail=1; }
sessions() {   # bilinen oturum dizinleri (LOOK 1.0.30: /tmp; 1.0.38+: look-sessions-<uid>, $HOME/.look/sessions)
    docker exec "$CT" sh -c 'ls -1 /tmp/look_sess_* /tmp/look-sessions-*/look_sess_* "$HOME"/.look/sessions/look_sess_* "${LOOK_SESSION_DIR:-/nonexistent}"/look_sess_* 2>/dev/null | wc -l'
}
token_of() { grep -o 'name="_csrf" value="[^"]*"' "$1" | head -1 | sed 's/.*value="//; s/"$//'; }
post() {   # post <cookie jar or -> <token or -> [extra curl args] → HTTP status of POST /forms/contact
    local jar="$1" tok="$2"; shift 2
    local args=(-s -o "$T/post.html" -w '%{http_code}' --max-time 10 -X POST "$BASE/forms/contact"
                --data-urlencode "name=CSRF test" --data-urlencode "email=csrf@example.com" --data-urlencode "message=hello")
    [ "$jar" != - ] && args+=(-b "$jar")
    [ "$tok" != - ] && args+=(--data-urlencode "_csrf=$tok")
    curl "${args[@]}" "$@"
}

echo "-- no server-side state for visitors --"
before=$(sessions)
for i in $(seq 1 200); do curl -s -o /dev/null --max-time 10 "$BASE/contact"; done
after=$(sessions)
[ $((after - before)) -le 0 ] && ok "200 visits to a page with a form left no session files ($before → $after)" \
                              || bad "200 visits to a page with a form left $((after - before)) session files ($before → $after)"

echo "-- the form still works --"
curl -s -c "$T/a" -b "$T/a" -o "$T/a.html" "$BASE/contact"; TA=$(token_of "$T/a.html")
[ -n "$TA" ] && ok "the form carries a token" || bad "no _csrf field in /contact"
c=$(post "$T/a" "$TA"); [ "$c" != 403 ] && ok "a correct token is accepted ($c)" || bad "a correct token is refused (403)"
curl -s -b "$T/a" -o "$T/a2.html" "$BASE/contact"; TA2=$(token_of "$T/a2.html")
[ "$TA" != "$TA2" ] && ok "the form value changes on every render (BREACH)" || bad "the same form value on every render"
c=$(post "$T/a" "$TA2"); [ "$c" != 403 ] && ok "an older render's value is accepted too ($c)" || bad "a second render's value is refused"

echo "-- forged requests are refused --"
c=$(post "$T/a" -);                         [ "$c" = 403 ] && ok "no token: 403" || bad "no token: $c"
c=$(post - "$TA");                          [ "$c" = 403 ] && ok "no cookie: 403" || bad "no cookie: $c"
c=$(post "$T/a" "${TA%?}0");                [ "$c" = 403 ] && ok "a changed token: 403" || bad "a changed token: $c"
curl -s -c "$T/b" -b "$T/b" -o "$T/b.html" "$BASE/contact"; TB=$(token_of "$T/b.html")
c=$(post "$T/a" "$TB");                     [ "$c" = 403 ] && ok "another visitor's token: 403" || bad "another visitor's token: $c"
sed -E 's/(lp_csrf\t[^.]*\.)./\10/' "$T/a" > "$T/forged"
c=$(post "$T/forged" "$TA");                [ "$c" = 403 ] && ok "a cookie with a changed signature: 403" || bad "a forged cookie: $c"
c=$(post "$T/a" "$TA" -H "Origin: https://evil.example"); [ "$c" = 403 ] && ok "a cross-site Origin: 403" || bad "a cross-site Origin: $c"

echo "-- proxy headers count only behind a trusted proxy (LOOK_TRUSTED_PROXY unset here) --"
# X-Forwarded-Host / X-Forwarded-Proto are believed only when LOOK_TRUSTED_PROXY is set — the rule
# LOOK applies to its own session cookie. Without it a request can claim any host or scheme.
c=$(post "$T/a" "$TA" -H "Origin: https://evil.example" -H "X-Forwarded-Host: evil.example")
[ "$c" = 403 ] && ok "a cross-site Origin with a matching X-Forwarded-Host: 403" || bad "X-Forwarded-Host believed without a trusted proxy: $c"
h=$(curl -s -D - -o /dev/null -H "X-Forwarded-Proto: https" "$BASE/contact")
if echo "$h" | grep -qi "^set-cookie: lp_csrf=" && ! echo "$h" | grep -qi "strict-transport-security"; then
    ok "X-Forwarded-Proto: https is not believed (cookie lp_csrf, no HSTS)"
else bad "X-Forwarded-Proto believed without a trusted proxy: $(echo "$h" | grep -iE 'set-cookie: (__Host-)?lp_csrf|strict-transport' | tr -d '\r' | tr '\n' ' ')"; fi

echo "-- sessions --"
# Aynı sayfadaki ikinci form: sepete ilk ekleme oturumu yaratır, sayfanın öbür formları çalışmaya
# devam etmeli (anahtar oturum kimliğine bağlıyken 403 alıyorlardı).
curl -s -c "$T/c" -b "$T/c" -o "$T/p.html" "$BASE/product/kirmizi-tisort"; TC=$(token_of "$T/p.html")
c1=$(curl -s -o /dev/null -w '%{http_code}' -c "$T/c" -b "$T/c" -X POST --data-urlencode "_csrf=$TC" -d "slug=kirmizi-tisort" "$BASE/cart/add")
c2=$(curl -s -o /dev/null -w '%{http_code}' -c "$T/c" -b "$T/c" -X POST --data-urlencode "_csrf=$TC" -d "slug=kirmizi-tisort" "$BASE/cart/add")
[ "$c1" != 403 ] && [ "$c2" != 403 ] && ok "a second form on the page works after the first one opened a session ($c1, $c2)" \
                                    || bad "a second form after the session was opened: $c1, $c2"
# Girişte anahtar yenilenir: girişten önce gösterilmiş bir anahtar girişten sonra geçmez.
curl -s -c "$T/l" -b "$T/l" -o "$T/l.html" "$BASE/contact"; TL=$(token_of "$T/l.html")
curl -s -o /dev/null -c "$T/l" -b "$T/l" -X POST -d "username=admin&password=${ADMIN_PW:-lookpress-dev}" "$BASE/admin/login"
c=$(post "$T/l" "$TL"); [ "$c" = 403 ] && ok "a token shown before login is refused after login (403)" || bad "a token from before login still works after login: $c"
curl -s -c "$T/l" -b "$T/l" -o "$T/l2.html" "$BASE/contact"; TL2=$(token_of "$T/l2.html")
c=$(post "$T/l" "$TL2"); [ "$c" != 403 ] && ok "a token shown after login works ($c)" || bad "a token shown after login: 403"

[ $fail = 0 ] && echo "PASS: CSRF without server-side state" || echo "FAIL: CSRF"
exit $fail

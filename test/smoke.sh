#!/usr/bin/env bash
# LookPress smoke/guard suite — exercises the critical flows end to end against a
# running instance so a change can't silently break them. Run against the Docker
# dev env (docker compose up -d), then:  bash test/smoke.sh  [BASE_URL]
# Default BASE=http://localhost:8080, admin password from ADMIN_PW (default the
# compose dev value). Exit non-zero on any failure.
set -u
BASE="${1:-http://localhost:8080}"
ADMIN_PW="${ADMIN_PW:-lookpress-dev}"
JAR="$(mktemp)"; EJAR="$(mktemp)"
trap 'rm -f "$JAR" "$EJAR"' EXIT
fails=0; n=0

ok()   { n=$((n+1)); echo "  ok   $1"; }
bad()  { n=$((n+1)); fails=$((fails+1)); echo "  FAIL $1"; }
code() { curl -s -o /dev/null -w "%{http_code}" "$@"; }         # -> status
body() { curl -s "$@"; }

# code_is TAG URL EXPECTED [curl args...]
code_is() { local tag="$1" url="$2" exp="$3"; shift 3; local c; c=$(code "$@" "$BASE$url");
  [ "$c" = "$exp" ] && ok "$tag ($c)" || bad "$tag (got $c, want $exp)"; }
# has TAG URL NEEDLE
has() { local tag="$1" url="$2" needle="$3"; if body "$BASE$url" | grep -q -- "$needle"; then ok "$tag"; else bad "$tag (missing: $needle)"; fi; }

echo "LookPress smoke @ $BASE"
echo "-- public --"
code_is "home"              "/" 200
has     "home brand"        "/" "LookPress"
code_is "catalog"           "/product" 200
code_is "product detail"    "/product/kirmizi-tisort" 200
has     "product price"     "/product/kirmizi-tisort" "&#8378;"
code_is "blog"              "/blog" 200
code_is "search hit"        "/search?q=tisort" 200
has     "search finds"      "/search?q=tisort" "product"
code_is "contact"           "/contact" 200
code_is "sitemap"           "/sitemap.xml" 200
code_is "robots"            "/robots.txt" 200
code_is "rss"               "/feed" 200
code_is "404 unknown"       "/no-such-thing-xyz" 404

echo "-- multilingual --"
code_is "en home"           "/en" 200
code_is "en product detail" "/en/product/kirmizi-tisort" 200
has     "en content"        "/en/product/kirmizi-tisort" "Red T-Shirt"
has     "tr content"        "/product/kirmizi-tisort" "Kırmızı"

echo "-- SEO --"
has     "meta description"  "/product/kirmizi-tisort" 'name="description"'
has     "product json-ld"   "/product/kirmizi-tisort" 'schema.org","@type":"Product"'

echo "-- commerce flow --"
curl -s -c "$JAR" -b "$JAR" -X POST -d "slug=kirmizi-tisort" "$BASE/cart/add" >/dev/null
if body -b "$JAR" "$BASE/cart" | grep -q "Kırmızı"; then ok "cart holds item"; else bad "cart holds item"; fi
n=$((n+1))
# checkout -> order
curl -s -c "$JAR" -b "$JAR" -X POST -d "cust_name=Test&email=t@e.com&phone=1&address=A" "$BASE/checkout" | grep -q "alındı" && ok "checkout confirms" || bad "checkout confirms"
n=$((n+1))

echo "-- admin + RBAC --"
code_is "login page"        "/admin/login" 200
has     "admin shell"       "/admin/login" "LookPress Admin"
# admin login
curl -s -c "$EJAR" -b "$EJAR" -X POST -d "username=admin&password=$ADMIN_PW" "$BASE/admin/login" >/dev/null
if body -b "$EJAR" "$BASE/admin" | grep -q "Content types"; then ok "admin login"; else bad "admin login"; fi
n=$((n+1))
# admin-only page reachable by admin
if body -b "$EJAR" "$BASE/admin/users" | grep -q "Kullanıcılar"; then ok "admin sees users"; else bad "admin sees users"; fi
n=$((n+1))
# orders visible
if body -b "$EJAR" "$BASE/admin/orders" | grep -q "Sipariş"; then ok "admin sees orders"; else bad "admin sees orders"; fi
n=$((n+1))
# wrong password rejected
if body -X POST -d "username=admin&password=WRONG" "$BASE/admin/login" | grep -q "hatalı"; then ok "wrong password rejected"; else bad "wrong password rejected"; fi
n=$((n+1))

echo ""
echo "== $((n-fails))/$n passed =="
[ "$fails" -eq 0 ] || { echo "SMOKE FAILED ($fails)"; exit 1; }
echo "SMOKE OK"

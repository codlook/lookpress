#!/usr/bin/env bash
# LookPress smoke/guard suite — exercises the critical flows end to end against a
# running instance so a change can't silently break them. Run against the Docker
# dev env (docker compose up -d), then:  bash test/smoke.sh  [BASE_URL]
# Default BASE=http://localhost:8080, admin password from ADMIN_PW (default the
# compose dev value). Exit non-zero on any failure.
set -u
BASE="${1:-http://localhost:8080}"
ADMIN_PW="${ADMIN_PW:-lookpress-dev}"
JAR="$(mktemp)"; EJAR="$(mktemp)"; WJAR="$(mktemp)"
trap 'rm -f "$JAR" "$EJAR" "$WJAR"' EXIT
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
# CSRF: a POST without the form's token is refused (403) — if the protection is ever
# dropped, this check fails. The flow itself reads the token from the product page's
# form (same session cookie) and sends it, like a browser does.
code_is "cart/add without CSRF token refused" "/cart/add" 403 -c "$JAR" -b "$JAR" -X POST -d "slug=kirmizi-tisort"
TOKEN="$(body -c "$JAR" -b "$JAR" "$BASE/product/kirmizi-tisort" | grep -o 'name="_csrf" value="[^"]*"' | head -1 | sed 's/.*value="//; s/"$//')"
[ -n "$TOKEN" ] && ok "product form carries a CSRF token" || bad "product form carries a CSRF token"
curl -s -o /dev/null -c "$JAR" -b "$JAR" -X POST --data-urlencode "_csrf=$TOKEN" -d "slug=kirmizi-tisort" "$BASE/cart/add"
if body -b "$JAR" "$BASE/cart" | grep -q "Kırmızı"; then ok "cart holds item"; else bad "cart holds item"; fi
code_is "checkout without CSRF token refused" "/checkout" 403 -c "$JAR" -b "$JAR" -X POST -d "cust_name=Test&email=t@e.com&phone=1&address=A"
body -c "$JAR" -b "$JAR" -X POST --data-urlencode "_csrf=$TOKEN" -d "cust_name=Test&email=t@e.com&phone=1&address=A" "$BASE/checkout" | grep -q "alındı" && ok "checkout confirms" || bad "checkout confirms"

echo "-- admin + RBAC --"
code_is "login page"        "/admin/login" 200
has     "admin shell"       "/admin/login" "LookPress Admin"
# Without a session /admin sends you to the login page.
code_is "admin without session redirects" "/admin" 302
# Login: judged by status and session, not by words on the page (text changes; a
# failed login used to pass a word check). A good login redirects (302) and the
# session then opens /admin itself (200); a wrong password does not redirect and
# its session still gets the 302 to the login page.
code_is "admin login redirects"           "/admin/login" 302 -c "$EJAR" -b "$EJAR" -X POST -d "username=admin&password=$ADMIN_PW"
code_is "admin session opens dashboard"   "/admin" 200 -b "$EJAR"
code_is "admin sees users"                "/admin/users" 200 -b "$EJAR"
code_is "admin sees orders"               "/admin/orders" 200 -b "$EJAR"
# Module list with field filters (JSON fields read per database: json_extract does not exist on
# PostgreSQL; on MySQL it returns a string with its quotes, so the filter offered "giyim" in quotes
# and found nothing).
code_is "admin product list" "/admin/type/product" 200 -b "$EJAR"
if body -b "$EJAR" "$BASE/admin/type/product" | grep -q '<option value="giyim"'; then ok "category filter offers giyim"; else bad "category filter offers giyim"; fi
if body -b "$EJAR" "$BASE/admin/type/product?f_category=giyim" | grep -q 'Kırmızı'; then ok "category filter finds the product"; else bad "category filter finds the product"; fi
# The order placed above shows in the dashboard's revenue (a failed sum used to read as 0).
REV="$(body -b "$EJAR" "$BASE/admin" | grep -o '<b>[^<]*</b> ciro' | head -1 | sed 's/<b>//; s/<\/b> ciro//')"
if echo "$REV" | grep -q '[1-9]'; then ok "dashboard revenue counts the order ($REV)"; else bad "dashboard revenue counts the order (got '$REV')"; fi
code_is "wrong password does not redirect" "/admin/login" 200 -c "$WJAR" -b "$WJAR" -X POST -d "username=admin&password=WRONG"
code_is "wrong password opens no session" "/admin" 302 -b "$WJAR"

echo "-- search (Turkish letters, LIKE metacharacters) --"
# Fixture pages are created through the admin form (the real write path); a run
# suffix keeps slugs and titles unique, so the suite can run twice on one database.
S="$$$(date +%s)"
ADMIN_TOKEN="$(body -b "$EJAR" "$BASE/admin/type/page/new" | grep -o '<meta name="csrf" content="[^"]*"' | head -1 | sed 's/.*content="//; s/"$//')"
savepage() {   # savepage PATH STATUS SLUG TITLE [curl args...] — through the admin form
  local path="$1" st="$2" slug="$3" title="$4"; shift 4
  code_is "page '$title' saved ($st)" "$path" 302 -b "$EJAR" -X POST --data-urlencode "_csrf=$ADMIN_TOKEN" \
    --data-urlencode "title=$title" --data-urlencode "slug=$slug" -d "status=$st&lang=tr" --data-urlencode "body=Arama testi" "$@"
}
mkpage() { savepage "/admin/type/page/new" published "$1-$S" "$2"; }   # mkpage SLUG TITLE
pageid() {   # pageid TITLE -> the page's id, from the admin list filtered by the title
  body -b "$EJAR" -G --data-urlencode "q=$1" "$BASE/admin/type/page" | grep -o "/admin/type/page/edit/[0-9]*\">$1<" | head -1 | sed 's#.*/edit/##; s#".*##'
}
mkpage srch-a "Tişörtler indirimde $S"
mkpage srch-b "Kırmızı kapı $S"
mkpage srch-c "IŞIK $S"
# Text comes back as written — 4-byte characters too (MySQL needs utf8mb4 for them).
mkpage srch-emoji "Çay ☕ keyfi 🙂 $S"
if body "$BASE/srch-emoji-$S" | grep -qF "Çay ☕ keyfi 🙂 $S"; then ok "emoji and Turkish text come back as written"; else bad "emoji and Turkish text come back as written"; fi
# finds TAG QUERY TITLE / misses TAG QUERY TITLE
finds()  { if body -G --data-urlencode "q=$2" "$BASE/search" | grep -qF -- "$3"; then ok "$1"; else bad "$1 (no '$3')"; fi; }
misses() { if body -G --data-urlencode "q=$2" "$BASE/search" | grep -qF -- "$3"; then bad "$1 (found '$3')"; else ok "$1"; fi; }
finds  "tisort finds Tişörtler"   "tisort"  "Tişörtler indirimde $S"
finds  "kirmizi finds Kırmızı"    "kirmizi" "Kırmızı kapı $S"
finds  "isik finds IŞIK"          "isik"    "IŞIK $S"
finds  "ışık finds IŞIK"          "ışık"    "IŞIK $S"
misses "% is a character, not a wildcard" "%%" "Tişörtler indirimde $S"
misses "_ is a character, not a wildcard" "__" "Kırmızı kapı $S"

# Only published text is searched: not a draft, not a page scheduled for later, not the
# old text of a page published again, not a published page taken back to draft.
savepage "/admin/type/page/new" draft     "srch-d-$S" "Taslak kavanoz$S"
misses "a draft is not found"              "kavanoz$S" "Taslak kavanoz$S"
savepage "/admin/type/page/new" published "srch-e-$S" "Gelecek fincan$S" -d "publish_at=2099-01-01T10:00"
misses "a page scheduled for later is not found" "fincan$S" "Gelecek fincan$S"
mkpage srch-f "Eski kase$S"
finds  "a published page is found"         "kase$S"    "Eski kase$S"
F_ID="$(pageid "Eski kase$S")"
savepage "/admin/type/page/edit/$F_ID" published "srch-f-$S" "Yeni tabak$S"
finds  "published again: the new text is found"  "tabak$S" "Yeni tabak$S"
misses "published again: the old text is not"    "kase$S"  "Eski kase$S"
mkpage srch-g "Yayinda tencere$S"
G_ID="$(pageid "Yayinda tencere$S")"
savepage "/admin/type/page/edit/$G_ID" draft "srch-g-$S" "Yayinda tencere$S"
misses "taken back to draft: not found"    "tencere$S" "Yayinda tencere$S"

echo ""
echo "== $((n-fails))/$n passed =="
[ "$fails" -eq 0 ] || { echo "SMOKE FAILED ($fails)"; exit 1; }
echo "SMOKE OK"

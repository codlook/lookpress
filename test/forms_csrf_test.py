#!/usr/bin/env python3
# Every POST form LookPress renders carries a CSRF token (LOOK 2 checks every POST of an app that
# uses cookies; a form without the token gets 403). Found by running LookPress on LOOK 2: the admin
# login form used the "auth" layout, which has no token script, so no admin could log in.
# Usage: forms_csrf_test.py <base url> <admin password>   (run after smoke.sh, which places an order)
# LookPress v2: her sayfadaki her POST formu CSRF anahtarı taşıyor mu? (çalışma anında, gerçek HTML)
# Herkese açık sayfa: formun içinde dolu bir _csrf alanı olmalı.
# Yönetici sayfası: <meta name="csrf"> dolu olmalı + düzenin enjeksiyon betiği sayfada olmalı
# (betik submit anında her POST formuna _csrf ekler); formun kendisinde alan olması gerekmez.
import http.cookiejar, re, sys, urllib.parse, urllib.request
B = sys.argv[1]
cj = http.cookiejar.CookieJar()
op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
def get(p):
    try: return op.open(B + p, timeout=15).read().decode("utf-8", "replace")
    except Exception as e: return "ERR %s" % e
def post(p, data):
    try: return op.open(B + p, urllib.parse.urlencode(data).encode(), timeout=15).read().decode("utf-8", "replace")
    except Exception as e: return "ERR %s" % e
FORM = re.compile(r'<form\b[^>]*method=["\']?post["\']?[^>]*>(.*?)</form>', re.S | re.I)
TOK = re.compile(r'name=["\']_csrf["\']\s+value=["\']([0-9a-f]+\.[0-9a-f]+)["\']')
bad, checked = [], 0
def public(p):
    global checked
    h = get(p)
    if h.startswith("ERR"): bad.append((p, h)); return
    for i, body in enumerate(FORM.findall(h)):
        checked += 1
        if not TOK.search(body): bad.append((p, "form %d has no _csrf token" % (i + 1)))
pub = ["/admin/login", "/", "/blog", "/contact", "/search?q=a", "/product/kirmizi-tisort", "/product/mavi-kot", "/en", "/en/blog",
       "/hesap/giris", "/hesap/kayit", "/hesap/sifremi-unuttum", "/hesap/sifre-sifirla?token=x"]
for p in pub: public(p)
# sepete bir ürün koy ki sepet sayfasının formları (adet, sil, kupon, ödeme) görünsün
h = get("/product/kirmizi-tisort"); m = TOK.search(h)
if m: post("/cart/add", {"slug": "kirmizi-tisort", "_csrf": m.group(1)})
public("/cart")
# yönetici
h = get("/admin/login"); m = TOK.search(h)
post("/admin/login", {"username": "admin", "password": sys.argv[2], "_csrf": m.group(1) if m else ""})
adm = ["/admin", "/admin/categories", "/admin/coupons", "/admin/forms", "/admin/import", "/admin/media", "/admin/menu",
       "/admin/orders", "/admin/roles", "/admin/settings", "/admin/themes", "/admin/types", "/admin/types/new",
       "/admin/users", "/admin/uyeler", "/admin/type/page", "/admin/type/page/new", "/admin/type/product", "/admin/order/1"]
for p in adm:
    h = get(p)
    if h.startswith("ERR"): bad.append((p, h)); continue
    forms = FORM.findall(h); checked += len(forms)
    if not forms: continue
    meta = re.search(r'<meta name="csrf" content="([0-9a-f]+\.[0-9a-f]+)"', h)
    inj = "document.addEventListener('submit'" in h
    if not (meta and inj):
        # betik yoksa formların kendisi anahtar taşımalı
        for i, body in enumerate(forms):
            if not TOK.search(body): bad.append((p, "form %d: no token, no injection script (meta=%s)" % (i + 1, bool(meta))))
print("checked %d POST form(s) on %d page(s)" % (checked, len(pub) + 1 + len(adm)))
for b in bad: print("  PROBLEM", b[0], "-", b[1][:150])
print("PASS" if not bad else "FAIL")

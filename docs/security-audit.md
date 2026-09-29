# LookPress security audit (product layer) — 2026-09-26

Scope: read-only review of the LookPress product layer (`app.lk`, `routes/`, `src/`,
`extensions/`, `views/`, `scripts/`, `docker/`, `docs/`) against the "Security baseline"
in `docs/cms-spec.md`, with LOOK core semantics confirmed in `look/cpp/src`
(`web_stdlib.cpp`, `web.cpp`, `http_main.cpp`, `interpreter.cpp`, `file_stdlib.cpp`,
`extra_stdlib.cpp`, `include/look/html_escape.h`). Nothing was executed; every finding
quotes the lines it rests on. Items that could not be settled by reading are marked
**needs runtime verification** with the exact test.

Engine note: the deployed configuration runs with `LOOK_BYTECODE=0` (tree-walk
interpreter). Route parameters are URL-decoded there (`interpreter.cpp:2039`:
`route_params[...] = WebContext::url_decode(match[pi+1].str(), false)`), which matters
for LP-04.

## Executive summary

| Severity | Count | IDs |
|---|---|---|
| Critical | 0 | — |
| High | 2 | LP-01, LP-02 |
| Medium | 9 | LP-03 … LP-11 |
| Low | 9 | LP-12 … LP-20 |
| Info | 6 | LP-21 … LP-26 |

What is solid (verified, no finding): every `db::query`/`db::exec` that takes user data
is parameterized; the only SQL string-building is over allow-listed identifiers
(`list_filter_where`, `list_filter_defs`: `^[A-Za-z0-9_]+$` before `json_extract('$.…')`),
constant fragments (`$lim`, `COALESCE(status,'acik') = ?`) and migration-time
`PRAGMA table_info(...)` with literal table names. Uploads are MIME-sniffed from magic
bytes in the core (`web.cpp:408 uf.mime = detect_mime(part_data)`), SVG is refused
unless `allow_svg` (`web_stdlib.cpp:405`), files are stored under a sha name with an
extension derived from the sniffed MIME (`web.cpp:157-164`), and `/media/{name}` only
serves `^[0-9a-f]{32}\.[a-z0-9]{2,5}$` names that exist in the `media` table
(`routes/public.lk:23-29`) with `X-Content-Type-Options: nosniff` set globally
(`src/security.lk:95`). The session cookie is `HttpOnly; SameSite=Lax` (+ `Secure` via
`LOOK_SESSION_SECURE`) (`web_stdlib.cpp:785`), `session::regenerate()` runs on admin
and member login (`routes/admin.lk:31`, `members.lk:93`), passwords are
PBKDF2-SHA256/100000 (`extra_stdlib.cpp:111`), `response::header`/`redirect` strip
CR/LF (`web_stdlib.cpp:433-440`), the template engine escapes `{$…}` by default with
`<>&"'` and backtick (`html_escape.h`), Markdown escapes all input before rendering
and neutralises `javascript:`/`data:`/`vbscript:` in links (`lib/markdown.lk`), and the
block renderer escapes every field except the explicitly trusted `html` block.
CSRF coverage is complete for every state-changing POST in the codebase (see LP-22).

---

## Findings

### LP-01 · High · Content actions ignore `{type}` — cross-type IDOR on delete / edit / duplicate / rollback / history

**Location:** `routes/admin.lk:293-339` (`POST /admin/type/{type}/{action}/{id}`),
`routes/admin.lk:255-287` (`GET|POST /admin/type/{type}/edit/{id}`),
`routes/admin.lk:342-359` (`GET /admin/type/{type}/history/{id}`).

**Description.** `{type}` is used only to build redirect targets and (for `edit`/`duplicate`)
to pick the field schema; the row lookups never constrain on `c.type`:

```
301  db::exec($c, "DELETE FROM revisions WHERE content_id = ?", [$id]);
302  db::exec($c, "DELETE FROM content WHERE id = ?", [$id]);
...
308  ... FROM content c JOIN revisions r ON r.id = c.current_rev WHERE c.id = ?", [$id]);   // duplicate
...
329  SELECT id FROM revisions WHERE id = ? AND content_id = ?", [$rev, $id]);              // rollback
...
261  ... WHERE c.id = ?", [request::param("id")]);                                          // edit GET
285  save_content($c, $t["slug"], type::to_int(request::param("id")), ...);                 // edit POST
```

`save_content()` (`src/types.lk:433`) issues `UPDATE content SET slug=?, lang=?, status=?
… WHERE id = ?` — it never touches `type`, so an edit through the wrong `{type}` writes a
revision whose `fields_json` follows type A's schema onto a row of type B (silent data
corruption), and `delete` removes any content row regardless of type. The `delete` branch
does not even call `load_type`, so `{type}` can be any string.

Impact is amplified because commerce hides `product` behind its own `products` permission
(`commerce.lk:551 xp_hidden_types()`, `:553 xp_permissions()`), but every
`/admin/type/*` route is gated by `can("content")` only (`routes/admin.lk:172, 228, 237,
257, 272, 295, 344`). A role holding `content` but not `products`/`orders` can therefore
list, edit and delete products (`/admin/type/product`), and — via this finding — any
content row of any module through any `{type}` it likes. The permission split in the UI
is nav-only.

**PoC** (logged in as a `content`-only editor; `$T` = CSRF token from
`<meta name="csrf">`; 42 = id of a product):

```
curl -b sess -X POST https://site/admin/type/page/delete/42 -d "_csrf=$T"     # deletes product 42
curl -b sess https://site/admin/type/page/edit/42                            # renders product 42 in the page form
curl -b sess -X POST https://site/admin/type/page/edit/42 -d "_csrf=$T&title=x&slug=x&status=published&lang=tr"
# -> product row 42 now carries a page-shaped revision
```

**Fix (minimal).** Load the type first and pin every lookup/mutation to it:

```look
// routes/admin.lk, POST /admin/type/{type}/{action}/{id}
$t = load_type($c, $type);
if ($t == null) { return response::status(404, "No such type"); }
$own = db::query($c, "SELECT id FROM content WHERE id = ? AND type = ?", [$id, $t["slug"]]);
if (count($own) == 0) { return response::status(404, "No such item"); }
```

Apply the same `AND c.type = ?` to the `SELECT`s at `:261`, `:308`, `:348`, and change
`save_content`'s `UPDATE` (`src/types.lk:433`) to `WHERE id = ? AND type = ?` with
`[$slug, $lang, $status, $ts, $id, $type]`. For the permission split, make the gate
type-aware: `if (!can(type_perm($t))) …` where `type_perm()` returns `"products"` for
`product` (extension seam `xp_type_perm()`), else `"content"`.

---

### LP-02 · High · `users` / `roles` permissions are silent superuser grants (privilege escalation)

**Location:** `routes/admin.lk:646-685` (`POST /admin/users/{id}/{action}`),
`:686-706` (`POST /admin/users/new`), `:746-770` (`POST /admin/roles/{id}/{action}`),
`src/rbac.lk:141-152` (`can()`).

**Description.** Any user with `can("users")` can (a) set their own role — or anyone's —
to `admin` (`:654-664`, the only guard is "don't demote the last admin"), (b) reset the
`admin` account's password (`:666-672`, no restriction on target), or (c) create a new
`admin`-role user (`:692-700`). Any user with `can("roles")` can add every permission to
their own role (`:752-757`; `can()` re-reads `roles.perms` from the DB on every request,
so the grant is live immediately). None of these require the current password or
super status. The comment at `:617` ("role 'admin' only — RBAC") does not match the
code, which uses `can("users")`.

**PoC** (editor whose role has `users`):

```
curl -b sess -X POST https://site/admin/users/<my-id>/role -d "_csrf=$T&role=admin"
# session role is read from session::get("role") → re-login, now superuser
curl -b sess -X POST https://site/admin/users/1/password -d "_csrf=$T&password=owned"
```

**Fix.** Treat superuser-affecting operations as super-only:

```look
// role change to/from 'admin', password of an admin-role user, creating an admin
if (($role == "admin" || $cur[0]["role"] == "admin") && !is_super()) { return response::status(403, "Yetkiniz yok."); }
```

and in `/admin/roles/{id}/save` refuse to edit the caller's own role unless `is_super()`
(`session::get("role") == $r[0]["name"]`). Also require the current password for
self-password changes. Document that `users`/`roles` are admin-tier permissions if you
choose to keep the behaviour.

---

### LP-03 · Medium · Stored XSS from a `content` editor to the super admin (Markdown/blocks are escaped, but the `html` block and image/link URLs are not)

**Location:** `src/render.lk:399-402` (`render_blk_html`), `views/themes/default/page.html:9`
(`{!$content}`), `routes/admin.lk:396-402` (`/preview/{id}`), `src/render.lk:95, 106, 184,
203, 207` (`href`/`src` = `html::escape(url)` only).

**Description.** Markdown bodies are safe (`lib/markdown.lk` escapes first, blocks
`javascript:`), but a `blocks` field may contain `{"type":"html","data":{"code":"<script>…"}}`,
which is printed raw for "trusted admin-authored markup". "Admin" here is any account with
`can("content")` (LP-01 shows how coarse that is). Block `button`/`hero`/`slide`/`image` URLs
and the `image`-kind custom field (`page.html:6 <img src="{$f.value}"`) are attribute-escaped
but scheme-unfiltered, so `javascript:` links survive in `<a href>`. Combined with the CSRF
token being in `<meta name="csrf">` and `window.LP_CSRF` on every admin page, a content
editor can plant a script that a super admin executes on `/preview/{id}` or the public page,
then `fetch('/admin/users/new', …)` with the token → full takeover. The CSP
`script-src 'self' 'unsafe-inline'` (`src/security.lk:102`) does not stop inline script.

**PoC.** As editor: edit any page, set the `icerik` blocks textarea to
`[{"type":"html","data":{"code":"<img src=x onerror=\"fetch('/admin/users/new',{method:'POST',headers:{'X-CSRF-Token':document.querySelector('meta[name=csrf]').content},body:new URLSearchParams({username:'evil',password:'evil1234',role:'admin'})})\">"}}]`,
publish; wait for the super admin to open the page or `/preview/<id>`.

**Fix.** Gate the raw block on a dedicated permission and drop it otherwise:

```look
function render_blk_html($d) {
    $code = block_val($d, "code"); if ($code == "") { return ""; }
    if (!$GLOBALS_html_block_allowed) { return "<div class=\"blk-html\">" . html::escape($code) . "</div>"; }
    …
```

Concretely: add `["key" => "html", "label" => "Ham HTML bloğu"]` to `cfg_permissions()`
and refuse to *save* a blocks value containing `"type":"html"` in `validate_post()` unless
`can("html")` (server-side, in `src/types.lk:382` area); keep rendering as is. For URLs add
a scheme allow-list helper (`^(https?:|mailto:|tel:|/)`) used by every `href`/`src` in
`render.lk` and the `image` custom field. Longer term: replace `'unsafe-inline'` with a
per-request nonce (`response::header` + `{$nonce}` in layouts) so planted inline script
is blocked even if it lands in the DOM.

---

### LP-04 · Medium · Reflected XSS in the revision-history page via the `{type}` path segment

**Location:** `routes/admin.lk:342-358`, specifically `:347` and `:354`:

```
347  $type = request::param("type");
354  $btn = "<form method=\"post\" action=\"/admin/type/" . $type . "/rollback/" . $id . "\" …
```

`$type` is never validated (no `load_type`) and is concatenated raw into HTML that the
template prints with `{!$rows}` (`views/admin/admin_history.html:7`). Route params are
URL-decoded (`interpreter.cpp:2039`), so `%22%3E` becomes `">`. A path segment cannot
contain `/`, but `<img src=x onerror=…>` needs none. The page requires a logged-in user
with `can("content")` and an existing content id, so this is a one-click attack against
an editor/admin (link in an e-mail).

**PoC:** `https://site/admin/type/x%22%3E%3Cimg%20src%3Dx%20onerror%3Dalert(document.cookie)%3E/history/1`
(cookie is HttpOnly, but the CSRF meta and any admin action are reachable).
**Needs runtime verification** only for the exact encoding accepted by the router regex.

**Fix.** `$t = load_type($c, $type); if ($t == null) { return 404; }` and use
`html::escape($t["slug"])` in the form action (or better, pass `$revs` as data and let the
template build the form with `{$type}`).

---

### LP-05 · Medium · Public form endpoint accepts unbounded, unauthenticated writes (DoS / disk fill / admin UI pollution)

**Location:** `routes/public.lk:107-137` (`POST /forms/{key}`), core body limit
`http_server.cpp:201-203` (`LOOK_MAX_BODY_SIZE`, default 10 MB).

**Description.** The only guard is the `website` honeypot (`:112-113`). No per-IP rate
limit, no field-length limit, and — for an unknown `{key}` — the legacy branch (`:126-133`)
stores `name/email/message` under **any** `form_key` the client chooses. Each submission may
be up to the 10 MB body cap. One script can fill the SQLite file, and every distinct key
appears as a row in `/admin/forms` ("submission keys with no form definition",
`routes/admin.lk:489-497`). The same lack of throttling applies to `/hesap/kayit`
(member registration) and `/checkout`.

**PoC:**
```
for i in $(seq 1 100000); do curl -s -X POST https://site/forms/zz$i -d "_csrf=$T&message=$(head -c 1000000 /dev/zero | tr '\0' a)"; done
```
(`$T` obtained once from any public page — the token is per-session, and `SameSite=Lax`
does not matter for same-site scripting.)

**Fix.** (1) Only accept the legacy branch for `key == "contact"`; 404 otherwise.
(2) Cap field lengths (`string::len($val) > 4000 → 400`). (3) Add a cache-backed limiter
reusing the login pattern: `form_key($ip)` → `cache::set(key, n+1, 600)`, reject at e.g.
20/10 min. (4) Set `LOOK_MAX_BODY_SIZE=6291456` (5 MB upload + headroom) in
`docker-compose.yml` and `.look.env`.

---

### LP-06 · Medium · Member login and password-reset endpoints have no rate limit (credential stuffing / mail bombing)

**Location:** `extensions/members/members.lk:207-224` (`giris`), `:247-252`
(`sifremi-unuttum`), `:47-64` (`member_reset_request`).

**Description.** The 5/10-min limiter exists only for `/admin/login`
(`routes/admin.lk:22-23`). `/hesap/giris` runs PBKDF2 verify for every attempt with no
throttle (also a CPU amplifier: 100k iterations per guess), and `/hesap/sifremi-unuttum`
sends an e-mail on every request for an existing address (`member_reset_request` cancels
the previous token and mails again). Enumeration is correctly suppressed (same response),
but the recipient can be flooded.

**PoC:** `while :; do curl -s -X POST https://site/hesap/giris -d "_csrf=$T&email=victim@x&password=$(next)"; done`

**Fix.** Reuse `login_key/login_allowed/login_failed` from `src/security.lk` in both
branches (key `"member:" . ip . ":" . email`), and for reset add a per-email cool-down:
`cache::get("reset:" . $email)` → skip send if set, `cache::set(…, 1, 300)` after send.

---

### LP-07 · Medium · Guest-order data disclosed to whoever registers with the same e-mail

**Location:** `extensions/members/members.lk:135-147` (`member_orders`), `:203-206`
(registration), `extensions/commerce/commerce.lk:245-258` (checkout stores the e-mail
unverified).

**Description.** Order history is joined by `orders.email = members.email`; registration
does not verify ownership of the address and checkout does not require login. Anyone can
register `victim@example.com` (if not yet a member) and read that customer's order ids,
totals, statuses and dates at `/hesap/siparisler`.

**PoC:** `POST /hesap/kayit email=victim@example.com&password=…` → `GET /hesap/siparisler`.

**Fix.** Add `member_id INTEGER DEFAULT 0` to `orders` (via `ensure_column` in
`commerce/schema.lk:38-41`), set it at checkout from `member_current()`, and query
`WHERE member_id = ?`. Show e-mail-matched guest orders only after an e-mail verification
step (or not at all).

---

### LP-08 · Medium · Outbound mail is attacker-addressable and attacker-authored (checkout confirmation)

**Location:** `extensions/commerce/commerce.lk:245-248, 270, 275-297`.

**Description.** `POST /checkout` sends `mailer_send($email, …)` to any address supplied in
the form, with `cust_name` (and cart titles) embedded in the body, without rate limiting or
address verification. With `MAIL_PROVIDER` configured this turns the site into an open
notification relay ("Siparişiniz alındı" to arbitrary recipients, body text chosen by the
attacker). `form_notify_mail` is safe (fixed recipient), password reset is covered by LP-06.

**PoC:** add any product to cart, then
`POST /checkout _csrf=$T&email=target@corp.com&cust_name=<spam text>&address=x`.

**Fix.** Validate the address (`member_email_valid`), rate-limit checkout per IP/session,
and only mail the customer copy when the address matches a logged-in member or after an
explicit confirmation link; keep the internal copy to `contact_email` unconditional.

---

### LP-09 · Medium · Docker deployment ships a known admin password and non-Secure cookies by default

**Location:** `docker-compose.yml:22, 27`, `.env.example:3`.

```
22  - LOOK_SESSION_SECURE=0 # plain-HTTP dev; set 1 (or use a TLS proxy) in prod
27  - ADMIN_PASSWORD=${ADMIN_PASSWORD:-lookpress-dev}
```

**Description.** The compose file is the documented production path (`docs/ops-backup.md`
"docker compose dev/prod"). Without an `.env` override the first `admin` user is seeded with
`lookpress-dev` (`setup_v2.lk:237-240`, seeded once and persisted in the volume — changing
the env later does not rotate it) and the session cookie is not `Secure`. Anyone who finds a
LookPress instance can try `admin/lookpress-dev`. This contradicts the "no changeme
backdoor" intent in `app.lk:26-27`.

**Fix.** `- ADMIN_PASSWORD=${ADMIN_PASSWORD:?set ADMIN_PASSWORD in .env}` (compose fails
loudly), drop `LOOK_SESSION_SECURE=0` (let the core default/`LOOK_TRUSTED_PROXY` decide),
and log a warning at boot (`app.lk`) when the seeded admin still verifies against a
well-known value.

---

### LP-10 · Medium · Login rate-limit key can be spoofed or shared, depending on proxy trust (needs runtime verification)

**Location:** `src/security.lk:64-68` (`login_key` uses `request::ip()`), core
`http_main.cpp:178-249` (`is_trusted_proxy`, `resolve_client_ip`), `docs/plesk-deploy.md:56`
(`LOOK_TRUSTED_PROXY=127.0.0.1`).

**Description.** The core is correct: headers are honoured only from a trusted peer, and it
prefers `X-Real-IP`, then the *first* `X-Forwarded-For` entry. Two deployment-dependent
weaknesses:
1. Plesk chain (nginx → Apache → lk-fcgi, trusted 127.0.0.1): if Apache does not forward
   nginx's `X-Real-IP`, the core falls back to the **first** XFF hop, which is
   client-controlled (`X-Forwarded-For: 1.2.3.4, <real>`), letting an attacker rotate keys
   and bypass the 5/10-min limit, or lock a chosen IP out.
2. Docker without `LOOK_TRUSTED_PROXY` (compose default): `request::ip()` is the TCP peer,
   which on Docker Desktop / userland-proxy setups is the same gateway address for every
   client → 5 failed attempts for username `admin` from anyone locks the real admin out for
   10 minutes (`login_key = ip + username`).

**Test:** from outside, `curl -H 'X-Forwarded-For: 9.9.9.9' https://site/admin/login -d …`
six times with a bad password and check whether the seventh from a different XFF value is
still 429; on docker, `docker logs` the peer IP for two different clients.

**Fix.** In LOOK: prefer the *last* untrusted XFF hop (or require `X-Real-IP` when
trusted) — that is a core change; in LookPress, mitigate by (a) keying the limiter on
username alone with a higher ceiling (e.g. 20/10 min) in addition to ip+username, and
(b) documenting `LOOK_TRUSTED_PROXY` for the Docker/reverse-proxy case.

---

### LP-11 · Medium · Backup archives are written world-readable inside the app root by default

**Location:** `scripts/backup.sh:152, 252, 469`; `docs/plesk-deploy.md:47-48` (env file
600) vs. `docs/ops-backup.md:51` (default `<root>/backups/`).

**Description.** `OUT_DIR` defaults to `<root>/backups` (the Plesk docroot), `mkdir -p`
and `tar -czf` run with the caller's umask (typically 022 → `0644` archive, `0755` dir).
The archive contains the full SQLite DB (admin/member PBKDF2 hashes, member e-mails,
orders with addresses/phones, form submissions) and every upload. The front controller
proxies everything to `lk-fcgi` (`ProxyPass /`), so it is not web-served, but any other
system user on the host, FTP sub-accounts, and Plesk File Manager users can read it. The
MySQL/PG credential files are correctly created with `umask 077` (`:290`), so the intent
exists but does not cover the archive.

**Fix.** At the top of `backup.sh` after arg parsing: `umask 077`; create `OUT_DIR` with
`mkdir -p -m 700`; document `--out /var/www/vhosts/<parent>/private/backups` as the
default recommendation (already suggested in ops-backup.md:82).

---

### LP-12 · Low · `/api/{type}` exposes every published module, including `public:false` ones, and full `fields_json`

**Location:** `routes/admin.lk:365-393`.

**Description.** The read API has no auth (by design) but ignores `config.public`
(`render_published`/`render_listing` honour it, `src/render.lk:507, 576`) and
`xp_hidden_types()`. Slider items, internal modules, `seo_*` keys, and product
`varyantlar` (SKU/stock) are all listable at `/api/slider`, `/api/product`. It also allows
`?category=` substring probing inside JSON (`:377`, LIKE on `fields_json`).

**Fix.** After `load_type`: `if (!$t["config"]["public"]) { return 404; }` and strip
`seo_title`/`seo_desc` from `$item`.

---

### LP-13 · Low · `/preview/{id}` is gated by login only, not by permission or type

**Location:** `routes/admin.lk:396-402`.

**Description.** Any authenticated admin-side user (e.g. `orders`-only staff) can read the
current draft of any content row, including `public:false` modules. Body is
`{!$content}` (admin-authored, see LP-03).

**Fix.** `if (!is_admin() || !can("content")) { return 403; }`.

---

### LP-14 · Low · Original upload filename is injected via `innerHTML` in the media picker (admin-to-admin XSS)

**Location:** `views/admin/layout.html:412`
`d.innerHTML='<img src="'+it.url+'" alt=""><span>'+(it.original||it.name)+'</span>';`,
data from `/admin/media/list` (`routes/admin.lk:449`, `original` = `$f["filename"]`
stored at `:426/:469`).

**Description.** The multipart filename is client-controlled (`web_stdlib.cpp` returns
`uf.orig_name` unfiltered). A `media`-permission user uploads a valid PNG named
`<img src=x onerror=alert(1)>.png`; every admin who opens the picker executes it. The
server-side `admin_media.html` prints `{$m.original}` escaped, so only the JS path is
affected.

**Fix.** Build nodes with `textContent` (`var s=document.createElement('span');
s.textContent=it.original||it.name;`) and set `img.src` via property. Optionally sanitise
`original` on insert: `string::regex_replace($f["filename"], "[^A-Za-z0-9._ -]", "_")`.

---

### LP-15 · Low · Admin-authored URLs allow `javascript:` (menus, settings, buttons, slides, image fields)

**Location:** `routes/admin.lk:814-817` (menu URL, only trimmed), `:884-887` (social
links), `src/core.lk:250` (`<a href="…">` escape only), `src/render.lk:106, 184, 207`,
`src/types.lk:303, 307`, `views/themes/default/page.html:6`.

**Description.** `html::escape` prevents attribute break-out but not the `javascript:`
scheme. These are `settings`/`content` tier inputs, so the impact is the same class as
LP-03 (editor → admin/public visitor).

**Fix.** One helper `safe_url($u)` (allow `^(https?://|mailto:|tel:|/|#)`, else `""`)
applied in the three write paths (`/admin/menu`, `/admin/settings` social keys, block
data on save) — cheaper than filtering on every render.

---

### LP-16 · Low · Login CSRF and logout via GET

**Location:** `src/security.lk:48` (`/admin/login` exempt), `routes/admin.lk:44`
(`GET /admin/logout` destroys the session), `members.lk:154-157` (`GET /hesap/cikis`).

**Description.** A cross-site form can log a victim into an attacker-controlled admin
account (login CSRF; later actions by the victim land in the attacker's account/audit
trail, e.g. notes signed with the attacker's `uname`), and an `<img src=/admin/logout>`
logs the victim out. `SameSite=Lax` blocks the POST case from a third-party site in modern
browsers but not top-level GET navigations.

**Fix.** Make logout a CSRF-protected POST; for login, issue a pre-login CSRF token
(the session already exists — `csrf_token()` can be rendered in `login.html` and
`csrf_required` can include `/admin/login`).

---

### LP-17 · Low · Username-enumeration timing on admin login

**Location:** `routes/admin.lk:27-29`.

**Description.** `auth::verify` (100k PBKDF2 rounds) runs only when the username exists;
a non-existent user returns tens of milliseconds faster. Rate limiting narrows but does not
remove the oracle (5 probes per ip+username, unlimited usernames).

**Fix.** When `count($rows) == 0`, call `auth::verify($p, <constant dummy hash>)` before
falling through.

---

### LP-18 · Low · `Content-Disposition` filename built from an unvalidated path segment

**Location:** `routes/admin.lk:551-554` (`$fname = $key … filename="<key>-gonderimler.csv"`),
key = `request::param("key")` (decoded, LP-04).

**Description.** CR/LF is stripped by the core, but `"` and `;` are not; a submission key
created through LP-05 (`/forms/a%22%3Bx`) yields a malformed header on export. No
exploitation beyond a broken download / header-parser confusion was identified.

**Fix.** `$fname = string::regex_replace($key, "[^A-Za-z0-9_-]", "_")` (and reject such
keys on the public POST, LP-05).

---

### LP-19 · Low · Deployment doc passes `ADMIN_PASSWORD` on the command line; reset links logged in dev

**Location:** `docs/plesk-deploy.md:78-80` (`DB_DSN=... ADMIN_PASSWORD=... /opt/look/lk
setup_v2.lk` → visible in `ps`/shell history), `members.lk:58-60` (`log::warn(… reset link
…)` with the token when the mailer is off).

**Fix.** Doc: `sudo -u "$U" bash -c "cd '$D' && set -a && . ./.look.env && set +a &&
/opt/look/lk setup_v2.lk"`. Code: log only `member #id` and the token *prefix* unless
`LOOK_DEBUG_MAIL=1`.

---

### LP-20 · Low · Cart prices are snapshotted at add-time and not re-validated at checkout

**Location:** `commerce.lk:177` (`"price" => $price` stored in the session cart), `:249-258`
(checkout totals from the cart, not from `product_published_rows`).

**Description.** The price is server-derived (not client-supplied), so this is not a tamper
bug, but a user who adds an item before a price increase or before a product is unpublished
checks out at the stale price / for an unavailable product. Stock *is* re-checked (`:238-244`).

**Fix.** In `/checkout`, re-read each line's price via `product_published_rows` +
`variant_find` and reject the order if the row is gone.

---

### LP-21 · Info · CSP relies on `'unsafe-inline'`

**Location:** `src/security.lk:98-104`.

The admin layout, the slider block (`src/render.lk:276`) and commerce repeater
(`commerce.lk:647`) all use inline `<script>`, so `'unsafe-inline'` is currently required.
It removes CSP's value against LP-03/LP-04/LP-14. Acceptable as a stop-gap; the nonce
approach in LP-03 is the way out. `frame-ancestors 'self'` + `X-Frame-Options` and
`object-src 'none'` are good.

### LP-22 · Info · CSRF coverage — verified complete

All 33 POST routes were matched against `csrf_required()` (`src/security.lk:47-56`):
`/admin/*` (32 incl. extensions; `/admin/login` intentionally exempt, see LP-16),
`/forms/{key}`, `/cart/coupon|add|remove|update`, `/checkout`, `/hesap/{action}`.
`/admin/media/upload` is covered (fetch sends `_csrf` in FormData and `X-CSRF-Token`,
`layout.html:425-427`). No GET mutates persistent state except the logout routes (LP-16);
`before_route(activate_scheduled)` is internal. Comparison at `:40` is `==` (not
constant-time); the token is 256-bit random and per-session, so this is not practically
exploitable — a `crypto::hash_equals`-style helper would be cleaner. **Needs runtime
verification:** whether the router matches paths case-insensitively or with duplicate
slashes (`/Admin/settings`, `//admin/settings`) — if it does, `starts_with($path, "/admin/")`
would miss them; test with `curl -X POST https://site//admin/settings -b sess` and expect
either 404 or 403.

### LP-23 · Info · HSTS gate trusts `X-Forwarded-Proto` at the app level

`src/security.lk:88-93` accepts any `X-Forwarded-Proto: https`. The core's own
`resolve_is_https` (`http_main.cpp:252-260`) is proxy-trusted, so cookie `Secure` is not
affected; a forged header only adds an HSTS header to a plain-HTTP response, which browsers
ignore. Harmless; could reuse `request::is_https()` if the core exposes it.

### LP-24 · Info · Error pages do not leak

Uncaught exceptions produce a bare `500 Internal Server Error` with the message going to
the log only (`http_main.cpp:1302-1308, 1406-1412`). `response::status(404, body)` ignores
the body in the core (`web_stdlib.cpp:447-450`), so the many `response::status(404, "…")`
calls in `routes/admin.lk` return empty bodies — cosmetic, already noted in `cms-spec.md`.

### LP-25 · Info · Type/field definitions from the `types` permission reach HTML unescaped

`src/types.lk:252-333` prints `$name` (regex-validated `^[a-z][a-z0-9_]*$` on create,
`routes/admin.lk:141`) raw, but `$target` (relation `to`, `:328`), `$f["min"]/["max"]`
(escaped) and choice values (escaped) are free-form; `$target` is not escaped. Only a
`types`-permission user can set it, and the consumer is a `content` user. Escape it
anyway (`html::escape($target)`).

### LP-26 · Info · Regex / ReDoS review — none found

All validation patterns (`src/types.lk:362-367`, `routes/admin.lk:130-141, 507, 738`,
`members.lk:106`, `routes/public.lk:23`) are linear (single character classes, no nested
quantifiers). `lib/markdown.lk` uses `[^*]+`, `[^\]]+`, `(.+?)` — linear. Search
(`routes/public.lk:38-52`) is `LIKE` with `LIMIT 50` and no `ESCAPE`, so `%`/`_` are
wildcards — a cost, not a vulnerability. Block nesting is capped at depth 3
(`src/render.lk:289`), category recursion at 64 (`commerce.lk:596, 614`).

---

## Prioritised fix list

1. **LP-01** — pin every `/admin/type/{type}/…` lookup and `save_content` `UPDATE` to
   `type`; make the content gate type-aware (`products` for `product`). Small diff, closes
   cross-type delete/corruption and the nav-only permission split.
2. **LP-02** — super-only guard on role→`admin`, admin password reset, admin creation,
   and self-role edits.
3. **LP-04** — `load_type` + escape in the history route (one-line reflected XSS).
4. **LP-03 / LP-15** — server-side permission for the `html` block; `safe_url()` on save.
5. **LP-05 / LP-06 / LP-08** — reuse the existing cache limiter for `/forms/*`,
   `/hesap/giris`, `/hesap/sifremi-unuttum`, `/checkout`; 404 unknown form keys; cap
   field sizes; set `LOOK_MAX_BODY_SIZE`.
6. **LP-09** — compose fails without `ADMIN_PASSWORD`; drop `LOOK_SESSION_SECURE=0`.
7. **LP-11** — `umask 077` + `mkdir -m 700` in `backup.sh`; default `--out` outside the
   docroot.
8. **LP-07** — `orders.member_id`; stop joining by e-mail.
9. **LP-10** — verify the proxy chain on test.codlook.com; add a username-only ceiling.
10. **LP-14, LP-16, LP-17, LP-18, LP-19, LP-20, LP-12, LP-13** — small hygiene fixes,
    can ship together.
11. Follow-up: CSP nonce (LP-21) once inline scripts are moved to `nonce`-tagged blocks.

---

## External review, 2026-09-29: status

A second, independent review was checked claim by claim against the code and, where
it mattered, measured on a running instance.

| # | Claim | Verdict | Status |
|---|---|---|---|
| 1 | `/api/{type}` serves `public:false` modules | Correct (LP-12) | Fixed: the API honours `config.public` |
| 2 | Checkout stock check/decrement race | Correct | Fixed: check + order + decrement in one transaction (`BEGIN IMMEDIATE`) |
| 3 | Role read from the session, so demotion/deletion did not affect live sessions | Correct, and wider than reported (`can()` too) | Fixed: role read from the database per request |
| 4 | Compose ships a default admin password | Correct (LP-09) | Fixed: compose refuses to start without `ADMIN_PASSWORD` |
| 5 | Login throttle bypass through username variations | Incorrect: the key is lower-cased and trimmed | The per-process counter part was correct; counters are now database-backed, plus a per-IP ceiling |
| 6 | Markdown scheme filter bypass with whitespace | Correct, and worse: mixed case (`JaVaScRiPt:`) passed too | Fixed: allow-list instead of deny-list |
| 7 | Menu and social URLs not scheme-filtered | Correct (LP-15) | Fixed: filtered on save and on render |
| 8 | `activate_scheduled` writes on every request | Correct (performance) | Fixed: reads first, writes only when something is due |
| 9 | `analytics_head` is raw HTML behind `settings` | Correct, by design | Changed: also requires the `html` permission |
| 10 | No stock decrement for products without variants | Such products had no stock field at all | Added: optional `stok` field, enforced in cart and checkout |
| low | Logout via GET | Correct (LP-16) | Fixed: POST with CSRF, admin and members |
| low | CSRF token compared with `==` | Correct | Fixed: `crypto::constant_compare` |

Not changed: a password change does not end the account's other sessions; the login
form itself carries no CSRF token (login CSRF, LP-16); LP-10, LP-17, LP-18 and LP-21.

Known trade-off of the per-IP login ceiling: 20 failures from one address lock every
login from that address for 10 minutes, including a correct one. Behind a proxy that
is not declared in `LOOK_TRUSTED_PROXY` all clients share one address.

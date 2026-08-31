# Phase 1 friction log — versioned core + type engine

Building the platform's content subsystem on LOOK. Severity: 🟢 minor · 🟡 real · 🔴 blocker.

| # | Where | What happened | Sev | Fix / note |
|---|-------|---------------|-----|------------|
| 1 | migrate | `UNIQUE(lang, slug)` (from the design) was too narrow — a page and a post may share a slug (different URL namespaces). | 🟡 | Design-first surfaced it before code: use **`UNIQUE(lang, type, slug)`** + a per-type `url_pattern`. Recorded; URL-uniqueness moves to build time (PROJECT.md ③, output-path-collision aborts loudly). |
| 2 | arrays | `$arr[] = x` (append) and `$assoc[$k] = v` (write) are **not** LOOK syntax — the parser rejects `[]`. | 🟢 | Use `array::push($arr, x)` (returns a new array) and `array::set($assoc, $k, v)`. Assoc **read** by key (`$a[$k]`) works; only writes need `array::set`. |
| 3 | routing | **`route()` inside a loop (`foreach` + a closure capturing the type) did not register/serve** — every dynamic per-type public route 404'd; the same routes as **direct top-level `route()` statements** work. | 🟡 | Root cause **not isolated** (setup-pass loop-collection vs closure capture) — a focused check is owed when per-type dynamic routing is built. For now, built-in type URL patterns are registered directly. **Core candidate.** |
| 4 | test env | `cp backup.db test.db` over a Windows bind mount left a stale `test.db-wal` → "database disk image is malformed". | 🟢 | Put the working DB on a container-local path (`/tmp`), not the bind mount. (Same bind-mount confound class as the earlier per-request stat finding.) |

## What worked (the type engine, proven end-to-end on migrated live data)

Defining a third type (`product`: title, body, price:decimal, sku, featured:bool, category:relation)
in `content_types` gave it, with **no type-specific code**: a generated admin form (number/checkbox/
select inputs from the field defs), **server-side validation** (required, decimal, select-choice,
relation-target), a generic CRUD, an auto `GET /api/product` (published only), and public rendering.
The **read-surface invariant** held (a draft product appears in neither `/api` nor the public URL;
`/preview/{id}` is admin-gated), and the migrated `page`/`post` content still serves. 0 VM fallback.
This is the platform's first working promise — *define a type, the system generates the rest* — and
the dress rehearsal for the Phase-6 commerce catalog.

# Phase 1 friction log — versioned core + type engine

Building the platform's content subsystem on LOOK. Severity: 🟢 minor · 🟡 real · 🔴 blocker.

| # | Where | What happened | Sev | Fix / note |
|---|-------|---------------|-----|------------|
| 1 | migrate | `UNIQUE(lang, slug)` (from the design) was too narrow — a page and a post may share a slug (different URL namespaces). | 🟡 | Design-first surfaced it before code: use **`UNIQUE(lang, type, slug)`** + a per-type `url_pattern`. Recorded; URL-uniqueness moves to build time (PROJECT.md ③, output-path-collision aborts loudly). |
| 2 | arrays | `$arr[] = x` (append) and `$assoc[$k] = v` (write) are **not** LOOK syntax — the parser rejects `[]`. | 🟢 | Use `array::push($arr, x)` (returns a new array) and `array::set($assoc, $k, v)`. Assoc **read** by key (`$a[$k]`) works; only writes need `array::set`. |
| 3 | web closure capture | Dynamic per-type routing (a `foreach` over `content_types` registering each `url_pattern`) 404'd. First blamed on "`route()` in a loop" — **that was a phantom** (a minimal test proved `route()` in a loop, with a variable pattern and a per-iteration closure capture, all register and match correctly). **Isolated properly (the lesson: two variables — a malformed DB *and* the registration form — changed in one turn; the blame went to the wrong one):** in **lk-fcgi (web)**, a closure that captures an **assoc-indexed loop value** (`$t = $pt["slug"]; use($t)`) receives it **array-wrapped** — `json::encode` of the captured value is `["product"]`, not `"product"` — at request time, so the type lookup fails. A literal-string capture is unaffected (`"product"`). | 🟡 | **Real core candidate** (web closure-capture / dispatch-copy mangles an assoc-indexed captured value; likely a tree-walk↔VM-in-web divergence — the CLI reads the same access correctly). Minimal repro: `debug/min_route3.lk`. Workaround: register built-in URL patterns directly (no loop capture). Dynamic per-type routing is deferred behind a core fix. |
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

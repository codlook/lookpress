# LookPress theme components — the contract

Pages are composed from **blocks**. A `blocks` field stores an ordered JSON list
`[{"type": "<type>", "data": {…}}, …]`; `render_blocks()` in `src/render.lk` turns it
into HTML. Every block emits one root element with the class **`blk-<type>`** (the
gallery/image/list/button/divider blocks predate this rule and keep their historic
classes, listed below). All text is `html::escape`d and all URLs are escaped in
attributes; a missing key reads as `""`; a block with missing/invalid data renders
`""` (never throws). Unknown types render `""`.

## Block types

| type | data keys | root class / markup |
|---|---|---|
| `heading` | `level` ("2"\|"3"), `text` | `<h2>` / `<h3>` (no class) |
| `paragraph` | `text` (newlines → `<br>`) | `<p>` |
| `image` | `url`, `alt`, `caption` | `figure.blk-img` |
| `gallery` | `images` (list of URLs) | `div.blk-gallery` |
| `button` | `label`, `url` | `p.blk-btn-wrap > a.btn` |
| `quote` | `text`, `cite` | `<blockquote>` |
| `list` | `items` (list of strings) | `ul.blk-list` |
| `divider` | — | `hr.blk-hr` |
| `hero` | `title`, `subtitle`, `image` (background URL), `button_label`, `button_url`, `align` ("left"\|"center") | `section.blk-hero.align-<align>` › `.hero-inner` › `h2`, `p`, `a.btn` |
| `slider` | `source` ("module"\|"manual"), `module` (slug, default `slider`), `limit` (default 5, max 50), `slides` (manual: `[{image,title,subtitle,link}]`) | `div.blk-slider` › `.slides` › `.slide[.is-active]` (› `a.slide-link`, `img`, `.slide-cap` › `h3`,`p`); `button.sl-prev`, `button.sl-next`, `.sl-dots` › `button.sl-dot`; plus one inline `<script>` (prev/next, dots, arrow keys, 5 s auto-advance, paused on hover, off under `prefers-reduced-motion`) |
| `columns` | `count` ("2"\|"3"), `cols` (`[{"blocks": [ …nested blocks… ]}]`; `blocks` may also be a JSON string) | `div.blk-columns.cols-<count>` › `div.col` × count |
| `listing` | `module` (slug), `limit` (default 6, max 50), `layout` ("cards"\|"list"), `show_image` ("1"\|"0"), `show_excerpt` ("1"\|"0") | `div.blk-listing.layout-<layout>` › `.cards` › `a.card` (reuses the catalog card look: `.card-img`, `.card-body`, `.card-title`, `.card-excerpt`) or `ul.listing-list` › `li > a` |
| `form` | `form` (form key), `title` (empty = the form's own title) | `div.blk-form` › `h2`, `form.contact-form` (same markup as `form.html`, CSRF field + honeypot, POST `/forms/<key>`) |
| `map` | `embed_url` | `div.blk-map` › `iframe` — only `https://www.google.com/maps/embed…` or `https://maps.google.com/…`; any other URL renders `""` |
| `video` | `url` | `div.blk-video` › `iframe` for YouTube (`watch?v=`, `youtu.be/`, served from `youtube-nocookie.com`) and Vimeo (`player.vimeo.com`, `dnt=1`); ids are limited to `[A-Za-z0-9_-]`; any other URL → `p.blk-video.blk-video-link > a` |
| `html` | `code` | `<!-- blk-html … --><div class="blk-html">` raw `</div>` — **trusted, admin-only**: the code is printed unescaped. Blocks are only ever authored in the admin, so this block is exactly as trusted as the admin account itself. Never feed it user-submitted content. |

### Data sources

- **`slider` with `source: "module"`** reads the module's published items
  (`content` JOIN `revisions ON revisions.id = content.published_rev`,
  `published_rev > 0`, all languages), decodes each item's `fields_json` and
  orders by its `order` field (int, missing = 0) then `id`, then applies `limit`.
  The seeded `slider` module (fields `image/title/subtitle/link/order`) is the
  default; any module with those field names works. `title` falls back to the
  revision title.
- **`listing`** only renders modules whose `config.public` is true. Items are the
  module's published items in the current request language (`/en…` → `en`, else
  `tr`), newest first (`updated_at DESC, id DESC`). Each item links to
  `lang_prefix + url_pattern without "/{slug}" + "/" + slug` — the same rule the
  catalog listing uses. The excerpt is `body_html` stripped of tags, cut at 140
  characters.
- **`columns`** recurse through the same renderer. Nesting depth is bounded to 3:
  a `columns` block at depth 3 (columns inside columns inside columns) renders
  `""`. Only the first `count` columns are rendered.

## Overriding a component from a theme

Today a theme overrides the **look** of a component with CSS: target the root
class (`.blk-hero`, `.blk-slider`, `.blk-columns.cols-3`, `.blk-listing .card`,
`.blk-form`, `.blk-map`, `.blk-video`, `.blk-html`) in the theme's `layout.html`
`<style>`. The default theme's styles are mobile-first, use the theme's custom
properties (`--accent`, `--surface`, `--line`, `--radius`, `--gutter`, …), and honour
`prefers-reduced-motion`. Skins (`data-theme`) apply automatically because the
components only use those tokens.

The markup is the contract: class names and element order above are stable.
Replacing a component's **renderer** per theme (a theme-provided
`render_blk_<type>`) is a later slice; until then, do not depend on it.

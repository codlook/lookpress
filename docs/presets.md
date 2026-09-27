# LookPress demo presets

A preset is a one-shot demo seed for a vertical. It is plain content in the
existing modules — no preset adds a route, a table or a code path.

## Environment

| variable | values | meaning |
|---|---|---|
| `LOOKPRESS_SEED` | `1` / `0` | the gate; nothing is seeded unless it is `1` |
| `LOOKPRESS_PRESET` | `kurumsal` (default) \| `haber` \| `eticaret` | which demo site to seed |

| combination | result |
|---|---|
| `LOOKPRESS_SEED=0` (any preset) | no demo content |
| `LOOKPRESS_SEED=1` | corporate site (same as before presets existed) |
| `LOOKPRESS_SEED=1` `LOOKPRESS_PRESET=haber` | news site |
| `LOOKPRESS_SEED=1` `LOOKPRESS_PRESET=eticaret` | shop |
| `LOOKPRESS_SEED=1` + unknown preset | warning line, falls back to `kurumsal` |

`setup_v2.lk` prints one line per seeded preset (`=== seeded preset haber (…) ===`).

Seeded for **every** preset (shared base): the `en` page `about`, the forms
`basvuru` / `iletisim` / `is-basvuru`, the `ekip` type, and the commerce
extension's own fixtures (products `kirmizi-tisort` tr+en, `mavi-kot`, brand
`lookwear`, categories `giyim` / `aksesuar` / `tisort`, coupon `WELCOME10`).

## Switching presets = fresh database

Seeds are idempotent by slug and never overwrite: content accumulates, and the
menu, settings and the `anasayfa` page keep whatever was written first. Changing
`LOOKPRESS_PRESET` on an existing database therefore gives a mix, not a switch.
Start from an empty database:

```bash
docker compose down -v
LOOKPRESS_PRESET=haber docker compose up --build
```

(or uncomment the `LOOKPRESS_PRESET` line in `docker-compose.yml`).

## `kurumsal` — corporate site (default)

Function: `seed_preset_kurumsal`.

| module | items |
|---|---|
| `page` | `anasayfa`, `hakkimizda` (block-composed) |
| `slider` | `slayt-1`, `slayt-2`, `slayt-3` |
| `haber` | 4 |
| `duyuru` | 3 |
| `proje` | 3 |
| `etkinlik` | 3 |
| `galeri` | 2 |
| `video` | 2 |
| `ekip` | 2 |

Menu: Anasayfa, Haberler, Projeler, Etkinlikler, Hakkımızda, İletişim.

## `haber` — news site

Function: `seed_preset_haber`.

The `haber` module gets a `category` select field (added only if absent) with
the choices `gundem`, `ekonomi`, `spor`, `kultur`, `teknoloji`. The values are
ASCII on purpose: they travel in URLs. The public listing filter is the generic
one — `/haber?category=gundem`.

| module | slugs |
|---|---|
| `page` | `anasayfa` |
| `haber` (gundem) | `kis-saati-tartismasi-yeniden-gundemde`, `buyuksehirde-yeni-metro-hatti-hizmete-girdi`, `okullarda-yeni-donem-hazirliklari-tamamlandi` |
| `haber` (ekonomi) | `merkez-bankasi-faiz-kararini-acikladi`, `ihracat-eylulde-rekor-kirdi`, `kobilere-yeni-destek-paketi` |
| `haber` (spor) | `derbide-gol-yagmuru`, `milli-voleybolcular-finalde` |
| `haber` (kultur) | `film-festivali-basliyor`, `antik-kentte-yeni-mozaik-bulundu` |
| `haber` (teknoloji) | `yerli-uydu-yorungeye-yerlesti`, `yapay-zeka-yasa-tasarisi-mecliste` |
| `video` | `haftanin-ozeti`, `ekonomi-masasi`, `spor-studyosu` |
| `galeri` | `gunun-kareleri`, `derbiden-kareler` |
| `duyuru` | `mobil-uygulamamiz-yayinda`, `e-bulten-aboneligi`, `okur-temsilcisi-basvurulari` |

Homepage blocks: hero (headline) → listing `haber` (6, cards) → columns (3) →
listing `video` (3) → form `iletisim`.

Menu: Anasayfa `/`, Gündem `/haber?category=gundem`, Ekonomi
`/haber?category=ekonomi`, Videolar `/video`, Galeri `/galeri`, İletişim
`/contact`. Settings defaults: `site_title` "Günlük Haber", `seo_description`,
`contact_email`, `sabit_footer_text`.

## `eticaret` — shop

Functions: `seed_preset_eticaret` (page, slider, campaigns, menu, settings) and
`seed_preset_eticaret_products` (categories, brands, products). The second one
runs after the commerce extension's own seed, so the commerce fixtures are kept.
It needs the commerce extension; without the `product` module it prints a
"products skipped" line.

| module | slugs |
|---|---|
| `page` | `anasayfa` |
| `slider` | `kampanya-sezon`, `kampanya-kargo`, `kampanya-kupon` |
| `duyuru` | `sonbahar-indirimi`, `hos-geldin-kuponu`, `ucretsiz-kargo` |
| `marka` | `anadolu-tekstil`, `adim-ayakkabi` |
| `product` (giyim) | `beyaz-gomlek`, `yun-kazak`, `kapusonlu-mont` |
| `product` (ayakkabi) | `deri-sneaker`, `suet-bot`, `kosu-ayakkabisi` |
| `product` (aksesuar) | `deri-kemer`, `sirt-cantasi` |

Categories `giyim`, `aksesuar`, `ayakkabi` are inserted only if the slug is
absent. Every product has `image`, `price`, `sku`, `category`, `marka` (the
brand's content id) and `ozellikler`; five of them have `varyantlar`. Both are
stored as JSON strings in the shapes commerce reads:

```json
[{"k": "Kumaş", "v": "%100 pamuk"}]
[{"ad": "S", "sku": "GM-WHT-010-S", "fiyat": "", "stok": "10"}]
```

Homepage blocks: hero → slider (module, 3) → listing `product` (8, cards) →
columns (3 selling points) → listing `marka`.

Menu: Anasayfa `/`, Ürünler `/product`, Markalar `/marka`, Kampanyalar
`/duyuru`, İletişim `/contact`. Settings defaults: `site_title` "LookShop",
`seo_description`, `contact_email`, `sabit_footer_text`.

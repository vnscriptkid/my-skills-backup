---
name: seed-listings-for-seller
description: "Create N listings for an EXISTING seller (by user ID) directly via listing-svc's internal gRPC API, no auth token or DB access needed. Use instead of bifrost-test-data-seeding when the seller already exists. Usage: /seed-listings-for-seller"
argument-hint: "[seller_user_id] [marketplace: SG|ID|MY|PH|HK|TW] [cc_id] [count]"
allowed-tools: Bash(grpcurl *), Bash(kubectl *), Read
---

# seed-listings-for-seller

Create test listings for a seller who **already has an account**, with no auth
token and no database access. `bifrost-test-data-seeding` (bulkdata-svc) only
creates listings bundled with a brand-new auto-generated seller — it cannot
target an existing user. This skill uses listing-svc's internal gRPC API
directly instead.

## Prerequisites

- The seller's **numeric user ID**, not username. If you only have a
  username/password, resolve it once:
  ```bash
  curl -X POST https://bifrost.staging.carousell.com/api/auth/login \
    -H "Content-Type: application/json" \
    -d '{"username":"<username>","password":"<password>"}' | jq '.user_id'
  ```
- kubectl context for staging: `gke_carousell-staging_asia-east1-c_staging-main-k127`
- `grpcurl` CLI
- `cs-proto` checked out locally (listing-svc has gRPC reflection disabled,
  so grpcurl needs explicit `.proto` files)

## Step 1 — Resolve `marketplace_id`

`marketplace_id` on the listing table is a **city ID**, not the category's
`country_id` — these are easy to confuse and look superficially similar
(e.g. SG city ID `1880252` vs SG country ID `1880251` from categoryclient).
Known values:

| Market | `marketplace_id` (city ID) |
|--------|---------------------------|
| SG     | `1880252`                 |
| HK     | `1819729`                 |

For others, grep test fixtures:
```bash
grep -rho 'country\.[A-Z_]*_[0-9]\+' <monorepo>/listing/listing/integrationtests/ | sort -u
```

The category itself needs no lookup or conversion — pass the plain cc_id
(e.g. `1233`) as `country_collection_id` in Step 3. Do **not** use the
`collection_id` field (see Gotchas — it's silently ignored by this RPC).

## Step 2 — Port-forward to listing-svc

The `listing` namespace has no active pods — find a namespace with a running
`listing-svc` pod first:
```bash
kubectl get pods -A --no-headers | grep listing-svc | grep Running | head -5
```
Common working namespaces: `ce-onboarding`, `fe-listing-*`. The CIP service
name is `listing-svc-cip` (not `listing-svc`):
```bash
kubectl config use-context gke_carousell-staging_asia-east1-c_staging-main-k127
kubectl port-forward -n <namespace> svc/listing-svc-cip 9281:9281 &
```

## Step 3 — Create listings via `InternalDjCreateListing`

Do **not** use the public `ListingService/CreateListing` RPC for this — it
requires a fully-profiled `request_user` and fails in a loop of mutually
exclusive errors for most staging accounts:
- `cannot get city ID to use as fallback default location` (no city_id given)
- `cannot fetch marketplace info for given fallback city ID` (city_id given but not a real marketplace ID)
- `category is not matched to listing's country` (marketplace_id's country ≠ category's country)

`InternalDjCreateListing` is the internal/migration RPC. It skips the whole
request_user/location-resolution chain — you supply `marketplace_id` and
`country_collection_id` directly:

```bash
PROTO=<monorepo>/cs-proto/proto
grpcurl -plaintext \
  -proto "$PROTO/listing/public/listing.proto" -import-path "$PROTO" \
  -d '{
    "listings": [{
      "seller_id": "<SELLER_USER_ID>",
      "title": "<title>",
      "price": <price>,
      "country_collection_id": "<cc_id>",
      "description": "<description>",
      "marketplace_id": "<marketplace_id>",
      "status": "L",
      "primary_photo_thumbnail": "<image_url>",
      "default_location": {
        "name": "Singapore", "address": "Singapore",
        "latitude": 1.3521, "longitude": 103.8198,
        "location_type": "default"
      }
    }]
  }' \
  localhost:9281 listing_proto.ListingService/InternalDjCreateListing
```

Verify the response: `categoryId` in the returned listing should equal the
`cc_id` you passed. If it doesn't, see the `collection_id` gotcha below.

Returns the created `listing.id` (UUID) + `legacyId`. Loop with varied
title/price/description for N listings — see `README.md` for a full script.

## Step 4 — Attach an image

`primary_photo_thumbnail` set above only covers listing-card thumbnails. For
the photo to also show in the media gallery / detail page (and in
`GetListings` with `include_media: true`), create a matching `Media` row via
`InternalDjCreateMedia`. Use an image already hosted on Carousell's own CDN
rather than an external placeholder service (avoids any egress/CSP surprises
in staging). A known-good test image:
```
https://media.karousell.com/media/photos/products/2026/10/14/test_used_car_qnust_uae_sid_1791939181_10d7cd30_thumbnail.jpg
```
Reuse this same URL for every seeded listing's `image`, `thumbnail`, and
`primary_photo_thumbnail` — it's a shared test fixture, not something that
needs to be unique per listing (only `legacy_id` on the media row does):

```bash
grpcurl -plaintext \
  -proto "$PROTO/listing/public/listing.proto" -import-path "$PROTO" \
  -d '{
    "listings": [{
      "id": "<listing_uuid_from_step_3>",
      "media": [{
        "legacy_id": <UNIQUE_INT64>,
        "is_primary": true,
        "image": "<image_url>",
        "thumbnail": "<thumbnail_url>"
      }]
    }]
  }' \
  localhost:9281 listing_proto.ListingService/InternalDjCreateMedia
```

`legacy_id` **must be unique per image across the whole table** — see
Gotchas, it silently overwrites another listing's photo otherwise.

## Step 5 — Bump listings (through bump-svc)

Don't fake a bump by poking `indexed_at` or writing an `is_bumped` attribute
directly on listing-svc — drive the real flow through `bump-svc` instead.
`bump-svc` has running pods in staging (`bump` namespace: `bump` +
`bump-worker` deployments), so there's no need for a workaround.

```bash
kubectl port-forward -n bump svc/bump-cip 9282:9281 &

PROTO=<monorepo>/cs-proto/proto
grpcurl -plaintext \
  -proto "$PROTO/bump-svc/public/bump.proto" -import-path "$PROTO" \
  -d '{
    "checkout_id": "<unique per listing, e.g. seed-bump-<legacy_id>>",
    "user_id": "<seller_user_id>",
    "marketplace": "HK",
    "product_type": "V2_1_DAY_BUMP",
    "listing_id": "<legacy_id>",
    "listing_cc_id": "<cc_id>"
  }' \
  localhost:9282 bump_proto.BumpService/FulfillBump
```

`{}` means success. `FulfillBump` is the same RPC bump-svc's post-checkout
fulfilment path calls — no `bump_schedule_config` needed for ad-hoc seeding;
leaving it unset defaults the schedule to "start now", so the bump executes
**synchronously inside this call** (`addBump` → `scheduleBump` →
`makeBumpsRunning` → `performBumpAndUpdateStatus`) — no need to wait on
`bump-worker` for a one-off seed.

Two field gotchas specific to this RPC (see Gotchas below for the full list):
- `marketplace` takes the 2-letter code (`HK`, `SG`, `MY`, ...) — a
  *different* enum than listing-svc's `MARKET_PLACE_*` values.
- `listing_id` is the listing's **legacy_id** (numeric, as a string) — not
  the UUID `InternalDjCreateListing` returned in Step 3.

This calls the real write path (`bumpHelper.BumpListings` →
`listingSvcClient.UpdateListingDetailsLastIndexed` → listing-svc's
`InternalUpdateListing`), which sets the attributes search/ranking actually
read — `last_bumped_at`, `last_liked`, `bump_campaign_started_at` — plus a
fresh `indexed_at`, tagged with `context: BUMP`. It also creates a real
`bump_listing_details` row in bump-svc's own DB, so bump analytics/purchase
history stay consistent.

Verify with listing-svc's `GetListings` (`include_attributes: true`) —
`last_bumped_at` should match the time you called `FulfillBump`.

## Gotchas

- **Use `country_collection_id`, not `collection_id`, for the category.**
  `transformInternalDjCreateListingRequestListingToModel`
  ([listing/service/internal.go:1436](https://github.com/carousell/listing/blob/master/listing/service/internal.go))
  resolves `category_id` from `country_collection_id` only — `collection_id`
  (the legacy/per-marketplace field) is read nowhere in this RPC path. Set
  only `collection_id` and the request still **succeeds**, silently falling
  back to each country's generic "Everything Else - Others" category via
  `SetFallbackCategory`. No error, no warning — always check `categoryId` in
  the response matches what you asked for.
- **`InternalDjCreateMedia` upserts by `legacy_id` alone** — it looks up
  `WHERE legacy_id = <media.legacy_id>` and updates whatever row it finds, or
  inserts if none. Reuse a `legacy_id` (including the zero-value default)
  across two images and the second call **silently reassigns the first
  photo's row to the new listing**, no error. Always generate a fresh,
  genuinely unique `legacy_id` per image (e.g. `$(date +%s%N)` + a counter).
- `InternalDjCreateMedia` does **not** sync `primary_photo_thumbnail` on the
  listing row — that denormalized field is only updated by the public
  update-media flow / messaging consumer (`SetListingThumbnailByMedia`). Set
  `primary_photo_thumbnail` explicitly in Step 3 if list-view thumbnails need
  to work; don't rely on the media row alone.
- grpcurl reflection is disabled on listing-svc — always pass `-proto` and `-import-path`.
- Run the loop script with `bash script.sh`, not by pasting into an interactive
  zsh shell — the `[ ... ]` comparisons in the README script are bash-correct
  but can throw spurious `= not found` errors under zsh depending on how it's
  invoked.
- `price` is a number in this RPC, unlike the public API's string `attributes` map.
- **The public `CreateListing` RPC does work** if you supply a real
  `request_user` (with matching `country_id`/`city_id`) and binary photo bytes
  in `request_files` — it also auto-runs smart-field detection and sets WTB
  flags automatically. But `InternalDjCreateListing` is simpler for seeding.
  If you use `CreateListing`, note that `detectDuplicateListing` fires on
  same-user + same-photo + same-title: vary the title or use a fresh photo per
  listing to avoid dedup collisions.
- Bypasses quota, smart-field validation, and seller-eligibility checks —
  **staging/test only, never point this at prod.**
- No cleanup RPC verified yet; track returned listing IDs if you need to
  tear them down later.
- **`is_bumped` is not a real listing-svc attribute the bump flow sets.**
  Only `last_bumped_at` (plus `last_liked`/`bump_campaign_started_at`) gets
  written — "bumped" is derived downstream from `last_bumped_at` recency,
  not a stored boolean. Don't write `is_bumped` yourself; it's dead data
  nothing reads.
- **`InternalDjBulkUpdateListings` with `indexed_at` is not a bump**, even
  though it does refresh recency and fire a `listing_updated` event — its
  `LegacyFields` path is explicitly restricted to `last_liked`,
  `is_campaign`, `is_collection_locked` ([internal.go:491](https://github.com/carousell/listing/blob/master/listing/service/internal.go)),
  so it can't touch `last_bumped_at` even if you wanted it to. Use Step 5's
  `bump-svc` flow instead.
- `FulfillBump`'s `marketplace` field uses bump-svc's own 2-letter
  `Marketplace` enum (`HK`, `SG`, `MY`, `TW`, `ID`, `PH`, ...) — not
  listing-svc's `MARKET_PLACE_*` enum used in Steps 1–4.
- Use a fresh, unique `checkout_id` per `FulfillBump` call — bump-svc keys
  off (`user_id`, `listing_id`, `checkout_id`) as an idempotency tuple and
  silently no-ops a repeat instead of erroring.

## Related

- [bifrost-test-data-seeding](../bifrost-test-data-seeding/SKILL.md) — for a brand-new auto-generated seller instead of an existing one.
- [carousell-categories](../carousell-categories/SKILL.md) — category/collection ID lookups.
- [carousell-golang-backend-services](../carousell-golang-backend-services/SKILL.md) — namespace/context conventions.
- Proto: `cs-proto/proto/bump-svc/public/bump.proto` (`BumpService.FulfillBump`) — owned by the pro-sellers team.

---

## Owner

| Field | Value |
|-------|-------|
| **Author** | Claude Code (AI) |
| **Team** | Test Engineering / Platform |
| **Last Updated** | 2026-11-16 |
| **Service Owner** | listing-svc (seller team) |

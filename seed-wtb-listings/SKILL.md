---
name: seed-wtb-listings
description: "Seed end-to-end 'Looking to buy ...' (WTB) test listings: get or create a verified, professional, bump-eligible seller, create luxury-category listing(s) with a WTB title/description pattern, and bump each one through bump-svc. Composes bifrost-test-data-seeding (user creation) and seed-listings-for-seller (listing creation + bump) rather than reimplementing their RPC calls. Usage: /seed-wtb-listings"
argument-hint: "[marketplace: SG|HK|MY|PH|ID|TW] [category: watches|bags_wallets] [seller_user_id] [user_count] [listings_per_user]"
allowed-tools: Bash(grpcurl *), Bash(kubectl *), Bash(curl *), Read
---

# seed-wtb-listings

Seed "Looking to buy ..." style listings end-to-end: seller → listing → bump.
This skill is a thin orchestration layer — it does not introduce new RPCs or
gRPC mechanics of its own. All the actual calls, ports, protos, and gotchas
live in the two skills it composes:

- [bifrost-test-data-seeding](../bifrost-test-data-seeding/SKILL.md) — creates
  the seller account (`verified`, `professional_seller`, `coins`) when no
  existing seller is given.
- [seed-listings-for-seller](../seed-listings-for-seller/SKILL.md) — creates
  the listing(s) on that seller (Steps 1–4), then bumps each one through
  bump-svc's `FulfillBump` (Step 5).

Read both before running this — this doc only covers what's specific to the
WTB flow: the title/description pattern, default market/category, and the
coins/verified/professional requirements that make the seller bump-eligible.

## Defaults (when not specified)

| Param | Default | Notes |
|---|---|---|
| Marketplace | `HK` | |
| Category | Random pick of **Luxury > Watches** or **Luxury > Bags & Wallets**, per listing | Resolve the cc_id for the chosen market — don't hardcode HK's `636`/`635` for another market, ccids are per-country. |
| Seller | Create 1 new user | Only when no `seller_user_id` is given |
| Listings per user | 1 | |
| Coins | `10000` | Safety margin, not a measured price — see "Coins & bump-eligibility" below |

## Step 1 — Get or create the seller

If `seller_user_id` is given, skip seller creation and still confirm the
existing seller is verified/professional/has enough coins before bumping —
if not, bring it up to spec with bulkdata-svc's `EditUser` RPC (same service
as `bifrost-test-data-seeding`, different RPC: takes username/password
instead of creating a fresh account).

Otherwise, create via `bifrost-test-data-seeding`'s `CreateUsers` RPC:

```json
{
  "marketplace": "MARKET_PLACE_HK",
  "record_count": 1,
  "source": "SOURCE_ON_DEMAND",
  "verified": true,
  "professional_seller": true,
  "coins": 10000
}
```

Check the response's `operation_errors` map is empty before continuing — a
user that looks created but silently failed `professional_seller` or
`coins` breaks the bump-eligibility requirement invisibly.

### Coins & bump-eligibility

`verified` and `professional_seller` must both be `true`. `coins` ≥ `10000`
is a safety margin, not a measured bump price: the synchronous immediate-bump
path `FulfillBump` takes (see seed-listings-for-seller Step 5) does **not**
call `CheckBalanceForPostPaid` at all — balance is only checked on the
scheduled/non-immediate path and in `ManualBumpByBumpIds` without
`skip_balance_check`. Provisioning coins anyway keeps the seller realistic
and future-proofs against switching to a bump type that isn't immediate. If
you need the real price for a specific bump type, check bump-svc's
`GetBumpPricingV2` rather than guessing.

## Step 2 — Resolve the category cc_id

Pick Watches or Bags & Wallets (randomly, if not specified) under the
market's Luxury L1 category, then resolve its cc_id via
[carousell-categories](../carousell-categories/SKILL.md), e.g.
`categoryclient tree <CC> | grep -E 'Luxury > (Watches|Bags & Wallets)$'`.
For HK specifically these are already known: `636` (Watches), `635`
(Bags & Wallets).

## Step 3 — Create the listing(s) with the WTB pattern

Follow `seed-listings-for-seller` Steps 2–4 (port-forward to listing-svc,
`InternalDjCreateListing`, `InternalDjCreateMedia`), with:

- `title` and `description` **both** starting with `"Looking to buy "` — e.g.
  `"Looking to buy a Rolex GMT-Master II in good condition"`. This prefix is
  what marks the listing as WTB-style for this skill.
- One listing per iteration of `listings_per_user`; if more than one and no
  fixed category was given, cycle between Watches and Bags & Wallets rather
  than repeating the same random pick.

`InternalDjCreateListing` runs the same smart-field pass the public
`CreateListing` RPC does, so `is_wtb` typically gets auto-detected from the
title/description text — confirm it actually landed (`GetListings` with
`include_attributes: true`) rather than assuming the prefix alone guarantees
it; see seed-listings-for-seller's Gotchas for the smart-field caveats.

## Step 4 — Bump each listing

Follow `seed-listings-for-seller` Step 5 (bump-svc's `FulfillBump`)
immediately after creating each listing — pair create+bump per listing
rather than batching all listings and bumping at the end, so a failed bump
is attributable to the listing that caused it. See that skill for the exact
request shape, the `marketplace`/`listing_id` field gotchas, and why
`indexed_at`/`is_bumped` are **not** valid bump signals.

## Verification

For each created listing, `GetListings` (`include_attributes: true`) on
listing-svc should show:

- `last_bumped_at` set, matching your `FulfillBump` call time
- `is_wtb: true`
- `title` / `description` starting with `"Looking to buy "`

## Gotchas

- A user that looks created but silently failed `professional_seller` or
  `coins` (check `operation_errors`) breaks bump-eligibility invisibly — see
  Step 1.
- Category ccids are per-market — resolve them for the target market, don't
  reuse HK's `635`/`636` elsewhere.
- This skill doesn't duplicate the composed skills' own Gotchas (port-forward
  namespaces, `collection_id` vs `country_collection_id`, media `legacy_id`
  uniqueness, the `marketplace` enum mismatch between listing-svc and
  bump-svc, `checkout_id` idempotency, etc.) — read
  seed-listings-for-seller's Gotchas section too.

## Related

- [bifrost-test-data-seeding](../bifrost-test-data-seeding/SKILL.md)
- [seed-listings-for-seller](../seed-listings-for-seller/SKILL.md)
- [carousell-categories](../carousell-categories/SKILL.md)

---

## Owner

| Field | Value |
|-------|-------|
| **Author** | Claude Code (AI) |
| **Team** | Test Engineering / Platform |
| **Last Updated** | 2026-11-16 |
| **Service Owner** | N/A — composition of bulkdata-svc, listing-svc, and bump-svc |

# Seed Listings for Seller — Quick Reference

End-to-end script for the common case: N listings, one category, one existing seller.

## Full Script

```bash
#!/bin/bash
set -e

SELLER_ID="<seller_user_id>"       # e.g. 261029
MARKETPLACE_ID="1880252"           # SG; see SKILL.md for other markets
CC_ID="1233"                       # category, e.g. Used Cars
COUNT=10

kubectl config use-context gke_carousell-staging_asia-east1-c_staging-main-k127
kubectl port-forward -n listing svc/listing-svc 9281:9281 &
PF_PID=$!
trap "kill $PF_PID" EXIT
sleep 2

PROTO="<monorepo>/cs-proto/proto"
IMAGE_URL="https://media.karousell.com/media/photos/products/2026/10/14/test_used_car_qnust_uae_sid_1791939181_10d7cd30_thumbnail.jpg"

SUCCESS=0; FAILED=0
for i in $(seq 1 "$COUNT"); do
  MEDIA_LEGACY_ID="$(date +%s%N)"             # must be unique across ALL media rows

  RESPONSE=$(grpcurl -plaintext \
    -proto "$PROTO/listing/public/listing.proto" -import-path "$PROTO" \
    -d "{\"listings\":[{
      \"seller_id\":\"$SELLER_ID\",
      \"title\":\"Test listing $i\",
      \"price\":$((RANDOM % 50000 + 10000)),
      \"country_collection_id\":\"$CC_ID\",
      \"description\":\"Auto-generated test listing $i\",
      \"marketplace_id\":\"$MARKETPLACE_ID\",
      \"status\":\"L\",
      \"primary_photo_thumbnail\":\"$IMAGE_URL\",
      \"default_location\":{
        \"name\":\"Singapore\",\"address\":\"Singapore\",
        \"latitude\":1.3521,\"longitude\":103.8198,\"location_type\":\"default\"
      }
    }]}" \
    localhost:9281 listing_proto.ListingService/InternalDjCreateListing 2>&1)

  LISTING_ID=$(echo "$RESPONSE" | jq -r '.listings[0].id' 2>/dev/null)
  CATEGORY_ID=$(echo "$RESPONSE" | jq -r '.listings[0].categoryId' 2>/dev/null)

  if [ -z "$LISTING_ID" ] || [ "$LISTING_ID" == "null" ]; then
    echo "❌ [$i/$COUNT] $(echo "$RESPONSE" | head -1)"
    ((FAILED++))
    continue
  fi
  if [ "$CATEGORY_ID" != "$CC_ID" ]; then
    echo "⚠️  [$i/$COUNT] $LISTING_ID created but WRONG category: got $CATEGORY_ID, expected $CC_ID"
    ((FAILED++))
    continue
  fi

  # attach the gallery photo (primary_photo_thumbnail above only covers card views)
  MEDIA_RESPONSE=$(grpcurl -plaintext \
    -proto "$PROTO/listing/public/listing.proto" -import-path "$PROTO" \
    -d "{\"listings\":[{
      \"id\":\"$LISTING_ID\",
      \"media\":[{
        \"legacy_id\":$MEDIA_LEGACY_ID,
        \"is_primary\":true,
        \"image\":\"$IMAGE_URL\",
        \"thumbnail\":\"$IMAGE_URL\"
      }]
    }]}" \
    localhost:9281 listing_proto.ListingService/InternalDjCreateMedia 2>&1)

  if echo "$MEDIA_RESPONSE" | jq -e '.media[0].id' >/dev/null 2>&1; then
    echo "✅ [$i/$COUNT] $LISTING_ID (category $CATEGORY_ID, image attached)"
    ((SUCCESS++))
  else
    echo "⚠️  [$i/$COUNT] $LISTING_ID created but image attach failed: $(echo "$MEDIA_RESPONSE" | head -1)"
    ((FAILED++))
  fi
done

echo "Done: $SUCCESS created, $FAILED failed"
```

**Always verify `categoryId` in the response** — a wrong or missing
`country_collection_id` doesn't error, it silently falls back to a generic
disabled category (see SKILL.md Gotchas). Likewise, `MEDIA_LEGACY_ID` must be
unique per image — reusing one silently reassigns another listing's photo
instead of erroring.

## Bumping the listings you just created

Through `bump-svc`'s real `FulfillBump` RPC — not by poking `indexed_at` on
listing-svc. Needs a separate port-forward (`bump-cip`, `bump` namespace):

```bash
kubectl port-forward -n bump svc/bump-cip 9282:9281 &

PROTO="<monorepo>/cs-proto/proto"

# LEGACY_IDS: array of legacy_ids from the listing-creation loop above
# SELLER_ID, CC_ID: same as above; MARKETPLACE: 2-letter code, e.g. "HK"
for LEGACY_ID in "${LEGACY_IDS[@]}"; do
  grpcurl -plaintext \
    -proto "$PROTO/bump-svc/public/bump.proto" -import-path "$PROTO" \
    -d "{
      \"checkout_id\": \"seed-bump-$LEGACY_ID\",
      \"user_id\": \"$SELLER_ID\",
      \"marketplace\": \"$MARKETPLACE\",
      \"product_type\": \"V2_1_DAY_BUMP\",
      \"listing_id\": \"$LEGACY_ID\",
      \"listing_cc_id\": \"$CC_ID\"
    }" \
    localhost:9282 bump_proto.BumpService/FulfillBump
done
```

`{}` per call means success — no `bump_schedule_config` needed, it defaults
to "start now" and executes synchronously. See SKILL.md Step 5 for why this
replaces the old `indexed_at` workaround.

## Resolving a username to a user ID

```bash
curl -X POST https://bifrost.staging.carousell.com/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"<username>","password":"<password>"}' | jq '.user_id'
```

## Known marketplace_id values

| Marketplace | marketplace_id (city ID) |
|---|---|
| Singapore | `1880252` |

Add other markets here as they're discovered — grep
`<monorepo>/listing/listing/integrationtests/` for `country.<NAME>_<id>`
constants to find more.

## See Also

- Full guide: `SKILL.md` in this directory
- Backend service: `listing-svc` (owned by seller team)
- Proto: `cs-proto/proto/listing/public/listing.proto` (`ListingService.InternalDjCreateListing`)
- Backend service: `bump-svc` (owned by pro-sellers team)
- Proto: `cs-proto/proto/bump-svc/public/bump.proto` (`BumpService.FulfillBump`)

# Seed WTB Listings — Quick Reference

End-to-end script for the common case: N new sellers, each with M "Looking to
buy ..." listings in HK's Luxury Watches / Bags & Wallets categories, bumped
through bump-svc. See `SKILL.md` for the defaults/gotchas this encodes.

## Full Script

```bash
#!/bin/bash
set -e

MARKETPLACE="HK"                 # bump-svc 2-letter code
MARKETPLACE_ID="1819729"         # listing-svc city id for HK
BULKDATA_MARKETPLACE="MARKET_PLACE_HK"
USER_COUNT=1
LISTINGS_PER_USER=1
COINS=10000

# HK Luxury category cc_ids — resolve via carousell-categories for other markets
declare -A CC_FOR_CATEGORY=(
  ["watches"]="636"
  ["bags_wallets"]="635"
)
CATEGORIES=("watches" "bags_wallets")

WTB_TITLES=(
  "a Rolex GMT-Master II in good condition"
  "a Chanel Classic Flap bag in black caviar leather"
  "an Omega Speedmaster, any condition"
  "a Hermes Birkin or Kelly bag"
)

kubectl config use-context gke_carousell-staging_asia-east1-c_staging-main-k127

# --- Step 1: create the seller(s) via bulkdata-svc ---
kubectl port-forward -n bulkdata-svc svc/bulkdata-svc-cip 9281:9281 &
PF_BULKDATA=$!
sleep 2

PROTO="<monorepo>/cs-proto/proto"
USERS_RESPONSE=$(grpcurl -plaintext \
  -proto "$PROTO/bulkdata/public/bulkdata.proto" -import-path "$PROTO" \
  -d "{
    \"marketplace\": \"$BULKDATA_MARKETPLACE\",
    \"record_count\": $USER_COUNT,
    \"source\": \"SOURCE_ON_DEMAND\",
    \"verified\": true,
    \"professional_seller\": true,
    \"coins\": $COINS
  }" \
  localhost:9281 bulkdata_public_pb.BulkDataService/CreateUsers)

kill $PF_BULKDATA

# fail loud if any user has operation_errors (e.g. professional_seller silently failed)
echo "$USERS_RESPONSE" | python3 -c "
import json, sys
d = json.load(sys.stdin)
bad = [r for r in d['records'] if r.get('operationErrors')]
if bad:
    print('operation_errors present, bump-eligibility not guaranteed:', bad, file=sys.stderr)
    sys.exit(1)
"

SELLER_IDS=($(echo "$USERS_RESPONSE" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(' '.join(r['userId'] for r in d['records']))
"))

# --- Step 2+3: create + bump listings via listing-svc and bump-svc ---
kubectl port-forward -n listing svc/listing-svc-cip 9281:9281 &
PF_LISTING=$!
kubectl port-forward -n bump svc/bump-cip 9282:9281 &
PF_BUMP=$!
sleep 2
trap "kill $PF_LISTING $PF_BUMP 2>/dev/null" EXIT

IMAGE_URL="https://media.karousell.com/media/photos/products/2026/10/14/test_used_car_qnust_uae_sid_1791939181_10d7cd30_thumbnail.jpg"
COUNTER=0
for SELLER_ID in "${SELLER_IDS[@]}"; do
  for i in $(seq 1 "$LISTINGS_PER_USER"); do
    COUNTER=$((COUNTER+1))
    CATEGORY="${CATEGORIES[$((RANDOM % ${#CATEGORIES[@]}))]}"
    CC_ID="${CC_FOR_CATEGORY[$CATEGORY]}"
    WANT="${WTB_TITLES[$((RANDOM % ${#WTB_TITLES[@]}))]}"
    TITLE="Looking to buy $WANT"
    DESC="Looking to buy $WANT. Please message me with price and photos if you have one for sale."

    LISTING_RESPONSE=$(grpcurl -plaintext \
      -proto "$PROTO/listing/public/listing.proto" -import-path "$PROTO" \
      -d "{\"listings\":[{
        \"seller_id\":\"$SELLER_ID\",
        \"title\":\"$TITLE\",
        \"price\":$((RANDOM % 5000 + 500)),
        \"country_collection_id\":\"$CC_ID\",
        \"description\":\"$DESC\",
        \"marketplace_id\":\"$MARKETPLACE_ID\",
        \"status\":\"L\",
        \"primary_photo_thumbnail\":\"$IMAGE_URL\",
        \"default_location\":{
          \"name\":\"Hong Kong\",\"address\":\"Hong Kong\",
          \"latitude\":22.3193,\"longitude\":114.1694,\"location_type\":\"default\"
        }
      }]}" \
      localhost:9281 listing_proto.ListingService/InternalDjCreateListing)

    LISTING_ID=$(echo "$LISTING_RESPONSE" | jq -r '.listings[0].id')
    LEGACY_ID=$(echo "$LISTING_RESPONSE" | jq -r '.listings[0].legacyId')
    CATEGORY_ID=$(echo "$LISTING_RESPONSE" | jq -r '.listings[0].categoryId')
    if [ "$CATEGORY_ID" != "$CC_ID" ]; then
      echo "⚠️  [$COUNTER] wrong category: got $CATEGORY_ID, expected $CC_ID" >&2
      continue
    fi

    grpcurl -plaintext \
      -proto "$PROTO/listing/public/listing.proto" -import-path "$PROTO" \
      -d "{\"listings\":[{
        \"id\":\"$LISTING_ID\",
        \"media\":[{
          \"legacy_id\":$(date +%s%N),
          \"is_primary\":true,
          \"image\":\"$IMAGE_URL\",
          \"thumbnail\":\"$IMAGE_URL\"
        }]
      }]}" \
      localhost:9281 listing_proto.ListingService/InternalDjCreateMedia > /dev/null

    # bump it now, per-listing, through the real bump-svc flow
    grpcurl -plaintext \
      -proto "$PROTO/bump-svc/public/bump.proto" -import-path "$PROTO" \
      -d "{
        \"checkout_id\": \"seed-wtb-$LEGACY_ID\",
        \"user_id\": \"$SELLER_ID\",
        \"marketplace\": \"$MARKETPLACE\",
        \"product_type\": \"V2_1_DAY_BUMP\",
        \"listing_id\": \"$LEGACY_ID\",
        \"listing_cc_id\": \"$CC_ID\"
      }" \
      localhost:9282 bump_proto.BumpService/FulfillBump > /dev/null

    echo "✅ [$COUNTER] seller=$SELLER_ID category=$CATEGORY legacy=$LEGACY_ID bumped"
  done
done
```

**Always check `operation_errors` on the `CreateUsers` response** before
treating the seller as bump-eligible — see SKILL.md's "Coins &
bump-eligibility". **Always verify `categoryId`** on the listing response —
a wrong/missing `country_collection_id` silently falls back to a generic
category instead of erroring (seed-listings-for-seller's Gotchas).

## See Also

- Full guide: `SKILL.md` in this directory
- [bifrost-test-data-seeding](../bifrost-test-data-seeding/README.md) — user creation details
- [seed-listings-for-seller](../seed-listings-for-seller/README.md) — listing creation + bump details
- Protos: `bulkdata/public/bulkdata.proto`, `listing/public/listing.proto`, `bump-svc/public/bump.proto`

---
name: bifrost-test-data-seeding
description: "Create test data (users, listings, offers, orders) using Bifrost Bulk Data Service via HTTP or gRPC without accessing the web UI. Supports marketplace selection, customizable record counts, and credential generation. Usage: /bifrost-test-data-seeding"
argument-hint: "[entity_type: users|listings|offers|orders] [marketplace: SG|ID|MY|PH|HK|TW] [count: 1-10]"
allowed-tools: Bash(curl *), Bash(go run *), Read, Write
---

# bifrost-test-data-seeding: Create Test Data via Bifrost Bulk Data Service

Create realistic test data for the Carousell marketplace without using the web UI. The Bifrost Bulk Data Service (`bulkdata-svc`) generates test users, listings, offers, and orders with auto-generated credentials and handles all external service integrations (Bifrost auth, Checkout, Delivery, Payments).

**Why:** The web UI is slow for bulk data creation. Direct API calls are faster and scriptable.

**Note:** This only works for brand-new, auto-generated sellers. To add
listings to a seller who **already exists**, use
[seed-listings-for-seller](../seed-listings-for-seller/SKILL.md) instead —
bulkdata-svc cannot target an existing user ID.

**How:** The `bulkdata-svc` gRPC microservice is exposed via:
- HTTP endpoints at `/api/1.0/bulkdata/{entity}/create` (via BifrostGateway)
- Direct gRPC calls (fastest)
- MCP tools in cs-mcp (best integration)

---

## Step-by-Step Guide

### Step 1: Determine Your Data Needs

Ask yourself:
- **What entity?** Users, listings, offers, or orders?
- **How many records?** 1–10 (5 max for orders)
- **Marketplace?** SG, ID, MY, PH, HK, TW
- **Specific properties?** (subscribed users, verified accounts, professional sellers, etc.)

### Step 2: Choose Your Access Method

#### **Method A: HTTP via BifrostGateway (Simplest)**
Use `curl` to POST to the HTTP endpoint.
- **Best for:** Quick ad-hoc data creation, shell scripts
- **Requirements:** BifrostGateway running (typically always on staging)
- **Speed:** ~2–5 seconds per request

```bash
curl -X POST http://bifrost-gateway.staging:8080/api/1.0/bulkdata/users/create \
  -H "Content-Type: application/json" \
  -d '{
    "data": {
      "marketplace": "MARKET_PLACE_SG",
      "record_count": 5,
      "source": "SOURCE_WEB",
      "verified": true,
      "subscribed": false
    }
  }'
```

#### **Method B: Direct gRPC (Fastest)**
Write a tiny Go program or use `grpcurl`.
- **Best for:** Performance-critical test suites, high volume
- **Requirements:** Direct network access to bulkdata-svc
- **Speed:** ~1–3 seconds per request (no HTTP overhead)

```bash
grpcurl -plaintext \
  -d '{"marketplace": "MARKET_PLACE_SG", "record_count": 5, "source": "SOURCE_ON_DEMAND"}' \
  bulkdata-svc.staging:9000 \
  bulkdata.BulkDataService/CreateUsers
```

#### **Method C: MCP Tools via cs-mcp (Best Integration)**
Use the wrapped service from cs-mcp with validation & external service resolution.
- **Best for:** Automated workflows, category resolution, package lookups
- **Requirements:** cs-mcp running
- **Speed:** ~2–5 seconds (includes external service calls)

```bash
claude-code invoke cs-mcp --tool BulkdataCreateUsers \
  --marketplace SG \
  --record_count 5 \
  --verified true
```

### Step 3: Prepare Your Payload

Each entity type has different required and optional fields:

**Create Users:**
```json
{
  "data": {
    "marketplace": "MARKET_PLACE_SG",
    "record_count": 5,
    "source": "SOURCE_WEB",
    "verified": true,
    "subscribed": false,
    "kyc_verified": false,
    "professional_seller": false,
    "user_type": "USER_TYPE_CERTIFIED",
    "coins": 0,
    "package_id": ""
  }
}
```

**Create Listings:**
```json
{
  "data": {
    "marketplace": "MARKET_PLACE_SG",
    "record_count": 3,
    "source": "SOURCE_WEB",
    "cc_id": "1010",
    "listings_per_user": 2,
    "listing_type": "LISTING_TYPE_AP",
    "delivery_mode": ["DELIVERY_MODE_MEETUP", "DELIVERY_MODE_SHIPPING"],
    "title": "iPhone 14 Pro",
    "price": "1299.99",
    "desc": "Mint condition"
  }
}
```

**Create Offers:**
```json
{
  "data": {
    "marketplace": "MARKET_PLACE_SG",
    "record_count": 2,
    "source": "SOURCE_WEB",
    "cc_id": "1010",
    "offers_per_user": 3,
    "offer_status": "OFFER_STATUS_PENDING",
    "listing_type": "LISTING_TYPE_AP"
  }
}
```

**Create Orders:**
```json
{
  "data": {
    "marketplace": "MARKET_PLACE_SG",
    "record_count": 2,
    "source": "SOURCE_WEB",
    "cc_id": "1010",
    "listings_per_order": 1,
    "listing_type": "LISTING_TYPE_AP",
    "delivery_mode": ["DELIVERY_MODE_SHIPPING"],
    "order_status": "ORDER_STATUS_COMPLETED",
    "payment_method": "PAYMENT_METHOD_SG_STRIPE"
  }
}
```

### Step 4: Make the Request

Use curl, grpcurl, or your gRPC client to submit the request. The response includes:
- Auto-generated `user_id`, `username`, `password`, `email`
- Created `listing_id`, `offer_id`, `order_id` (as applicable)
- `record_id` for cleanup later

Example response (users):
```json
{
  "records": [
    {
      "user_id": "12345",
      "username": "user_sg_xyz",
      "password": "auto_generated_password",
      "email": "user@carousell.test",
      "marketplace": "MARKET_PLACE_SG",
      "verified": true,
      "subscribed": false,
      "user_type": "USER_TYPE_CERTIFIED"
    }
  ]
}
```

### Step 5: Cleanup (Optional)

Records are tagged with `record_id` and `source` for easy tracking. When done with testing:

```bash
# Deactivate a batch of records
curl -X POST http://bifrost-gateway.staging:8080/api/1.0/bulkdata/records/deactivate \
  -H "Content-Type: application/json" \
  -d '{ "record_id": "batch_123" }'

# Delete all deactivated records
curl -X POST http://bifrost-gateway.staging:8080/api/1.0/bulkdata/records/delete-deactivated \
  -H "Content-Type: application/json" \
  -d '{}'
```

---

## Reference Data

### Marketplace Enum Values
| Marketplace | Value |
|------------|-------|
| Singapore | `MARKET_PLACE_SG` |
| Indonesia | `MARKET_PLACE_ID` |
| Malaysia | `MARKET_PLACE_MY` |
| Philippines | `MARKET_PLACE_PH` |
| Hong Kong | `MARKET_PLACE_HK` |
| Taiwan | `MARKET_PLACE_TW` |

### Common Category IDs (cc_id)
| Category | ID |
|----------|-------|
| Electronics | `1010` |
| Fashion & Apparel | `1020` |
| Home & Living | `1030` |
| Books & Media | `1040` |
| Sports & Outdoors | `1050` |
| Toys & Games | `1060` |
| Beauty & Personal Care | `1070` |
| Collectibles & Art | `1080` |

To get all category IDs, query dj-gw's category tree endpoint or check the admin panel.

### Listing Types
- `LISTING_TYPE_AP` - Add Price (auction)
- `LISTING_TYPE_BP` - Buy Price (fixed)
- `LISTING_TYPE_OM` - Offer Me (offers)

### Delivery Modes
- `DELIVERY_MODE_MEETUP` - Meet in person
- `DELIVERY_MODE_SHIPPING` - Shipping via carrier

### Order Status
- `ORDER_STATUS_IN_PROGRESS` - Ongoing
- `ORDER_STATUS_COMPLETED` - Finished
- `ORDER_STATUS_CANCELLED` - Cancelled
- `ORDER_STATUS_RETURNED` - Returned

### Offer Status
- `OFFER_STATUS_PENDING` - Awaiting response
- `OFFER_STATUS_ACCEPTED` - Accepted
- `OFFER_STATUS_REJECTED` - Rejected

### Payment Methods
- `PAYMENT_METHOD_SG_STRIPE` - Singapore Stripe

---

## Environment Setup

### Local Development
```bash
export BULKDATA_HOST=localhost:9000
export BIFROST_GATEWAY_HOST=localhost:8080
```

### Staging
```bash
export BULKDATA_HOST=bulkdata-svc.staging:9000
export BIFROST_GATEWAY_HOST=bifrost-gateway.staging:8080
```

### Infra Experimental
```bash
export BULKDATA_HOST=bulkdata-svc.infra-experimental:9000
export BIFROST_GATEWAY_HOST=bifrost-gateway.infra-experimental:8080
```

**Note:** The bulkdata-svc service is restricted to **staging** and **infra-experimental** only. Production calls are rejected by design.

---

## Do's and Don'ts

| Do ✅ | Don't ❌ |
|-------|---------|
| Always specify the marketplace explicitly | Assume a default marketplace |
| Use `SOURCE_WEB` or `SOURCE_ON_DEMAND` as source | Use other source values |
| Verify category IDs (cc_id) for the marketplace before listing creation | Use random category IDs |
| Clean up test data when done via deactivate/delete | Leave orphaned test records in the database |
| Cache category IDs locally to reduce external service calls | Query category tree on every request |
| Batch multiple record creations together (up to limits) | Create one record at a time in a loop |
| Use specific usernames/passwords for reproducible tests | Rely on auto-generated credentials |
| Check response `operation_errors` map for partial failures | Assume all records were created successfully |

---

## Common Issues & Troubleshooting

### "Service Unavailable"
- **Cause:** BifrostGateway or bulkdata-svc is down or unreachable
- **Fix:** Check service health, verify network connectivity, confirm environment/host

### "Empty Response or Silent Failure"
- **Cause:** Often category ID resolution failure or invalid delivery mode for listing type
- **Fix:** Verify cc_id exists in the marketplace, check listing_type + delivery_mode combination is valid

### "Permission Denied / Unauthorized"
- **Cause:** Invalid credentials or service doesn't allow test data creation on this environment
- **Fix:** Check authentication token, verify environment is staging or infra-experimental (not production)

### "Invalid Enum Value"
- **Cause:** Typo in marketplace, order status, or other enum field
- **Fix:** Verify all enum values match the reference table above

### "Request Timeout"
- **Cause:** Service is slow or creating large numbers of records
- **Fix:** Reduce record_count, check service health, try again with a longer timeout

---

## Constraints & Limits

| Constraint | Value | Notes |
|-----------|-------|-------|
| Max users per request | 10 | HTTP timeout increases after 5 |
| Max orders per request | 5 | Orders take longer to create |
| Max coins per user | 50,000 | Business logic limit |
| HTTP request timeout | 60 seconds | 120 seconds for orders |
| Delivery modes per listing | Multiple | But validates against listing type |

---

## External Service Integrations

When you create test data, bulkdata-svc also:
1. **Bifrost** — Creates user accounts & handles auth
2. **Subscription Service** — Resolves CarouBiz package IDs if `subscribed=true`
3. **Checkout Services** — Creates orders with payment info
4. **Delivery Carriers** — Integrates SPX, NinjaVan, J&T, PosLaju, SF Express
5. **Payment Surfaces** — Handles region-specific payment methods
6. **Category Service (dj-gw)** — Resolves category names to IDs (cached)

All integrations are automatic — you just need to specify the data parameters.

---

## Record Bookkeeping

Each created record is tagged with metadata for tracking and cleanup:
- **record_id** — Unique batch identifier for cleanup
- **record_type** — USER, LISTING, ORDER, OFFER, etc.
- **marketplace** — SG, ID, MY, PH, HK, TW
- **source** — ON_DEMAND (for gRPC), WEB (for HTTP), CI (for automated tests)

Use these tags to query active records or deactivate entire batches.

---

## Related Skills

- [carousell-golang-backend-services](../carousell-golang-backend-services/SKILL.md) — Understanding service architecture
- [db-query](../db-query/SKILL.md) — Querying service databases
- [deploy](../deploy/SKILL.md) — Deploying services to staging/production

---

## Owner

| Field | Value |
|-------|-------|
| **Author** | Claude Code (AI) |
| **Team** | Test Engineering / Platform |
| **Last Updated** | 2026-11-06 |
| **Service Owner** | cs-test-eng |
| **Backend Service** | bulkdata-svc |

# Bifrost Test Data Seeding Skill

Quick reference for seeding test data using the Bifrost Bulk Data Service.

## Quick Examples

### Create 5 test users in Singapore
```bash
curl -X POST http://bifrost-gateway.staging:8080/api/1.0/bulkdata/users/create \
  -H "Content-Type: application/json" \
  -d '{
    "data": {
      "marketplace": "MARKET_PLACE_SG",
      "record_count": 5,
      "source": "SOURCE_WEB",
      "verified": true
    }
  }' | jq '.records[] | {user_id, username, password, email}'
```

### Create 3 listings per user in Malaysia
```bash
curl -X POST http://bifrost-gateway.staging:8080/api/1.0/bulkdata/listings/create \
  -H "Content-Type: application/json" \
  -d '{
    "data": {
      "marketplace": "MARKET_PLACE_MY",
      "record_count": 2,
      "source": "SOURCE_WEB",
      "cc_id": "1010",
      "listings_per_user": 3,
      "delivery_mode": ["DELIVERY_MODE_MEETUP", "DELIVERY_MODE_SHIPPING"]
    }
  }' | jq '.records[] | {user: .user.username, listings: .items[].listing_id}'
```

### Create completed orders in Hong Kong
```bash
curl -X POST http://bifrost-gateway.staging:8080/api/1.0/bulkdata/orders/create \
  -H "Content-Type: application/json" \
  -d '{
    "data": {
      "marketplace": "MARKET_PLACE_HK",
      "record_count": 2,
      "source": "SOURCE_WEB",
      "cc_id": "1010",
      "order_status": "ORDER_STATUS_COMPLETED",
      "payment_method": "PAYMENT_METHOD_SG_STRIPE",
      "delivery_mode": ["DELIVERY_MODE_SHIPPING"]
    }
  }' | jq '.records[] | {buyer: .buyer.username, seller: .seller.username, order_id}'
```

### Create pending offers
```bash
curl -X POST http://bifrost-gateway.staging:8080/api/1.0/bulkdata/offers/create \
  -H "Content-Type: application/json" \
  -d '{
    "data": {
      "marketplace": "MARKET_PLACE_SG",
      "record_count": 1,
      "source": "SOURCE_WEB",
      "cc_id": "1010",
      "offers_per_user": 2,
      "offer_status": "OFFER_STATUS_PENDING"
    }
  }' | jq '.records[] | {buyer: .buyer.username, seller: .seller.username, offers: .offers[].offer_id}'
```

## Environment Variables

Set these for convenience:
```bash
export GATEWAY_HOST=bifrost-gateway.staging
export GATEWAY_PORT=8080
export BULKDATA_URL=http://$GATEWAY_HOST:$GATEWAY_PORT/api/1.0/bulkdata
```

Then use:
```bash
curl -X POST $BULKDATA_URL/users/create -H "Content-Type: application/json" -d '...'
```

## Save Credentials to CSV

Extract credentials and save as CSV for later use:
```bash
curl -s -X POST http://bifrost-gateway.staging:8080/api/1.0/bulkdata/users/create \
  -H "Content-Type: application/json" \
  -d '{
    "data": {
      "marketplace": "MARKET_PLACE_SG",
      "record_count": 5,
      "source": "SOURCE_WEB"
    }
  }' | jq -r '.records[] | [.user_id, .username, .password, .email] | @csv' > users.csv
```

## Cleanup

Remove test data when done:
```bash
# Deactivate a batch
curl -X POST http://bifrost-gateway.staging:8080/api/1.0/bulkdata/records/deactivate \
  -H "Content-Type: application/json" \
  -d '{ "record_id": "batch_123" }'

# Delete all deactivated records
curl -X POST http://bifrost-gateway.staging:8080/api/1.0/bulkdata/records/delete-deactivated \
  -H "Content-Type: application/json" \
  -d '{}'
```

## See Also

- Full documentation: `SKILL.md` in this directory
- Backend service: `bulkdata-svc` (owned by cs-test-eng)
- Proto definitions: `/cs-proto/proto/bulkdata/public/bulkdata.proto`
- MCP wrapper: `/cs-mcp/internal/tools/test-engineering/bulkdata_handler.go`

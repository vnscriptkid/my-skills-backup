# Carousell gRPC - Usage Examples

## Example 1: Get User from Staging

**Goal**: Fetch user details from UserSvc in staging

**Steps**:
1. Environment: `stage` (staging-main-k127)
2. Service: `user-svc`
3. Method: `GetUser` from `carousell.user.v1.UserService`
4. Request:
   ```json
   {
     "user_id": "12345"
   }
   ```

**Commands**:
```bash
# Switch context
kubectl config use-context gke_carousell-staging_asia-east1-c_staging-main-k127

# Find pod
kubectl get pods -l app=user-svc
# Output: user-svc-abc123-xyz    1/1     Running

# Port-forward
kubectl port-forward -n default pod/user-svc-abc123-xyz 50051:50051

# In another terminal, call gRPC
grpcurl -plaintext \
  -d '{"user_id":"12345"}' \
  localhost:50051 \
  carousell.user.v1.UserService/GetUser
```

**Expected Response**:
```json
{
  "user": {
    "id": "12345",
    "name": "John Doe",
    "email": "john@example.com",
    "status": "ACTIVE"
  }
}
```

---

## Example 2: List Listings from Feature Environment

**Goal**: Test new listing query filters in feature env

**Steps**:
1. Environment: `feat` (staging-feature-k127)
2. Service: `listing-svc`
3. Method: `ListListings` from `carousell.listing.v1.ListingService`
4. Request:
   ```json
   {
     "filter": {
       "status": "ACTIVE",
       "category_id": "1001"
     },
     "limit": 10,
     "offset": 0
   }
   ```

**Commands**:
```bash
kubectl config use-context gke_carousell-staging_asia-east1-c_staging-feature-k127
kubectl get pods -l app=listing-svc
kubectl port-forward -n default pod/listing-svc-def456-uvw 50053:50053

grpcurl -plaintext \
  -d '{
    "filter": {
      "status": "ACTIVE",
      "category_id": "1001"
    },
    "limit": 10,
    "offset": 0
  }' \
  localhost:50053 \
  carousell.listing.v1.ListingService/ListListings
```

---

## Example 3: Create Offer in Staging (WRITE OPERATION)

**Goal**: Create a new offer to test offer service

**⚠️ WARNING**: This modifies data. Confirm before executing.

**Steps**:
1. Environment: `stage` (staging-main-k127)
2. Service: `offer-svc`
3. Method: `CreateOffer` from `carousell.offer.v1.OfferService`
4. Request:
   ```json
   {
     "seller_id": "12345",
     "listing_id": "67890",
     "offer_price": 10000,
     "message": "Is this still available?"
   }
   ```

**Confirmation dialog**:
```
This is a WRITE operation on staging.
This will create a new offer in the database.
Proceed? (y/n)
```

**Commands**:
```bash
kubectl config use-context gke_carousell-staging_asia-east1-c_staging-main-k127
kubectl get pods -l app=offer-svc
kubectl port-forward -n default pod/offer-svc-ghi789-rst 50054:50054

grpcurl -plaintext \
  -d '{
    "seller_id": "12345",
    "listing_id": "67890",
    "offer_price": 10000,
    "message": "Is this still available?"
  }' \
  localhost:50054 \
  carousell.offer.v1.OfferService/CreateOffer
```

**Expected Response**:
```json
{
  "offer": {
    "id": "offer_abc123",
    "seller_id": "12345",
    "listing_id": "67890",
    "offer_price": 10000,
    "status": "PENDING",
    "created_at": "2026-11-06T10:30:00Z"
  }
}
```

---

## Example 4: Production Read-Only Query (EXTRA CAUTION)

**Goal**: Check user status in production

**⚠️ CRITICAL**: This is production. Mistakes affect real users.

**Steps**:
1. Environment: `prod` (thecarousell.com)
2. Service: `user-svc`
3. Method: `GetUser`
4. Request:
   ```json
   {
     "user_id": "99999"
   }
   ```

**Confirmation dialog**:
```
⚠️  PRODUCTION ENVIRONMENT
You are about to query the production cluster.
This is a READ operation (safe), but errors may impact real users.

Service: user-svc
Method: GetUser
Confirm? (y/n)
```

**Commands**:
```bash
kubectl config use-context gke_thecarousell.com:api-project-11554775814_asia-east1_main-a-k127
kubectl get pods -l app=user-svc -n default
kubectl port-forward -n default pod/user-svc-prod-jkl012 50051:50051

grpcurl -plaintext \
  -d '{"user_id":"99999"}' \
  localhost:50051 \
  carousell.user.v1.UserService/GetUser
```

---

## Example 5: Describe Service Contract

**Goal**: See all available methods on a service

**Steps**:
```bash
# Connect to any environment (staging shown)
kubectl config use-context gke_carousell-staging_asia-east1-c_staging-main-k127
kubectl port-forward -n default pod/user-svc-abc123-xyz 50051:50051

# List all services available
grpcurl -plaintext localhost:50051 list

# Describe specific service
grpcurl -plaintext localhost:50051 describe carousell.user.v1.UserService

# Describe specific method
grpcurl -plaintext localhost:50051 describe carousell.user.v1.UserService/GetUser

# Describe request message structure
grpcurl -plaintext localhost:50051 describe carousell.user.v1.GetUserRequest
```

**Output Example**:
```
carousell.user.v1.UserService is a service:
  rpc CreateUser ( .carousell.user.v1.CreateUserRequest ) returns ( .carousell.user.v1.CreateUserResponse );
  rpc GetUser ( .carousell.user.v1.GetUserRequest ) returns ( .carousell.user.v1.GetUserResponse );
  rpc UpdateUser ( .carousell.user.v1.UpdateUserRequest ) returns ( .carousell.user.v1.UpdateUserResponse );
  rpc ListUsers ( .carousell.user.v1.ListUsersRequest ) returns ( .carousell.user.v1.ListUsersResponse );
```

---

## Quick Decision Tree

```
Am I testing a new feature?
  ├─ YES → Use FEAT environment
  │        └─ Least stable, safe for experiments
  │
  └─ NO → Is this for production?
           ├─ YES → Use PROD environment
           │        ⚠️  Extreme caution, explicit confirmations
           │
           └─ NO → Use STAGE environment
                   └─ Safe, mirrors production structure
```

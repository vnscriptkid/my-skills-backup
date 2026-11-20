---
name: db-access-request
description: Automate Postgres database access requests through the multi-step access control portal. Use when you need to renew or request fresh Postgres credentials for a database.
---

# DB Access Request

Fully automates the 4-step Postgres DB Access Request form with smart defaults. You provide the database scope; Claude handles the rest.

## Quick start

```
/db-access-request
```

Claude will prompt you for:
1. **Project** (required): Choose from:
   - `thecarousell.com:api-project-11554775814` (prod)
   - `carousell-staging`
   - `carousell-infra`
2. **Search DB** (required): Database name or pattern
   - Examples: `merchant-pricing`, `backstage`, `stage-*`, `/^cats/`
3. **Reason for Access** (optional): Why you need it
   - Default: `test` (press enter to use)

Then automates:
- **Step 1:** Pre-fills email & team, searches for your database
- **Step 2:** Selects matching database(s)
- **Step 3:** Requests Read-Only Access
- **Step 4:** Sets duration to 60 days with your reason
- **Submit:** Confirms success

## What to expect

- Form completes in ~10 seconds
- Access credentials delivered via email
- Read-Only access valid for 60 days (longest available)

## Common databases (Pro/Prod)

Subscription & Merchant:
- `subscription-manager` - Subscription service (note: hyphen, not underscore)
- `carousell_subscription` - Alternative subscription DB
- `merchant-pricing` - Merchant pricing data
- `merchant-payment` - Merchant payments
- `merchant-automation` - Merchant automation

Listings & Catalog:
- `listing` - Listing service
- `cats` - Category service
- `catalogue` - Catalog data

Others:
- Leave Search DB **blank** to see all 150+ databases in the project

## Tips

**Database naming:** Carousell databases use **hyphens** (`subscription-manager`), not underscores (`subscription_manager`)

**Searching:** Use the Search DB field to filter results:
- Exact name: `subscription-manager`
- Pattern: `merchant-*` (matches all merchant DBs)
- Regex: `/^subscription/` (matches DBs starting with "subscription")

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "No databases found" | Check spelling and use **hyphens** not underscores (e.g., `subscription-manager` not `subscription_manager`) |
| "No matching databases" | Try leaving Search DB blank, or use a pattern like `merchant-*` |
| "Access denied" | Ensure you're part of Pro Sellers Team |
| Form times out | Network issue; try again or check URL is accessible |

## Customizing

Change defaults by updating the skill:
- Access level: Edit to `Request Read-Write Access` or `Request Admin Access`
- Duration: Edit to `30d`, `45d`, etc.
- Reason: Edit default text
- Pre-filled team: Change from `Pro Sellers Team` to another team

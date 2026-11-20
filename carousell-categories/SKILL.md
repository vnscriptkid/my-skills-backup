---
name: carousell-categories
description: Use whenever categories, CCIDs, CC_IDs, country collections, collection id, category id or listing taxonomy comes up in Carousell code or discussions. Also use when you need to look up lists of categories or specific category. Use to understand key terms such as category tree, L1 categories, leaf categories, legacy collection id. Use when using categorylib (Go) and categoryclient (shell).
---

# Categories in Carousell

- "Categories" / "CCIDs" / "CC_IDs" / "Country Collections" / "Collections" all generally refer to category of a listing on Carousell (an e-commerce marketplace)
- Categories are in an acyclic tree structure. Ie. categories can have parents/children. Examples:
    - `electronics > mobile phones > iPhone`
    - `electronics > mobile phones > android phones`
    - `electronics` - no parents/children (L1 category)
- L1 Category (AKA "L1 Categories"): top level category, they have no parent
- Leaf Category: category with no children.
- A category can be enabled / disabled. 
- Technical definitions:
    - **ccid** / **cc_id** / **country collection ID** = category id, it's unique across marketplaces (same category in different marketplace will have different ccid)
    - **collection id** = legacy category id, it needs to be paired with marketplace id (same category in different marketplaces may have the same collection id).

## Common Misconceptions

The below are DIFFERENT, they are NOT CATEGORIES:
- **Custom collection**: this is a collection of listings that the user curates

## Code libraries

### Golang

`github.com/carousell/categorylib`

### Shell

`categoryclient` is a CLI tool for exploring the category tree and looking up categories. Read `references/categoryclient.md` for full usage.

## BigQuery

`woven-bonbon-90705.dw_entities.category` — one row per category (cc_id) per country. Prefer this over `categoryclient` when looking up many ccids at once (eg. from a list/file), since it's a single query vs. one CLI call per ccid.

Key columns:
- `cc_id` — the ccid, STRING (cast to INT64 if sorting numerically)
- `category_name`, `path` — path is pretty-printed, eg. `Toys & Collectibles >> Trading Cards`
- `level` — 1/2/3/4, directly answers "what level is this ccid" (L1/L2/L3/L4)
- `country_name`, `country_id`
- `enabled`
- `l1_cc_id`/`l1_category_name`, `l2_cc_id`/`l2_category_name`, etc. — ancestor ccid/name at each level, same as `cc_id`/`category_name` when the row's own level matches

Example — look up level for a batch of ccids:
```sql
SELECT cc_id, category_name, level, path, country_name, enabled
FROM `woven-bonbon-90705.dw_entities.category`
WHERE cc_id IN ('10', '1147', '22')
```

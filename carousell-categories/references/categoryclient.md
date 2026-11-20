# categoryclient reference

`categoryclient` is a CLI tool installed locally on the path. It talks to the category API. Use it to explore the category tree or find information about specific categories.

Run `categoryclient --help` (or `categoryclient <subcommand> --help`) for the full list of subcommands and flags. Common ones:

Browse the category tree for a country. Use a 2-letter country code: SG, MY, HK, TW, PH, ID (these aren't listed in `--help`).
```
$ categoryclient tree SG
1     SG  Following
7090  SG  Likes
22    SG  Cars
1233  SG  Cars > Used Cars
# etc ...
```

Look up a category by ccid (outputs JSON with id, name, legacy_id, parent_id, enabled, ...)
```
categoryclient GetCategoryByID 363
```

Look up a category by legacy collection_id (requires numeric country_id, NOT country code)
```
categoryclient GetCategoryByCountryIDAndLegacyID --country-id 1880251 --collection-id 215
```

DO NOT use `categoryclient search`, it is an interactive TUI for searching the category tree (it will hang when used non-interactively)

`GetCategoryByID` and `GetCategoryByCountryIDAndLegacyID` output JSON with fields:
- `id` — ccid
- `legacy_id` — legacy collection_id
- `country_id` — numeric country ID (not the 2-letter code)
- `parent_id` — ccid of parent, empty string if L1
- `enabled` — whether the category is active
- `subcategories` — null unless `--show-subcats` is passed

Note that `GetCategoryByID` and `GetCategoryByCountryIDAndLegacyID` doesn't pretty print the category path (eg. `Electronics > Mobiles > iPhone`). 
The `tree` command is the easiest way to get a pretty printed category path. Eg. to get a specific ccid 388:
```
$ categoryclient --stage tree SG | grep '^388 '
388   SG  Hobbies & Toys > Stationary & Craft > Craft Supplies & Tools
```

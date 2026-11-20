# PII annotations on proto fields

## The rule

The validator (`devctl proto validation`) flags a field **only when its name matches a
built-in PII name pattern**. It says nothing about any other field. A new `string` field
whose name doesn't match needs no annotation and never will.

So there are exactly two reasons to write `pii_classification`:

1. The field name matches a pattern **and holds real PII** -> the specific tag (`PII_EMAIL`, ...).
2. The field name matches a pattern **but is not PII** -> `NOT_PII` to silence it.

Anything else gets **no annotation**.

`NOT_PII` is a suppression mechanism, not a declaration of safety. Adding it to a field the
validator was never going to flag suppresses nothing.

## Don't guess -- ask the validator

`devctl` is a local binary and runs in about a second. Never reason about which fields need
annotating, and never push to find out:

```bash
cd <proto checkout>
devctl proto validation --file proto/<service> --base_path proto --disableNonErrorLogs
```

Silence and exit 0 means nothing needs annotating. Otherwise it prints one line per field
that needs one. Run it on the whole service directory (not just your file) -- that is what
CI does.

If `devctl` is missing: `go install github.com/carousell/devctl@latest`.

`devctl proto annotate --file <same path>` rewrites the file with suggested annotations and
adds the import. It only touches matching fields, so it will not over-annotate. It refuses
to write to a file with uncommitted changes, so commit first. **Its enum choice is a guess
from the field name -- review every line it adds** (see the `created_by` trap below).

## Reading the error output

```
content-feed/public/smart_refinement_search.proto:88 string name = 1 [(common_annotations.pii_classification) = PII_NAME];
Error: validation failed. Please fix those errors before continuing.
```

**That line is a suggested fix, not the current contents of your file.** The annotation
shown is the validator's guess, filled in from the field name. Two consequences:

- Don't conclude CI is reading a different file or branch because your line looks different.
  It is showing you what it thinks the line should become.
- Don't paste the suggestion in blindly. It is right about *which line* and often wrong
  about *which tag*.

## The suggestion is frequently wrong -- these are the `NOT_PII` cases

The pattern list is broad and catches plenty of non-PII fields. When it does, the suggested
tag is actively misleading:

| Field | Suggested | Usually correct | Why |
|---|---|---|---|
| `created_by` / `modified_by` | `PII_NAME` | `NOT_PII` | Audit columns; typically a service or user *id*, not a name |
| `account_id` | `PII_FINANCIAL` | `NOT_PII` | An internal account key is not financial data |
| `country` | `PII_LOCATION` | `NOT_PII` | A marketplace region on a listing does not locate a person |
| `name` on a non-user entity | `PII_NAME` | `NOT_PII` | Flag/tag/category/experiment names are not people |

Decide from what the field **holds**, not what it is called. `name` on a `FeatureFlag` is
`NOT_PII`; `name` on a `User` is `PII_NAME`. If the field genuinely holds user data, use the
specific tag -- `NOT_PII` on real PII is the one failure mode worse than over-annotating.

Genuinely unsure? Leave it off and let CI tell you, or ask the user. Do not annotate
defensively.

## What matches (verified against the validator, 2026-07-31)

Matching is on the field name, case-insensitively, mostly as a substring. Non-string
fields and `map` fields are never flagged; `repeated string` and fields in nested messages
and `oneof`s are.

| Category | Matches | Suggested tag |
|---|---|---|
| Name | `*name*` (`first_name`, `display_name`, `seller_name`), `username`, `created_by`, `modified_by` | `PII_NAME` |
| Email | `*email*` | `PII_EMAIL` |
| Phone | `phone`, `mobile`, `tel`, `tele*`, `tel_*` | `PII_PHONE` |
| Location | `location`, `address`, `city`, `district`, `country`, `zipcode`, `lat`, `latitude`, `long`, `longitude` | `PII_LOCATION` |
| Avatar | `*avatar*` | `PII_AVATAR` |
| Online id | `google_id`, `zalo_id`, `*facebook*`, `*instagram*` | `PII_ONLINE_ID` |
| Financial | `account_id`, `wallet_id`, `credit_card`, `bank_account`, `fin_*`, `*payoo*` | `PII_FINANCIAL` |
| Id number | `nric*`, `passport*` | `PII_ID_NUMBER` |
| Vehicle | `vin*`, `license_plate`, `*chassis*` | `PII_VEHICLE` |
| Chat | `*chat*` | `PII_CHAT_MESSAGE` |
| IP | `ip`, `*_ip`, `*ip_addr*`, `ipaddress*`, `remote_host*` | `PII_IP_ADDRESS` |
| Gender / age / DOB | `*gender`, `age`, `age_group`, `dob`, `birthday` | `PII_GENDER` / `PII_AGE` / `PII_DOB` |
| Fax | `fax*` | `PII_FAX` |

**Explicitly exempt despite looking like matches** -- these pass unannotated:
`field_name`, `file_name`, `fee_name`, `filter_name`, `user_id`, `seller_id`, `buyer_id`,
`message` (only `chat_message` matches), `photo`, `profile_picture`, `handle`,
`license_plate` variants not listed above.

This table is a guide for anticipating the validator, not a substitute for running it. The
list changes; the command is authoritative.

## Never flagged, so never annotate

Non-string types (`int64 phone_count`, `bool is_email_verified`), `map` fields, and any
string whose name doesn't match: `listing_id`, `listing_expiry_id`, `quota_bundle_id`,
`status`, `title`, `description`, `url`, `prompt`, `cc_id`, `warnings`, `token`, `service`,
`package`, `template`, `entity`, `file`.

The validator **accepts a redundant `NOT_PII` without complaint**, so over-annotation is
never caught by CI -- there is no feedback loop to correct it. That is exactly why it has to
be avoided deliberately.

## Enum values

```proto
NOT_PII = 0;      PII_NAME = 1;       PII_EMAIL = 2;     PII_PHONE = 3;
PII_AVATAR = 4;   PII_FINANCIAL = 5;  PII_GENDER = 6;    PII_DOB = 7;
PII_AGE = 8;      PII_ID_NUMBER = 9;  PII_LOCATION = 10; PII_IP_ADDRESS = 11;
PII_CHAT_MESSAGE = 12; PII_ONLINE_ID = 13; PII_FAX = 14; PII_VEHICLE = 15;
```

Usage, and the import needed only if the file lacks it:

```proto
import "common-annotations/field_options.proto";
string email = 2 [(common_annotations.pii_classification) = PII_EMAIL];
```

Only add that import when you are actually adding an annotation. An import added
"speculatively" for annotations you then didn't need leaves the file permanently dirty.

## Which services are checked

Effectively all of them. Validation is skipped only where `module.yaml` sets
`operation_override.skip_validation: true` -- three services in cs-proto
(`common-annotations`, `google`, `messaging`).

The `validate: 1` plugin in `module.yaml` does **not** gate this check. An earlier version of
this skill claimed it did, based on an unannotated field passing CI on a non-`validate`
service; the field was named `pii_probe_field`, which no pattern matches, so it would have
passed anywhere. Don't use the `validate` plugin to decide whether to annotate -- run the
validator.

## Guidance for reference

The org's PII definition (what counts as PII, and why) is in the
[PII/API Metadata User Guide](https://carousell.atlassian.net/wiki/spaces/BE/pages/2412642325/PII+API+Metadata+User+Guide).
Useful when a field genuinely is borderline -- eg. delivery location counts as
`PII_LOCATION`, but a user's photo inside a listing image is not tagged.

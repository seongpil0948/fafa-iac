# module: firestore

Manages the Cloud Firestore `(default)` database, security rules, and indexes.

## What it does

- Manages the imported `(default)` Firestore database resource.
- Deploys security rules from `firebase/firestore.rules` (root path, not module path).
- Deploys composite indexes from `firebase/firestore.indexes.json` using a stable `for_each` key: `"collectionGroup#fieldPath1-fieldPath2-..."`.

## Critical invariants

1. **Do not replace the database.** If a plan ever proposes `replace` on `google_firestore_database.default`, stop — re-import instead.
2. **CMEK is off.** `lifecycle.ignore_changes` covers `type`, `location_id`, and `cmek_config`. Do not add CMEK to the live database.
3. **Edit rules/indexes via files**, not by adding Terraform `google_firestore_index` resources manually.
   - Rules: `firebase/firestore.rules`
   - Indexes: `firebase/firestore.indexes.json`

## Inputs

| Name | Type | Description |
|------|------|-------------|
| `project_id` | `string` | GCP project ID. |

## Outputs

None.

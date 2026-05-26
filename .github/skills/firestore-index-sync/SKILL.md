---
name: firestore-index-sync
description: 'Synchronize Firestore composite indexes between fafa-iac/firebase/firestore.indexes.json and firestore.tf (Terraform). Use when: adding or removing a composite index, deploying index changes, recovering from out-of-band "firebase deploy --only firestore:indexes" that left Terraform state out of sync, verifying that live Firestore indexes match the JSON file, or resolving a "google_firestore_index.composite" + create failure in terraform apply. Keywords: firestore index, composite index, firebase deploy, terraform import, index drift, nextSyncAt, expire-trials, FAILED_PRECONDITION.'
argument-hint: 'What changed: "add <collection> (<field1>, <field2>)", "remove <collection>", "drift recover", or "verify".'
user-invocable: true
---

# Firestore Index Sync

Authoritative workflow for keeping `firebase/firestore.indexes.json`,
`firestore.tf`, and live Firestore composite indexes in sync.

## Canonical Relationship

```
fafa-iac/
├── firebase/
│   ├── firebase.json              ← points "indexes": "firestore.indexes.json"
│   └── firestore.indexes.json     ← THE SINGLE SOURCE OF TRUTH
└── firestore.tf
    local.firestore_indexes = jsondecode(file("${path.root}/firebase/firestore.indexes.json"))
    resource "google_firestore_index" "composite" {
      for_each = { for idx in local.firestore_indexes.indexes : "${idx.collectionGroup}#${join("-", [for f in idx.fields : f.fieldPath])}" => idx }
      ...
    }
```

**Both deployment paths read the same JSON.**

| Path | Command | State | Speed |
|---|---|---|---|
| **A — Firebase CLI** | `firebase deploy --only firestore:indexes` (from `firebase/`) | Bypasses Terraform | Fast |
| **B — Terraform** | `terraform apply` (from repo root) | State-tracked | Slower |

> **Rule**: Always deploy via **one path only per change**. Mixing paths causes
> drift — Firestore has the index but Terraform state doesn't, causing a failed
> `terraform apply` on the next run (index already exists).
>
> **Default for this repo: use Path B (Terraform).** Reserve Path A for
> production hotfixes only, and immediately run the drift-recovery workflow after.

## Safety Rules

1. Never edit `google_firestore_index` resources in `firestore.tf` directly —
   the `for_each` is fully auto-generated from the JSON. Only edit the JSON.
2. Never add indexes via the Firestore Console or `gcloud firestore indexes create`.
   Console-created indexes are not in state and not in the JSON.
3. Never remove an index from the JSON until you have confirmed no live query
   depends on it. A missing index for an active query causes
   `FAILED_PRECONDITION` in Cloud Functions (e.g. `expire-trials`).
4. `google_firestore_database.default` must **never** be replaced.
   If `terraform plan` proposes replace on the database, STOP — see
   [terraform-drift-sync](./../terraform-drift-sync/SKILL.md) invariant #3.

## Procedure

### A. Add a new composite index

1. **Edit the JSON** (canonical source):

   ```json
   // fafa-iac/firebase/firestore.indexes.json
   {
     "collectionGroup": "<collection>",
     "queryScope": "COLLECTION",
     "fields": [
       { "fieldPath": "<field1>", "order": "ASCENDING" },
       { "fieldPath": "<field2>", "order": "ASCENDING" }
     ]
   }
   ```

   Append the entry inside `"indexes": [ ... ]`. Do not add `__name__` —
   Firestore appends it implicitly. Match the pattern of existing entries.

2. **Validate JSON syntax**:

   ```bash
   python3 -c "import json,sys; json.load(open('firebase/firestore.indexes.json'))" && echo OK
   ```

3. **Terraform plan** — confirm exactly one `+ create` for the new index:

   ```bash
   cd /home/sp/code/project/fafa-iac
   terraform plan -no-color -target='google_firestore_index.composite'
   ```

   The new resource address will be
   `google_firestore_index.composite["<collectionGroup>#<field1>-<field2>"]`.
   If you see `-/+` or more changes than expected, stop and investigate.

4. **Terraform apply**:

   ```bash
   terraform apply -target='google_firestore_index.composite'
   ```

   Index build is async — Firestore starts building in the background.

5. **Wait for build completion** before deploying Cloud Functions that
   depend on this index:

   ```bash
   gcloud firestore indexes composite list --project=fafa-255a2 --format='table(name,state)' \
     | grep -v READY
   ```

   Repeat until no `CREATING` rows remain (typically 1–5 min for small
   collections, longer for millions of docs).

---

### B. Remove a composite index

1. **Verify no live query uses it.** Search all Cloud Functions and web
   API routes for the collection + field combination:

   ```bash
   grep -r "<collectionGroup>" /home/sp/code/project/SiveraV2/functions/src \
                               /home/sp/code/project/SiveraV2/apps/web/lib/server
   ```

   If any `.where()` chain matches the index fields, abort until the
   query is updated or the code is deployed without that query.

2. **Remove the JSON entry** (canonical source). Identify it by
   `collectionGroup` + `fields` combination.

3. `terraform plan -target='google_firestore_index.composite'`
   — confirm exactly one `- destroy`.

4. `terraform apply -target='google_firestore_index.composite'`

---

### C. Recover from out-of-band `firebase deploy` (drift)

Use this when someone ran `firebase deploy --only firestore:indexes`
without a subsequent `terraform apply`, leaving live indexes that are in
the JSON but not in Terraform state.

**Symptom**: `terraform plan` proposes `+ create` for an index that
already exists in Firestore, then `terraform apply` fails with
`"indexes/xxx already exists"`.

1. **List live composite indexes** and get their resource IDs:

   ```bash
   gcloud firestore indexes composite list \
     --project=fafa-255a2 \
     --database='(default)' \
     --format='value(name)'
   ```

   Each name has the format:
   `projects/fafa-255a2/databases/(default)/collectionGroups/<col>/indexes/<id>`

2. **Compute the Terraform address** for each drifted index. The key in
   `for_each` is `"<collectionGroup>#<fieldPath1>-<fieldPath2>-..."` —
   a human-readable stable key. You can compute it with:

   ```bash
   python3 - <<'EOF'
   import json
   data = json.load(open("firebase/firestore.indexes.json"))
   for idx in data["indexes"]:
       fields = "-".join(f["fieldPath"] for f in idx["fields"])
       key = f"{idx['collectionGroup']}#{fields}"
       print(key, "->", [f["fieldPath"] for f in idx["fields"]])
   EOF
   ```

   Match each key to the live index by collection + fields.

3. **Import each drifted index**:

   ```bash
   terraform import \
     'google_firestore_index.composite["<collectionGroup>#<field1>-<field2>"]' \
     'projects/fafa-255a2/databases/(default)/collectionGroups/<col>/indexes/<live-id>'
   ```

4. **Verify clean plan**:

   ```bash
   terraform plan -no-color -target='google_firestore_index.composite'
   ```

   Expected: `Plan: 0 to add, 0 to change, 0 to destroy.`

---

### D. Verify sync state (read-only)

Run this at any time to confirm JSON, Terraform state, and live Firestore
are all consistent.

```bash
# 1. Count entries in JSON
python3 -c "import json; d=json.load(open('firebase/firestore.indexes.json')); print(len(d['indexes']), 'entries in JSON')"

# 2. Count Terraform-managed indexes
terraform state list | grep 'google_firestore_index.composite' | wc -l

# 3. Count live Firestore composite indexes (excludes auto-created single-field)
gcloud firestore indexes composite list --project=fafa-255a2 --database='(default)' --format=json | python3 -c "import json,sys; print(len(json.load(sys.stdin)))"
```

All three counts should match. A mismatch means:
- JSON > Terraform state → drift from an out-of-band deploy (→ C above).
- Terraform state > JSON → an index was removed from JSON but Terraform state wasn't cleaned up (rerun `terraform apply`).
- Firestore > both → Console/gcloud-created index outside either managed path — delete it or add it to the JSON.

---

## Common Pitfalls

- **Reordering fields in the JSON changes the md5 key.** Terraform will
  `- destroy` the old address and `+ create` a new one. The net effect on
  the index definition may be identical, but Terraform will briefly delete it
  before recreating. Coordinate carefully in production.
- **Compact vs pretty JSON changes the md5.** `jsonencode` in Terraform uses
  compact format; the Python snippet above uses `separators=(',', ':')` to
  match. Don't pretty-print the JSON with extra spaces in the keys.
- **`firebase deploy` reads `firebase.json` in the `firebase/` subdirectory.**
  Run it from `fafa-iac/firebase/`, not the root:
  ```bash
  cd /home/sp/code/project/fafa-iac/firebase && firebase deploy --only firestore:indexes --project fafa-255a2
  ```
- **Single-field indexes are always auto-managed by Firestore.** Only composite
  (multi-field) indexes need to be in `firestore.indexes.json`. Never add a
  `fields` array with only one entry.
- **Index build is async.** `terraform apply` returns immediately after
  submitting. The index state will be `CREATING`. Queries that require the
  index will fail with `FAILED_PRECONDITION` until the state becomes `READY`.
  Always verify with `gcloud firestore indexes composite list` before routing
  traffic to a new Cloud Function that uses the index.

## References

- Canonical index file: [firebase/firestore.indexes.json](../../../firebase/firestore.indexes.json)
- Terraform consumer: [firestore.tf](../../../firestore.tf)
- Drift recovery (broader): [terraform-drift-sync](../terraform-drift-sync/SKILL.md)
- Firestore schema types: `packages/platforms/src/firestore-schema.ts` in the SiveraV2 repo

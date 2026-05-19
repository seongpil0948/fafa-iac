---
description: "Add a Cloud Firestore composite index to fafa-iac, deploy it, and verify the query that needed it. Use when a Firestore query throws FAILED_PRECONDITION 'The query requires an index', when Vercel function logs show a 'missing index' link, when a new query in apps/web/lib/server/queries/** or functions/src/** filters/orders on field combinations not yet in firebase/firestore.indexes.json, or when the user says 'add a firestore index' / '인덱스 추가'."
argument-hint: "<collection> <field1:asc|desc> <field2:asc|desc> ... — or paste the 'missing index' URL / error message"
agent: "agent"
---

# Add a Firestore Composite Index

Single-task: edit [firebase/firestore.indexes.json](../../firebase/firestore.indexes.json),
deploy it, and verify. The file is the source of truth — never define indexes
through Terraform or the Firebase console for this project.

## Inputs

`$ARGUMENTS` is one of:

1. A collection + field list, e.g. `campaignDailyMetrics uid:asc platform:asc date:desc`.
2. A pasted **missing index URL** from the error (preferred — it encodes the exact spec).
3. The full error string from Cloud Logging or Vercel logs.

If `$ARGUMENTS` is empty, ask the user for one of the above. Do **not** guess
field order — query operators (`==`, `in`, range, `orderBy`) determine it and
the wrong order silently fails to match the query.

## Preconditions

- Confirm the project is `fafa-255a2` and the user is authenticated:
  `gcloud config get-value project` and `firebase projects:list`.
- Confirm the offending query file path so the index can be cross-referenced
  in the PR description (`apps/web/lib/server/queries/**` or
  `functions/src/**`).
- Read existing entries in [firebase/firestore.indexes.json](../../firebase/firestore.indexes.json)
  to check for duplicates — Firestore rejects deploy if a logically identical
  index already exists.

## Steps

### 1. Parse the spec

If given a URL or error string, extract:

- `collectionGroup` (collection name, **not** a path).
- `queryScope` — almost always `COLLECTION`; use `COLLECTION_GROUP` only if
  the query uses `collectionGroup(...)`.
- Field list **in the exact order the error specifies**, each with
  `ASCENDING` / `DESCENDING`. Equality filters come first, then range/orderBy.

State the parsed spec back to the user before editing.

### 2. Edit `firebase/firestore.indexes.json`

Append the new entry to the `indexes` array, matching the existing formatting
(2-space indent, trailing comma rules of JSON, alphabetical-ish grouping by
`collectionGroup`). Example shape:

```json
{
  "collectionGroup": "<collection>",
  "queryScope": "COLLECTION",
  "fields": [
    { "fieldPath": "<f1>", "order": "ASCENDING" },
    { "fieldPath": "<f2>", "order": "DESCENDING" }
  ]
}
```

### 3. Validate locally

```bash
cd /home/sp/code/project/fafa-iac
jq . firebase/firestore.indexes.json > /dev/null   # JSON well-formed
```

### 4. Deploy (requires user confirmation)

State the command, get approval, run:

```bash
firebase deploy --only firestore:indexes --project fafa-255a2
```

Index builds are async; the CLI returns once submitted. Tell the user the
console URL to watch build progress:
`https://console.firebase.google.com/project/fafa-255a2/firestore/indexes`.

### 5. Verify

After the console shows the index `Enabled`:

- Re-run the failing query (or refresh the affected dashboard page).
- Confirm the previous error is gone in Cloud Logging or Vercel logs.

### 6. Commit

```bash
cd /home/sp/code/project/fafa-iac
git add firebase/firestore.indexes.json
git commit -m "firestore: add <collection>(<fields>) index for <query location>"
```

Push and open a PR. Do **not** force-push.

## Output Format

Reply with:

```
Parsed spec:    <collection> [<f1>:<dir>, <f2>:<dir>, ...] scope=<COLLECTION|COLLECTION_GROUP>
Duplicate check: none | matches index #N (abort)
Edit:           firebase/firestore.indexes.json (+<N> lines)
Deploy command: <exact command, awaiting confirmation>
Verification:   <how the user will confirm fix>
Commit message: <one line>
```

## Guardrails

- Never define indexes via Terraform or `google_firestore_index` — the project
  convention is JSON file + `firebase deploy`.
- Never delete or reorder existing index entries — Firestore treats reorder
  as delete+create and large collections may take hours to rebuild.
- Never enable `--force` flags on the deploy.
- If the missing-index error is for a query you don't recognize, **stop and
  ask** — adding indexes for ad-hoc queries pollutes the file and increases
  write costs (every write updates every matching index).

## References

- Existing indexes: [firebase/firestore.indexes.json](../../firebase/firestore.indexes.json)
- Index docs: https://firebase.google.com/docs/firestore/query-data/indexing
- Why this lives here, not Terraform: [fafa-iac AGENTS.md](../../AGENTS.md)
- Related: [SiveraV2 debug-background-sync skill](../../../SiveraV2/.github/skills/debug-background-sync/SKILL.md) §9

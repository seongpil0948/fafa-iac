---
description: "Use when running any terraform plan, apply, import, state mv, or destroy in fafa-iac. Enforces mandatory before/after graph capture (terraform graph > before.dot / after.dot) and diff review before and after every operation. Keywords: terraform graph, before after diff, plan apply import state drift verification, dot graph compare."
applyTo: "**/*.tf"
---

# Terraform Graph Verification (mandatory for every operation)

Before **and** after any `terraform plan`, `apply`, `import`, `state mv`, `state rm`, or `destroy`, capture the dependency graph and diff it. This detects unintended resource additions, removals, or rewiring that would not surface in a text diff of `.tf` files alone.

## Required Steps

### Before the operation

```bash
cd /home/sp/code/project/fafa-iac
terraform graph > before.dot
```

### After the operation (or after editing `.tf` files, before apply)

```bash
terraform graph > after.dot
diff before.dot after.dot
```

### Interpret the diff

| Diff output | Meaning |
|---|---|
| Empty | No structural change — safe to proceed |
| New `->` edge or node | A dependency or resource was added |
| Removed `->` edge or node | A resource or dependency was removed |
| Node renamed | A resource address changed (possible destroy+recreate) |

If the diff contains unexpected removals or renames of critical resources (`google_firestore_database`, `google_secret_manager_secret`, `google_cloudfunctions2_function`), **stop and investigate** before applying.

### Cleanup after review

```bash
rm -f before.dot after.dot
```

Do not commit `.dot` files to the repository.

## Per-operation Expected Diffs

| Operation | Expected graph diff |
|---|---|
| Add Firestore composite index | One new `google_firestore_index.composite[…]` node |
| Remove Firestore composite index | One removed node of the same form |
| `terraform import` only | **Empty diff** — import changes state, not config |
| Add Cloud Scheduler job | One new `google_cloud_scheduler_job.*` node |
| Add secret | One new `google_secret_manager_secret.*` node |
| Add IAM binding | New edge from resource to IAM member node |
| Any other operation | Exactly the nodes/edges matching `.tf` edits — no more |

## Hard Stops

- If `google_firestore_database.default` appears in the diff as a removal or rename → **abort**, do not apply.
- If a secret resource node disappears from the graph → **abort**, verify `prevent_destroy = true` is intact.
- If the diff is unexpectedly large (many nodes changed) when only a small `.tf` edit was made → investigate provider version drift or accidental `lifecycle` removal before proceeding.

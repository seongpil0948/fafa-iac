locals {
  firestore_indexes = jsondecode(file("${path.root}/firebase/firestore.indexes.json"))
  firestore_rules   = file("${path.root}/firebase/firestore.rules")
}

# Firebase project — already exists. Imported into state on bootstrap.
resource "google_firebase_project" "this" {
  provider = google-beta
  project  = var.project_id
}

# Existing Firebase web app — imported on bootstrap.
resource "google_firebase_web_app" "web" {
  provider     = google-beta
  project      = var.project_id
  display_name = "fafa-web"

  depends_on = [google_firebase_project.this]

  lifecycle {
    # appId is set by import; display_name may diverge from what was created in the console.
    ignore_changes = [display_name]
  }
}

# Firestore (Native) in asia-northeast3.
#
# CMEK is intentionally OPTIONAL here: GCP only lets you choose CMEK at
# database-creation time, and the production database was first provisioned
# via the Firebase Console (non-CMEK). Switching to CMEK after the fact
# requires destroy + recreate, which we are not willing to risk on a live
# database. The KMS module still provisions the CMEK key for future use
# (e.g. a second database, or a future re-provisioning window).
#
# If you ever need CMEK on a NEW database, set `var.firestore_cmek_key_name`
# to the crypto key id and uncomment the cmek_config block before the first
# apply on that database.
resource "google_firestore_database" "default" {
  provider                    = google-beta
  project                     = var.project_id
  name                        = "(default)"
  location_id                 = var.region
  type                        = "FIRESTORE_NATIVE"
  concurrency_mode            = "OPTIMISTIC"
  app_engine_integration_mode = "DISABLED"
  delete_protection_state     = "DELETE_PROTECTION_ENABLED"

  # dynamic cmek_config — populated only when firestore_cmek_key_name is non-empty.
  # On an imported, non-CMEK database this stays empty and matches reality.
  dynamic "cmek_config" {
    for_each = var.firestore_cmek_key_name == "" ? [] : [1]
    content {
      kms_key_name = var.firestore_cmek_key_name
    }
  }

  lifecycle {
    # Database type / location can only be set at creation. Once imported,
    # these must never re-trigger replacement, even if someone tweaks the
    # variables. CMEK is also immutable post-creation.
    ignore_changes = [
      type,
      location_id,
      cmek_config,
    ]
  }

  depends_on = [google_firebase_project.this]
}

resource "google_firestore_index" "composite" {
  provider = google-beta

  # Stable key: collectionGroup + field paths. More resilient to JSON
  # re-ordering than md5(jsonencode(idx)) — state mv is not needed when
  # only non-structural metadata (e.g. comments) changes in the JSON.
  for_each = {
    for idx in local.firestore_indexes.indexes :
    "${idx.collectionGroup}#${join("-", [for f in idx.fields : f.fieldPath])}" => idx
  }

  project     = var.project_id
  database    = google_firestore_database.default.name
  collection  = each.value.collectionGroup
  query_scope = try(each.value.queryScope, null)

  dynamic "fields" {
    for_each = each.value.fields

    content {
      field_path   = try(fields.value.fieldPath, null)
      order        = try(fields.value.order, null)
      array_config = try(fields.value.arrayConfig, null)
    }
  }
}

# Single-field index exemptions, driven by the `fieldOverrides` array in
# firestore.indexes.json.
#
# Firestore indexes every field by default and rejects a write whose index
# entry is too large. `amazonMetricCache` stores a whole downloaded report on
# one document (gzipped in `dataGz`; `data` is the pre-gzip shape still
# draining via TTL) and neither field is ever queried on, so both are exempted.
# Without this the sync-side report cache cannot be written at all for any
# non-trivial account.
#
# NOTE: applies only to the fields listed here — `expiresAt` keeps the TTL
# policy set by scripts/apply-ttl.sh, which this does not touch.
resource "google_firestore_field" "index_exemptions" {
  provider = google-beta

  for_each = {
    for f in try(local.firestore_indexes.fieldOverrides, []) :
    "${f.collectionGroup}#${f.fieldPath}" => f
  }

  project    = var.project_id
  database   = google_firestore_database.default.name
  collection = each.value.collectionGroup
  field      = each.value.fieldPath

  # Empty index_config = no single-field indexes for this field.
  index_config {}
}

resource "google_firebaserules_ruleset" "firestore" {
  provider = google-beta
  project  = var.project_id

  source {
    files {
      name    = "firestore.rules"
      content = local.firestore_rules
    }
  }
}

resource "google_firebaserules_release" "firestore" {
  provider     = google-beta
  project      = var.project_id
  name         = "cloud.firestore"
  ruleset_name = google_firebaserules_ruleset.firestore.name
}

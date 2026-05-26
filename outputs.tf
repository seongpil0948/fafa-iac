output "project_id" {
  value = var.project_id
}

output "region" {
  value = var.region
}

output "function_urls" {
  value = { for k, f in google_cloudfunctions2_function.https : k => f.service_config[0].uri }
}

output "sync_runner_sa_email" {
  value = google_service_account.sync_runner.email
}

output "scheduler_invoker_sa_email" {
  value = google_service_account.scheduler_invoker.email
}

output "vercel_app_sa_email" {
  description = "Create the JSON key for this SA manually via gcloud and paste into Vercel env GOOGLE_APPLICATION_CREDENTIALS_JSON. Never commit."
  value       = google_service_account.vercel_app.email
}

output "kms_crypto_key_id" {
  value = google_kms_crypto_key.firestore.id
}

output "platform_secret_refs" {
  description = "Comma-joined --set-secrets value passed to gcloud for sync-credential; consumed by functions/scripts/deploy-all.sh."
  value = join(",", [
    for name in local.platform_secret_names :
    "${name}=projects/${var.project_id}/secrets/${name}/versions/latest"
  ])
}

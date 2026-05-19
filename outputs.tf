output "project_id" {
  value = var.project_id
}

output "region" {
  value = var.region
}

output "function_urls" {
  value = module.functions.function_urls
}

output "sync_runner_sa_email" {
  value = module.iam.sync_runner_email
}

output "scheduler_invoker_sa_email" {
  value = module.iam.scheduler_invoker_email
}

output "vercel_app_sa_email" {
  description = "Create the JSON key for this SA manually via gcloud and paste into Vercel env GOOGLE_APPLICATION_CREDENTIALS_JSON. Never commit."
  value       = module.iam.vercel_app_email
}

output "kms_crypto_key_id" {
  value = module.kms.crypto_key_id
}

output "platform_secret_refs" {
  description = "Comma-joined --set-secrets value passed to gcloud for sync-credential; consumed by functions/scripts/deploy-all.sh."
  value       = module.secrets.secret_refs_for_gcloud
}

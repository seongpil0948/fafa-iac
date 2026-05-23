locals {
  function_names = {
    sync_on_connect       = "sync-on-connect"
    sync_on_demand        = "sync-on-demand"
    sync_dispatch         = "sync-dispatch"
    sync_credential       = "sync-credential"
    send_fcm              = "send-fcm"
    cleanup               = "cleanup"
    expire_trials         = "expire-trials"
    process_amazon_report = "process-amazon-report"
  }
}

module "project" {
  source     = "./modules/project"
  project_id = var.project_id
}

module "kms" {
  source     = "./modules/kms"
  project_id = var.project_id
  region     = var.region

  depends_on = [module.project]
}

module "firestore" {
  source     = "./modules/firestore"
  project_id = var.project_id
  region     = var.region
  # The current (default) database was provisioned via the Firebase Console
  # without CMEK. Firestore CMEK is create-time-only, so we leave this empty.
  # See modules/firestore/main.tf for how to switch on CMEK for a new DB.
  cmek_key_name = ""

  depends_on = [module.kms]
}

module "iam" {
  source     = "./modules/iam"
  project_id = var.project_id

  depends_on = [module.project]
}

module "pubsub" {
  source               = "./modules/pubsub"
  project_id           = var.project_id
  sync_runner_sa_email = module.iam.sync_runner_email

  depends_on = [module.iam]
}

module "functions" {
  source                = "./modules/functions"
  project_id            = var.project_id
  region                = var.region
  runtime               = var.functions_runtime
  service_account_email = module.iam.sync_runner_email
  function_names        = local.function_names
  pubsub_topics = {
    sync_credential = module.pubsub.sync_credential_topic_id
    fcm_send        = module.pubsub.fcm_send_topic_id
    amazon_report   = module.pubsub.amazon_report_topic_id
  }

  depends_on = [module.firestore, module.pubsub]
}

# Allow the Vercel app SA to invoke sync-on-connect and sync-on-demand.
# sync-on-demand powers the dashboard "지금 동기화" button; the Vercel route
# mints an OIDC ID token via sa-vercel-app and POSTs {uid, credentialId}.
resource "google_cloud_run_v2_service_iam_member" "vercel_invokes_sync_on_connect" {
  project  = var.project_id
  location = var.region
  name     = module.functions.cloud_run_service_names[local.function_names.sync_on_connect]
  role     = "roles/run.invoker"
  member   = "serviceAccount:${module.iam.vercel_app_email}"
}

resource "google_cloud_run_v2_service_iam_member" "vercel_invokes_sync_on_demand" {
  project  = var.project_id
  location = var.region
  name     = module.functions.cloud_run_service_names[local.function_names.sync_on_demand]
  role     = "roles/run.invoker"
  member   = "serviceAccount:${module.iam.vercel_app_email}"
}

# Allow the Scheduler SA to invoke the three scheduled HTTPS functions.
resource "google_cloud_run_v2_service_iam_member" "scheduler_invokes_https_functions" {
  for_each = toset([
    local.function_names.sync_dispatch,
    local.function_names.cleanup,
    local.function_names.expire_trials,
  ])

  project  = var.project_id
  location = var.region
  name     = module.functions.cloud_run_service_names[each.value]
  role     = "roles/run.invoker"
  member   = "serviceAccount:${module.iam.scheduler_invoker_email}"
}

module "secrets" {
  source               = "./modules/secrets"
  project_id           = var.project_id
  sync_runner_sa_email = module.iam.sync_runner_email

  depends_on = [module.project, module.iam]
}

module "scheduler" {
  source                 = "./modules/scheduler"
  project_id             = var.project_id
  region                 = var.region
  timezone               = var.scheduler_timezone
  invoker_sa_email       = module.iam.scheduler_invoker_email
  sync_dispatch_url      = module.functions.function_urls[local.function_names.sync_dispatch]
  cleanup_url            = module.functions.function_urls[local.function_names.cleanup]
  expire_trials_url      = module.functions.function_urls[local.function_names.expire_trials]
  sync_dispatch_schedule = var.sync_dispatch_schedule
  cleanup_schedule       = var.cleanup_schedule
  expire_trials_schedule = var.expire_trials_schedule

  depends_on = [
    google_cloud_run_v2_service_iam_member.scheduler_invokes_https_functions,
  ]
}

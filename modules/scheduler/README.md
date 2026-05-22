# module: scheduler

Provisions Cloud Scheduler jobs that invoke Cloud Functions via OIDC-authenticated HTTP.

## Jobs

| Job | Schedule | Target |
|-----|----------|--------|
| `sync-dispatch` | `var.sync_dispatch_schedule` | `var.sync_dispatch_url` |
| `cleanup` | `var.cleanup_schedule` | `var.cleanup_url` |
| `expire-trials` | `var.expire_trials_schedule` | `var.expire_trials_url` |

## Key settings

- `attempt_deadline = var.function_timeout_seconds + 60` (default 600s). This must exceed the function's own timeout so the scheduler does not prematurely retry a still-running function.
- `retry_config`: `retry_count = var.retry_count` (default 3), `min_backoff_duration = "5s"`, `max_backoff_duration = "60s"`.
- All jobs POST `{}` with `Content-Type: application/json`.
- OIDC token audience is set to the function URL.

## URL validation

All three URL variables have a `validation` block that enforces `https://` prefix — plain HTTP is rejected at `terraform validate` time.

## Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `project_id` | `string` | — | GCP project ID. |
| `region` | `string` | — | Scheduler region. |
| `timezone` | `string` | — | IANA timezone for cron expressions. |
| `invoker_sa_email` | `string` | — | SA granted `roles/run.invoker`. |
| `sync_dispatch_url` | `string` | — | HTTPS URL of sync-dispatch function. |
| `cleanup_url` | `string` | — | HTTPS URL of cleanup function. |
| `expire_trials_url` | `string` | — | HTTPS URL of expire-trials function. |
| `sync_dispatch_schedule` | `string` | — | Cron expression for sync-dispatch. |
| `cleanup_schedule` | `string` | — | Cron expression for cleanup. |
| `expire_trials_schedule` | `string` | — | Cron expression for expire-trials. |
| `function_timeout_seconds` | `number` | `540` | Function timeout; sets `attempt_deadline`. |
| `retry_count` | `number` | `3` | Max scheduler retries per execution. |

## Outputs

None.

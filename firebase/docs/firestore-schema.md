# Firestore Schema — SiveraV2

All collections are accessed exclusively via the Admin SDK (Next.js server / Cloud Functions). Client SDK access is denied by [firestore.rules](../firestore.rules) except for `fcmDevices/{uid}/devices/{deviceId}` (browser registers its own push token).

Encryption-at-rest: CMEK (KMS key `projects/fafa-255a2/locations/asia-northeast3/keyRings/fafa-firestore/cryptoKeys/firestore-cmek`). No application-layer envelope encryption — OAuth tokens are stored as plaintext fields and protected by CMEK + IAM.

## Collections

### `users/{uid}`
Replaces `profiles` + `subscriptions`. UID matches Firebase Auth UID.
```ts
{
  uid: string,
  email: string,
  displayName: string | null,
  locale: 'ko' | 'en',
  // subscription
  tier: 'trial' | 'pro',
  status: 'active' | 'canceled' | 'past_due' | 'expired',
  trialEndsAt: Timestamp | null,
  paypalSubscriptionId: string | null,
  paypalCustomerId: string | null,
  currentPeriodEnd: Timestamp | null,
  canceledAt: Timestamp | null,
  // Active paid plan when tier === 'pro' (optional; null/absent on trial).
  // Drives upgrade/downgrade UX. Written by the mock-checkout flow in
  // apps/web/lib/server/mutations/subscription.ts (pending real PayPal billing).
  billingPlan?: 'pro_monthly' | 'pro_yearly' | null,
  // Cancellation scheduled. tier/status stay pro/active so access is RETAINED
  // until currentPeriodEnd ("cancel at period end"); a period-end job — or the
  // defensive web check — then drops access. Absent/false = auto-renewing.
  cancelAtPeriodEnd?: boolean,
  createdAt: Timestamp,
  updatedAt: Timestamp,
}
```

### `oauthStates/{state}`
Short-lived CSRF token for OAuth flows. TTL field: `expiresAt` (10 min).
```ts
{
  state: string,            // doc id
  uid: string,
  platform: 'google' | 'meta' | 'amazon' | 'tiktok',
  redirectTo: string | null,
  expiresAt: Timestamp,
  createdAt: Timestamp,
}
```

### `credentials/{credentialId}`
Per-platform OAuth credential. **`credentialId`** = `credentialDocId(uid, platform, accountId)` → `${uid}:${platform}:${accountId}` (deterministic, enforces uniqueness without a separate transaction).
```ts
{
  uid: string,
  platform: 'google' | 'meta' | 'amazon' | 'tiktok',
  accountId: string,
  accountName: string,
  label: string | null,
  accessToken: string,      // plaintext at rest (CMEK is NOT enabled on the live DB)
  refreshToken: string | null,
  expiresAt: Timestamp | null,
  scope: string | null,
  meta: Record<string, unknown>,   // platform-specific (marketplace, profile_id, etc.)
  isActive: boolean,
  lastSyncedAt: Timestamp | null,
  nextSyncAt: Timestamp | null,    // drives sync-dispatch query; backs off on repeated failure
  lastSyncStatus: 'idle' | 'pending' | 'success' | 'partial' | 'error' | 'auth_required',
  lastSyncError: string | null,
  consecutiveFailures: number,
  // Short-lived idempotency lease held by an in-flight sync-credential run
  // (transaction-acquired, released on every terminal path). A redelivered
  // Pub/Sub message that finds a non-expired lease aborts instead of
  // double-writing. Absent/null when idle.
  syncLease?: { runId: string, expiresAt: Timestamp } | null,
  createdAt: Timestamp,
  updatedAt: Timestamp,
}
```

### `dailyMetrics/{uid}_{platform}_{accountId}_{YYYY-MM-DD}`
Pre-aggregated daily totals per ad account. Written by `syncCredential` CF.
```ts
{
  uid: string,
  platform: string,
  accountId: string,
  date: string,             // YYYY-MM-DD (also indexed)
  currency: string,
  impressions: number,
  clicks: number,
  spend: number,
  conversions: number,
  revenue: number,
  ctr: number,              // derived; stored to avoid recompute
  cpc: number,
  cpm: number,
  roas: number,
  updatedAt: Timestamp,
}
```

### `campaigns/{uid}_{platform}_{accountId}_{campaignId}`
Campaign metadata snapshot.
```ts
{
  uid: string,
  platform: string,
  accountId: string,
  campaignId: string,
  name: string,
  status: string,
  objective: string | null,
  budget: number | null,
  budgetType: 'daily' | 'lifetime' | null,
  startDate: string | null, // YYYY-MM-DD
  endDate: string | null,
  meta: Record<string, unknown>,
  updatedAt: Timestamp,
}
```

### `campaignDailyMetrics/{uid}_{platform}_{accountId}_{campaignId}_{YYYY-MM-DD}`
Per-campaign daily roll-up. Powers TopPerformers.
```ts
{
  uid: string,
  platform: string,
  accountId: string,
  campaignId: string,
  campaignName: string,    // denormalized to avoid join
  date: string,
  impressions: number,
  clicks: number,
  spend: number,
  conversions: number,
  revenue: number,
  updatedAt: Timestamp,
}
```

### `syncRuns/{runId}`
One doc per sync attempt. TTL field: `expiresAt` (90 days).
```ts
{
  runId: string,
  uid: string,
  credentialId: string,
  platform: string,
  trigger: 'on_connect' | 'scheduled' | 'manual',
  status: 'pending' | 'success' | 'error',
  startedAt: Timestamp,
  finishedAt: Timestamp | null,
  itemsWritten: number,
  error: string | null,
  expiresAt: Timestamp,
}
```

### `amazonReportCache/{hash}`
Replaces `amazon_report_cache` table. `hash` = `sha1(credentialId + ':' + reportType + ':' + startDate + ':' + endDate)`. TTL field: `expiresAt` (24 h).
```ts
{
  hash: string,
  uid: string,
  credentialId: string,
  reportType: string,
  startDate: string,
  endDate: string,
  amazonReportId: string,
  status: 'pending' | 'success' | 'error',
  data: unknown[] | null,
  expiresAt: Timestamp,
  createdAt: Timestamp,
  updatedAt: Timestamp,
}
```

Meta-specific note: credentials store the long-lived user access token returned
from the OAuth callback, plus `expiresAt` for the token lifetime. The sync
worker can silently re-exchange the token before expiry; after expiry the
credential transitions to `auth_required`.

### `usageLogs/{logId}`
Append-only event log. TTL field: `expiresAt` (90 days).
```ts
{
  uid: string,
  platform: string,
  action: string,
  metadata: Record<string, unknown>,
  expiresAt: Timestamp,
  createdAt: Timestamp,
}
```

### `tableSettings/{uid}/platforms/{platform}/views/{view}`
Replaces `user_meta_table_settings` + `user_google_table_settings`. `view` ∈ `campaign | adset | adgroup | ad`.
```ts
{
  uid: string,
  platform: 'meta' | 'google',
  view: string,
  columns: unknown[],
  sort: unknown[],
  preset: string | null,
  updatedAt: Timestamp,
}
```

### `tablePresets/{uid}/platforms/{platform}/presets/{presetId}`
Replaces `user_*_table_presets`.
```ts
{
  uid: string,
  platform: 'meta' | 'google',
  view: string,
  name: string,
  columns: unknown[],
  sort: unknown[],
  createdAt: Timestamp,
  updatedAt: Timestamp,
}
```

### `fcmDevices/{uid}/devices/{deviceId}`
Browser-registered push tokens. **Only client-writable collection**.
```ts
{
  uid: string,
  deviceId: string,
  token: string,
  userAgent: string,
  createdAt: Timestamp,
  lastSeenAt: Timestamp,
}
```

## TTL Policies

Configure via gcloud / Firebase console (no Firestore Admin API surface in Terraform `google_firestore_field` for TTL on nested fields yet — see fafa-iac TTL note):

| Collection | Field |
|---|---|
| `oauthStates` | `expiresAt` |
| `syncRuns` | `expiresAt` |
| `amazonReportCache` | `expiresAt` |
| `usageLogs` | `expiresAt` |

Set with:
```bash
gcloud firestore fields ttls update expiresAt \
  --collection-group=oauthStates --enable-ttl --project=fafa-255a2
# repeat for syncRuns, amazonReportCache, usageLogs
```

## Index notes

See [firestore.indexes.json](../firestore.indexes.json). The 90-day dashboard query is `where uid == X and date >= cutoff` ordered by `date desc` — served by the composite index `(uid asc, date desc)` on `dailyMetrics`.

The sync-dispatch query is `where isActive == true and nextSyncAt <= now()` — served by the composite index `(isActive asc, nextSyncAt asc)` on `credentials`.

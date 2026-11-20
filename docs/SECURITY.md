# Security & Hardening

Status: the template is a starting point. These layers close real gaps before exposing to untrusted users.

## Threat model

- Unauthorized access to the dataset via the public chat URL
- A user querying data they shouldn't see (no RLS enforcement in DAX by default)
- Prompt injection triggering a `refresh_dataset` write op without authorization
- Service Principal secret leakage → full dataset read access for attackers
- Rate abuse hitting Power BI's 120 req/min limit and breaking the service for other apps

## Layered defenses (in order of impact)

### Layer 1 — Authenticate the chat trigger

**Problem:** `public: true` on the Chat Trigger = anyone with the URL queries your Power BI.

**Fix:** `public: false`, embed via `@n8n/chat` in your own app, pass JWT in `metadata`. Or put the webhook behind Cloudflare Access / Authelia / nginx basic auth.

### Layer 2 — Enforce Power BI RLS via `impersonatedUserName`

Power BI's `executeQueries` API accepts an `impersonatedUserName` in the request body. When set, DAX runs under that user's Row-Level Security role. This is the only real multi-tenant boundary for Power BI.

Requirements:
- The dataset must have RLS roles defined (e.g. `[Region] = USERPRINCIPALNAME()`).
- The Service Principal must have "Admin" or "Member" on the workspace (Viewer can't impersonate).

Modify the DAX sub-workflow's `Run DAX via REST API` node body to:

```json
{
  "queries": [{ "query": "<DAX>" }],
  "impersonatedUserName": "{{ $json.impersonatedUserName }}",
  "serializerSettings": { "includeNulls": true }
}
```

And pass the user's UPN from the chat metadata through the tool call chain:

```
Chat Trigger (metadata.user_email)
  → Agent system prompt: "You are operating as <user_email>."
  → run_dax sub: passes impersonatedUserName through to the REST call
```

The agent itself cannot bypass this — Power BI filters the rows server-side.

### Layer 3 — Scope the Service Principal as narrowly as possible

- Don't use a tenant-admin Service Principal. Create one dedicated for this agent.
- Add it only to the specific workspace(s) it needs. Never "Admin" on the whole tenant.
- **Role:** Member for read-only dataset access. Contributor adds write perms on workspace items — only needed if `refresh_dataset` is enabled.
- Consider "Dataset-only" access if your Power BI tier supports it (Build permission on the dataset, nothing else on the workspace).

### Layer 4 — Guard `refresh_dataset`

`refresh_dataset` is a write operation. Attackers exploiting prompt injection could trigger costly refreshes.

Options from weakest to strongest:
- **Prompt-level:** system prompt requires explicit user consent. (Current default — not sufficient against injection.)
- **Keyword gate:** add a regex check in the tool — only allow if the prompt contains `refresh now` literally.
- **Second-factor confirm:** have the agent respond with a confirmation prompt and only call `refresh_dataset` after the user responds "yes, refresh". Requires an intermediate state node.
- **Remove the tool entirely** for untrusted users — let admins trigger refreshes via a separate admin-only workflow.

### Layer 5 — Rotate secrets; never commit them

- Azure AD client secrets expire. Calendar a 30-day-before-expiry reminder.
- The n8n credential stores the secret encrypted. Never export credentials to JSON / commit the full credential objects to Git.
- `.gitignore` in this repo blocks `.env`, `credentials.json`, etc. Verify before pushing.

### Layer 6 — Audit log

Add a Postgres node at the start of the main workflow:

```sql
INSERT INTO public.pbi_agent_audit (user_id, session_id, prompt, group_id, dataset_id, ts)
VALUES ($1, $2, $3, $4, $5, now());
```

Every prompt is captured. Rate-limit check in same node:

```sql
SELECT count(*) FROM public.pbi_agent_audit
WHERE user_id = $1 AND ts > now() - interval '1 minute';
```

If > 20, short-circuit and return a rate-limit message.

### Layer 7 — Power BI API rate limiting

Power BI throttles at 120 req/min per SP. Hundreds of concurrent chats will hit the cap.

Mitigations:
- **Cache metadata:** `list_tables_and_measures` output is stable across turns — cache it in Postgres keyed by `dataset_id`, refresh hourly. Saves 1 API call per conversation.
- **Queue refresh requests:** don't call `/refreshes` more than once per N minutes per dataset.
- **Multiple SPs:** for high-concurrency scenarios, round-robin across several Service Principals.

### Layer 8 — Output filter

Code node after the agent scans the final response for:
- Email addresses that don't match the authenticated user's tenant
- Raw DAX containing `CREDENTIAL`, `KEY`, or other sensitive keywords
- Model metadata that shouldn't leak (role names, hidden measures)

If matched, return a generic error and log.

### Layer 9 — Cost cap + agent bounds

- OpenRouter monthly spend cap on the API key.
- `maxIterations: 8` instead of 12 (cuts runaway loops).
- `contextWindowLength: 10` on memory to cap per-turn tokens.

## Priority

If implementing only some:

1. **Layer 1** (authenticate the URL) and **Layer 2** (`impersonatedUserName` + RLS) — without these, the agent is an open data exfil vector for authenticated Power BI users.
2. **Layer 4** (guard refresh) — cheap to add, prevents obvious abuse.
3. **Layer 3** (scoped SP) — one-time setup cost, massive blast-radius reduction if keys leak.
4. **Layers 5-9** — operational hygiene.

## Reporting security issues

Open a private security advisory on GitHub. 5-day response target.

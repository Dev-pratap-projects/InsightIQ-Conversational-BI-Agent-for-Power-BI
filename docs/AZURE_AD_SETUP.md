# Azure AD + Power BI Setup

One-time setup to let the agent call the Power BI REST API as a Service Principal. ~10 minutes.

## Prerequisites

- Azure AD tenant admin OR "Cloud Application Administrator" / "Application Administrator" role (to register the app)
- Power BI admin rights in your tenant (to enable service principals) OR a Power BI admin willing to run the toggle
- Access to the Power BI workspace whose dataset you want the agent to read

## 1. Register the Azure AD application

1. Go to https://portal.azure.com → **Microsoft Entra ID** (formerly Azure AD).
2. **App registrations** → **New registration**.
3. Name: `n8n-powerbi-agent`. Supported account types: **Single tenant**. Redirect URI: leave blank. → **Register**.
4. On the app's Overview page, copy:
   - **Application (client) ID**
   - **Directory (tenant) ID**

## 2. Create a client secret

1. **Certificates & secrets** → **Client secrets** → **New client secret**.
2. Description: `n8n-pbi-agent`, expires: 24 months (rotate before it expires).
3. **Copy the Value** immediately. You can't see it again after leaving the page.

## 3. (Optional) Create a security group for Power BI access

Power BI's service-principal toggle is often scoped to a specific security group.

1. Entra ID → **Groups** → **New group**. Type: `Security`. Name: `PowerBIApiServicePrincipals`.
2. **Members** → Add the app you just registered.

Skip this step if your admin enables service principals tenant-wide.

## 4. Enable service principals in Power BI

1. https://app.powerbi.com → gear icon → **Admin portal** → **Tenant settings**.
2. Scroll to **Developer settings** → **Service principals can use Power BI APIs**.
3. Enable it. If your admin wants to restrict: set "Apply to specific security groups" → `PowerBIApiServicePrincipals`.
4. Also enable **Allow service principals to use Power BI APIs** under **Integration settings**.
5. Save.

> Settings changes take ~15 minutes to propagate.

## 5. Add the Service Principal to your workspace

1. https://app.powerbi.com → open the target workspace (the one containing your dataset).
2. **Access** (top-right).
3. Add members → search by the app name (`n8n-powerbi-agent`) → role: **Member** or **Contributor**.
4. Add.

> For *read-only* agent behavior, consider using **Viewer** instead — but Viewer can't call `executeQueries` in many setups, so test first.

## 6. Grab the workspace and dataset GUIDs

- **Workspace GUID**: open the workspace in the browser. The URL is `https://app.powerbi.com/groups/<GUID>/list`. Copy the `<GUID>`.
- **Dataset GUID**: click the dataset → **Settings** → the URL contains `?datasetObjectId=<GUID>`. Or from the workspace list, hover "..." on the dataset → "Settings" → the panel title shows the GUID.

## 7. Create the n8n credential

In n8n → **Credentials** → **New** → search "Microsoft OAuth2 API" or "OAuth2 API" (generic). Use whichever your n8n version offers; fill it like this:

| Field | Value |
|---|---|
| **Grant Type** | `Client Credentials` |
| **Access Token URL** | `https://login.microsoftonline.com/<TENANT_ID>/oauth2/v2.0/token` |
| **Client ID** | from step 1 |
| **Client Secret** | from step 2 |
| **Scope** | `https://analysis.windows.net/powerbi/api/.default` |
| **Authentication** | `Body` |

Click **Test**. If you see "Connection tested successfully" you're done.

## 8. Verify with a manual REST call (optional)

```bash
# Get a token
TOKEN=$(curl -s -X POST "https://login.microsoftonline.com/<TENANT_ID>/oauth2/v2.0/token" \
  -d "grant_type=client_credentials" \
  -d "client_id=<CLIENT_ID>" \
  -d "client_secret=<CLIENT_SECRET>" \
  -d "scope=https://analysis.windows.net/powerbi/api/.default" | jq -r .access_token)

# List datasets in your workspace
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://api.powerbi.com/v1.0/myorg/groups/<GROUP_ID>/datasets" | jq '.value[] | {name, id}'

# Run a quick DAX
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "https://api.powerbi.com/v1.0/myorg/groups/<GROUP_ID>/datasets/<DATASET_ID>/executeQueries" \
  -d '{"queries":[{"query":"EVALUATE TOPN(5, INFO.TABLES())"}]}'
```

If the last call returns rows, your agent will work.

## Common errors

| Error | Cause | Fix |
|---|---|---|
| `AADSTS700016: Application not found` | Wrong client ID | Copy from App Registration Overview, not the secret |
| `401 Unauthorized` on executeQueries | SP not added to workspace | Step 5 |
| `Feature DatasetExecuteQueries not available` | Legacy workspace | Migrate dataset to a modern workspace |
| `PowerBINotAuthorizedToAccessResource` | Tenant toggle not propagated | Wait 15 min, try again |
| `invalid_scope` when getting token | Scope typo | Must be exactly `https://analysis.windows.net/powerbi/api/.default` |

## Rotation

Client secrets expire. Put a reminder for 30 days before expiry. To rotate:
1. Create a new client secret in step 2.
2. Update the n8n credential with the new value.
3. Delete the old secret after confirming the new one works.

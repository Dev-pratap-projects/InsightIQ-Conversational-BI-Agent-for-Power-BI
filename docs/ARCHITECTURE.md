# Architecture

How the Power BI agent works under the hood.

## High-level

Same shape as the Supabase sibling: LangChain Tools Agent (ReAct loop), Postgres chat memory, tool-call fanout. The difference is everything beyond the agent itself — query language, auth, metadata model.

```
user message
     │
     ▼
load memory (last 10 messages for this sessionId)
     │
     ▼
┌────────────── agent loop (max 12 iterations) ──────────────┐
│                                                             │
│   LLM call (Claude Sonnet 4.6 via OpenRouter)               │
│        │                                                    │
│        ├─ final answer ─▶ return to user                    │
│        │                                                    │
│        └─ tool call ─▶ execute ─▶ feed result back ──┐      │
│                                                       │      │
│                                                       ▼      │
│                                           next iteration     │
└─────────────────────────────────────────────────────────────┘
```

## Components

### Chat Trigger
Same as Supabase version — hosted chat mode, `sessionId` key for memory isolation.

### Config (Set node)
Pinned `group_id` and `dataset_id` for the workspace + dataset the agent operates on. All tools reference these via `$('Config').item.json.group_id`. Swap values once, agent targets a new model.

### The Agent
LangChain Tools Agent. System prompt is DAX-specific: teaches `EVALUATE`, `SUMMARIZECOLUMNS`, `CALCULATE`, favors existing measures over ad-hoc aggregations.

### LLM + Memory
- OpenRouter → Claude Sonnet 4.6 (tool-calling model).
- Postgres Chat Memory → `n8n_chat_histories` table, last 10 messages.

## The 6 tools

### 1. `list_tables_and_measures` (HTTP Request Tool)
One REST call to `/executeQueries` with:
```dax
EVALUATE UNION(
  SELECTCOLUMNS(INFO.TABLES(),   "kind", "table",   "name", [Name], "description", [Description]),
  SELECTCOLUMNS(INFO.MEASURES(), "kind", "measure", "name", [Name], "description", [Description])
)
```
Returns both object types in one flat result. `INFO.TABLES()` / `INFO.MEASURES()` are DAX data management views — no admin privileges needed, works on any dataset the SP can read.

### 2. `get_table_columns` (HTTP Request Tool)
```dax
EVALUATE FILTER(
  SELECTCOLUMNS(INFO.COLUMNS(),
    "Table", [Table],
    "Column", [ExplicitName],
    "DataType", [ExplicitDataType],
    "IsKey", [IsKey],
    "Description", [Description]
  ),
  [Table] = "<TableName from $fromAI>"
)
```
Parameterized via `$fromAI` — the agent picks which table to inspect.

### 3. `run_dax` (Tool Workflow → `[PBI Sub] Run DAX with Row Cap`)

Flow: trigger → HTTP POST executeQueries → Code (flatten + cap).

**Why a sub-workflow?**
- **Response flattening:** Power BI returns `{"[Customer].[Country]": "Saudi Arabia"}`. The Code node strips `[Table].[Column]` brackets to just `Country`, so downstream table rendering and chart labels are clean.
- **Row cap:** 200 rows max, adds `truncated: true` + `total_rows` + human-readable note. Prevents token explosion from unbounded DAX.
- **Future hook point:** audit logging, query rewriting, RLS impersonation all belong here.

### 4. `create_chart` (Tool Workflow → `[PBI Sub] Generate Chart from Data`)
Identical pattern to the Supabase version — takes simple primitives (`chart_type`, `title`, `labels`, `series`), Code node assembles the Chart.js spec, HTTP to QuickChart. Full Chart.js config as one JSON string proved unreliable under memory pressure (parse errors ~5-10%).

### 5. `refresh_dataset` (HTTP Request Tool)
```
POST /v1.0/myorg/groups/{group_id}/datasets/{dataset_id}/refreshes
Body: {"notifyOption": "NoNotification"}
```
Returns 202 Accepted if queued. The agent is instructed to call this ONLY on explicit user request.

### 6. `think` (Code tool)
Scratchpad. Same rationale as Supabase version — forcing the model to verbalize reasoning improves tool-call accuracy.

## Auth flow

```
n8n tool call
     │
     │  (uses Microsoft OAuth2 credential)
     ▼
https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token
   grant_type=client_credentials
   scope=https://analysis.windows.net/powerbi/api/.default
     │
     │  → access_token (1hr TTL)
     ▼
https://api.powerbi.com/v1.0/myorg/groups/{group}/datasets/{dataset}/executeQueries
   Authorization: Bearer <token>
```

n8n caches the access token automatically per credential and refreshes before expiry. Every Power BI REST call the agent makes is authenticated as the Service Principal.

## DAX query patterns the agent uses

### Aggregation (preferred — scales well)
```dax
EVALUATE
SUMMARIZECOLUMNS(
  Product[Category],
  "Revenue", [Total Sales],
  "Orders",  COUNTROWS(Sales)
)
ORDER BY [Revenue] DESC
```

### Time series
```dax
EVALUATE
SUMMARIZECOLUMNS(
  'Date'[Year-Month],
  "Revenue", [Total Sales]
)
ORDER BY 'Date'[Year-Month]
```

### Filtered aggregation
```dax
EVALUATE
ROW(
  "Q1Revenue", CALCULATE([Total Sales], 'Date'[Quarter] = "Q1")
)
```

### Raw row dump (always capped with TOPN)
```dax
EVALUATE TOPN(500, Sales, Sales[OrderDate], DESC)
```

## Why prefer measures over hand-rolled DAX?

If the model defines `[Total Sales] = SUMX(Sales, Sales[Qty] * Sales[UnitPrice])`, and the agent writes `SUMX(Sales, Sales[Qty] * Sales[UnitPrice])` instead of calling `[Total Sales]`, the number might be "right" but:
- It skips currency conversion the modeler built into the measure
- It skips exclusion filters (e.g. `Sales[IsInternalTransfer] = FALSE`)
- It diverges from reports downstream

The system prompt instructs: **"If `list_tables_and_measures` shows a measure, USE IT."**

## Performance notes

| Step | Latency |
|---|---|
| Token acquisition | 150-400ms (first call) / cached after |
| `executeQueries` DAX call | 300ms-3s depending on query + model size |
| `list_tables_and_measures` | ~500ms |
| `get_table_columns` | ~300ms |
| **Total per user turn** | **5-15s** |

Power BI REST API rate limits: 120 requests/minute/user (Service Principal counts as one user). Hundreds of concurrent chat users would need multiple SPs or XMLA fallback.

## Observability

- **Executions tab** in n8n shows every tool call with inputs/outputs.
- **Power BI usage metrics** dashboard shows `executeQueries` activity per dataset.
- **Azure AD sign-in logs** show Service Principal auth events.
- **`n8n_chat_histories`** is your conversation audit log.

## See also

- [AZURE_AD_SETUP.md](AZURE_AD_SETUP.md) — service principal + tenant config
- [SECURITY.md](SECURITY.md) — hardening for production

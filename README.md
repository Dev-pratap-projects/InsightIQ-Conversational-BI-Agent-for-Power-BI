# n8n Power BI Data Analyst Agent

A production-ready [n8n](https://n8n.io) workflow template that turns any [Power BI](https://powerbi.microsoft.com) semantic model into a **natural-language analytics chatbot**. Users ask questions in plain English — the agent writes DAX, runs it via the Power BI REST API, and returns answers with charts.

Built as a LangChain Tools Agent using OpenRouter (Claude Sonnet 4.6 by default), QuickChart for visualizations, and Postgres Chat Memory for persistent conversations.

![n8n](https://img.shields.io/badge/n8n-template-EA4B71?logo=n8n) ![Power BI](https://img.shields.io/badge/Power_BI-REST_API-F2C811?logo=powerbi&logoColor=black) ![Claude](https://img.shields.io/badge/Claude-Sonnet_4.6-D97757) ![License](https://img.shields.io/badge/License-MIT-yellow.svg)

> Part of the **[n8n-ai-agents catalog](https://github.com/MinaSaad1/n8n-ai-agents)** — see the catalog for shared [architecture principles](https://github.com/MinaSaad1/n8n-ai-agents/blob/main/docs/architecture-principles.md), [security framework](https://github.com/MinaSaad1/n8n-ai-agents/blob/main/docs/security-framework.md), and [output conventions](https://github.com/MinaSaad1/n8n-ai-agents/blob/main/docs/output-conventions.md) every template in the collection follows. Sibling: [Supabase/Postgres Data Analyst](https://github.com/MinaSaad1/n8n-supabase-data-analyst-agent).

---

## What it does

- **Chat interface** — hosted n8n chat URL or embeddable widget
- **Model discovery** — queries `INFO.TABLES()` / `INFO.MEASURES()` / `INFO.COLUMNS()` so the agent never hallucinates names
- **Safe DAX execution** — 200-row cap + `truncated` flag, response flattening strips `[Table].[Column]` brackets
- **Measure-aware** — agent prefers existing measures over hand-rolled DAX (respects your semantic layer)
- **Automatic chart generation** — bar / line / pie / doughnut / scatter via QuickChart.io
- **Persistent memory** — follow-up questions work across turns
- **Dataset refresh** — agent can trigger a refresh on explicit user request

## Architecture

```
┌─────────────────┐      ┌──────────────────────┐
│  Chat Trigger   │─────▶│  Tools Agent (LC)    │
│  (hosted chat)  │      │  Claude Sonnet 4.6   │
└─────────────────┘      └──┬───────────────────┘
                            │
       ┌────────────────────┼────────────────────┐
       │                    │                    │
       ▼                    ▼                    ▼
┌────────────┐      ┌──────────────┐      ┌──────────────┐
│ Postgres   │      │ 6 Tools      │      │   Config     │
│ Chat       │      ├──────────────┤      │ group_id +   │
│ Memory     │      │ list_tables_ │      │ dataset_id   │
└────────────┘      │  and_measures│      └──────────────┘
                    │ get_table_   │
                    │  columns     │
                    │ run_dax      │─┬──▶ [Sub] Run DAX + Row Cap
                    │ create_chart │─┘        │
                    │ refresh_     │          ▼
                    │  dataset     │    POST executeQueries
                    │ think        │    → flatten + 200-row cap
                    └──────────────┘
```

All Power BI REST calls go through Microsoft OAuth2 (Service Principal, client_credentials grant).

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for a deep dive.

## Requirements

- **n8n** ≥ 1.78 (self-hosted or cloud) with LangChain community nodes (included by default)
- **Power BI Service** workspace with a published dataset — any license (free/Pro/Premium all work via REST API)
- **Azure AD tenant** with permission to register apps
- **OpenRouter** account — [get an API key](https://openrouter.ai/keys)
- **Postgres** database for chat memory (can be the same Supabase/Neon/Railway instance you already have)

## Quickstart

### 1. Clone

```bash
git clone https://github.com/MinaSaad1/n8n-powerbi-data-analyst-agent.git
cd n8n-powerbi-data-analyst-agent
```

### 2. Set up Azure AD + Power BI access

Follow [docs/AZURE_AD_SETUP.md](docs/AZURE_AD_SETUP.md) step by step. ~10 minutes. Outcome:
- A Service Principal with a client ID + secret
- "Service principals can use Power BI APIs" enabled in your tenant
- Service Principal added as Member/Contributor on the target workspace

### 3. Prepare Postgres chat-memory table

Paste [sql/01-setup.sql](sql/01-setup.sql) into your Postgres database.

### 4. Import the workflows into n8n

In n8n → **Workflows** → **Import from File**, in this order:

1. [workflows/02-pbi-sub-run-dax.json](workflows/02-pbi-sub-run-dax.json)
2. [workflows/03-pbi-sub-generate-chart.json](workflows/03-pbi-sub-generate-chart.json)
3. [workflows/01-pbi-main-agent.json](workflows/01-pbi-main-agent.json)

After importing the main agent, open the `run_dax` and `create_chart` tool nodes and **re-bind them** to the matching imported sub-workflows (the IDs differ per n8n instance).

### 5. Create n8n credentials

| Credential | Attach to | Notes |
|---|---|---|
| **Microsoft OAuth2 API** | `list_tables_and_measures`, `get_table_columns`, `refresh_dataset`, AND `Run DAX via REST API` (inside the DAX sub-workflow) | Grant type = Client Credentials. Scope = `https://analysis.windows.net/powerbi/api/.default`. Client ID/secret from Azure AD. |
| **OpenRouter API** | `OpenRouter Chat Model` | — |
| **Postgres** | `Postgres Chat Memory` | Writable. Uses `n8n_chat_histories` table. |

### 6. Configure workspace + dataset

Open the main agent workflow → click the **Config** node → replace the two placeholders:
- `group_id` — your Power BI workspace GUID (from the URL: `app.powerbi.com/groups/<GUID>/...`)
- `dataset_id` — your dataset GUID (from Settings → Datasets → "This dataset is refreshed...")

### 7. Activate & test

1. Activate all 3 workflows (sub-workflows first, then the main agent).
2. Open the main agent → click **Chat**.
3. Ask: *"What tables and measures does this model have?"*

Expected flow: `list_tables_and_measures` → formatted response grouping tables and measures with their descriptions. From there try *"Show me revenue by [your-category-dimension] as a bar chart"*.

## Configuration

### Swap the LLM

Main agent → `OpenRouter Chat Model` → change `model`. Any tool-calling-capable model works. Tested with `anthropic/claude-sonnet-4.6`.

### Adjust the system prompt

All behavior (DAX primer, tool-call order, chart policy, output format) lives in the `Power BI Analyst Agent` node's `systemMessage` option.

### Point at a different dataset

Edit the **Config** node's `group_id` and `dataset_id`. Or make them dynamic by reading from `$json.metadata.group_id` when you embed the chat.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `401 Unauthorized` on every REST call | Service Principal not added to the workspace | Power BI Service → Workspace → Access → add the SP as Member/Contributor |
| `404 Not Found` on executeQueries | Wrong `group_id` or `dataset_id` | Double-check GUIDs from the Power BI URL and dataset settings page |
| `Feature 'DatasetExecuteQueries' is not available` | Workspace is classic (personal), not modern | Move the dataset to a modern workspace (v2) |
| `DMV is not supported` on `INFO.TABLES()` | Older Power BI cached model | Refresh the dataset once; INFO functions need recent model updates |
| Agent loops / max iterations | Poisoned chat memory from earlier iteration | Click ↺ in the chat panel for a fresh session |
| Chart returns generic/error image | `create_chart` got malformed data | Check the sub-workflow's last execution to see the inputs |

## Security

**This template is a starting point, not a hardened production deployment.** Concerns to address before exposing to untrusted users:

- Chat URL is public by default — authenticate via embed + JWT
- Service Principal has broad model access — scope to read-only via Power BI dataset permissions, not just workspace role
- No RLS in DAX queries by default — implement via `impersonatedUserName` in `executeQueries` body + RLS roles on the dataset
- `refresh_dataset` is a write op — gate behind stricter authorization

See [docs/SECURITY.md](docs/SECURITY.md) for the layered hardening guide.

## Roadmap

- [ ] Multi-dataset support — agent picks the right dataset from `INFO.DATABASES()`
- [ ] `explain_measure` tool — returns the DAX expression + lineage for any measure
- [ ] XMLA endpoint support (Premium) for richer introspection
- [ ] Streaming tool-call events to the chat UI
- [ ] Scheduled PBI briefing companion workflow (KPI digest → email/Teams)

## License

MIT — see [LICENSE](LICENSE).

## Credits

Built by [Mina Saad](https://github.com/MinaSaad1). Companion to [n8n-supabase-data-analyst-agent](https://github.com/MinaSaad1/n8n-supabase-data-analyst-agent). PRs welcome.

---

## Need this running in your business?

This template is free and MIT, and it is meant to be forked. Getting one into
production against your real data, your credentials and your edge cases is a
different job, and it is the one I do.

I work out what is actually costing a business, then build whatever fixes it: an
AI agent, an automation, or a full application. Handed over so your team owns it.

[Book a call](https://cal.com/minasaad/60min) · [mina-saad.com](https://www.mina-saad.com)

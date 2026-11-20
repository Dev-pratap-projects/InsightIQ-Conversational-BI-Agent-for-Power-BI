-- One-time setup for Postgres Chat Memory (any Postgres instance, including Supabase).
-- This table stores the agent's conversation history keyed by sessionId.

CREATE TABLE IF NOT EXISTS public.n8n_chat_histories (
  id          BIGSERIAL PRIMARY KEY,
  session_id  TEXT NOT NULL,
  message     JSONB NOT NULL
);

CREATE INDEX IF NOT EXISTS n8n_chat_histories_session_idx
  ON public.n8n_chat_histories (session_id);

-- n8n auto-creates this table on first use if the credential has DDL rights,
-- but pre-creating it avoids "relation does not exist" on the first chat message.

-- Optional: nightly cleanup — drop sessions older than 30 days.
-- Run manually or wire into a scheduled n8n workflow.
-- DELETE FROM public.n8n_chat_histories
-- WHERE id IN (
--   SELECT id FROM public.n8n_chat_histories
--   WHERE session_id IN (
--     SELECT session_id FROM public.n8n_chat_histories
--     GROUP BY session_id HAVING max(id) < (
--       SELECT coalesce(max(id), 0) - 10000 FROM public.n8n_chat_histories
--     )
--   )
-- );

-- Run manually in Supabase SQL Editor. No existing tables/functions are modified.
-- Read-only server role; NOT the Make connector. Script may be re-run.
BEGIN;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cabinet_reader') THEN
    CREATE ROLE cabinet_reader LOGIN;
  END IF;
END $$;
GRANT CONNECT ON DATABASE postgres TO cabinet_reader;
GRANT USAGE ON SCHEMA public TO cabinet_reader;
GRANT SELECT ON public.designers, public.projects, public.ledger_entries, public.reward_rules TO cabinet_reader;
DROP POLICY IF EXISTS cabinet_read_designers ON public.designers;
CREATE POLICY cabinet_read_designers ON public.designers FOR SELECT TO cabinet_reader USING (true);
DROP POLICY IF EXISTS cabinet_read_projects ON public.projects;
CREATE POLICY cabinet_read_projects ON public.projects FOR SELECT TO cabinet_reader USING (true);
DROP POLICY IF EXISTS cabinet_read_ledger ON public.ledger_entries;
CREATE POLICY cabinet_read_ledger ON public.ledger_entries FOR SELECT TO cabinet_reader USING (true);
DROP POLICY IF EXISTS cabinet_read_reward_rules ON public.reward_rules;
CREATE POLICY cabinet_read_reward_rules ON public.reward_rules FOR SELECT TO cabinet_reader USING (true);
ALTER ROLE cabinet_reader SET default_transaction_read_only = on;
COMMIT;
-- Set a strong unique password separately, not in this file or Git history:
-- ALTER ROLE cabinet_reader PASSWORD '<set privately in SQL Editor>';
-- Shared session pooler username: cabinet_reader.<your-project-ref>
-- Database connection is server-only. This role reads all rows, so the server
-- MUST verify Telegram auth and filter every query by the resolved designer_id.

-- Only needed if cabinet_reader was created before UI v0.2.
-- Run in Supabase SQL Editor. Grants read access to program rates only.
BEGIN;
GRANT SELECT ON public.reward_rules TO cabinet_reader;
DROP POLICY IF EXISTS cabinet_read_reward_rules ON public.reward_rules;
CREATE POLICY cabinet_read_reward_rules ON public.reward_rules
  FOR SELECT TO cabinet_reader USING (true);
COMMIT;

-- Run as postgres. Full settlement only. Does not issue payments or change accruals.
-- No new accounting tables: settlement is recorded on the existing ledger entry.
BEGIN;
ALTER TABLE public.ledger_entries ADD COLUMN IF NOT EXISTS settled_at timestamptz;
ALTER TABLE public.ledger_entries ADD COLUMN IF NOT EXISTS settlement_source_id text;
ALTER TABLE public.ledger_entries ADD COLUMN IF NOT EXISTS settled_amount numeric;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.ledger_entries'::regclass AND conname = 'ledger_full_settlement_check') THEN
    ALTER TABLE public.ledger_entries ADD CONSTRAINT ledger_full_settlement_check CHECK (
      (settled_at IS NULL AND settlement_source_id IS NULL AND settled_amount IS NULL)
      OR (settled_at IS NOT NULL AND settlement_source_id IS NOT NULL
          AND length(trim(settlement_source_id)) > 0 AND settled_amount IS NOT NULL
          AND settled_amount = amount AND settled_amount > 0));
  END IF;
END $$;
CREATE UNIQUE INDEX IF NOT EXISTS ledger_unique_settlement_source
ON public.ledger_entries(settlement_source_id) WHERE settlement_source_id IS NOT NULL;

-- Make calls this AFTER a real full payment and only for an affirmative Y or Z.
-- p_operation_id = Google column R; expected_amount = L (RUB) or Q (LR).
-- Empty/negative dropdowns never call this function and never undo settlement.
CREATE OR REPLACE FUNCTION public.settle_sheet_operation(
    p_operation_id text, p_designer_id text, p_operation_type text,
    p_order_number text, p_event_id text, p_expected_amount numeric
) RETURNS TABLE(entry_id bigint, currency text, settled_amount numeric,
                settled_at timestamptz, already_settled boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
    v_designer text := CASE WHEN trim(p_designer_id) ~* '^D[0-9]+$'
      THEN upper(trim(p_designer_id)) ELSE trim(p_designer_id) END;
    v_type text;
    v_key text;
    v_source text;
    v_project public.projects%ROWTYPE;
    v_activity public.designer_activities%ROWTYPE;
    v_entry public.ledger_entries%ROWTYPE;
    v_seen boolean;
BEGIN
    IF coalesce(trim(p_operation_id), '') = '' OR length(p_operation_id) > 500
       OR coalesce(v_designer, '') = '' OR p_expected_amount IS NULL
       OR p_expected_amount::text IN ('NaN', 'Infinity', '-Infinity')
       OR p_expected_amount <= 0 THEN RAISE EXCEPTION 'Не заполнены ID операции, дизайнер или сумма'; END IF;
    v_type := CASE lower(trim(p_operation_type))
      WHEN 'доля от проекта' THEN 'project_share'
      WHEN 'бонус за закрытый проект' THEN 'project_bonus'
      WHEN 'бонус за метки' THEN 'mention_bonus'
      WHEN 'бонус за мероприятия' THEN 'event_bonus'
      WHEN 'бонус за реферала' THEN 'referral_bonus'
      ELSE NULL END;
    IF v_type IS NULL THEN RAISE EXCEPTION 'Тип операции не поддерживает выплату из этой строки'; END IF;
    IF NOT EXISTS (SELECT 1 FROM public.designers d WHERE d.designer_id = v_designer) THEN
      RAISE EXCEPTION 'Дизайнер не найден';
    END IF;
    v_source := 'GOOGLE|1lY1XJJjwQ0A883kAbQkVqabQhBHWjSfBO2yv68dUwlE|' || trim(p_operation_id);
    IF v_type IN ('project_share', 'project_bonus', 'referral_bonus') THEN
      SELECT p.* INTO v_project FROM public.projects p
      WHERE p.order_number = upper(trim(p_order_number));
      IF NOT FOUND THEN RAISE EXCEPTION 'Заказ не найден'; END IF;
      IF v_type <> 'referral_bonus' AND v_project.designer_id IS DISTINCT FROM v_designer THEN
        RAISE EXCEPTION 'Заказ относится к другому дизайнеру';
      END IF;
      IF v_type = 'referral_bonus' THEN
        v_key := 'TEST|REFERRAL|' || v_project.designer_id;
      ELSE
        v_key := 'TEST|PROJECT|' || v_project.project_id::text || '|' || v_type;
      END IF;
    ELSE
      SELECT a.* INTO v_activity FROM public.designer_activities a
      WHERE a.designer_id = v_designer AND a.activity_type = v_type
        AND a.source_event_id = upper(trim(p_event_id));
      IF NOT FOUND THEN RAISE EXCEPTION 'Событие начисления не найдено'; END IF;
      v_key := 'TEST|ACTIVITY|' || v_activity.activity_id::text;
    END IF;
    SELECT e.* INTO v_entry FROM public.ledger_entries e
    WHERE e.operation_key = v_key FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Исходное начисление ещё не существует'; END IF;
    IF v_entry.designer_id IS DISTINCT FROM v_designer OR v_entry.operation_type IS DISTINCT FROM v_type
       OR v_entry.currency IS DISTINCT FROM (CASE WHEN v_type = 'project_share' THEN 'RUB' ELSE 'LR' END)
       OR (v_type IN ('project_share','project_bonus','referral_bonus')
           AND v_entry.project_id IS DISTINCT FROM v_project.project_id) THEN
      RAISE EXCEPTION 'Начисление не соответствует строке выплаты';
    END IF;
    IF v_entry.amount IS DISTINCT FROM p_expected_amount THEN
      RAISE EXCEPTION 'Сумма строки не совпадает с начислением. Частичная выплата запрещена';
    END IF;
    v_seen := v_entry.settled_at IS NOT NULL;
    IF v_seen THEN
      IF v_entry.settlement_source_id IS DISTINCT FROM v_source THEN
        RAISE EXCEPTION 'Начисление уже выплачено по другой строке';
      END IF;
    ELSE
      IF EXISTS (SELECT 1 FROM public.ledger_entries e WHERE e.settlement_source_id = v_source) THEN
        RAISE EXCEPTION 'Этот ID строки уже использован для другой выплаты';
      END IF;
      UPDATE public.ledger_entries e SET settled_at = now(), settlement_source_id = v_source,
        settled_amount = e.amount WHERE e.entry_id = v_entry.entry_id RETURNING e.* INTO v_entry;
    END IF;
    RETURN QUERY SELECT v_entry.entry_id, v_entry.currency, v_entry.settled_amount,
      v_entry.settled_at, v_seen;
END;
$$;

-- Cabinet uses this only after verifying Telegram initData; no arbitrary designer ID.
-- LR totals are units of redeemed bonuses, NOT the RUB bank transfer amount.
CREATE OR REPLACE FUNCTION leroy_private.get_settlement_balance(p_telegram_id bigint)
RETURNS TABLE(commission_accrued_rub numeric, commission_paid_rub numeric,
 commission_remaining_rub numeric, bonus_accrued_lr numeric, bonus_redeemed_lr numeric,
 bonus_remaining_lr numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
    SELECT
      coalesce(sum(e.amount) FILTER (WHERE e.currency = 'RUB'),0),
      coalesce(sum(e.settled_amount) FILTER (WHERE e.currency = 'RUB' AND e.settled_at IS NOT NULL),0),
      coalesce(sum(e.amount) FILTER (WHERE e.currency = 'RUB' AND e.settled_at IS NULL),0),
      coalesce(sum(e.amount) FILTER (WHERE e.currency = 'LR'),0),
      coalesce(sum(e.settled_amount) FILTER (WHERE e.currency = 'LR' AND e.settled_at IS NOT NULL),0),
      coalesce(sum(e.amount) FILTER (WHERE e.currency = 'LR' AND e.settled_at IS NULL),0)
    FROM public.designers d LEFT JOIN public.ledger_entries e ON e.designer_id = d.designer_id
    WHERE d.telegram_id = p_telegram_id AND d.is_active = true;
$$;
ALTER FUNCTION public.settle_sheet_operation(text,text,text,text,text,numeric) OWNER TO postgres;
ALTER FUNCTION leroy_private.get_settlement_balance(bigint) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.settle_sheet_operation(text,text,text,text,text,numeric),
 leroy_private.get_settlement_balance(bigint) FROM PUBLIC, anon, authenticated, cabinet_reader, make_connector;
GRANT USAGE ON SCHEMA leroy_private TO cabinet_reader;
GRANT EXECUTE ON FUNCTION public.settle_sheet_operation(text,text,text,text,text,numeric) TO make_connector;
GRANT EXECUTE ON FUNCTION leroy_private.get_settlement_balance(bigint) TO cabinet_reader;
COMMIT;

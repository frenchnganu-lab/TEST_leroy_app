-- Cumulative paid total. Apply transactionally as postgres. No entries are rewritten.
ALTER TABLE public.ledger_entries DROP CONSTRAINT ledger_full_settlement_check;
ALTER TABLE public.ledger_entries ADD CONSTRAINT ledger_cumulative_settlement_check CHECK (
  (settled_amount IS NULL AND settlement_source_id IS NULL AND settled_at IS NULL)
  OR (settled_amount IS NOT NULL AND settled_amount::text NOT IN ('NaN','Infinity','-Infinity')
      AND settled_amount > 0 AND settled_amount <= amount
      AND settlement_source_id IS NOT NULL AND length(trim(settlement_source_id)) > 0
      AND ((settled_amount=amount AND settled_at IS NOT NULL) OR
           (settled_amount<amount AND settled_at IS NULL))));
CREATE OR REPLACE FUNCTION public.record_sheet_paid_total(
    p_operation_id text, p_designer_id text, p_operation_type text,
    p_order_number text, p_event_id text, p_expected_amount numeric, p_paid_rub numeric
) RETURNS TABLE(entry_id bigint, currency text, settled_amount numeric,
                settled_at timestamptz, unchanged boolean)
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
    v_total_rub numeric;
    v_units numeric;
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
      RAISE EXCEPTION 'Сумма начисления в строке не совпадает с журналом';
    END IF;
    IF p_paid_rub IS NULL OR p_paid_rub::text IN ('NaN','Infinity','-Infinity')
       OR p_paid_rub <= 0 OR round(p_paid_rub,2) <> p_paid_rub THEN
      RAISE EXCEPTION 'Укажите положительную сумму выплаты в рублях с точностью до копейки';
    END IF;
    v_total_rub := round(v_entry.amount * CASE WHEN v_entry.currency='LR' THEN v_entry.rub_per_lr ELSE 1 END, 2);
    IF p_paid_rub > v_total_rub THEN RAISE EXCEPTION 'Выплачено больше, чем начислено'; END IF;
    v_units := CASE WHEN p_paid_rub=v_total_rub THEN v_entry.amount
      WHEN v_entry.currency='RUB' THEN p_paid_rub ELSE round(p_paid_rub/v_entry.rub_per_lr,2) END;
    IF v_units <= 0 OR (p_paid_rub<v_total_rub AND v_units >= v_entry.amount)
       OR round(v_units * CASE WHEN v_entry.currency='LR' THEN v_entry.rub_per_lr ELSE 1 END,2) <> p_paid_rub THEN
      RAISE EXCEPTION 'Сумму в копейках нельзя точно учесть по курсу операции';
    END IF;
    IF v_entry.settlement_source_id IS NOT NULL AND v_entry.settlement_source_id <> v_source THEN
      RAISE EXCEPTION 'Выплата уже привязана к другой строке';
    END IF;
    IF v_units < coalesce(v_entry.settled_amount,0) THEN
      RAISE EXCEPTION 'Нельзя уменьшать подтверждённую сумму выплат';
    END IF;
    IF v_units IS NOT DISTINCT FROM v_entry.settled_amount THEN
      RETURN QUERY SELECT v_entry.entry_id,v_entry.currency,v_units,v_entry.settled_at,true;
      RETURN;
    END IF;
    UPDATE public.ledger_entries e SET settled_amount=v_units,settlement_source_id=v_source,
      settled_at=CASE WHEN v_units=e.amount THEN now() ELSE NULL END
      WHERE e.entry_id=v_entry.entry_id RETURNING e.* INTO v_entry;
    RETURN QUERY SELECT v_entry.entry_id,v_entry.currency,v_units,v_entry.settled_at,false;
END;
$$;
REVOKE ALL ON FUNCTION public.record_sheet_paid_total(text,text,text,text,text,numeric,numeric)
FROM PUBLIC, anon, authenticated, cabinet_reader;
GRANT EXECUTE ON FUNCTION public.record_sheet_paid_total(text,text,text,text,text,numeric,numeric) TO make_connector;
CREATE OR REPLACE FUNCTION leroy_private.get_settlement_balance(p_telegram_id bigint)
RETURNS TABLE(commission_accrued_rub numeric, commission_paid_rub numeric,
 commission_remaining_rub numeric, bonus_accrued_lr numeric, bonus_redeemed_lr numeric,
 bonus_remaining_lr numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
    SELECT
      coalesce(sum(e.amount) FILTER (WHERE e.currency = 'RUB'),0),
      coalesce(sum(e.settled_amount) FILTER (WHERE e.currency = 'RUB'),0),
      coalesce(sum(e.amount-coalesce(e.settled_amount,0)) FILTER (WHERE e.currency = 'RUB'),0),
      coalesce(sum(e.amount) FILTER (WHERE e.currency = 'LR'),0),
      coalesce(sum(e.settled_amount) FILTER (WHERE e.currency = 'LR'),0),
      coalesce(sum(e.amount-coalesce(e.settled_amount,0)) FILTER (WHERE e.currency = 'LR'),0)
    FROM public.designers d LEFT JOIN public.ledger_entries e ON e.designer_id = d.designer_id
    WHERE d.telegram_id = p_telegram_id AND d.is_active = true;
$$;
CREATE OR REPLACE FUNCTION public.sync_designer_dashboard(p_designer_id text,p_full_name text,p_phone text,p_level text,p_weight numeric)
RETURNS TABLE(designer_id text,full_name text,level_code text,bonus_accrued_lr numeric,bonus_redeemed_lr numeric,bonus_remaining_lr numeric,commission_accrued_rub numeric,commission_paid_rub numeric,commission_remaining_rub numeric)
LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE v_id text;
BEGIN
IF p_weight IS NULL OR p_weight<0 OR p_weight::text IN ('NaN','Infinity','-Infinity') THEN RAISE EXCEPTION 'Некорректный вес'; END IF;
SELECT s.designer_id INTO v_id FROM public.sync_designer(p_designer_id,p_full_name,p_phone,p_level) s;
UPDATE public.designers d SET loyalty_weight=p_weight WHERE d.designer_id=v_id;
RETURN QUERY SELECT d.designer_id,d.full_name,d.level_code,
coalesce(sum(e.amount) FILTER(WHERE e.currency='LR'),0),
coalesce(sum(e.settled_amount) FILTER(WHERE e.currency='LR'),0),
coalesce(sum(e.amount-coalesce(e.settled_amount,0)) FILTER(WHERE e.currency='LR'),0),
coalesce(sum(e.amount) FILTER(WHERE e.currency='RUB'),0),
coalesce(sum(e.settled_amount) FILTER(WHERE e.currency='RUB'),0),
coalesce(sum(e.amount-coalesce(e.settled_amount,0)) FILTER(WHERE e.currency='RUB'),0)
FROM public.designers d LEFT JOIN public.ledger_entries e ON e.designer_id=d.designer_id
WHERE d.designer_id=v_id GROUP BY d.designer_id;
END $$;

-- Applied to designer project 2026-11-25 with explicit approval.
ALTER TABLE public.designers ADD COLUMN IF NOT EXISTS loyalty_weight numeric NOT NULL DEFAULT 0;
ALTER TABLE public.designers DROP CONSTRAINT designers_level_code_check;
ALTER TABLE public.designers ADD CONSTRAINT designers_level_code_check CHECK(level_code IN ('bronze','silver','gold','platinum','diamond'));
CREATE OR REPLACE FUNCTION public.sync_designer(p_designer_id text, p_full_name text, p_phone text, p_level text)
 RETURNS TABLE(designer_id text, full_name text, level_code text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_id text := CASE
        WHEN trim(p_designer_id) ~* '^D[0-9]+$'
            THEN upper(trim(p_designer_id))
        ELSE trim(p_designer_id)
    END;

    v_name text := trim(p_full_name);
    v_level text;

BEGIN
    IF coalesce(v_id, '') = ''
       OR coalesce(v_name, '') = '' THEN
        RAISE EXCEPTION 'Не заполнены ID или ФИО дизайнера';
    END IF;

    v_level := CASE lower(trim(p_level))
        WHEN 'бронзовый'   THEN 'bronze'
        WHEN 'серебряный'  THEN 'silver'
        WHEN 'серебрянный' THEN 'silver'
        WHEN 'золотой'    THEN 'gold'
        WHEN 'платиновый' THEN 'platinum'
        WHEN 'bronze'     THEN 'bronze'
        WHEN 'silver'     THEN 'silver'
        WHEN 'gold'       THEN 'gold'
        WHEN 'platinum'   THEN 'platinum'
        WHEN 'бриллиантовый' THEN 'diamond'
        WHEN 'брилиантовый' THEN 'diamond'
        WHEN 'diamond' THEN 'diamond'
        ELSE NULL
    END;

    IF v_level IS NULL THEN
        RAISE EXCEPTION 'Неизвестный уровень: %', p_level;
    END IF;

    INSERT INTO public.designers AS d (
        designer_id,
        full_name,
        phone,
        level_code
    )
    VALUES (
        v_id,
        v_name,
        nullif(trim(p_phone), ''),
        v_level
    )
    ON CONFLICT ON CONSTRAINT designers_pkey
    DO UPDATE SET
        full_name = EXCLUDED.full_name,
        phone = CASE
            WHEN d.telegram_id IS NOT NULL
                THEN d.phone
            ELSE coalesce(EXCLUDED.phone, d.phone)
        END,
        level_code = EXCLUDED.level_code;

    RETURN QUERY
    SELECT d.designer_id, d.full_name, d.level_code
    FROM public.designers AS d
    WHERE d.designer_id = v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.import_sheet_manual_project(p_order_number text, p_designer_id text, p_amount_rub numeric, p_delivered_date date, p_operation_type text, p_accrual_rub numeric)
 RETURNS TABLE(order_number text, added_operations integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
    v_order text := upper(trim(p_order_number));
    v_designer text := CASE
        WHEN trim(p_designer_id) ~* '^D[0-9]+$'
            THEN upper(trim(p_designer_id))
        ELSE trim(p_designer_id)
    END;
    v_type text;
    v_level text;
    v_rate numeric;
    v_amount numeric;
    v_currency text;
    v_key text;
    v_count integer;
    v_project public.projects%ROWTYPE;
    v_rules public.reward_rules%ROWTYPE;
BEGIN
    v_type := CASE lower(trim(p_operation_type))
        WHEN 'доля от проекта' THEN 'project_share'
        WHEN 'бонус за закрытый проект' THEN 'project_bonus'
        ELSE NULL
    END;

    IF coalesce(v_order, '') = ''
       OR coalesce(v_designer, '') = ''
       OR p_amount_rub IS NULL
       OR p_amount_rub <= 0
       OR p_delivered_date IS NULL
       OR v_type IS NULL THEN
        RAISE EXCEPTION 'Проверьте данные заказа и тип начисления';
    END IF;

    SELECT d.level_code
    INTO v_level
    FROM public.designers AS d
    WHERE d.designer_id = v_designer
      AND d.is_active = true;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Не найден активный дизайнер: %', v_designer;
    END IF;

    INSERT INTO public.projects (
        order_number, designer_id, amount_rub,
        status, delivered_at
    )
    VALUES (
        v_order, v_designer, p_amount_rub,
        'delivered',
        p_delivered_date::timestamp
            AT TIME ZONE 'Asia/Krasnoyarsk'
    )
    ON CONFLICT DO NOTHING;

    SELECT p.*
    INTO v_project
    FROM public.projects AS p
    WHERE p.order_number = v_order
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Не удалось получить заказ: %', v_order;
    END IF;

    IF v_project.designer_id IS DISTINCT FROM v_designer
       OR v_project.amount_rub IS DISTINCT FROM p_amount_rub
       OR v_project.status IS DISTINCT FROM 'delivered'
       OR (v_project.delivered_at
           AT TIME ZONE 'Asia/Krasnoyarsk')::date
           IS DISTINCT FROM p_delivered_date THEN
        RAISE EXCEPTION
            'Заказ уже существует с другими данными: %', v_order;
    END IF;

    -- Такой же ключ, как у старой функции:
    -- ранее начисленная операция не должна повториться.
    v_key := 'TEST|PROJECT|' || v_project.project_id
        || '|' || v_type;

    SELECT r.*
    INTO v_rules
    FROM public.reward_rules AS r
    WHERE r.valid_from <= v_project.delivered_at
    ORDER BY r.valid_from DESC, r.rule_version DESC
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Не найдены правила начисления';
    END IF;

    IF p_accrual_rub IS NULL OR p_accrual_rub <= 0 OR p_accrual_rub::text IN ('NaN','Infinity','-Infinity') THEN
        RAISE EXCEPTION 'Укажите ручную сумму начисления в рублях';
    END IF;
    v_currency := CASE WHEN v_type = 'project_share' THEN 'RUB' ELSE 'LR' END;
    v_amount := CASE WHEN v_type = 'project_share' THEN round(p_accrual_rub,2)
                    ELSE round(p_accrual_rub/v_rules.rub_per_lr,2) END;
    IF v_amount IS NULL OR v_amount <= 0 THEN
        RAISE EXCEPTION 'Размер начисления должен быть больше нуля';
    END IF;

    IF EXISTS (SELECT 1 FROM public.ledger_entries e WHERE e.operation_key=v_key) THEN
        IF EXISTS (SELECT 1 FROM public.ledger_entries e WHERE e.operation_key=v_key
                   AND (e.designer_id IS DISTINCT FROM v_designer OR e.currency IS DISTINCT FROM v_currency
                        OR e.amount IS DISTINCT FROM v_amount)) THEN
            RAISE EXCEPTION 'Начисление уже существует с другой суммой';
        END IF;
        RETURN QUERY SELECT v_order, 0;
        RETURN;
    END IF;

    INSERT INTO public.ledger_entries (
        operation_key, designer_id, project_id,
        operation_type, currency, amount,
        rule_version, rub_per_lr, event_at
    )
    VALUES (
        v_key, v_designer, v_project.project_id,
        v_type, v_currency, v_amount,
        v_rules.rule_version, v_rules.rub_per_lr,
        v_project.delivered_at
    )
    ON CONFLICT (operation_key) DO NOTHING;

    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN QUERY SELECT v_order, v_count;
END;
$function$;

REVOKE ALL ON FUNCTION public.import_sheet_manual_project(text,text,numeric,date,text,numeric) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.import_sheet_manual_project(text,text,numeric,date,text,numeric) TO make_connector;
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
coalesce(sum(e.settled_amount) FILTER(WHERE e.currency='LR' AND e.settled_at IS NOT NULL),0),
coalesce(sum(e.amount) FILTER(WHERE e.currency='LR' AND e.settled_at IS NULL),0),
coalesce(sum(e.amount) FILTER(WHERE e.currency='RUB'),0),
coalesce(sum(e.settled_amount) FILTER(WHERE e.currency='RUB' AND e.settled_at IS NOT NULL),0),
coalesce(sum(e.amount) FILTER(WHERE e.currency='RUB' AND e.settled_at IS NULL),0)
FROM public.designers d LEFT JOIN public.ledger_entries e ON e.designer_id=d.designer_id
WHERE d.designer_id=v_id GROUP BY d.designer_id;
END $$;
REVOKE ALL ON FUNCTION public.sync_designer_dashboard(text,text,text,text,numeric) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.sync_designer_dashboard(text,text,text,text,numeric) TO make_connector;

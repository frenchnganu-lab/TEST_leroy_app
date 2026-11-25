-- The bonus row supplies delivery. A commission row has its own accrual date.
CREATE OR REPLACE FUNCTION public.import_dated_project_accrual(
    p_order_number text, p_designer_id text, p_amount_rub numeric, p_event_date date,
    p_operation_type text, p_accrual_rub numeric, p_sheet_delivery_iso text
) RETURNS TABLE(order_number text, added_operations integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
    v_order text := upper(trim(p_order_number));
    v_type text := lower(trim(p_operation_type));
    v_delivery date;
    v_sheet_date text := nullif(trim(p_sheet_delivery_iso),'');
    v_event timestamptz := p_event_date::timestamp AT TIME ZONE 'Asia/Krasnoyarsk';
    v_added integer;
    v_id bigint;
    v_recorded timestamptz;
BEGIN
    IF p_event_date IS NULL THEN RAISE EXCEPTION 'Укажите дату операции'; END IF;
    IF v_type = 'бонус за закрытый проект' THEN
        v_delivery := p_event_date;
    ELSIF v_type = 'доля от проекта' THEN
        IF v_sheet_date IS NOT NULL THEN
            IF v_sheet_date !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' THEN
                RAISE EXCEPTION 'Проверьте дату и стоимость в парной строке закрытого проекта: %', v_order;
            END IF;
            v_delivery := v_sheet_date::date;
        ELSE
            SELECT (p.delivered_at AT TIME ZONE 'Asia/Krasnoyarsk')::date INTO v_delivery
            FROM public.projects p WHERE p.order_number = v_order AND p.status='delivered';
        END IF;
        IF v_delivery IS NULL THEN
            RAISE EXCEPTION 'Для нового заказа нужна подтверждённая дата сдачи: %', v_order;
        END IF;
    ELSE
        RAISE EXCEPTION 'Неизвестный тип проектного начисления';
    END IF;

    -- The existing importer checks designer, order, amount, date and retries and locks the project.
    SELECT i.added_operations INTO STRICT v_added FROM public.import_sheet_manual_project(
        v_order,p_designer_id,p_amount_rub,v_delivery,v_type,p_accrual_rub) i;
    IF v_type = 'доля от проекта' THEN
        SELECT e.entry_id,e.event_at INTO STRICT v_id,v_recorded
        FROM public.projects p JOIN public.ledger_entries e ON e.project_id=p.project_id
        WHERE p.order_number=v_order AND e.operation_key='TEST|PROJECT|' || p.project_id || '|project_share'
        FOR UPDATE OF e;
        IF v_added = 1 THEN
            UPDATE public.ledger_entries SET event_at=v_event WHERE entry_id=v_id;
        ELSIF v_recorded IS DISTINCT FROM v_event THEN
            RAISE EXCEPTION 'Вознаграждение уже зарегистрировано с другой датой: %',v_order;
        END IF;
    END IF;
    RETURN QUERY SELECT v_order, v_added;
END;
$$;
REVOKE ALL ON FUNCTION public.import_dated_project_accrual(text,text,numeric,date,text,numeric,text)
FROM PUBLIC,anon,authenticated,cabinet_reader;
GRANT EXECUTE ON FUNCTION public.import_dated_project_accrual(text,text,numeric,date,text,numeric,text) TO make_connector;

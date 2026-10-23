-- Run as postgres in Supabase SQL Editor after fixing duplicate phone numbers.
-- No passwords, bot tokens or phone numbers belong in this file.
BEGIN;

CREATE UNIQUE INDEX IF NOT EXISTS designers_phone_digits_unique
ON public.designers (regexp_replace(phone, '[^0-9]', '', 'g'))
WHERE NULLIF(regexp_replace(phone, '[^0-9]', '', 'g'), '') IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS designers_telegram_id_unique
ON public.designers (telegram_id) WHERE telegram_id IS NOT NULL;

CREATE SCHEMA IF NOT EXISTS leroy_private;
REVOKE ALL ON SCHEMA leroy_private FROM PUBLIC;
GRANT USAGE ON SCHEMA leroy_private TO cabinet_reader;

CREATE OR REPLACE FUNCTION leroy_private.bind_telegram_contact(
    p_phone_digits text, p_telegram_id bigint
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
    v_card public.designers%ROWTYPE;
    v_count bigint;
BEGIN
    IF p_telegram_id IS NULL OR p_telegram_id <= 0
       OR p_phone_digits IS NULL
       OR p_phone_digits !~ '^[1-9][0-9]{7,14}$' THEN
        RETURN 'invalid';
    END IF;

    -- Serialize bindings and concurrent Make writes for this small partner base.
    -- The caller sets a short lock timeout; unique indexes also prevent races.
    LOCK TABLE public.designers IN SHARE ROW EXCLUSIVE MODE;
    SELECT count(*) INTO v_count FROM public.designers d
    WHERE regexp_replace(d.phone, '[^0-9]', '', 'g') = p_phone_digits;
    IF v_count = 0 THEN RETURN 'not_found'; END IF;
    IF v_count <> 1 THEN RETURN 'ambiguous'; END IF;

    SELECT d.* INTO v_card FROM public.designers d
    WHERE regexp_replace(d.phone, '[^0-9]', '', 'g') = p_phone_digits;
    IF v_card.is_active IS DISTINCT FROM true THEN RETURN 'inactive'; END IF;
    IF v_card.telegram_id = p_telegram_id THEN RETURN 'already_bound'; END IF;
    IF v_card.telegram_id IS NOT NULL THEN RETURN 'card_conflict'; END IF;
    IF EXISTS (SELECT 1 FROM public.designers d WHERE d.telegram_id = p_telegram_id) THEN
        RETURN 'account_conflict';
    END IF;

    UPDATE public.designers SET telegram_id = p_telegram_id
    WHERE designer_id = v_card.designer_id AND telegram_id IS NULL AND is_active = true;
    IF NOT FOUND THEN RETURN 'conflict'; END IF;
    RETURN 'bound';
END;
$$;

ALTER FUNCTION leroy_private.bind_telegram_contact(text, bigint) OWNER TO postgres;
REVOKE ALL ON FUNCTION leroy_private.bind_telegram_contact(text, bigint)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION leroy_private.bind_telegram_contact(text, bigint) TO cabinet_reader;
COMMIT;

-- This function is trusted-server-only. Never expose it through a browser API
-- that accepts arbitrary phone/Telegram ID. The webhook authenticates Telegram
-- and checks that message.from.id equals message.contact.user_id first.
-- Do not configure leroy_private as a Supabase exposed schema.
-- Keep phones in international format (+7..., not 8...).
-- Make upserts must NOT overwrite telegram_id from an empty sheet column.

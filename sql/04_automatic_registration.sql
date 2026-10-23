-- Run as postgres in Supabase SQL Editor after 03_telegram_phone_binding.sql.
BEGIN;
ALTER TABLE public.designers ALTER COLUMN designer_id
SET DEFAULT ('TG-' || gen_random_uuid()::text);

CREATE TABLE IF NOT EXISTS leroy_private.registration_sessions (
    telegram_id bigint PRIMARY KEY CHECK (telegram_id > 0),
    phone_digits text NOT NULL CHECK (phone_digits ~ '^[1-9][0-9]{7,14}$'),
    full_name text,
    stage text NOT NULL CHECK (stage IN ('name', 'confirm')),
    last_update_id bigint NOT NULL,
    expires_at timestamptz NOT NULL DEFAULT (now() + interval '24 hours')
);
REVOKE ALL ON leroy_private.registration_sessions FROM PUBLIC, anon, authenticated, cabinet_reader;

CREATE OR REPLACE FUNCTION leroy_private.onboard_designer(
    p_telegram_id bigint, p_action text, p_phone_digits text,
    p_full_name text, p_update_id bigint
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog
AS $$
DECLARE
    v_session leroy_private.registration_sessions%ROWTYPE;
    v_card public.designers%ROWTYPE;
    v_has_session boolean;
    v_count bigint;
    v_status text;
BEGIN
    IF p_telegram_id IS NULL OR p_telegram_id <= 0 OR p_update_id IS NULL
       OR p_update_id < 0 OR p_action IS NULL
       OR p_action NOT IN ('contact', 'resume', 'text', 'confirm', 'edit', 'cancel') THEN
        RETURN jsonb_build_object('status', 'invalid');
    END IF;
    -- Fixed lock ordering serializes registration with Make and phone binding.
    LOCK TABLE public.designers IN SHARE ROW EXCLUSIVE MODE;
    SELECT d.* INTO v_card FROM public.designers d WHERE d.telegram_id = p_telegram_id;
    IF FOUND THEN
        IF v_card.is_active IS DISTINCT FROM true THEN
            RETURN jsonb_build_object('status', 'inactive');
        END IF;
        RETURN jsonb_build_object('status', 'already_bound');
    END IF;

    -- Expired, unfinished sessions contain no usable phone proof.
    DELETE FROM leroy_private.registration_sessions WHERE expires_at <= now();
    SELECT r.* INTO v_session FROM leroy_private.registration_sessions r
    WHERE r.telegram_id = p_telegram_id;
    v_has_session := FOUND;

    IF v_has_session AND p_update_id <= v_session.last_update_id THEN
        -- Telegram retries must return the same stage, never repeat a mutation.
        RETURN jsonb_build_object('status', v_session.stage,
          'full_name', v_session.full_name, 'phone', '+' || v_session.phone_digits);
    END IF;

    IF p_action = 'cancel' THEN
        DELETE FROM leroy_private.registration_sessions WHERE telegram_id = p_telegram_id;
        RETURN jsonb_build_object('status', 'cancelled');
    END IF;

    IF p_action = 'contact' THEN
        IF p_phone_digits IS NULL OR p_phone_digits !~ '^[1-9][0-9]{7,14}$' THEN
            RETURN jsonb_build_object('status', 'invalid');
        END IF;
        v_status := leroy_private.bind_telegram_contact(p_phone_digits, p_telegram_id);
        IF v_status <> 'not_found' THEN
            RETURN jsonb_build_object('status', v_status);
        END IF;
        INSERT INTO leroy_private.registration_sessions
            (telegram_id, phone_digits, stage, last_update_id, expires_at)
        VALUES (p_telegram_id, p_phone_digits, 'name', p_update_id, now() + interval '24 hours')
        ON CONFLICT (telegram_id) DO UPDATE SET phone_digits = EXCLUDED.phone_digits,
            full_name = NULL, stage = 'name', last_update_id = EXCLUDED.last_update_id,
            expires_at = EXCLUDED.expires_at;
    ELSE
        IF NOT v_has_session THEN RETURN jsonb_build_object('status', 'needs_contact'); END IF;
        IF p_action = 'edit' THEN
            UPDATE leroy_private.registration_sessions SET full_name = NULL, stage = 'name',
                last_update_id = p_update_id WHERE telegram_id = p_telegram_id;
        ELSIF p_action = 'text' AND v_session.stage = 'name' THEN
            IF p_full_name IS NULL OR char_length(p_full_name) NOT BETWEEN 4 AND 200
               OR p_full_name !~ '^[[:alpha:]]' OR p_full_name ~ '[[:cntrl:][:digit:]]'
               OR p_full_name !~ '[[:alpha:]][[:space:]]+[[:alpha:]]' THEN
                RETURN jsonb_build_object('status', 'invalid_name');
            END IF;
            UPDATE leroy_private.registration_sessions SET full_name = p_full_name,
                stage = 'confirm', last_update_id = p_update_id WHERE telegram_id = p_telegram_id;
        ELSIF p_action = 'confirm' AND v_session.stage = 'confirm' THEN
            -- Recheck the phone at confirmation: Make may have added a card meanwhile.
            SELECT count(*) INTO v_count FROM public.designers d
            WHERE regexp_replace(d.phone, '[^0-9]', '', 'g') = v_session.phone_digits;
            IF v_count > 0 THEN
                -- Never overwrite an existing designer's name or rewards.
                v_status := leroy_private.bind_telegram_contact(v_session.phone_digits, p_telegram_id);
                IF v_status IN ('bound', 'already_bound') THEN
                    DELETE FROM leroy_private.registration_sessions WHERE telegram_id = p_telegram_id;
                END IF;
                RETURN jsonb_build_object('status', v_status);
            END IF;
            INSERT INTO public.designers (full_name, phone, telegram_id, level_code, is_active)
            VALUES (v_session.full_name, '+' || v_session.phone_digits, p_telegram_id, 'bronze', true);
            DELETE FROM leroy_private.registration_sessions WHERE telegram_id = p_telegram_id;
            RETURN jsonb_build_object('status', 'registered');
        ELSE
            UPDATE leroy_private.registration_sessions SET last_update_id = p_update_id
            WHERE telegram_id = p_telegram_id;
        END IF;
    END IF;
    SELECT r.* INTO v_session FROM leroy_private.registration_sessions r
    WHERE r.telegram_id = p_telegram_id;
    RETURN jsonb_build_object('status', v_session.stage,
        'full_name', v_session.full_name, 'phone', '+' || v_session.phone_digits);
END;
$$;
ALTER FUNCTION leroy_private.onboard_designer(bigint, text, text, text, bigint) OWNER TO postgres;
REVOKE ALL ON FUNCTION leroy_private.onboard_designer(bigint, text, text, text, bigint)
FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION leroy_private.onboard_designer(bigint, text, text, text, bigint)
TO cabinet_reader;
COMMIT;
-- No welcome bonus is issued here: its amount/rate must be configured separately.
-- Keep Make upserts from overwriting telegram_id or renumbering TG-* designers.

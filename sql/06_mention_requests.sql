-- Run as postgres. Adds requests only; existing accruals and weights are unchanged.
BEGIN;
CREATE TABLE IF NOT EXISTS public.mention_requests (
    request_id text PRIMARY KEY DEFAULT ('MENTION-' || upper(gen_random_uuid()::text)),
    designer_id text NOT NULL REFERENCES public.designers(designer_id),
    publication_url text NOT NULL,
    status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'needs_revision')),
    review_comment text,
    created_at timestamptz NOT NULL DEFAULT now(),
    reviewed_at timestamptz,
    CONSTRAINT mention_requests_url_check CHECK (
      publication_url ~ '^https://www\.instagram\.com/(p|reel|tv)/[A-Za-z0-9_-]+/$'),
    CONSTRAINT mention_requests_review_check CHECK (
      (status = 'accepted' AND reviewed_at IS NOT NULL) OR
      (status <> 'accepted' AND reviewed_at IS NULL)),
    UNIQUE (designer_id, publication_url)
);
CREATE UNIQUE INDEX IF NOT EXISTS mention_requests_one_open
ON public.mention_requests(designer_id) WHERE status <> 'accepted';
ALTER TABLE public.mention_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.mention_requests FROM PUBLIC, anon, authenticated, cabinet_reader, make_connector;

-- Server must verify Telegram initData before passing telegram_id. Not a public RPC.
CREATE OR REPLACE FUNCTION leroy_private.submit_mention_request(
    p_telegram_id bigint, p_publication_url text
) RETURNS public.mention_requests
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE
    v_designer text;
    v_url text;
    v_match text[];
    v_request public.mention_requests%ROWTYPE;
BEGIN
    SELECT d.designer_id INTO v_designer FROM public.designers d
    WHERE d.telegram_id = p_telegram_id AND d.is_active = true FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Активный дизайнер не найден'; END IF;
    IF p_publication_url IS NULL OR length(p_publication_url) > 2048 THEN
        RAISE EXCEPTION 'Некорректная ссылка';
    END IF;
    v_match := regexp_match(trim(p_publication_url),
      '^https://(?:www\.)?instagram\.com/(p|reel|tv)/([A-Za-z0-9_-]+)/?(?:[?#][^[:space:]]*)?$');
    IF v_match IS NULL THEN
        RAISE EXCEPTION 'Нужна ссылка Instagram на публикацию или Reels';
    END IF;
    v_url := 'https://www.instagram.com/' || v_match[1] || '/' || v_match[2] || '/';
    -- Retries of the same publication return the original request.
    SELECT r.* INTO v_request FROM public.mention_requests r
    WHERE r.designer_id = v_designer AND r.publication_url = v_url;
    IF FOUND THEN RETURN v_request; END IF;
    IF EXISTS (SELECT 1 FROM public.mention_requests r
               WHERE r.designer_id = v_designer AND r.status <> 'accepted') THEN
        RAISE EXCEPTION 'Предыдущая отметка ещё не зачтена';
    END IF;
    INSERT INTO public.mention_requests (designer_id, publication_url)
    VALUES (v_designer, v_url) RETURNING * INTO v_request;
    RETURN v_request;
END;
$$;

CREATE OR REPLACE FUNCTION leroy_private.get_mention_requests(p_telegram_id bigint)
RETURNS SETOF public.mention_requests
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
    SELECT r.* FROM public.mention_requests r JOIN public.designers d USING (designer_id)
    WHERE d.telegram_id = p_telegram_id AND d.is_active = true
    ORDER BY r.created_at DESC, r.request_id;
$$;

-- Make reads pages and searches Google by request_id before inserting a row.
CREATE OR REPLACE FUNCTION public.export_mention_requests(p_offset integer DEFAULT 0, p_limit integer DEFAULT 200)
RETURNS TABLE(request_id text, created_at timestamptz, full_name text,
              designer_id text, publication_url text, status text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
BEGIN
    IF p_offset IS NULL OR p_offset < 0 OR p_limit IS NULL OR p_limit NOT BETWEEN 1 AND 500 THEN
        RAISE EXCEPTION 'Некорректный размер страницы';
    END IF;
    RETURN QUERY SELECT r.request_id, r.created_at, d.full_name, r.designer_id,
      r.publication_url, r.status
    FROM public.mention_requests r JOIN public.designers d USING (designer_id)
    ORDER BY r.created_at, r.request_id LIMIT p_limit OFFSET p_offset;
END;
$$;

-- Call only after the existing mention accrual succeeds. This issues no bonus.
-- Event ID in the accrual must equal request_id, not designer_id or sheet row.
CREATE OR REPLACE FUNCTION public.accept_mention_request(p_request_id text, p_designer_id text)
RETURNS public.mention_requests
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE v_request public.mention_requests%ROWTYPE;
BEGIN
    SELECT r.* INTO v_request FROM public.mention_requests r
    WHERE r.request_id = trim(p_request_id) FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Заявка не найдена'; END IF;
    IF v_request.designer_id IS DISTINCT FROM trim(p_designer_id) THEN
        RAISE EXCEPTION 'Дизайнер заявки не совпадает с начислением';
    END IF;
    IF v_request.status = 'accepted' THEN RETURN v_request; END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.designer_activities a
        JOIN public.ledger_entries e ON e.operation_key = 'TEST|ACTIVITY|' || a.activity_id::text
        WHERE a.source_event_id = v_request.request_id AND a.designer_id = v_request.designer_id
          AND a.activity_type = 'mention_bonus' AND e.designer_id = v_request.designer_id
          AND e.operation_type = 'mention_bonus' AND e.currency = 'LR' AND e.amount > 0
    ) THEN RAISE EXCEPTION 'Начисление за эту заявку ещё не подтверждено'; END IF;
    UPDATE public.mention_requests SET status = 'accepted', reviewed_at = now()
    WHERE request_id = v_request.request_id RETURNING * INTO v_request;
    RETURN v_request;
END;
$$;

ALTER FUNCTION leroy_private.submit_mention_request(bigint,text) OWNER TO postgres;
ALTER FUNCTION leroy_private.get_mention_requests(bigint) OWNER TO postgres;
ALTER FUNCTION public.export_mention_requests(integer,integer) OWNER TO postgres;
ALTER FUNCTION public.accept_mention_request(text,text) OWNER TO postgres;
REVOKE ALL ON FUNCTION leroy_private.submit_mention_request(bigint,text),
 leroy_private.get_mention_requests(bigint), public.export_mention_requests(integer,integer),
 public.accept_mention_request(text,text) FROM PUBLIC, anon, authenticated, cabinet_reader, make_connector;
GRANT USAGE ON SCHEMA leroy_private TO cabinet_reader;
GRANT EXECUTE ON FUNCTION leroy_private.submit_mention_request(bigint,text),
 leroy_private.get_mention_requests(bigint) TO cabinet_reader;
GRANT EXECUTE ON FUNCTION public.export_mention_requests(integer,integer),
 public.accept_mention_request(text,text) TO make_connector;
COMMIT;

-- Run in Supabase SQL Editor as postgres. No bonuses or weights are changed.
BEGIN;
CREATE TABLE IF NOT EXISTS public.club_publications (
    publication_id text PRIMARY KEY CHECK (publication_id ~ '^[A-Za-z0-9_-]{1,100}$'),
    publication_type text NOT NULL CHECK (publication_type IN ('news', 'event', 'promotion')),
    title text NOT NULL CHECK (length(trim(title)) BETWEEN 1 AND 300),
    synopsis text NOT NULL DEFAULT '' CHECK (length(synopsis) <= 2000),
    body text NOT NULL DEFAULT '' CHECK (length(body) <= 20000),
    image_url text CHECK (image_url IS NULL OR image_url ~ '^https://[^[:space:]]+$'),
    event_label text,
    publish_from date NOT NULL,
    publish_until date NOT NULL,
    button_label text,
    is_published boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CHECK (publish_until >= publish_from)
);
CREATE TABLE IF NOT EXISTS public.club_event_invitations (
    publication_id text NOT NULL REFERENCES public.club_publications(publication_id),
    designer_id text NOT NULL REFERENCES public.designers(designer_id),
    accepted_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (publication_id, designer_id)
);
ALTER TABLE public.club_publications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.club_event_invitations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.club_publications, public.club_event_invitations
FROM PUBLIC, anon, authenticated, cabinet_reader, make_connector;

-- Called by Make for BOTH published and unpublished rows. Keep IDs unchanged.
-- Deleting a Google row does not unpublish it: set is_published=false via sync.
CREATE OR REPLACE FUNCTION public.sync_club_publication(
    p_publication_id text, p_publication_type text, p_title text,
    p_synopsis text, p_body text, p_image_url text, p_event_label text,
    p_publish_from date, p_publish_until date, p_button_label text, p_is_published boolean
) RETURNS public.club_publications
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE v_type text; v_result public.club_publications%ROWTYPE;
BEGIN
    v_type := CASE lower(trim(p_publication_type))
      WHEN 'новость' THEN 'news' WHEN 'новости' THEN 'news' WHEN 'news' THEN 'news'
      WHEN 'мероприятие' THEN 'event' WHEN 'мероприятия' THEN 'event' WHEN 'event' THEN 'event'
      WHEN 'акция' THEN 'promotion' WHEN 'акции' THEN 'promotion' WHEN 'promotion' THEN 'promotion'
      ELSE NULL END;
    IF v_type IS NULL THEN RAISE EXCEPTION 'Неизвестный тип публикации'; END IF;
    INSERT INTO public.club_publications AS p
      (publication_id, publication_type, title, synopsis, body, image_url, event_label,
       publish_from, publish_until, button_label, is_published)
    VALUES (trim(p_publication_id), v_type, trim(p_title), coalesce(p_synopsis, ''),
      coalesce(p_body, ''), nullif(trim(p_image_url), ''), nullif(trim(p_event_label), ''),
      p_publish_from, p_publish_until, nullif(trim(p_button_label), ''), coalesce(p_is_published, false))
    ON CONFLICT (publication_id) DO UPDATE SET
      publication_type = EXCLUDED.publication_type, title = EXCLUDED.title,
      synopsis = EXCLUDED.synopsis, body = EXCLUDED.body, image_url = EXCLUDED.image_url,
      event_label = EXCLUDED.event_label, publish_from = EXCLUDED.publish_from,
      publish_until = EXCLUDED.publish_until, button_label = EXCLUDED.button_label,
      is_published = EXCLUDED.is_published, updated_at = now()
    RETURNING * INTO v_result;
    RETURN v_result;
END;
$$;

-- Server must verify Telegram initData before passing the Telegram ID.
CREATE OR REPLACE FUNCTION leroy_private.get_club_publications(p_telegram_id bigint)
RETURNS TABLE(publication_id text, publication_type text, title text, synopsis text,
    body text, image_url text, event_label text, button_label text, invitation_accepted boolean,
    accepted_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
    SELECT p.publication_id, p.publication_type, p.title, p.synopsis, p.body,
      p.image_url, p.event_label, p.button_label, i.designer_id IS NOT NULL, i.accepted_at
    FROM public.club_publications p
    JOIN public.designers d ON d.telegram_id = p_telegram_id AND d.is_active = true
    LEFT JOIN public.club_event_invitations i ON i.publication_id = p.publication_id
      AND i.designer_id = d.designer_id
    WHERE p.is_published AND (now() AT TIME ZONE 'Asia/Krasnoyarsk')::date
      BETWEEN p.publish_from AND p.publish_until
    ORDER BY p.publish_from DESC, p.created_at DESC, p.publication_id;
$$;

CREATE OR REPLACE FUNCTION leroy_private.accept_club_invitation(
    p_telegram_id bigint, p_publication_id text
) RETURNS public.club_event_invitations
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE v_designer text; v_publication public.club_publications%ROWTYPE;
    v_result public.club_event_invitations%ROWTYPE;
BEGIN
    SELECT d.designer_id INTO v_designer FROM public.designers d
    WHERE d.telegram_id = p_telegram_id AND d.is_active = true FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Активный дизайнер не найден'; END IF;
    SELECT p.* INTO v_publication FROM public.club_publications p
    WHERE p.publication_id = trim(p_publication_id) FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Мероприятие не найдено'; END IF;
    IF v_publication.publication_type <> 'event' THEN
        RAISE EXCEPTION 'Приглашение доступно только для мероприятий';
    END IF;
    IF NOT v_publication.is_published OR (now() AT TIME ZONE 'Asia/Krasnoyarsk')::date
       NOT BETWEEN v_publication.publish_from AND v_publication.publish_until THEN
        RAISE EXCEPTION 'Приём приглашений сейчас закрыт';
    END IF;
    INSERT INTO public.club_event_invitations(publication_id, designer_id)
    VALUES (v_publication.publication_id, v_designer) ON CONFLICT DO NOTHING;
    SELECT i.* INTO v_result FROM public.club_event_invitations i
    WHERE i.publication_id = v_publication.publication_id AND i.designer_id = v_designer;
    RETURN v_result;
END;
$$;

-- Read-only participant export for Make/admin. No phone numbers or Telegram IDs.
CREATE OR REPLACE FUNCTION public.export_club_invitations(p_publication_id text)
RETURNS TABLE(publication_id text, designer_id text, full_name text, accepted_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
    SELECT i.publication_id, i.designer_id, d.full_name, i.accepted_at
    FROM public.club_event_invitations i JOIN public.designers d USING (designer_id)
    WHERE i.publication_id = trim(p_publication_id) ORDER BY i.accepted_at, i.designer_id;
$$;
ALTER FUNCTION public.sync_club_publication(text,text,text,text,text,text,text,date,date,text,boolean) OWNER TO postgres;
ALTER FUNCTION leroy_private.get_club_publications(bigint) OWNER TO postgres;
ALTER FUNCTION leroy_private.accept_club_invitation(bigint,text) OWNER TO postgres;
ALTER FUNCTION public.export_club_invitations(text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.sync_club_publication(text,text,text,text,text,text,text,date,date,text,boolean),
 leroy_private.get_club_publications(bigint), leroy_private.accept_club_invitation(bigint,text),
 public.export_club_invitations(text) FROM PUBLIC, anon, authenticated, cabinet_reader, make_connector;
GRANT USAGE ON SCHEMA leroy_private TO cabinet_reader;
GRANT EXECUTE ON FUNCTION leroy_private.get_club_publications(bigint),
 leroy_private.accept_club_invitation(bigint,text) TO cabinet_reader;
GRANT EXECUTE ON FUNCTION public.sync_club_publication(text,text,text,text,text,text,text,date,date,text,boolean),
 public.export_club_invitations(text) TO make_connector;
COMMIT;

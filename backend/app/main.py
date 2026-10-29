import logging
from contextlib import asynccontextmanager
import os
import ssl
from pathlib import Path

import psycopg
from dotenv import load_dotenv
from fastapi import FastAPI, Header, HTTPException
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field
from psycopg.rows import dict_row
from psycopg.conninfo import conninfo_to_dict

from .auth import verify_init_data
from .telegram_bot import router as telegram_router, configure_webhook

load_dotenv()
logger = logging.getLogger(__name__)

# Diagnostics log only fixed categories and query names, never driver messages.
_DATABASE_CHECKS = (
    ("designers", "SELECT designer_id, full_name, level_code, telegram_id, is_active, invited_by FROM public.designers LIMIT 0"),
    ("projects", "SELECT project_id, designer_id, order_number, amount_rub, status, delivered_at, created_at FROM public.projects LIMIT 0"),
    ("ledger", "SELECT entry_id, designer_id, project_id, operation_type, currency, amount, event_at FROM public.ledger_entries LIMIT 0"),
    ("rules", "SELECT rub_per_lr, valid_from, rule_version FROM public.reward_rules LIMIT 0"),
)


def database_failure_kind(exc):
    state = getattr(exc, "sqlstate", None)
    known = {"28P01": "password_rejected", "28000": "authentication_rejected",
             "42501": "permission_denied", "42703": "missing_column",
             "42P01": "missing_table", "3D000": "missing_database"}
    if state in known:
        return known[state]
    # Inspect locally; the original message must never reach logs or the client.
    message = str(exc).lower()
    patterns = (
        ("root certificate file", "tls_root_certificate"),
        ("could not read root certificate", "tls_root_certificate"),
        ("certificate verify failed", "tls_certificate_verification"),
        ("does not match host name", "tls_hostname_mismatch"),
        ("password authentication failed", "password_rejected"),
        ("tenant or user not found", "pooler_identity"),
        ("could not translate host name", "dns_lookup"),
        ("name or service not known", "dns_lookup"),
        ("timeout", "connection_timeout"),
        ("connection refused", "connection_refused"),
        ("invalid sslmode", "invalid_connection_string"),
        ("invalid uri", "invalid_connection_string"),
        ("invalid connection option", "invalid_connection_string"),
        ("ssl connection is required", "tls_required"),
        ("wrong password", "password_rejected"),
        ("server login has been failing", "pooler_login_failure"),
        ("no pg_hba.conf entry", "database_access_rejected"),
        ("network is unreachable", "network_unreachable"),
        ("connection reset", "connection_reset"),
        ("server closed the connection", "connection_closed"),
        ("eof detected", "connection_closed"),
        ("missing \"=\"", "invalid_connection_string"),
        ("invalid percent-encoded token", "invalid_connection_string"),
    )
    for fragment, category in patterns:
        if fragment in message:
            return category
    return "database_error"


def log_database_failure(exc, phase):
    state = getattr(exc, "sqlstate", None)
    state = state if isinstance(state, str) and len(state) == 5 and state.isalnum() else "none"
    markers = ("ssl", "certificate", "password", "tenant", "authentication",
               "invalid", "connection", "timeout", "file", "permission", "encoding",
               "sasl", "scram", "fatal", "eof", "resolve", "port")
    message = str(exc).lower()
    matched = ",".join(word for word in markers if word in message) or "none"
    logger.error("Cabinet database check failed: phase=%s category=%s type=%s state=%s markers=%s",
                 phase, database_failure_kind(exc), type(exc).__name__, state, matched)


def log_database_configuration(database):
    try:
        params = conninfo_to_dict(database)
    except psycopg.Error:
        logger.error("Cabinet database configuration: invalid_connection_string")
        return
    mode_ok = params.get("sslmode") == "verify-full"
    role_ok = params.get("user", "").startswith("cabinet_reader.")
    port_ok = str(params.get("port", "")) == "5432"
    password_set = bool(params.get("password"))
    cert = params.get("sslrootcert") or os.getenv("PGSSLROOTCERT")
    cert_status = "not_configured"
    if cert:
        try:
            ssl.create_default_context(cafile=cert)
            cert_status = "loaded"
        except FileNotFoundError:
            cert_status = "missing"
        except PermissionError:
            cert_status = "unreadable"
        except (ssl.SSLError, OSError):
            cert_status = "invalid"
    logger.warning("Cabinet database configuration: role_ok=%s port_ok=%s password_set=%s sslmode_ok=%s certificate=%s",
                   role_ok, port_ok, password_set, mode_ok, cert_status)


def check_database_startup():
    database = os.getenv("DATABASE_URL", "")
    if not database:
        logger.warning("Cabinet database startup check skipped: database_not_configured")
        return
    log_database_configuration(database)
    phase = "connect"
    try:
        with psycopg.connect(database, connect_timeout=5, row_factory=dict_row) as conn:
            conn.execute("SET TRANSACTION READ ONLY")
            conn.execute("SET LOCAL statement_timeout = '5s'")
            for phase, query in _DATABASE_CHECKS:
                conn.execute(query)
        logger.info("Cabinet database startup check passed")
    except psycopg.Error as exc:
        log_database_failure(exc, phase)


@asynccontextmanager
async def lifespan(application):
    check_database_startup()
    configure_webhook()
    yield


app = FastAPI(title="LEROY Designer Cabinet", docs_url=None, redoc_url=None,
              openapi_url=None, lifespan=lifespan)

app.include_router(telegram_router)


@app.middleware("http")
async def security_headers(request, call_next):
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Referrer-Policy"] = "no-referrer"
    if request.url.path.startswith("/api/"):
        response.headers["Cache-Control"] = "no-store"
    return response


def referral_url(designer_id):
    import re
    username = os.getenv("TELEGRAM_BOT_USERNAME", "").lstrip("@")
    if (os.getenv("REFERRALS_ENABLED", "false").lower() != "true"
            or not re.fullmatch(r"[A-Za-z0-9_]{5,32}", username)
            or not re.fullmatch(r"[A-Za-z0-9_-]{1,60}", designer_id)):
        return None
    return f"https://t.me/{username}?start=ref_{designer_id}"


@app.get("/api/health")
def health():
    return {"status": "ok"}


@app.get("/api/config")
def config():
    return {"demo_available": os.getenv("DEMO_MODE", "false").strip().lower() == "true"}


@app.get("/api/cabinet")
def cabinet(authorization: str | None = Header(default=None)):
    token = os.getenv("BOT_TOKEN", "")
    database = os.getenv("DATABASE_URL", "")
    if not token or not database:
        raise HTTPException(503, "Подключение кабинета ещё не настроено")
    if not authorization or not authorization.startswith("tma "):
        raise HTTPException(401, "Откройте кабинет через Telegram")
    try:
        telegram_id = verify_init_data(authorization[4:], token)
    except ValueError:
        raise HTTPException(401, "Вход истёк или не подтверждён. Откройте кабинет заново") from None
    phase = "connect"
    try:
        with psycopg.connect(database, connect_timeout=5, row_factory=dict_row) as conn:
            with conn.transaction():
                conn.execute("SET TRANSACTION READ ONLY")
                conn.execute("SET LOCAL statement_timeout = '5s'")
                phase = "designer"
                designer = conn.execute(
                    "SELECT designer_id, full_name, level_code FROM public.designers "
                    "WHERE telegram_id = %s AND is_active = true", (telegram_id,)
                ).fetchone()
                if not designer:
                    raise HTTPException(403, "Ваш Telegram ещё не привязан к карточке дизайнера. Обратитесь к менеджеру")
                did = designer["designer_id"]
                # Accrued amounts only: there is no payout/debit ledger yet.
                phase = "balance"
                balance = conn.execute(
                    "SELECT COALESCE(SUM(amount) FILTER (WHERE currency = 'RUB'), 0) AS commission_rub, "
                    "COALESCE(SUM(amount) FILTER (WHERE currency = 'LR'), 0) AS bonus_lr "
                    "FROM public.ledger_entries WHERE designer_id = %s", (did,)
                ).fetchone()
                phase = "operations"
                operations = conn.execute(
                    "SELECT e.operation_type, e.currency, e.amount, e.event_at, p.order_number "
                    "FROM public.ledger_entries e LEFT JOIN public.projects p ON p.project_id = e.project_id "
                    "WHERE e.designer_id = %s ORDER BY e.event_at DESC, e.entry_id DESC LIMIT 30", (did,)
                ).fetchall()
                phase = "projects"
                projects = conn.execute(
                    "SELECT order_number, amount_rub, status, delivered_at FROM public.projects "
                    "WHERE designer_id = %s ORDER BY created_at DESC, project_id DESC LIMIT 30", (did,)
                ).fetchall()
                # Dashboard totals cover every project, independently of the 30-row list.
                phase = "project_summary"
                project_summary = conn.execute(
                    "SELECT COUNT(*) FILTER (WHERE status = 'in_progress') AS active, "
                    "COUNT(*) FILTER (WHERE status = 'delivered') AS delivered, COUNT(*) AS total, "
                    "COALESCE(SUM(amount_rub) FILTER (WHERE status <> 'cancelled'), 0) AS total_amount_rub "
                    "FROM public.projects WHERE designer_id = %s", (did,)
                ).fetchone()
                phase = "rules"
                rule = conn.execute(
                    "SELECT rub_per_lr FROM public.reward_rules WHERE valid_from <= now() "
                    "ORDER BY valid_from DESC, rule_version DESC LIMIT 1"
                ).fetchone()
                phase = "referrals"
                referrals = conn.execute(
                    "SELECT designer_id, full_name, created_at FROM public.designers "
                    "WHERE invited_by = %s AND telegram_id IS NOT NULL "
                    "ORDER BY created_at DESC, designer_id", (did,)
                ).fetchall()
                return {"designer": designer, "balance": balance, "operations": operations,
                        "projects": projects, "project_summary": project_summary,
                        "rub_per_lr": rule["rub_per_lr"] if rule else None,
                        "loyalty": None, "referral_count": len(referrals), "referrals": referrals,
                        "referral_url": referral_url(did), "test_mode": True}
    except psycopg.Error as exc:
        log_database_failure(exc, phase)
        raise HTTPException(503, "База временно недоступна. Попробуйте позже") from None


class MentionSubmission(BaseModel):
    publication_url: str = Field(min_length=1, max_length=2048)


def mention_identity(authorization):
    if not authorization or not authorization.startswith("tma "):
        raise HTTPException(401, "Откройте кабинет через Telegram")
    token = os.getenv("BOT_TOKEN", "")
    if not token or not os.getenv("DATABASE_URL"):
        raise HTTPException(503, "Подключение кабинета ещё не настроено")
    try:
        return verify_init_data(authorization[4:], token)
    except ValueError:
        raise HTTPException(401, "Вход истёк. Откройте кабинет заново") from None


def mention_query(uid, url=None):
    try:
        with psycopg.connect(os.environ["DATABASE_URL"], connect_timeout=5, row_factory=dict_row) as conn:
            conn.execute("SET TRANSACTION READ WRITE" if url is not None else "SET TRANSACTION READ ONLY")
            conn.execute("SET LOCAL statement_timeout = '5s'")
            conn.execute("SET LOCAL lock_timeout = '2s'")
            if url is None:
                return conn.execute("SELECT * FROM leroy_private.get_mention_requests(%s)", (uid,)).fetchall()
            return conn.execute("SELECT * FROM leroy_private.submit_mention_request(%s, %s)", (uid, url)).fetchone()
    except psycopg.errors.RaiseException as exc:
        allowed = {"Активный дизайнер не найден", "Некорректная ссылка",
                   "Нужна ссылка Instagram на публикацию или Reels", "Предыдущая отметка ещё не зачтена"}
        message = exc.diag.message_primary
        raise HTTPException(400, message if message in allowed else "Не удалось отправить заявку") from None
    except psycopg.Error as exc:
        log_database_failure(exc, "mentions")
        raise HTTPException(503, "Не удалось подтвердить сохранение. Обновите список перед повторной отправкой") from None


@app.get("/api/mentions")
def get_mentions(authorization: str | None = Header(default=None)):
    return {"requests": mention_query(mention_identity(authorization))}


@app.post("/api/mentions")
def submit_mention(body: MentionSubmission, authorization: str | None = Header(default=None)):
    return {"request": mention_query(mention_identity(authorization), body.publication_url)}


class InvitationAcceptance(BaseModel):
    publication_id: str = Field(min_length=1, max_length=100)


def publication_query(uid, publication_id=None):
    try:
        with psycopg.connect(os.environ["DATABASE_URL"], connect_timeout=5, row_factory=dict_row) as conn:
            conn.execute("SET TRANSACTION READ WRITE" if publication_id is not None else "SET TRANSACTION READ ONLY")
            conn.execute("SET LOCAL statement_timeout = '5s'")
            conn.execute("SET LOCAL lock_timeout = '2s'")
            if publication_id is None:
                return conn.execute("SELECT * FROM leroy_private.get_club_publications(%s)", (uid,)).fetchall()
            return conn.execute("SELECT * FROM leroy_private.accept_club_invitation(%s, %s)", (uid, publication_id)).fetchone()
    except psycopg.errors.RaiseException as exc:
        allowed = {"Активный дизайнер не найден", "Мероприятие не найдено",
                   "Приглашение доступно только для мероприятий", "Приём приглашений сейчас закрыт"}
        message = exc.diag.message_primary
        raise HTTPException(400, message if message in allowed else "Не удалось принять приглашение") from None
    except psycopg.Error as exc:
        log_database_failure(exc, "publications")
        raise HTTPException(503, "Не удалось подтвердить результат. Обновите список событий") from None


@app.get("/api/publications")
def get_publications(authorization: str | None = Header(default=None)):
    return {"publications": publication_query(mention_identity(authorization))}


@app.post("/api/publications/accept")
def accept_publication(body: InvitationAcceptance, authorization: str | None = Header(default=None)):
    return {"invitation": publication_query(mention_identity(authorization), body.publication_id)}


static = Path(__file__).resolve().parents[2] / "frontend" / "dist"
if static.is_dir():
    app.mount("/", StaticFiles(directory=static, html=True), name="frontend")






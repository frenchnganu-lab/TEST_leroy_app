import logging
import os
from pathlib import Path

import psycopg
from dotenv import load_dotenv
from fastapi import FastAPI, Header, HTTPException
from fastapi.staticfiles import StaticFiles
from psycopg.rows import dict_row

from .auth import verify_init_data

load_dotenv()
app = FastAPI(title="LEROY Designer Cabinet", docs_url=None, redoc_url=None, openapi_url=None)
logger = logging.getLogger(__name__)


@app.middleware("http")
async def security_headers(request, call_next):
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Referrer-Policy"] = "no-referrer"
    if request.url.path.startswith("/api/"):
        response.headers["Cache-Control"] = "no-store"
    return response


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
    try:
        with psycopg.connect(database, connect_timeout=5, row_factory=dict_row) as conn:
            with conn.transaction():
                conn.execute("SET TRANSACTION READ ONLY")
                conn.execute("SET LOCAL statement_timeout = '5s'")
                designer = conn.execute(
                    "SELECT designer_id, full_name, level_code FROM public.designers "
                    "WHERE telegram_id = %s AND is_active = true", (telegram_id,)
                ).fetchone()
                if not designer:
                    raise HTTPException(403, "Ваш Telegram ещё не привязан к карточке дизайнера. Обратитесь к менеджеру")
                did = designer["designer_id"]
                # Accrued amounts only: there is no payout/debit ledger yet.
                balance = conn.execute(
                    "SELECT COALESCE(SUM(amount) FILTER (WHERE currency = 'RUB'), 0) AS commission_rub, "
                    "COALESCE(SUM(amount) FILTER (WHERE currency = 'LR'), 0) AS bonus_lr "
                    "FROM public.ledger_entries WHERE designer_id = %s", (did,)
                ).fetchone()
                operations = conn.execute(
                    "SELECT e.operation_type, e.currency, e.amount, e.event_at, p.order_number "
                    "FROM public.ledger_entries e LEFT JOIN public.projects p ON p.project_id = e.project_id "
                    "WHERE e.designer_id = %s ORDER BY e.event_at DESC, e.entry_id DESC LIMIT 30", (did,)
                ).fetchall()
                projects = conn.execute(
                    "SELECT order_number, amount_rub, status, delivered_at FROM public.projects "
                    "WHERE designer_id = %s ORDER BY created_at DESC, project_id DESC LIMIT 30", (did,)
                ).fetchall()
                # Dashboard totals cover every project, independently of the 30-row list.
                project_summary = conn.execute(
                    "SELECT COUNT(*) FILTER (WHERE status = 'in_progress') AS active, "
                    "COUNT(*) FILTER (WHERE status = 'delivered') AS delivered, COUNT(*) AS total, "
                    "COALESCE(SUM(amount_rub) FILTER (WHERE status <> 'cancelled'), 0) AS total_amount_rub "
                    "FROM public.projects WHERE designer_id = %s", (did,)
                ).fetchone()
                rule = conn.execute(
                    "SELECT rub_per_lr FROM public.reward_rules WHERE valid_from <= now() "
                    "ORDER BY valid_from DESC, rule_version DESC LIMIT 1"
                ).fetchone()
                referrals = conn.execute(
                    "SELECT COUNT(*) AS count FROM public.designers WHERE invited_by = %s", (did,)
                ).fetchone()["count"]
                return {"designer": designer, "balance": balance, "operations": operations,
                        "projects": projects, "project_summary": project_summary,
                        "rub_per_lr": rule["rub_per_lr"] if rule else None,
                        "loyalty": None, "referral_count": referrals, "test_mode": True}
    except psycopg.Error:
        # Do not log DSNs, credentials, auth headers or database error messages.
        logger.error("Cabinet database request failed")
        raise HTTPException(503, "База временно недоступна. Попробуйте позже") from None


static = Path(__file__).resolve().parents[2] / "frontend" / "dist"
if static.is_dir():
    app.mount("/", StaticFiles(directory=static, html=True), name="frontend")

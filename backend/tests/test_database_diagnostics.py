import logging
from contextlib import contextmanager
from unittest.mock import Mock

import psycopg
import pytest

from app.main import check_database_startup, database_failure_kind


@pytest.mark.parametrize(("error", "expected"), [
    (psycopg.OperationalError("root certificate file /private/path does not exist"), "tls_root_certificate"),
    (psycopg.OperationalError("SSL error: certificate verify failed"), "tls_certificate_verification"),
    (psycopg.OperationalError("server certificate does not match host name"), "tls_hostname_mismatch"),
    (psycopg.OperationalError("FATAL: Tenant or user not found"), "pooler_identity"),
    (psycopg.OperationalError("could not translate host name"), "dns_lookup"),
    (psycopg.OperationalError("connection timeout expired"), "connection_timeout"),
    (psycopg.OperationalError("invalid sslmode value"), "invalid_connection_string"),
    (psycopg.errors.InvalidPassword("secret password"), "password_rejected"),
    (psycopg.errors.InsufficientPrivilege("private details"), "permission_denied"),
    (psycopg.errors.UndefinedColumn("private column"), "missing_column"),
])
def test_error_categories(error, expected):
    assert database_failure_kind(error) == expected


def test_no_database_skips_connection(monkeypatch):
    monkeypatch.delenv("DATABASE_URL", raising=False)
    connect = Mock()
    monkeypatch.setattr("app.main.psycopg.connect", connect)
    check_database_startup()
    connect.assert_not_called()


def test_probe_never_logs_connection_secrets(monkeypatch, caplog):
    secret = "postgresql://user:SENSITIVE_PASSWORD@private-host/database"
    monkeypatch.setenv("DATABASE_URL", secret)
    connect = Mock(side_effect=psycopg.OperationalError(
        f"password authentication failed DSN={secret}"))
    monkeypatch.setattr("app.main.psycopg.connect", connect)
    with caplog.at_level(logging.ERROR):
        check_database_startup()
    assert "phase=connect category=password_rejected" in caplog.text
    assert secret not in caplog.text
    assert "SENSITIVE_PASSWORD" not in caplog.text
    assert "private-host" not in caplog.text


def test_probe_checks_schema_without_reading_rows(monkeypatch):
    monkeypatch.setenv("DATABASE_URL", "not-a-real-dsn")
    conn = Mock()

    @contextmanager
    def connect(*args, **kwargs):
        yield conn

    monkeypatch.setattr("app.main.psycopg.connect", connect)
    check_database_startup()
    queries = [call.args[0] for call in conn.execute.call_args_list]
    assert queries[0] == "SET TRANSACTION READ ONLY"
    schema_queries = [query for query in queries if query.startswith("SELECT ")]
    assert len(schema_queries) == 4
    assert all(query.endswith("LIMIT 0") for query in schema_queries)
    assert any("public.reward_rules" in query for query in schema_queries)
    conn.execute.return_value.fetchall.assert_not_called()


def test_probe_identifies_schema_stage_without_logging_details(monkeypatch, caplog):
    monkeypatch.setenv("DATABASE_URL", "not-a-real-dsn")
    conn = Mock()

    def execute(query):
        if "public.projects" in query:
            raise psycopg.errors.UndefinedColumn("PRIVATE_SQL_CONTENT")
        return Mock()

    conn.execute.side_effect = execute

    @contextmanager
    def connect(*args, **kwargs):
        yield conn

    monkeypatch.setattr("app.main.psycopg.connect", connect)
    with caplog.at_level(logging.ERROR):
        check_database_startup()
    assert "phase=projects category=missing_column" in caplog.text
    assert "PRIVATE_SQL_CONTENT" not in caplog.text

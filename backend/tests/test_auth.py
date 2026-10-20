import hashlib
import hmac
import json
from urllib.parse import urlencode

import pytest
from fastapi.testclient import TestClient
from app.auth import verify_init_data
from app.main import app

TOKEN = 'test-token-not-a-real-bot'
NOW = 1_800_000_000


def signed(**extra):
    data = {'auth_date': str(NOW), 'user': json.dumps({'id': 123456})} | extra
    check = '\n'.join(f'{k}={v}' for k, v in sorted(data.items()))
    key = hmac.new(b'WebAppData', TOKEN.encode(), hashlib.sha256).digest()
    data['hash'] = hmac.new(key, check.encode(), hashlib.sha256).hexdigest()
    return urlencode(data)


def test_valid_and_additional_signed_fields():
    assert verify_init_data(signed(signature='signed-future-field'), TOKEN, now=NOW) == 123456


@pytest.mark.parametrize('raw', [signed() + '&user=x', signed().replace('123456', '999999'), 'hash=bad', signed(user='{}'), signed(user='{"id":true}')])
def test_invalid_auth(raw):
    with pytest.raises(ValueError):
        verify_init_data(raw, TOKEN, now=NOW)


@pytest.mark.parametrize('clock', [NOW + 3601, NOW - 31])
def test_expired_or_future(clock):
    with pytest.raises(ValueError):
        verify_init_data(signed(), TOKEN, now=clock)


def test_wrong_bot():
    with pytest.raises(ValueError):
        verify_init_data(signed(), 'another-token', now=NOW)


def test_missing_auth_never_connects_database(monkeypatch):
    monkeypatch.setenv('BOT_TOKEN', TOKEN)
    monkeypatch.setenv('DATABASE_URL', 'not-a-real-dsn')
    def forbidden(*args, **kwargs):
        raise AssertionError('Database must not be called for invalid auth')
    monkeypatch.setattr('app.main.psycopg.connect', forbidden)
    client = TestClient(app)
    assert client.get('/api/cabinet').status_code == 401
    assert client.get('/api/cabinet', headers={'Authorization': 'tma hash=bad'}).status_code == 401
    assert client.get('/api/health').json() == {'status': 'ok'}
    assert client.get('/api/config').headers['cache-control'] == 'no-store'


def test_demo_is_explicit_and_never_authenticates(monkeypatch):
    monkeypatch.delenv('DEMO_MODE', raising=False)
    monkeypatch.delenv('BOT_TOKEN', raising=False)
    client = TestClient(app)
    assert client.get('/api/config').json() == {'demo_available': False}
    monkeypatch.setenv('DEMO_MODE', 'true')
    assert client.get('/api/config').json() == {'demo_available': True}
    assert client.get('/api/cabinet').status_code == 503


def test_all_data_queries_are_scoped_to_authenticated_designer(monkeypatch):
    from contextlib import nullcontext
    queries = []
    class Result:
        def __init__(self, one=None, many=None):
            self.one, self.many = one, many or []
        def fetchone(self):
            return self.one
        def fetchall(self):
            return self.many
    class Connection:
        def __enter__(self): return self
        def __exit__(self, *args): pass
        def transaction(self): return nullcontext()
        def execute(self, query, params=None):
            queries.append((query, params))
            if 'WHERE telegram_id' in query:
                assert params == (123456,)
                return Result({'designer_id': 'OWN', 'full_name': 'Test', 'level_code': 'bronze'})
            if query.startswith('SELECT'):
                assert params == ('OWN',)
                if 'SUM(amount)' in query:
                    return Result({'commission_rub': 0, 'bonus_lr': 0})
                if 'COUNT(*)' in query:
                    return Result({'count': 0})
                return Result(many=[])
            return Result()
    monkeypatch.setenv('BOT_TOKEN', TOKEN)
    monkeypatch.setenv('DATABASE_URL', 'unused')
    monkeypatch.setattr('app.main.verify_init_data', lambda raw, token: 123456)
    monkeypatch.setattr('app.main.psycopg.connect', lambda *args, **kwargs: Connection())
    response = TestClient(app).get('/api/cabinet?designer_id=OTHER', headers={'Authorization': 'tma signed'})
    assert response.status_code == 200
    assert response.json()['designer']['designer_id'] == 'OWN'
    assert len([q for q, p in queries if q.startswith('SELECT')]) == 5

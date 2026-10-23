from unittest.mock import Mock

import psycopg
import pytest
from fastapi.testclient import TestClient

from app.main import app
from app import telegram_bot as bot

SECRET = 'test_webhook_secret_not_real_123456789'
URL = 'https://cabinet.example.com'


@pytest.fixture
def setup(monkeypatch):
    monkeypatch.setenv('TELEGRAM_WEBHOOK_SECRET', SECRET)
    monkeypatch.setenv('PUBLIC_APP_URL', URL)
    monkeypatch.setenv('BOT_TOKEN', 'test-token-not-real')
    send = Mock()
    bind = Mock(return_value='bound')
    monkeypatch.setattr(bot, 'telegram_call', send)
    monkeypatch.setattr(bot, 'bind_contact', bind)
    return TestClient(app), send, bind


def event(contact=None, **extra):
    message = {'from': {'id': 123, 'is_bot': False},
               'chat': {'id': 123, 'type': 'private'}, 'text': '/start'}
    if contact is not None:
        message['contact'] = contact
    message.update(extra)
    return {'update_id': 1, 'message': message}


def post(client, payload, secret=SECRET):
    headers = {} if secret is None else {'X-Telegram-Bot-Api-Secret-Token': secret}
    return client.post('/api/telegram/webhook', json=payload, headers=headers)


@pytest.mark.parametrize('secret', [None, 'wrong', b'\xff' * 40])
def test_untrusted_webhook_never_processes_contact(setup, secret):
    client, send, bind = setup
    assert post(client, event({'user_id': 123, 'phone_number': '+79991234567'}), secret).status_code == 403
    send.assert_not_called()
    bind.assert_not_called()


def test_disabled_without_secret(setup, monkeypatch):
    client, send, bind = setup
    monkeypatch.delenv('TELEGRAM_WEBHOOK_SECRET')
    assert post(client, event()).status_code == 503
    send.assert_not_called()


def test_start_requests_own_contact(setup):
    client, send, bind = setup
    assert post(client, event()).status_code == 200
    payload = send.call_args.args[1]
    assert payload['chat_id'] == 123
    assert payload['reply_markup']['keyboard'][0][0]['request_contact'] is True
    bind.assert_not_called()


@pytest.mark.parametrize('contact', [
    {'user_id': 999, 'phone_number': '+79991234567'},
    {'phone_number': '+79991234567'},
    {'user_id': True, 'phone_number': '+79991234567'},
    {'user_id': 123, 'phone_number': 'call me 79991234567'},
    {'user_id': 123, 'phone_number': '123'},
])
def test_invalid_or_foreign_contact_cannot_bind(setup, contact):
    client, send, bind = setup
    assert post(client, event(contact)).status_code == 200
    bind.assert_not_called()
    assert 'web_app' not in str(send.call_args)


@pytest.mark.parametrize('extra', [
    {'chat': {'id': -100, 'type': 'group'}},
    {'chat': {'id': 999, 'type': 'private'}},
    {'from': {'id': True}},
    {'forward_origin': {'type': 'user'}},
])
def test_group_or_forwarded_contact_cannot_bind(setup, extra):
    client, send, bind = setup
    assert post(client, event({'user_id': 123, 'phone_number': '+79991234567'}, **extra)).status_code == 200
    bind.assert_not_called()


@pytest.mark.parametrize('status', ['bound', 'already_bound'])
def test_verified_contact_binds_sender_and_opens_same_app(setup, status):
    client, send, bind = setup
    bind.return_value = status
    assert post(client, event({'user_id': 123, 'phone_number': '+7 (999) 123-45-67'})).status_code == 200
    bind.assert_called_once_with('79991234567', 123)
    assert send.call_args.args[1]['reply_markup']['inline_keyboard'][0][0]['web_app']['url'] == URL


@pytest.mark.parametrize('status', ['not_found', 'inactive', 'ambiguous', 'card_conflict', 'account_conflict'])
def test_conflicts_do_not_open_cabinet_or_leak_card_data(setup, status):
    client, send, bind = setup
    bind.return_value = status
    assert post(client, event({'user_id': 123, 'phone_number': '+79991234567'})).status_code == 200
    payload = send.call_args.args[1]
    assert payload['reply_markup'] == {'remove_keyboard': True}
    assert '79991234567' not in str(payload)
    assert status not in str(payload)


def test_db_error_returns_retry_without_logging_secrets(setup, caplog):
    client, send, bind = setup
    bind.side_effect = psycopg.OperationalError('password=must-not-leak')
    response = post(client, event({'user_id': 123, 'phone_number': '+79991234567'}))
    assert response.status_code == 503
    assert 'must-not-leak' not in response.text + caplog.text
    send.assert_not_called()


def test_delivery_retry_after_bind_is_idempotent(setup):
    client, send, bind = setup
    payload = event({'user_id': 123, 'phone_number': '+79991234567'})
    send.side_effect = RuntimeError('telegram_api_failed')
    assert post(client, payload).status_code == 503
    send.side_effect = None
    bind.return_value = 'already_bound'
    assert post(client, payload).status_code == 200


def test_configure_webhook_uses_secret_header_contract(setup):
    client, send, bind = setup
    bot.configure_webhook()
    method, payload = send.call_args.args
    assert method == 'setWebhook'
    assert payload['url'] == URL + '/api/telegram/webhook'
    assert payload['secret_token'] == SECRET
    assert payload['allowed_updates'] == ['message']
    assert 'drop_pending_updates' not in payload


@pytest.mark.parametrize('url', ['http://example.com', 'https://user:pass@example.com',
                               'https://example.com/?token=x', 'https://example.com/other'])
def test_bad_public_url_fails_closed(setup, monkeypatch, url):
    client, send, bind = setup
    monkeypatch.setenv('PUBLIC_APP_URL', url)
    assert post(client, event()).status_code == 503
    send.assert_not_called()


def test_bind_uses_restricted_function_and_commits_before_reply(monkeypatch):
    queries = []
    class Connection:
        def __enter__(self): return self
        def __exit__(self, *args): queries.append(('closed', args))
        def execute(self, query, params=None):
            queries.append((query, params))
            return self
        def fetchone(self): return {'status': 'bound'}
    monkeypatch.setenv('DATABASE_URL', 'test-dsn')
    monkeypatch.setattr(bot.psycopg, 'connect', lambda *args, **kwargs: Connection())
    assert bot.bind_contact('79991234567', 123) == 'bound'
    assert queries[0][0] == 'SET TRANSACTION READ WRITE'
    assert queries[-2] == ('SELECT leroy_private.bind_telegram_contact(%s, %s) AS status', ('79991234567', 123))
    assert queries[-1][0] == 'closed'

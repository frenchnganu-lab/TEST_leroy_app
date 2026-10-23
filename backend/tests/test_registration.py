from unittest.mock import Mock

import pytest
from fastapi.testclient import TestClient
from app.main import app
from app import registration as reg
from app import telegram_bot as bot


@pytest.fixture
def setup(monkeypatch):
    monkeypatch.setenv('AUTO_REGISTRATION_ENABLED', 'true')
    monkeypatch.setenv('TELEGRAM_WEBHOOK_SECRET', 'test_webhook_secret_not_real_123456789')
    monkeypatch.setenv('PUBLIC_APP_URL', 'https://cabinet.example.com')
    advance = Mock(return_value={'status': 'needs_contact'})
    send = Mock()
    monkeypatch.setattr(reg, 'advance', advance)
    monkeypatch.setattr(bot, 'telegram_call', send)
    return TestClient(app), advance, send


def post(client, text=None, contact=None, **extra):
    message = {'from': {'id': 123}, 'chat': {'id': 123, 'type': 'private'}}
    if text is not None: message['text'] = text
    if contact is not None: message['contact'] = contact
    message.update(extra)
    return client.post('/api/telegram/webhook', json={'update_id': 10, 'message': message},
        headers={'X-Telegram-Bot-Api-Secret-Token': 'test_webhook_secret_not_real_123456789'})


@pytest.mark.parametrize('name', ['Иванов Иван Иванович', 'Ли Ли', "O’Neil John", 'Jean-Pierre Dupont'])
def test_names(name):
    assert reg.normalize_name(name) == name


@pytest.mark.parametrize('name', ['79991234567', 'Иван', '=IMPORTXML(1)', 'Иванов Иван\x00', 'A <B>', 'Иван 123'])
def test_invalid_names(name):
    assert reg.normalize_name(name) is None


def test_start_and_typed_phone_do_not_prove_contact(setup):
    client, advance, send = setup
    post(client, '/start')
    assert advance.call_args.args == (123, 'resume', 10, None, None)
    post(client, '+79991234567')
    assert advance.call_args.args == (123, 'text', 10, None, None)
    assert send.call_args.args[1]['reply_markup']['keyboard'][0][0]['request_contact'] is True


def test_verified_contact_starts_name_form(setup):
    client, advance, send = setup
    advance.return_value = {'status': 'name'}
    assert post(client, contact={'user_id': 123, 'phone_number': '+79991234567'}).status_code == 200
    advance.assert_called_once_with(123, 'contact', 10, '79991234567', None)
    assert 'ФИО' in send.call_args.args[1]['reply_markup']['input_field_placeholder'] or 'фамилию' in send.call_args.args[1]['reply_markup']['input_field_placeholder']


@pytest.mark.parametrize('extra,contact', [
    ({}, {'user_id': 999, 'phone_number': '+79991234567'}),
    ({}, {'phone_number': '+79991234567'}),
    ({}, {'user_id': True, 'phone_number': '+79991234567'}),
    ({'forward_origin': {'type': 'user'}}, {'user_id': 123, 'phone_number': '+79991234567'}),
    ({'chat': {'type': 'group', 'id': -1}}, {'user_id': 123, 'phone_number': '+79991234567'}),
])
def test_foreign_contact_never_reaches_registration(setup, extra, contact):
    client, advance, send = setup
    assert post(client, contact=contact, **extra).status_code == 200
    advance.assert_not_called()


def test_name_is_reviewed_before_registration(setup):
    client, advance, send = setup
    advance.return_value = {'status': 'confirm', 'full_name': 'Иванов Иван', 'phone': '+79991234567'}
    post(client, '  Иванов   Иван  ')
    advance.assert_called_once_with(123, 'text', 10, None, 'Иванов Иван')
    payload = send.call_args.args[1]
    assert 'Иванов Иван' in payload['text']
    assert payload['reply_markup']['keyboard'][0][0]['text'] == 'Всё верно'
    assert 'inline_keyboard' not in payload['reply_markup']


@pytest.mark.parametrize('text,action', [('Всё верно', 'confirm'), ('Изменить ФИО', 'edit'), ('Отмена', 'cancel')])
def test_confirmation_controls(setup, text, action):
    client, advance, send = setup
    post(client, text)
    advance.assert_called_once_with(123, action, 10, None, None)


def test_ready_profile_opens_cabinet(setup):
    client, advance, send = setup
    advance.return_value = {'status': 'registered'}
    post(client, 'Всё верно')
    assert send.call_args.args[1]['reply_markup']['inline_keyboard'][0][0]['web_app']['url'] == 'https://cabinet.example.com'

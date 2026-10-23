"""Private-chat onboarding. Credentials and contacts must never be logged."""
import hmac
import json
import logging
import os
import re
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

import psycopg
from fastapi import APIRouter, Header, HTTPException
from psycopg.rows import dict_row

router = APIRouter()
logger = logging.getLogger(__name__)


def app_url():
    value = os.getenv('PUBLIC_APP_URL', '').rstrip('/')
    parsed = urlsplit(value)
    if (parsed.scheme != 'https' or not parsed.hostname or parsed.username
            or parsed.password or parsed.query or parsed.fragment or parsed.path):
        raise ValueError('invalid_public_app_url')
    return value


def webhook_secret():
    value = os.getenv('TELEGRAM_WEBHOOK_SECRET', '')
    if not re.fullmatch(r'[A-Za-z0-9_-]{32,256}', value):
        raise ValueError('invalid_webhook_secret')
    return value


def positive_id(value):
    return type(value) is int and 0 < value <= 9223372036854775807


def phone_digits(value):
    if not isinstance(value, str) or not re.fullmatch(r'\+?[0-9 ()-]+', value):
        raise ValueError('invalid_phone')
    digits = re.sub(r'[^0-9]', '', value)
    if not re.fullmatch(r'[1-9][0-9]{7,14}', digits):
        raise ValueError('invalid_phone')
    return digits


def telegram_call(method, payload):
    token = os.getenv('BOT_TOKEN', '')
    if not token:
        raise RuntimeError('bot_not_configured')
    request = Request(
        f'https://api.telegram.org/bot{token}/{method}',
        data=json.dumps(payload).encode(),
        headers={'Content-Type': 'application/json'}, method='POST',
    )
    try:
        with urlopen(request, timeout=10) as response:
            result = json.load(response)
        if not isinstance(result, dict) or result.get('ok') is not True:
            raise RuntimeError('telegram_api_failed')
        return result.get('result')
    except (HTTPError, URLError, OSError, ValueError):
        # No exception chaining: HTTPError includes the bot token in its URL.
        raise RuntimeError('telegram_api_failed') from None


def configure_webhook():
    if not os.getenv('TELEGRAM_WEBHOOK_SECRET'):
        logger.warning('Telegram onboarding disabled: webhook_secret_not_configured')
        return
    try:
        secret = webhook_secret()
        url = app_url()
        telegram_call('setWebhook', {
            'url': url + '/api/telegram/webhook',
            'secret_token': secret,
            'allowed_updates': ['message'],
            'max_connections': 1,
        })
        logger.warning('Telegram onboarding webhook configured')
    except (ValueError, RuntimeError):
        logger.error('Telegram onboarding webhook configuration failed')


def bind_contact(digits, telegram_id):
    database = os.getenv('DATABASE_URL', '')
    if not database:
        raise RuntimeError('database_not_configured')
    with psycopg.connect(database, connect_timeout=5, row_factory=dict_row) as conn:
        # cabinet_reader stays read-only by default. This transaction can only
        # write through the restricted SECURITY DEFINER function granted in SQL.
        conn.execute('SET TRANSACTION READ WRITE')
        conn.execute("SET LOCAL statement_timeout = '5s'")
        conn.execute("SET LOCAL lock_timeout = '2s'")
        row = conn.execute(
            'SELECT leroy_private.bind_telegram_contact(%s, %s) AS status',
            (digits, telegram_id),
        ).fetchone()
    return row['status']


def reply(chat_id, text, markup):
    telegram_call('sendMessage', {'chat_id': chat_id, 'text': text, 'reply_markup': markup})


def contact_keyboard():
    return {'keyboard': [[{'text': 'Поделиться номером', 'request_contact': True}]],
            'resize_keyboard': True, 'one_time_keyboard': True}


def process_update(update):
    message = update.get('message')
    if not isinstance(message, dict):
        return
    sender, chat = message.get('from'), message.get('chat')
    if not isinstance(sender, dict) or not isinstance(chat, dict):
        return
    uid = sender.get('id')
    if (not positive_id(uid) or sender.get('is_bot') is True
            or chat.get('type') != 'private' or chat.get('id') != uid):
        return
    contact = message.get('contact')
    if contact is None:
        reply(uid, 'Добро пожаловать в LEROY! Для привязки кабинета передайте свой номер кнопкой ниже. '
              'Мы сопоставим его с вашей карточкой дизайнера.', contact_keyboard())
        return
    if (not isinstance(contact, dict) or not positive_id(contact.get('user_id'))
            or contact.get('user_id') != uid or message.get('forward_origin')
            or message.get('forward_date')):
        reply(uid, 'Нужен ваш собственный контакт. Нажмите «Поделиться номером» ниже.', contact_keyboard())
        return
    try:
        digits = phone_digits(contact.get('phone_number'))
    except ValueError:
        reply(uid, 'Не удалось распознать номер. Передайте его кнопкой ниже.', contact_keyboard())
        return
    status = bind_contact(digits, uid)
    if status in ('bound', 'already_bound'):
        reply(uid, 'Ваш профиль подтверждён. Можно открыть кабинет.',
              {'inline_keyboard': [[{'text': 'Открыть кабинет', 'web_app': {'url': app_url()}}]]})
        return
    # Do not disclose names, balances or who already owns a conflicting card.
    reply(uid, 'Не удалось автоматически привязать профиль. Обратитесь к менеджеру LEROY: '
          'он проверит номер и карточку дизайнера.', {'remove_keyboard': True})


@router.post('/api/telegram/webhook')
def telegram_webhook(update: dict, x_telegram_bot_api_secret_token: str | None = Header(default=None)):
    try:
        secret = webhook_secret()
        app_url()
    except ValueError:
        raise HTTPException(503, 'Подключение бота ещё не настроено') from None
    if (not x_telegram_bot_api_secret_token
            or not hmac.compare_digest(secret.encode(), x_telegram_bot_api_secret_token.encode())):
        raise HTTPException(403, 'Forbidden')
    try:
        process_update(update)
    except (psycopg.Error, RuntimeError):
        logger.error('Telegram onboarding failed: database_or_delivery_error')
        raise HTTPException(503, 'Попробуйте позже') from None
    return {'ok': True}

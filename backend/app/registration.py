"""Automatic registration uses only phone proofs received from Telegram."""
import os
import re
import unicodedata

import psycopg
from psycopg.rows import dict_row


def enabled():
    return os.getenv('AUTO_REGISTRATION_ENABLED', 'false').strip().lower() == 'true'


def normalize_name(text):
    if not isinstance(text, str) or any(unicodedata.category(c).startswith('C') for c in text):
        return None
    text = ' '.join(text.split())
    if not 4 <= len(text) <= 200 or len(text.split()) < 2 or not text[0].isalpha():
        return None
    if not all(c.isalpha() or c in " -'’" for c in text):
        return None
    if not all(any(c.isalpha() for c in part) for part in text.split()):
        return None
    return text


def advance(uid, action, update_id, digits=None, name=None, referrer=None):
    database = os.getenv('DATABASE_URL', '')
    if not database:
        raise RuntimeError('database_not_configured')
    with psycopg.connect(database, connect_timeout=5, row_factory=dict_row) as conn:
        conn.execute('SET TRANSACTION READ WRITE')
        conn.execute("SET LOCAL statement_timeout = '5s'")
        conn.execute("SET LOCAL lock_timeout = '2s'")
        use_referrals = os.getenv('REFERRALS_ENABLED', 'false').lower() == 'true'
        query = ('SELECT leroy_private.onboard_designer_referral(%s, %s, %s, %s, %s, %s) AS result'
                 if use_referrals else 'SELECT leroy_private.onboard_designer(%s, %s, %s, %s, %s) AS result')
        params = (uid, action, digits, name, update_id)
        if use_referrals:
            params += (referrer,)
        result = conn.execute(
            query, params,
        ).fetchone()['result']
    return result


def process(uid, message, update_id, *, send, contact_keyboard, phone_digits, app_url):
    # Ignore malformed update IDs; Telegram supplies integer update_id values.
    if type(update_id) is not int or update_id < 0:
        return
    contact = message.get('contact')
    text = message.get('text')
    digits, name = None, None
    if contact is not None:
        owner = contact.get('user_id') if isinstance(contact, dict) else None
        if (type(owner) is not int or owner != uid or message.get('forward_origin')
                or message.get('forward_date')):
            send(uid, 'Нажмите «Поделиться номером» под полем сообщения и подтвердите '
                 'передачу своего номера в Telegram.', contact_keyboard())
            return
        try:
            digits = phone_digits(contact.get('phone_number'))
        except ValueError:
            send(uid, 'Не удалось распознать номер. Нажмите кнопку ниже.', contact_keyboard())
            return
        action = 'contact'
    elif isinstance(text, str):
        command = text.strip().split(' ', 1)[0].split('@', 1)[0]
        if command == '/start':
            action = 'resume'
        elif command == '/cancel' or text == 'Отмена':
            action = 'cancel'
        elif text == 'Всё верно':
            action = 'confirm'
        elif text == 'Изменить ФИО':
            action = 'edit'
        else:
            action, name = 'text', normalize_name(text)
    else:
        action = 'resume'
    referrer = None
    if action == 'resume' and isinstance(text, str):
        parts = text.strip().split()
        if len(parts) == 2 and re.fullmatch(r'ref_[A-Za-z0-9_-]{1,60}', parts[1]):
            referrer = parts[1][4:]
    if referrer is not None:
        result = advance(uid, action, update_id, digits, name, referrer=referrer)
    else:
        result = advance(uid, action, update_id, digits, name)
    status = result.get('status')
    if status in ('bound', 'already_bound', 'registered'):
        send(uid, 'Ваш кабинет готов. Добро пожаловать в LEROY!',
             {'inline_keyboard': [[{'text': 'Открыть кабинет', 'web_app': {'url': app_url()}}]]})
    elif status in ('name', 'invalid_name'):
        prompt = ('Номер подтверждён. Укажите фамилию, имя и отчество '
                  '(если есть) одним сообщением. Например: Иванов Иван Иванович.\n\n'
                  'После проверки данных кабинет откроется автоматически.')
        if status == 'invalid_name':
            prompt = 'Не удалось распознать ФИО. Введите фамилию и имя буквами, отчество — если есть.\n\n' + prompt
        send(uid, prompt, {'keyboard': [[{'text': 'Отмена'}]], 'resize_keyboard': True,
                          'input_field_placeholder': 'Введите фамилию, имя и отчество'})
    elif status == 'confirm':
        send(uid, f"Проверьте данные:\n\nФИО: {result['full_name']}\nТелефон: {result['phone']}\n\n"
             'Нажмите «Всё верно», чтобы создать кабинет.',
             {'keyboard': [[{'text': 'Всё верно'}], [{'text': 'Изменить ФИО'}, {'text': 'Отмена'}]],
              'resize_keyboard': True, 'one_time_keyboard': True})
    elif status in ('needs_contact', 'cancelled'):
        send(uid, ('Регистрация отменена.\n\n' if status == 'cancelled' else 'Добро пожаловать в LEROY!\n\n') +
             'Для входа или регистрации нажмите «Поделиться номером» — большую кнопку под полем сообщения. '
             'Подтвердите передачу номера в Telegram. Вводить номер вручную не нужно.', contact_keyboard())
    else:
        send(uid, 'Не удалось привязать профиль. Обратитесь к менеджеру LEROY: '
             'нужно уточнить существующую карточку или доступ.', {'remove_keyboard': True})


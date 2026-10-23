"""Run only against the disposable registration_test database in CI."""
import os
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor

import psycopg
import pytest
from psycopg.conninfo import conninfo_to_dict

DSN = os.getenv('TEST_DATABASE_URL')
pytestmark = pytest.mark.skipif(not DSN, reason='Disposable PostgreSQL is configured in CI')


@pytest.fixture(scope='module')
def db():
    assert conninfo_to_dict(DSN).get('dbname') == 'registration_test'
    conn = psycopg.connect(DSN, autocommit=True)
    conn.execute('CREATE ROLE cabinet_reader')
    conn.execute('CREATE ROLE anon')
    conn.execute('CREATE ROLE authenticated')
    conn.execute('CREATE TABLE public.designers (designer_id text PRIMARY KEY, full_name text NOT NULL, '
                 'phone text, telegram_id bigint, level_code text NOT NULL DEFAULT \'bronze\', '
                 'invited_by text, is_active boolean NOT NULL DEFAULT true, '
                 'created_at timestamptz NOT NULL DEFAULT now())')
    root = Path(__file__).resolve().parents[2]
    for file in ['03_telegram_phone_binding.sql', '04_automatic_registration.sql']:
        conn.execute((root / 'sql' / file).read_text())
    # Migration is safe to apply again and does not replace existing records.
    conn.execute((root / 'sql/04_automatic_registration.sql').read_text())
    yield conn
    conn.close()


@pytest.fixture(autouse=True)
def clean(db):
    db.execute('TRUNCATE public.designers, leroy_private.registration_sessions')


def step(conn, uid=123, action='resume', digits=None, name=None, update=1):
    return conn.execute('SELECT leroy_private.onboard_designer(%s,%s,%s,%s,%s)',
                        (uid, action, digits, name, update)).fetchone()[0]


def start(db, uid=123, phone='79991234567'):
    assert step(db, uid, 'contact', phone, update=1)['status'] == 'name'
    assert step(db, uid, 'text', name='Иванов Иван', update=2)['status'] == 'confirm'


def test_full_flow_and_retries(db):
    assert step(db, action='confirm')['status'] == 'needs_contact'
    start(db)
    assert db.execute('SELECT count(*) FROM designers').fetchone()[0] == 0
    assert step(db, action='text', name='Петров Пётр', update=2)['full_name'] == 'Иванов Иван'
    assert step(db, action='confirm', update=3)['status'] == 'registered'
    assert step(db, action='confirm', update=3)['status'] == 'already_bound'
    assert step(db, update=4)['status'] == 'already_bound'
    row = db.execute('SELECT designer_id,full_name,phone,telegram_id,level_code,is_active FROM designers').fetchone()
    assert row[0].startswith('TG-')
    assert row[1:] == ('Иванов Иван', '+79991234567', 123, 'bronze', True)
    assert db.execute('SELECT count(*) FROM designers').fetchone()[0] == 1


def test_existing_card_keeps_identity(db):
    db.execute("INSERT INTO designers (designer_id,full_name,phone) VALUES ('D010','Old Name','+79991234567')")
    assert step(db, action='contact', digits='79991234567')['status'] == 'bound'
    assert db.execute('SELECT designer_id,full_name,telegram_id FROM designers').fetchone() == ('D010', 'Old Name', 123)


def test_conflicting_and_inactive_cards(db):
    db.execute("INSERT INTO designers (designer_id,full_name,phone,telegram_id) VALUES ('D010','Old Name','+79991234567',999)")
    assert step(db, action='contact', digits='79991234567')['status'] == 'card_conflict'
    db.execute('UPDATE designers SET telegram_id=NULL,is_active=false')
    assert step(db, action='contact', digits='79991234567',update=2)['status'] == 'inactive'
    assert db.execute('SELECT count(*) FROM designers').fetchone()[0] == 1


def test_make_card_added_during_form(db):
    start(db)
    db.execute("INSERT INTO designers (designer_id,full_name,phone) VALUES ('D011','Existing Name','+79991234567')")
    assert step(db, action='confirm', update=3)['status'] == 'bound'
    assert db.execute('SELECT count(*) FROM designers').fetchone()[0] == 1
    assert db.execute('SELECT full_name FROM designers').fetchone()[0] == 'Existing Name'


def test_cancel_expiry_edit_and_invalid_name(db):
    assert step(db, action='contact', digits='79991234567')['status'] == 'name'
    assert step(db, action='text',name='1234',update=2)['status'] == 'invalid_name'
    assert step(db, action='text',name='Иванов Иван',update=3)['status'] == 'confirm'
    assert step(db, action='edit',update=4)['status'] == 'name'
    assert step(db, action='confirm',update=5)['status'] == 'name'
    assert step(db, action='cancel',update=6)['status'] == 'cancelled'
    assert step(db, action='confirm',update=7)['status'] == 'needs_contact'
    step(db, action='contact',digits='79991234567',update=8)
    db.execute("UPDATE leroy_private.registration_sessions SET expires_at=now()-interval '1 second'")
    assert step(db, action='text',name='Иванов Иван',update=9)['status'] == 'needs_contact'


def test_least_privilege(db):
    with psycopg.connect(DSN, autocommit=True) as conn:
        conn.execute('SET ROLE cabinet_reader')
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            conn.execute("INSERT INTO public.designers (full_name) VALUES ('Forbidden')")
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            conn.execute('SELECT * FROM leroy_private.registration_sessions')
        conn.execute('SET default_transaction_read_only=on')
        with conn.transaction():
            conn.execute('SET TRANSACTION READ WRITE')
            assert step(conn, action='contact',digits='79991234567')['status'] == 'name'
        conn.execute('RESET ROLE')
        conn.execute('SET ROLE anon')
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            step(conn)


def test_concurrent_confirmation_creates_one_card(db):
    start(db)
    def confirm():
        with psycopg.connect(DSN, autocommit=True) as conn:
            return step(conn, action='confirm',update=3)['status']
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: confirm(), range(2)))
    assert sorted(results) == ['already_bound', 'registered']
    assert db.execute('SELECT count(*) FROM designers').fetchone()[0] == 1

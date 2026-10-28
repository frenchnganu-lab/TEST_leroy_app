from unittest.mock import Mock
from app import registration
from app.main import referral_url


def test_links_feature_gate(monkeypatch):
    monkeypatch.setenv('TELEGRAM_BOT_USERNAME', 'Leroy_app_bot')
    monkeypatch.delenv('REFERRALS_ENABLED', raising=False)
    assert referral_url('D001') is None
    monkeypatch.setenv('REFERRALS_ENABLED', 'true')
    assert referral_url('TG-aB_c-123') == 'https://t.me/Leroy_app_bot?start=ref_TG-aB_c-123'
    assert referral_url('x' * 61) is None
    assert referral_url('bad?id') is None


def test_start_preserves_exact_designer_id(monkeypatch):
    advance = Mock(return_value={'status': 'needs_contact'})
    monkeypatch.setattr(registration, 'advance', advance)
    registration.process(123, {'text': '/start ref_TG-aBc-123'}, 10,
        send=Mock(), contact_keyboard=lambda: {}, phone_digits=Mock(), app_url=Mock())
    assert advance.call_args.kwargs == {'referrer': 'TG-aBc-123'}


def test_bad_payload_is_ordinary_registration(monkeypatch):
    advance = Mock(return_value={'status': 'needs_contact'})
    monkeypatch.setattr(registration, 'advance', advance)
    registration.process(123, {'text': '/start ref_bad?x'}, 10,
        send=Mock(), contact_keyboard=lambda: {}, phone_digits=Mock(), app_url=Mock())
    assert not advance.call_args.kwargs

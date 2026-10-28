from unittest.mock import Mock
from fastapi.testclient import TestClient
from app import main


def test_no_auth_never_queries(monkeypatch):
    q=Mock(); monkeypatch.setattr(main,'mention_query',q)
    c=TestClient(main.app)
    assert c.get('/api/mentions').status_code==401
    assert c.post('/api/mentions',json={'publication_url':'https://instagram.com/p/X/'}).status_code==401
    q.assert_not_called()


def test_identity_not_from_client(monkeypatch):
    monkeypatch.setenv('BOT_TOKEN','test'); monkeypatch.setenv('DATABASE_URL','test')
    monkeypatch.setattr(main,'verify_init_data',Mock(return_value=123))
    q=Mock(return_value={'request_id':'MENTION-X'}); monkeypatch.setattr(main,'mention_query',q)
    c=TestClient(main.app)
    assert c.post('/api/mentions',headers={'Authorization':'tma signed'},json={'publication_url':'https://instagram.com/p/X/','telegram_id':999}).status_code==200
    q.assert_called_once_with(123,'https://instagram.com/p/X/')


def test_bad_signature(monkeypatch):
    monkeypatch.setenv('BOT_TOKEN','test'); monkeypatch.setenv('DATABASE_URL','test')
    monkeypatch.setattr(main,'verify_init_data',Mock(side_effect=ValueError()))
    q=Mock(); monkeypatch.setattr(main,'mention_query',q)
    assert TestClient(main.app).get('/api/mentions',headers={'Authorization':'tma invalid'}).status_code==401
    q.assert_not_called()

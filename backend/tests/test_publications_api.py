from unittest.mock import Mock
from fastapi.testclient import TestClient
from app import main


def test_unauthenticated_events(monkeypatch):
    q=Mock(); monkeypatch.setattr(main,'publication_query',q)
    c=TestClient(main.app)
    assert c.get('/api/publications').status_code==401
    assert c.post('/api/publications/accept',json={'publication_id':'event-001'}).status_code==401
    q.assert_not_called()


def test_invitation_identity_is_verified(monkeypatch):
    monkeypatch.setenv('BOT_TOKEN','test'); monkeypatch.setenv('DATABASE_URL','test')
    monkeypatch.setattr(main,'verify_init_data',Mock(return_value=123))
    q=Mock(return_value={'publication_id':'event-001','designer_id':'D001'})
    monkeypatch.setattr(main,'publication_query',q)
    c=TestClient(main.app)
    assert c.post('/api/publications/accept',headers={'Authorization':'tma signed'},json={'publication_id':'event-001','telegram_id':999,'designer_id':'D999'}).status_code==200
    q.assert_called_once_with(123,'event-001')


def test_feed_is_scoped_to_user(monkeypatch):
    monkeypatch.setenv('BOT_TOKEN','test'); monkeypatch.setenv('DATABASE_URL','test')
    monkeypatch.setattr(main,'verify_init_data',Mock(return_value=456))
    q=Mock(return_value=[]); monkeypatch.setattr(main,'publication_query',q)
    assert TestClient(main.app).get('/api/publications',headers={'Authorization':'tma signed'}).json()=={'publications':[]}
    q.assert_called_once_with(456)


def test_invalid_signature(monkeypatch):
    monkeypatch.setenv('BOT_TOKEN','test'); monkeypatch.setenv('DATABASE_URL','test')
    monkeypatch.setattr(main,'verify_init_data',Mock(side_effect=ValueError()))
    q=Mock(); monkeypatch.setattr(main,'publication_query',q)
    assert TestClient(main.app).get('/api/publications',headers={'Authorization':'tma bad'}).status_code==401
    q.assert_not_called()

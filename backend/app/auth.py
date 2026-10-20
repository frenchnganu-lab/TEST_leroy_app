"""Telegram initData HMAC verification; no trust in client-supplied designer IDs."""
import hashlib
import hmac
import json
import time
from urllib.parse import parse_qsl


def verify_init_data(raw: str, token: str, *, now: int | None = None) -> int:
    if not raw or len(raw) > 16384 or not token:
        raise ValueError("Missing authentication")
    try:
        pairs = parse_qsl(raw, strict_parsing=True, max_num_fields=30)
        data = dict(pairs)
        if len(data) != len(pairs):
            raise ValueError("Duplicate fields")
        received = data.pop("hash")
        check = "\n".join(f"{key}={value}" for key, value in sorted(data.items()))
        secret = hmac.new(b"WebAppData", token.encode(), hashlib.sha256).digest()
        expected = hmac.new(secret, check.encode(), hashlib.sha256).hexdigest()
        if not hmac.compare_digest(received, expected):
            raise ValueError("Invalid signature")
        timestamp = int(data["auth_date"])
        age = (int(time.time()) if now is None else now) - timestamp
        if age < -30 or age > 3600:
            raise ValueError("Expired authentication")
        user_id = json.loads(data["user"])["id"]
        if type(user_id) is not int or user_id <= 0:
            raise ValueError("Invalid Telegram ID")
        return user_id
    except (KeyError, TypeError, json.JSONDecodeError, OverflowError) as exc:
        raise ValueError("Invalid authentication") from exc

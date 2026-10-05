"""
4jawaly — raw SMS gateway (CITC-licensed, Saudi Arabia).

Unlike Twilio Verify, 4jawaly only DELIVERS a message — it does not generate or
validate the code. So the OTP code itself is created, stored (hashed) and checked
by us in routes/otp.py; this module's only job is to hand 4jawaly a ready SMS.

Credentials come from the environment (set on Cloud Run), never the repo:

    JAWALY_API_KEY       (the token's "API KEY")
    JAWALY_API_SECRET    (the token's "API Secret")
    JAWALY_SENDER        (the approved Sender Name, e.g. "Hamsa")
    JAWALY_SEND_URL      (optional — defaults to the public send endpoint)

Auth is HTTP Basic: base64("<API_KEY>:<API_SECRET>").
Numbers must be in 9665XXXXXXXX form (country code, no leading "+").
"""
import base64
import os

import httpx

_DEFAULT_SEND_URL = "https://api-sms.4jawaly.com/api/v1/account/area/sms/send"


def _auth_header() -> str:
    key = os.environ["JAWALY_API_KEY"]
    secret = os.environ["JAWALY_API_SECRET"]
    token = base64.b64encode(f"{key}:{secret}".encode()).decode()
    return f"Basic {token}"


def _to_local(phone: str) -> str:
    """E.164 (+9665XXXXXXXX) → 4jawaly form (9665XXXXXXXX, no +)."""
    return phone.lstrip("+")


def send_sms(phone: str, text: str) -> None:
    """Send `text` to `phone` via 4jawaly. Raises on a transport error or a
    non-success response so the caller can report failure."""
    sender = os.environ["JAWALY_SENDER"]
    url = os.getenv("JAWALY_SEND_URL", _DEFAULT_SEND_URL)
    payload = {
        "messages": [
            {
                "text": text,
                "numbers": [_to_local(phone)],
                "sender": sender,
            }
        ]
    }
    headers = {
        "Authorization": _auth_header(),
        "Content-Type": "application/json",
        "Accept": "application/json",
    }
    with httpx.Client(timeout=15) as client:
        resp = client.post(url, json=payload, headers=headers)

    if resp.status_code >= 300:
        raise RuntimeError(f"4jawaly HTTP {resp.status_code}: {resp.text}")

    # 4jawaly returns 200 even for per-message problems; the top-level
    # `success` flag is the reliable signal. Be defensive if the body isn't JSON.
    try:
        data = resp.json()
    except Exception:
        return  # 2xx with a non-JSON body — treat as accepted.
    if isinstance(data, dict) and data.get("success") is False:
        raise RuntimeError(f"4jawaly rejected the message: {data}")

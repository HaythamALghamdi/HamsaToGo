"""
Twilio Verify — managed phone OTP (send + check).

Twilio generates, delivers, expires, and validates the code, so we never
store or compare codes ourselves. Credentials come from the environment
(set on Cloud Run), never the repo:

    TWILIO_ACCOUNT_SID          (starts with AC…)
    TWILIO_AUTH_TOKEN
    TWILIO_VERIFY_SERVICE_SID   (the Verify Service, starts with VA…)
"""
import os
from twilio.rest import Client

_client = None


def _client_and_service():
    global _client
    if _client is None:
        _client = Client(
            os.environ["TWILIO_ACCOUNT_SID"],
            os.environ["TWILIO_AUTH_TOKEN"],
        )
    return _client, os.environ["TWILIO_VERIFY_SERVICE_SID"]


def send_code(phone: str) -> None:
    """Send an SMS OTP to `phone` (E.164, e.g. +9665XXXXXXXX).
    Raises on a transport/Twilio error so the caller can report failure."""
    client, service = _client_and_service()
    client.verify.v2.services(service).verifications.create(to=phone, channel="sms")


def check_code(phone: str, code: str) -> bool:
    """True if `code` is the valid, unexpired code for `phone`, else False.
    Twilio raises once a verification is expired/consumed — treat that as a
    failed check rather than an error."""
    client, service = _client_and_service()
    try:
        result = client.verify.v2.services(service).verification_checks.create(
            to=phone, code=code
        )
    except Exception:
        return False
    return result.status == "approved"

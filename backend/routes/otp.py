"""
Phone OTP via 4jawaly (raw SMS) + Firebase custom tokens.

Flow (replaces Firebase's own phone verification):
  1. POST /auth/otp/send    → we generate a 6-digit code, store it HASHED in
     Firestore with an expiry, and have 4jawaly deliver the SMS.
  2. POST /auth/otp/verify  → we check the code against the stored hash; on
     success we look up (or create) the Firebase user for that phone, ensure the
     Firestore profile exists, and return a Firebase CUSTOM TOKEN. The app signs
     in with it, so everything downstream (uid, Firestore rules, orders,
     payments, FCM) is unchanged — only the SMS delivery moved off Firebase.

Identity note: existing customers keep their account because
get_user_by_phone_number returns their original uid, so the custom token is
minted for the SAME uid their orders already reference.

Test numbers: set OTP_TEST_NUMBERS="+966500000000:123456,+966511111111:654321"
to give fixed codes that skip SMS entirely — for Apple review and local testing
(mirrors Firebase's old static test numbers).
"""
import hashlib
import hmac
import os
import secrets
import time
from typing import Optional

from fastapi import APIRouter, HTTPException, status
from pydantic import BaseModel
from firebase_admin import auth as firebase_auth

from services import firestore as db
from services import postgres as pg
from services import jawaly_sms
from firebase.config import get_firestore
from routes.auth import _normalize_phone, _allowed_staff_phones

router = APIRouter(prefix="/auth/otp", tags=["OTP"])

_CODE_TTL = 300        # seconds a code stays valid (5 min)
_MAX_ATTEMPTS = 5      # wrong tries before a code is burned


# ─── Models ───────────────────────────────────────────────────
class SendOtpRequest(BaseModel):
    phone: str


class VerifyOtpRequest(BaseModel):
    phone: str
    code: str
    full_name: Optional[str] = None
    lang: Optional[str] = None


class AdminVerifyOtpRequest(BaseModel):
    phone: str
    code: str


# ─── Test numbers (fixed codes, no SMS) ───────────────────────
def _test_numbers() -> dict[str, str]:
    """Parse OTP_TEST_NUMBERS ("phone:code,phone:code") into {E.164: code}."""
    raw = os.getenv("OTP_TEST_NUMBERS", "").strip()
    out: dict[str, str] = {}
    for pair in raw.split(","):
        pair = pair.strip()
        if ":" in pair:
            phone, code = pair.split(":", 1)
            out[_normalize_phone(phone.strip())] = code.strip()
    return out


# ─── Code store (Firestore) ───────────────────────────────────
def _hash_code(phone: str, code: str) -> str:
    """Salted hash so a Firestore leak never exposes active codes. The phone
    binds the hash to its number (a code is only valid for the number it was
    sent to)."""
    return hashlib.sha256(f"{phone}:{code}".encode()).hexdigest()


def _store_code(phone: str, code: str) -> None:
    get_firestore().collection("otp_codes").document(phone).set({
        "code_hash": _hash_code(phone, code),
        "expires_at": time.time() + _CODE_TTL,
        "attempts": 0,
    })


def _check_code(phone: str, code: str) -> bool:
    """True iff `code` is the valid, unexpired code for `phone`. Enforces an
    attempt limit and consumes the code on success. Test numbers match their
    fixed code without touching Firestore."""
    test = _test_numbers()
    if phone in test:
        return hmac.compare_digest(code, test[phone])

    ref = get_firestore().collection("otp_codes").document(phone)
    snap = ref.get()
    if not snap.exists:
        return False
    data = snap.to_dict() or {}

    if time.time() > (data.get("expires_at") or 0):
        ref.delete()
        return False
    if (data.get("attempts") or 0) >= _MAX_ATTEMPTS:
        ref.delete()
        return False

    if hmac.compare_digest(data.get("code_hash", ""), _hash_code(phone, code)):
        ref.delete()
        return True

    ref.update({"attempts": (data.get("attempts") or 0) + 1})
    return False


# ─── Rate limit ───────────────────────────────────────────────
def _enforce_send_rate(phone: str) -> None:
    """Per-phone throttle: at most one send per 30s and 5 per hour. Backed by
    Firestore so it holds across Cloud Run instances."""
    fs = get_firestore()
    ref = fs.collection("otp_throttle").document(phone)
    snap = ref.get()
    now = time.time()
    sends = (snap.to_dict().get("sends") if snap.exists else None) or []
    sends = [t for t in sends if now - t < 3600]  # keep the last hour
    if sends and now - max(sends) < 30:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="Please wait a few seconds before requesting another code.",
        )
    if len(sends) >= 5:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="Too many code requests. Please try again later.",
        )
    sends.append(now)
    ref.set({"sends": sends})


# ─── Firebase identity helpers ────────────────────────────────
def _get_or_create_uid(phone: str) -> str:
    """Existing customer → their original uid; new customer → a fresh Firebase
    Auth user keyed by phone (so the mapping persists for next time)."""
    try:
        return firebase_auth.get_user_by_phone_number(phone).uid
    except firebase_auth.UserNotFoundError:
        return firebase_auth.create_user(phone_number=phone).uid


def _custom_token(uid: str) -> str:
    return firebase_auth.create_custom_token(uid).decode("utf-8")


def _otp_message(code: str) -> str:
    """The SMS body. Overridable via OTP_MESSAGE_TEMPLATE (must contain {code})."""
    template = os.getenv(
        "OTP_MESSAGE_TEMPLATE",
        "رمز التحقق الخاص بك في همسة: {code}",
    )
    try:
        return template.format(code=code)
    except Exception:
        return f"Hamsa verification code: {code}"


# ─── Send ─────────────────────────────────────────────────────
@router.post("/send")
def send_otp(body: SendOtpRequest):
    phone = _normalize_phone(body.phone)

    # Test numbers skip SMS entirely — the fixed code always "works".
    if phone in _test_numbers():
        return {"status": "sent"}

    _enforce_send_rate(phone)
    code = f"{secrets.randbelow(1_000_000):06d}"
    _store_code(phone, code)
    try:
        jawaly_sms.send_sms(phone, _otp_message(code))
    except Exception as e:
        print(f"[OTP] 4jawaly send failed for {phone}: {e}")
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Could not send the verification code. Please try again.",
        )
    return {"status": "sent"}


# ─── Verify (customer sign-in + register) ─────────────────────
@router.post("/verify")
def verify_otp(body: VerifyOtpRequest):
    phone = _normalize_phone(body.phone)
    if not _check_code(phone, body.code):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="The code is incorrect or has expired.",
        )

    uid = _get_or_create_uid(phone)
    lang = body.lang if body.lang in ("en", "ar") else "en"

    user_data = db.get_user(uid)
    if not user_data:
        # New customer — a name is required to finish registration.
        if not body.full_name or not body.full_name.strip():
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND, detail="NO_ACCOUNT"
            )
        user_data = db.create_user(uid, {
            "phone": phone,
            "full_name": body.full_name.strip(),
            "fcm_token": None,
            "lang": lang,
        })
    elif body.lang and user_data.get("lang") != lang:
        user_data = db.update_user(uid, {"lang": lang})

    pg.upsert_customer(uid, user_data.get("phone", ""), user_data.get("full_name", ""))

    return {"custom_token": _custom_token(uid), "user": user_data}


# ─── Verify (staff) ───────────────────────────────────────────
@router.post("/admin-verify")
def admin_verify_otp(body: AdminVerifyOtpRequest):
    phone = _normalize_phone(body.phone)
    allowed = _allowed_staff_phones()
    if not allowed:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Staff phones not configured.",
        )
    if phone not in allowed:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="This number is not authorized for staff access.",
        )
    if not _check_code(phone, body.code):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="The code is incorrect or has expired.",
        )

    uid = _get_or_create_uid(phone)
    try:
        db.mark_staff(uid, phone)
    except Exception as e:
        print(f"[OTP] Failed to mark staff {uid}: {e}")
    return {"custom_token": _custom_token(uid), "success": True}

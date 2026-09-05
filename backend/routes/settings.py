from fastapi import APIRouter, Depends
from pydantic import BaseModel
from services import firestore as db
from dependencies import require_user, require_staff

router = APIRouter(prefix="/settings", tags=["Settings"])


class CafeStatus(BaseModel):
    is_busy: bool


# ─── Read cafe status (any signed-in user) ───────────────────
# The app normally reads this straight from Firestore in real time; this
# endpoint is a simple fallback / health check for the same flag.
@router.get("/status", response_model=CafeStatus)
def get_status(decoded: dict = Depends(require_user)):
    return CafeStatus(is_busy=db.get_cafe_busy())


# ─── Toggle busy (staff only) ────────────────────────────────
@router.put("/busy", response_model=CafeStatus, dependencies=[Depends(require_staff)])
def set_busy(body: CafeStatus, decoded: dict = Depends(require_staff)):
    """Staff pause / resume ordering. Written via the Admin SDK so the
    settings/status doc stays read-only to clients."""
    result = db.set_cafe_busy(body.is_busy, uid=decoded["uid"])
    return CafeStatus(is_busy=result["is_busy"])

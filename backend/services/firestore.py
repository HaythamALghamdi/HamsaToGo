from firebase.config import get_firestore
from datetime import datetime, timezone
from google.cloud import firestore as gcf


# ─── Collections ─────────────────────────────────────────────
USERS       = "users"
CATEGORIES  = "categories"
MENU_ITEMS  = "menu_items"
ORDERS      = "orders"
COUNTERS    = "counters"
STAFF       = "staff"
SAVED_CARDS = "saved_cards"
SETTINGS    = "settings"


def now() -> datetime:
    return datetime.now(timezone.utc)


# ─── Generic Helpers ─────────────────────────────────────────
def doc_to_dict(doc) -> dict:
    """Convert a Firestore document snapshot to a plain dict with its ID."""
    if not doc.exists:
        return None
    data = doc.to_dict()
    data["id"] = doc.id
    return data


def collection_to_list(query) -> list:
    """Convert a Firestore query result to a list of dicts."""
    return [doc_to_dict(doc) for doc in query.stream()]


# ─── Users ───────────────────────────────────────────────────
def create_user(uid: str, data: dict) -> dict:
    db = get_firestore()
    data["created_at"] = now()
    db.collection(USERS).document(uid).set(data)
    data["id"] = uid
    return data


def get_user(uid: str) -> dict:
    db = get_firestore()
    return doc_to_dict(db.collection(USERS).document(uid).get())


def user_exists_by_phone(phone: str) -> bool:
    """True if a customer account is registered with this phone number."""
    db = get_firestore()
    docs = db.collection(USERS).where("phone", "==", phone).limit(1).get()
    return len(docs) > 0


def update_user(uid: str, data: dict) -> dict:
    db = get_firestore()
    data = {k: v for k, v in data.items() if v is not None}
    db.collection(USERS).document(uid).update(data)
    return get_user(uid)


def delete_user(uid: str):
    """Permanently remove a customer's profile document."""
    db = get_firestore()
    db.collection(USERS).document(uid).delete()


# ─── Staff ───────────────────────────────────────────────────
def mark_staff(uid: str, phone: str = "") -> None:
    """
    Record a verified staff member as a /staff/{uid} document.
    Firestore security rules check for this document to grant the staff
    member read access to the order queue — no ID-token refresh needed.
    """
    db = get_firestore()
    db.collection(STAFF).document(uid).set({"phone": phone, "added_at": now()})


def is_staff(uid: str) -> bool:
    """True if a /staff/{uid} document exists for this user."""
    db = get_firestore()
    return db.collection(STAFF).document(uid).get().exists


def set_staff_fcm_token(uid: str, token: str) -> None:
    """Save a staff member's device token for new-order alerts."""
    db = get_firestore()
    db.collection(STAFF).document(uid).set({"fcm_token": token}, merge=True)


def get_staff_fcm_tokens() -> list:
    """All registered staff device tokens (deduplicated)."""
    db = get_firestore()
    tokens = set()
    for doc in db.collection(STAFF).stream():
        t = (doc.to_dict() or {}).get("fcm_token")
        if t:
            tokens.add(t)
    return list(tokens)


# ─── Cafe Settings (busy toggle) ─────────────────────────────
# A single settings/status document holds the cafe's "busy" flag. Staff
# flip it from the dashboard (via the backend, using the Admin SDK); both
# customers and staff read it in real time through a Firestore stream, so
# the "we're busy, can't take orders" banner appears/disappears instantly.

def get_cafe_busy() -> bool:
    """True if staff have marked the cafe as busy (ordering paused)."""
    db = get_firestore()
    snap = db.collection(SETTINGS).document("status").get()
    return bool((snap.to_dict() or {}).get("is_busy", False)) if snap.exists else False


def set_cafe_busy(is_busy: bool, uid: str = "") -> dict:
    """
    Set the cafe busy flag. Written by the backend (Admin SDK) so clients
    never write it directly — the security rules keep the doc read-only.
    Returns the stored status.
    """
    db = get_firestore()
    data = {"is_busy": bool(is_busy), "updated_at": now(), "updated_by": uid}
    db.collection(SETTINGS).document("status").set(data)
    return {"is_busy": bool(is_busy)}


# ─── Saved Cards (Moyasar tokens) ────────────────────────────
# Only the Moyasar token + display data (brand/last4/expiry) is stored —
# never the card number. The token is only usable with the secret key.

def save_card(customer_id: str, data: dict) -> dict:
    """
    Store a saved card for a customer. If the same physical card was
    already saved (same last4 + brand + expiry), the existing document is
    updated with the fresh token instead of creating a duplicate entry.
    Returns the stored document; data must include 'token'.
    """
    db = get_firestore()
    data["customer_id"] = customer_id

    existing = (
        db.collection(SAVED_CARDS)
        .where("customer_id", "==", customer_id)
        .where("last4", "==", data.get("last4"))
        .where("brand", "==", data.get("brand"))
        .get()
    )
    for doc in existing:
        doc.reference.update({**data, "updated_at": now()})
        return doc_to_dict(doc.reference.get())

    data["created_at"] = now()
    ref = db.collection(SAVED_CARDS).document()
    ref.set(data)
    data["id"] = ref.id
    return data


def get_saved_cards(customer_id: str) -> list:
    db = get_firestore()
    query = db.collection(SAVED_CARDS).where("customer_id", "==", customer_id)
    cards = collection_to_list(query)
    cards.sort(key=lambda c: str(c.get("created_at", "")), reverse=True)
    return cards


def get_saved_card(card_id: str) -> dict:
    db = get_firestore()
    return doc_to_dict(db.collection(SAVED_CARDS).document(card_id).get())


def delete_saved_card(card_id: str):
    db = get_firestore()
    db.collection(SAVED_CARDS).document(card_id).delete()


def delete_customer_cards(customer_id: str) -> list:
    """Remove all of a customer's saved cards (account deletion).
    Returns the deleted docs so the caller can invalidate their tokens."""
    db = get_firestore()
    docs = db.collection(SAVED_CARDS).where("customer_id", "==", customer_id).get()
    deleted = []
    for doc in docs:
        deleted.append(doc_to_dict(doc))
        doc.reference.delete()
    return deleted


# ─── Categories ──────────────────────────────────────────────
def create_category(data: dict) -> dict:
    db = get_firestore()
    ref = db.collection(CATEGORIES).document()
    ref.set(data)
    data["id"] = ref.id
    return data


def get_all_categories() -> list:
    db = get_firestore()
    query = db.collection(CATEGORIES).order_by("sort_order")
    return collection_to_list(query)


def get_category(category_id: str) -> dict:
    db = get_firestore()
    return doc_to_dict(db.collection(CATEGORIES).document(category_id).get())


def update_category(category_id: str, data: dict) -> dict:
    db = get_firestore()
    data = {k: v for k, v in data.items() if v is not None}
    db.collection(CATEGORIES).document(category_id).update(data)
    return get_category(category_id)


def delete_category(category_id: str):
    db = get_firestore()
    db.collection(CATEGORIES).document(category_id).delete()


# ─── Menu Items ──────────────────────────────────────────────
def create_menu_item(data: dict) -> dict:
    db = get_firestore()
    # Convert options (list of Pydantic models) to plain dicts
    if "options" in data:
        data["options"] = [
            o.model_dump() if hasattr(o, "model_dump") else o
            for o in data["options"]
        ]
    ref = db.collection(MENU_ITEMS).document()
    ref.set(data)
    data["id"] = ref.id
    return data


def get_all_menu_items(available_only: bool = False) -> list:
    db = get_firestore()
    query = db.collection(MENU_ITEMS)
    if available_only:
        query = query.where("available", "==", True)
    return collection_to_list(query)


def get_menu_items_by_category(category_id: str, available_only: bool = False) -> list:
    db = get_firestore()
    query = db.collection(MENU_ITEMS).where("category_id", "==", category_id)
    if available_only:
        query = query.where("available", "==", True)
    return collection_to_list(query)


def get_menu_item(item_id: str) -> dict:
    db = get_firestore()
    return doc_to_dict(db.collection(MENU_ITEMS).document(item_id).get())


def update_menu_item(item_id: str, data: dict) -> dict:
    db = get_firestore()
    data = {k: v for k, v in data.items() if v is not None}
    if "options" in data:
        data["options"] = [
            o.model_dump() if hasattr(o, "model_dump") else o
            for o in data["options"]
        ]
    db.collection(MENU_ITEMS).document(item_id).update(data)
    return get_menu_item(item_id)


def clear_menu_item_image(item_id: str) -> dict:
    """Remove an item's photo. Separate from update_menu_item because that
    helper drops None values, which would make image_url impossible to unset."""
    db = get_firestore()
    db.collection(MENU_ITEMS).document(item_id).update({"image_url": None})
    return get_menu_item(item_id)


def delete_menu_item(item_id: str):
    db = get_firestore()
    db.collection(MENU_ITEMS).document(item_id).delete()


# ─── Orders ──────────────────────────────────────────────────
def _next_order_number(db) -> int:
    """
    Atomically allocate the next sequential order number (1, 2, 3, …)
    using a transaction on the counters/orders document, so two orders
    placed at the same moment can never get the same number.
    """
    counter_ref = db.collection(COUNTERS).document("orders")

    @gcf.transactional
    def _increment(tx):
        snap = counter_ref.get(transaction=tx)
        current = (snap.to_dict() or {}).get("current", 0) if snap.exists else 0
        tx.set(counter_ref, {"current": current + 1})
        return current + 1

    return _increment(db.transaction())


def create_order(data: dict) -> dict:
    db = get_firestore()
    data["status"]       = "received"
    data["order_number"] = _next_order_number(db)
    data["created_at"]   = now()
    data["updated_at"]   = now()

    # Calculate total price
    data["total_price"] = sum(
        item["price"] * item["quantity"]
        for item in data.get("items", [])
    )

    # Serialize items
    data["items"] = [
        i.model_dump() if hasattr(i, "model_dump") else i
        for i in data.get("items", [])
    ]

    ref = db.collection(ORDERS).document()
    ref.set(data)
    data["id"] = ref.id
    return data


def get_all_orders(status: str = None) -> list:
    db = get_firestore()
    query = db.collection(ORDERS).order_by("created_at")
    if status:
        query = query.where("status", "==", status)
    return collection_to_list(query)


def get_active_orders() -> list:
    """Orders the employee needs to action (received + in_progress + ready)."""
    db = get_firestore()
    results = []
    for status in ["received", "in_progress", "ready"]:
        docs = db.collection(ORDERS).where("status", "==", status).stream()
        results.extend([doc_to_dict(d) for d in docs])
    results.sort(key=lambda x: x.get("created_at", ""))
    return results


def get_customer_orders(customer_id: str) -> list:
    db = get_firestore()
    query = (
        db.collection(ORDERS)
        .where("customer_id", "==", customer_id)
        .order_by("created_at")
    )
    return collection_to_list(query)


def get_order(order_id: str) -> dict:
    db = get_firestore()
    return doc_to_dict(db.collection(ORDERS).document(order_id).get())


def update_order_status(order_id: str, status: str) -> dict:
    db = get_firestore()
    db.collection(ORDERS).document(order_id).update({
        "status":     status,
        "updated_at": now(),
    })
    return get_order(order_id)

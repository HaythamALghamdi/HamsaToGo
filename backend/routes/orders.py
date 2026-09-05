from fastapi import APIRouter, Depends, HTTPException, Query
from models.order import OrderCreate, OrderStatusUpdate, OrderResponse, OrderStatus
from services import firestore as db
from services import postgres as pg
from services.fcm import notify_order_status, notify_staff_new_order
from dependencies import require_user, require_staff
from services.moyasar import (
    verify_payment, refund_payment, get_token,
    PaymentVerificationError, RefundError,
)
from typing import List, Optional

router = APIRouter(prefix="/orders", tags=["Orders"])


def _save_card_from_payment(uid: str, payment: dict) -> None:
    """
    Persist the Moyasar card token from a verified payment as the
    customer's saved card. No-op when the payment carries no token (Apple
    Pay, or the SDK didn't tokenize). Expiry comes from the token record;
    brand/last4 fall back to the payment's card source.
    """
    source = payment.get("source") or {}
    token = source.get("token")
    if not token:
        return

    # source.number is masked, e.g. "XXXX-XXXX-XXXX-1115"
    masked = source.get("number", "") or ""
    last4 = "".join(ch for ch in masked if ch.isdigit())[-4:]
    brand = (source.get("company") or "").lower()

    expiry_month = expiry_year = None
    token_info = get_token(token)
    if token_info:
        try:
            expiry_month = int(token_info.get("month"))
            expiry_year = int(token_info.get("year"))
        except (TypeError, ValueError):
            pass
        brand = (token_info.get("brand") or brand or "").lower()
        last4 = token_info.get("last_four") or last4

    db.save_card(uid, {
        "token": token,
        "brand": brand,
        "last4": last4,
        "expiry_month": expiry_month,
        "expiry_year": expiry_year,
    })


def _authoritative_unit_price(menu_item: dict, customizations: dict) -> float:
    """
    Compute an item's unit price from the menu (never trust the client).
    Base price + any selected option's price modifier + the chosen
    crop's price modifier. Modifiers are signed (negatives discount).
    """
    price = float(menu_item.get("price", 0.0))
    for opt in menu_item.get("options", []):
        mods = opt.get("price_modifiers") or {}
        chosen = (customizations or {}).get(opt.get("name"))
        if chosen and chosen in mods:
            price += float(mods[chosen])

    # The chosen crop is stored under the "Crop" key with its localized
    # name, so match against both languages.
    chosen_crop = (customizations or {}).get("Crop")
    if chosen_crop:
        for crop in menu_item.get("crops", []):
            if chosen_crop in (crop.get("name_en"), crop.get("name_ar")):
                price += float(crop.get("price_modifier", 0) or 0)
                break
    return price


def price_order_items(items) -> float:
    """
    Validate cart items against the menu (exist + available) and stamp each
    with its authoritative unit price. Mutates the items in place and
    returns the order total. Shared by order placement and by saved-card
    charging so both always price identically.
    """
    for item in items:
        menu_item = db.get_menu_item(item.menu_item_id)
        if not menu_item:
            raise HTTPException(
                status_code=404,
                detail=f"Menu item '{item.name_en}' not found."
            )
        if not menu_item.get("available", False):
            raise HTTPException(
                status_code=400,
                detail=f"'{item.name_en}' is currently unavailable."
            )
        item.price = _authoritative_unit_price(menu_item, item.customizations)
    return sum(item.price * item.quantity for item in items)


# ─── Place Order (Customer) ───────────────────────────────────
@router.post("/", response_model=OrderResponse, status_code=201)
def place_order(order: OrderCreate, decoded: dict = Depends(require_user)):
    """
    Customer places a new order.
    - Identity (customer_id/name) comes from the verified token, not the client.
    - Item prices are recomputed from the menu, never trusted from the client.
    - Saves to Firestore with status = 'received' (no push notification —
      status-change pushes start once staff begins preparing).
    """
    # Identity from the token — a caller can only order as themselves.
    uid = decoded["uid"]
    customer = db.get_user(uid)
    if not customer:
        raise HTTPException(status_code=404, detail="Customer not found.")
    order.customer_id = uid
    order.customer_name = customer.get("full_name", "") or order.customer_name

    # Busy guard — staff can pause new orders from the dashboard. The app
    # disables checkout while busy, so this is the server-side safety net for
    # the race where busy flips on mid-payment. Because the customer pays
    # client-side before this call, refund any charge that already went
    # through so nobody is charged for an order we won't accept.
    if db.get_cafe_busy():
        if order.payment_id:
            try:
                refund_payment(order.payment_id)
            except Exception as e:
                print(f"[Busy] Refund of paused order {order.payment_id} failed: {e}")
        raise HTTPException(
            status_code=409,
            detail="cafe_busy: The cafe is not accepting new orders right now.",
        )

    # Verify items exist + are available, and set the authoritative price.
    expected_total = price_order_items(order.items)

    # Verify the payment actually went through before creating the order —
    # never trust the client's claim alone.
    try:
        payment = verify_payment(order.payment_id, expected_total)
    except PaymentVerificationError as e:
        raise HTTPException(status_code=402, detail=f"Payment verification failed: {e}")

    # Customer opted to save their card: the verified payment record carries
    # the Moyasar token (present only when the SDK tokenized the card).
    # Failures here must never lose a paid order, so they only log.
    if order.save_card:
        try:
            _save_card_from_payment(uid, payment)
        except Exception as e:
            print(f"[Cards] Saving card after payment {order.payment_id} failed: {e}")

    # Create the order in Firestore (store the method as a plain string;
    # save_card is a payment-flow flag, not order data)
    payload = order.model_dump(exclude={"save_card"})
    payload["payment_method"] = order.payment_method.value
    data = db.create_order(payload)

    # Sync to PostgreSQL
    pg.insert_order(data)
    pg.insert_order_items(data["id"], data.get("items", []))

    # No customer notification here — they just placed the order themselves;
    # their pushes start when staff moves it to in_progress. Staff devices
    # DO get alerted so new orders aren't missed while the app is closed.
    try:
        notify_staff_new_order(data)
    except Exception as e:
        print(f"[FCM] Staff new-order alert failed: {e}")

    return OrderResponse(**data)


# ─── Get All Orders (Admin / Employee) ───────────────────────
@router.get("/", response_model=List[OrderResponse],
            dependencies=[Depends(require_staff)])
def get_orders(
    status: Optional[str] = Query(None, description="Filter by status"),
    active_only: bool = Query(False, description="Show only received + in_progress + ready"),
):
    """
    Admin: Get all orders.
    - active_only=true → only 'received', 'in_progress' and 'ready' (the live queue)
    - status=received  → filter by specific status
    """
    if active_only:
        orders = db.get_active_orders()
    else:
        orders = db.get_all_orders(status=status)
    return [OrderResponse(**o) for o in orders]


# ─── Get Customer Orders ──────────────────────────────────────
@router.get("/customer/{customer_id}", response_model=List[OrderResponse])
def get_customer_orders(customer_id: str, decoded: dict = Depends(require_user)):
    """A customer may fetch only their own orders; staff may fetch anyone's."""
    if decoded["uid"] != customer_id and not db.is_staff(decoded["uid"]):
        raise HTTPException(status_code=403, detail="Not allowed.")
    orders = db.get_customer_orders(customer_id)
    return [OrderResponse(**o) for o in orders]


# ─── Get Single Order ─────────────────────────────────────────
@router.get("/{order_id}", response_model=OrderResponse)
def get_order(order_id: str, decoded: dict = Depends(require_user)):
    """Readable by the order's owner or by staff."""
    order = db.get_order(order_id)
    if not order:
        raise HTTPException(status_code=404, detail="Order not found.")
    if order.get("customer_id") != decoded["uid"] and not db.is_staff(decoded["uid"]):
        raise HTTPException(status_code=403, detail="Not allowed.")
    return OrderResponse(**order)


# ─── Cancel Order (Customer) ──────────────────────────────────
@router.post("/{order_id}/cancel", response_model=OrderResponse)
def cancel_order(order_id: str, decoded: dict = Depends(require_user)):
    """
    Customer: Cancel an order and receive a full refund.
    Only the order's owner (or staff) may cancel it, and only while the
    order is still 'received' — once staff has started preparing it, it
    can no longer be cancelled.
    """
    order = db.get_order(order_id)
    if not order:
        raise HTTPException(status_code=404, detail="Order not found.")

    if order.get("customer_id") != decoded["uid"] and not db.is_staff(decoded["uid"]):
        raise HTTPException(status_code=403, detail="Not allowed.")

    if order["status"] != OrderStatus.RECEIVED.value:
        raise HTTPException(
            status_code=400,
            detail="Only orders that haven't started preparation can be cancelled.",
        )

    payment_id = order.get("payment_id")
    if payment_id:
        try:
            refund_payment(payment_id)
        except RefundError as e:
            raise HTTPException(status_code=502, detail=f"Refund failed: {e}")

    updated = db.update_order_status(order_id, OrderStatus.CANCELLED.value)
    pg.update_order_status(order_id, OrderStatus.CANCELLED.value)

    notify_order_status(
        customer_id=order["customer_id"],
        order_id=order_id,
        status=OrderStatus.CANCELLED.value,
    )

    return OrderResponse(**updated)


# ─── Update Order Status (Admin / Employee) ───────────────────
@router.patch("/{order_id}/status", response_model=OrderResponse,
              dependencies=[Depends(require_staff)])
def update_order_status(order_id: str, update: OrderStatusUpdate):
    """
    Admin: Update the status of an order.

    Flow:
      received → in_progress → ready → picked_up

    A push notification is sent to the customer on every status change.
    """
    order = db.get_order(order_id)
    if not order:
        raise HTTPException(status_code=404, detail="Order not found.")

    # Enforce valid status transitions
    transitions = {
        OrderStatus.RECEIVED:    [OrderStatus.IN_PROGRESS],
        OrderStatus.IN_PROGRESS: [OrderStatus.READY],
        OrderStatus.READY:       [OrderStatus.PICKED_UP],
        OrderStatus.PICKED_UP:   [],
    }

    current = OrderStatus(order["status"])
    allowed = transitions.get(current, [])

    if update.status not in allowed:
        raise HTTPException(
            status_code=400,
            detail=f"Cannot transition from '{current}' to '{update.status}'. "
                   f"Allowed: {[s.value for s in allowed]}",
        )

    # Update in Firestore
    updated = db.update_order_status(order_id, update.status.value)

    # Sync status to PostgreSQL
    pg.update_order_status(order_id, update.status.value)

    # Notify the customer of the new status (in_progress / ready / picked_up)
    notify_order_status(
        customer_id=order["customer_id"],
        order_id=order_id,
        status=update.status.value,
    )

    return OrderResponse(**updated)

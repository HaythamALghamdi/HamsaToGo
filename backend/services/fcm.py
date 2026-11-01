from firebase_admin import messaging
from firebase.config import get_firestore

USERS = "users"


# ─── Per-status notification copy (EN + AR) ───────────────────
# "received" (order placed) intentionally has no entry — the customer just
# placed the order themselves, so no notification is sent for it.
STATUS_MESSAGES = {
    "in_progress": {
        "title_en": "Order being prepared ☕",
        "title_ar": "جاري تحضير الطلب ☕",
        "body_en": "Your order is being prepared.",
        "body_ar": "يتم تحضير طلبك الآن.",
    },
    "ready": {
        "title_en": "Order ready",
        "title_ar": "الطلب جاهز",
        "body_en": "Your order is ready for pick up.",
        "body_ar": "طلبك جاهز للاستلام.",
    },
    "picked_up": {
        "title_en": "Thank you!",
        "title_ar": "شكراً لك!",
        "body_en": "Thank you for your visit.",
        "body_ar": "شكراً لزيارتك.",
    },
    "cancelled": {
        "title_en": "Order cancelled",
        "title_ar": "تم إلغاء الطلب",
        "body_en": "Your order was cancelled and refunded.",
        "body_ar": "تم إلغاء طلبك واسترجاع المبلغ.",
    },
}


# ─── Per-status notification sounds ───────────────────────────
# Android 8+ binds the sound to the notification channel, so each sound has
# its own channel (created in the app's MainActivity.kt); the android value
# is both the channel id and the res/raw sound resource name. The ios value
# is the .caf filename bundled in the Xcode Runner target.
# Statuses not listed here (e.g. cancelled) fall back to the default sound
# on the default "orders" channel.
STATUS_SOUNDS = {
    "in_progress": {"android": "order_being_prepared", "ios": "OrderBeingPreparedIOS.caf"},
    "ready":       {"android": "order_ready",          "ios": "OrderReadyIOS.caf"},
    "picked_up":   {"android": "order_picked_up",      "ios": "OrderPickedUpIOS.caf"},
}


def get_customer_doc(customer_id: str) -> dict | None:
    """Fetch the customer's profile document from Firestore."""
    db = get_firestore()
    doc = db.collection(USERS).document(customer_id).get()
    if not doc.exists:
        return None
    return doc.to_dict()


def get_customer_fcm_token(customer_id: str) -> str | None:
    """Fetch the customer's FCM token from Firestore."""
    doc = get_customer_doc(customer_id)
    return doc.get("fcm_token") if doc else None


def send_push_notification(
    fcm_token: str,
    title_en: str,
    title_ar: str,
    body_en: str,
    body_ar: str,
    data: dict = None,
    lang: str = "en",
    android_sound: str = "default",
    android_channel_id: str = "orders",
    ios_sound: str = "default",
) -> bool:
    """
    Send a push notification via FCM.
    The customer's preferred language determines which title/body is sent.
    [android_sound] doubles as the res/raw resource name (pre-Android-8
    devices play it directly; on 8+ the channel's sound wins).
    """
    if not fcm_token:
        return False

    title = title_ar if lang == "ar" else title_en
    body  = body_ar  if lang == "ar" else body_en

    try:
        message = messaging.Message(
            notification=messaging.Notification(
                title=title,
                body=body,
            ),
            data={k: str(v) for k, v in (data or {}).items()},
            token=fcm_token,
            android=messaging.AndroidConfig(
                priority="high",
                notification=messaging.AndroidNotification(
                    sound=android_sound,
                    channel_id=android_channel_id,
                ),
            ),
            apns=messaging.APNSConfig(
                payload=messaging.APNSPayload(
                    aps=messaging.Aps(sound=ios_sound),
                ),
            ),
        )
        messaging.send(message)
        return True
    except Exception as e:
        print(f"[FCM Error] Failed to send notification: {e}")
        return False


def notify_staff_new_order(order: dict) -> int:
    """
    Alert every registered staff device that a new order was placed.
    Staff have no stored language preference, so the text is bilingual.
    Returns the number of devices notified.
    """
    from services.firestore import get_staff_fcm_tokens

    number = order.get("order_number", "")
    name = order.get("customer_name", "")
    total = order.get("total_price", 0)
    count = sum(i.get("quantity", 1) for i in order.get("items", []))

    title = f"🔔 New order #{number} · طلب جديد"
    body = f"{name} · {count} × items · SAR {total:.2f}"

    sent = 0
    for token in get_staff_fcm_tokens():
        ok = send_push_notification(
            fcm_token=token,
            title_en=title,
            title_ar=title,
            body_en=body,
            body_ar=body,
            data={
                "order_id": order.get("id", ""),
                "type": "staff_new_order",
            },
            android_sound="new_order",
            android_channel_id="new_order",
            ios_sound="NewOrderIOS.caf",
        )
        if ok:
            sent += 1
    return sent


def notify_order_status(customer_id: str, order_id: str, status: str) -> bool:
    """
    Notify a customer that their order moved to a new status, with a
    status-specific notification sound.
    Sends in the customer's preferred language (stored on their profile).
    Fires for in_progress → ready → picked_up (and cancelled); placing an
    order ("received") sends no notification.
    """
    msg = STATUS_MESSAGES.get(status)
    if not msg:
        return False

    doc = get_customer_doc(customer_id)
    if not doc:
        return False

    token = doc.get("fcm_token")
    if not token:
        print(f"[FCM] No token for customer {customer_id}, skipping notification.")
        return False

    lang = doc.get("lang", "en")
    sound = STATUS_SOUNDS.get(status, {})

    return send_push_notification(
        fcm_token=token,
        title_en=msg["title_en"],
        title_ar=msg["title_ar"],
        body_en=msg["body_en"],
        body_ar=msg["body_ar"],
        data={"order_id": order_id, "type": f"order_{status}", "status": status},
        lang=lang,
        android_sound=sound.get("android", "default"),
        android_channel_id=sound.get("android", "orders"),
        ios_sound=sound.get("ios", "default"),
    )

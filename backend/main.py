from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from contextlib import asynccontextmanager
from dotenv import load_dotenv

from firebase.config import init_firebase
from services.postgres import init_db
from routes import auth, menu, orders, notifications, cards, settings

load_dotenv()


# ─── Startup / Shutdown ───────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    """Initialize Firebase on startup."""
    print("[*] Initializing Firebase...")
    init_firebase()
    print("[OK] Firebase ready.")
    print("[*] Initializing PostgreSQL...")
    init_db()
    yield
    print("[*] Shutting down Hamsa Backend.")


# ─── App ──────────────────────────────────────────────────────
app = FastAPI(
    title="Hamsa To Go — Backend API",
    description=(
        "REST API for Hamsa Coffee Roasters ordering app.\n\n"
        "**Two user types:**\n"
        "- **Customer** — browse menu, place orders, receive push notifications\n"
        "- **Admin (Employee)** — single shared device, manages orders and menu\n\n"
        "**Order flow:** `received → in_progress → ready → picked_up`\n\n"
        "Push notification is sent automatically when status becomes `ready`."
    ),
    version="1.0.0",
    lifespan=lifespan,
)

# ─── CORS ─────────────────────────────────────────────────────
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],       # mobile app has no browser origin; auth is via Bearer token
    allow_credentials=False,   # no cookies — avoids the invalid "*" + credentials combo
    allow_methods=["*"],
    allow_headers=["*"],
)

# ─── Routes ───────────────────────────────────────────────────
app.include_router(auth.router)
app.include_router(menu.router)
app.include_router(orders.router)
app.include_router(notifications.router)
app.include_router(cards.router)
app.include_router(settings.router)


# ─── Health Check ─────────────────────────────────────────────
@app.get("/", tags=["Health"])
def root():
    return {
        "app":     "Hamsa To Go",
        "version": "1.0.0",
        "status":  "running",
    }


@app.get("/health", tags=["Health"])
def health():
    return {"status": "ok"}

"""VowKy Analytics - Lightweight self-hosted analytics."""

import hashlib
import json
import os
import re
import secrets
import sqlite3
import time
from contextlib import contextmanager
from datetime import datetime, timedelta
from pathlib import Path

from fastapi import FastAPI, Request, Response, Depends, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, JSONResponse
from fastapi.security import HTTPBasic, HTTPBasicCredentials

# --- Config ---
DB_PATH = os.environ.get("ANALYTICS_DB", "/opt/vowky-analytics/vowky_analytics.db")
DASHBOARD_HTML = Path(__file__).parent / "dashboard.html"
ADMIN_USER = os.environ.get("ANALYTICS_USER", "admin")
ADMIN_PASS = os.environ.get("ANALYTICS_PASS", "vowky-stats-2026")
SALT = os.environ.get("ANALYTICS_SALT", "vowky-anon-salt-x7k")
ALLOWED_ORIGINS = ["https://vowky.com", "https://www.vowky.com", "https://dev.vowky.com"]

# 1x1 transparent GIF
PIXEL = (
    b"\x47\x49\x46\x38\x39\x61\x01\x00\x01\x00\x80\x00\x00"
    b"\xff\xff\xff\x00\x00\x00\x21\xf9\x04\x00\x00\x00\x00"
    b"\x00\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02"
    b"\x44\x01\x00\x3b"
)

app = FastAPI(docs_url=None, redoc_url=None)
security = HTTPBasic()

app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_methods=["GET", "POST"],
    allow_headers=["Content-Type"],
)

# --- Rate limit (simple in-memory) ---
_rate = {}
_RATE_WINDOW = 60  # seconds
_RATE_LIMIT = 30   # requests per window per IP


def _check_rate(ip: str) -> bool:
    now = time.time()
    key = ip
    if key not in _rate:
        _rate[key] = []
    _rate[key] = [t for t in _rate[key] if now - t < _RATE_WINDOW]
    if len(_rate[key]) >= _RATE_LIMIT:
        return False
    _rate[key].append(now)
    return True


# --- Database ---
def _init_db():
    with _get_db() as db:
        db.executescript("""
            CREATE TABLE IF NOT EXISTS pageviews (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts DATETIME DEFAULT CURRENT_TIMESTAMP,
                path TEXT,
                referrer TEXT,
                visitor_hash TEXT,
                browser TEXT,
                os TEXT,
                device TEXT,
                lang TEXT
            );
            CREATE TABLE IF NOT EXISTS events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts DATETIME DEFAULT CURRENT_TIMESTAMP,
                name TEXT,
                data TEXT,
                visitor_hash TEXT,
                path TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_pv_ts ON pageviews(ts);
            CREATE INDEX IF NOT EXISTS idx_pv_visitor ON pageviews(visitor_hash);
            CREATE INDEX IF NOT EXISTS idx_ev_ts ON events(ts);
            CREATE INDEX IF NOT EXISTS idx_ev_name ON events(name);
        """)


@contextmanager
def _get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


# --- UA Parsing (lightweight, no dependency) ---
def _parse_ua(ua: str) -> dict:
    browser = "Other"
    os_name = "Other"
    device = "Desktop"

    if not ua:
        return {"browser": browser, "os": os_name, "device": device}

    # Browser
    if "Edg/" in ua:
        browser = "Edge"
    elif "Chrome/" in ua and "Safari/" in ua:
        browser = "Chrome"
    elif "Firefox/" in ua:
        browser = "Firefox"
    elif "Safari/" in ua and "Chrome/" not in ua:
        browser = "Safari"
    elif "MSIE" in ua or "Trident/" in ua:
        browser = "IE"

    # OS
    if "Mac OS X" in ua or "Macintosh" in ua:
        os_name = "macOS"
    elif "Windows" in ua:
        os_name = "Windows"
    elif "Linux" in ua:
        os_name = "Linux"
    elif "iPhone" in ua or "iPad" in ua:
        os_name = "iOS"
    elif "Android" in ua:
        os_name = "Android"

    # Device
    if "Mobile" in ua or "iPhone" in ua or "Android" in ua:
        device = "Mobile"
    elif "iPad" in ua or "Tablet" in ua:
        device = "Tablet"

    return {"browser": browser, "os": os_name, "device": device}


def _visitor_hash(ip: str, ua: str) -> str:
    today = datetime.utcnow().strftime("%Y-%m-%d")
    raw = f"{SALT}:{ip}:{ua}:{today}"
    return hashlib.sha256(raw.encode()).hexdigest()[:16]


def _get_ip(request: Request) -> str:
    forwarded = request.headers.get("x-forwarded-for", "")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.client.host if request.client else "unknown"


def _period_to_days(period: str) -> int:
    m = re.match(r"(\d+)d", period)
    if m:
        return min(int(m.group(1)), 365)
    return 7


# --- Auth ---
def _verify_admin(credentials: HTTPBasicCredentials = Depends(security)):
    ok_user = secrets.compare_digest(credentials.username, ADMIN_USER)
    ok_pass = secrets.compare_digest(credentials.password, ADMIN_PASS)
    if not (ok_user and ok_pass):
        raise HTTPException(status_code=401, headers={"WWW-Authenticate": "Basic"})
    return True


# --- Collection Endpoints ---
@app.get("/t.gif")
async def track_pageview(request: Request, p: str = "/"):
    ip = _get_ip(request)
    if not _check_rate(ip):
        return Response(content=PIXEL, media_type="image/gif")

    ua = request.headers.get("user-agent", "")
    parsed = _parse_ua(ua)
    ref = request.headers.get("referer", "")
    lang = request.headers.get("accept-language", "")[:10]
    vh = _visitor_hash(ip, ua)

    with _get_db() as db:
        db.execute(
            "INSERT INTO pageviews (path, referrer, visitor_hash, browser, os, device, lang) VALUES (?,?,?,?,?,?,?)",
            (p, ref, vh, parsed["browser"], parsed["os"], parsed["device"], lang),
        )

    return Response(
        content=PIXEL,
        media_type="image/gif",
        headers={"Cache-Control": "no-cache, no-store", "Expires": "0"},
    )


@app.post("/api/event")
async def track_event(request: Request):
    ip = _get_ip(request)
    if not _check_rate(ip):
        return JSONResponse({"ok": True})

    try:
        body = await request.json()
    except Exception:
        return JSONResponse({"ok": False}, status_code=400)

    name = str(body.get("name", ""))[:64]
    data = json.dumps(body.get("data", {}))[:512]
    path = str(body.get("path", "/"))[:256]
    ua = request.headers.get("user-agent", "")
    vh = _visitor_hash(ip, ua)

    if not name:
        return JSONResponse({"ok": False}, status_code=400)

    with _get_db() as db:
        db.execute(
            "INSERT INTO events (name, data, visitor_hash, path) VALUES (?,?,?,?)",
            (name, data, vh, path),
        )

    return JSONResponse({"ok": True})


# --- Dashboard ---
@app.get("/", response_class=HTMLResponse)
async def dashboard(_=Depends(_verify_admin)):
    if DASHBOARD_HTML.exists():
        return HTMLResponse(DASHBOARD_HTML.read_text(encoding="utf-8"))
    return HTMLResponse("<h1>Dashboard not found</h1>", status_code=404)


# --- API Endpoints ---
@app.get("/api/stats")
async def api_stats(period: str = "7d", _=Depends(_verify_admin)):
    days = _period_to_days(period)
    since = (datetime.utcnow() - timedelta(days=days)).strftime("%Y-%m-%d %H:%M:%S")
    today = datetime.utcnow().strftime("%Y-%m-%d")

    with _get_db() as db:
        pv = db.execute("SELECT COUNT(*) c FROM pageviews WHERE ts >= ?", (since,)).fetchone()["c"]
        uv = db.execute("SELECT COUNT(DISTINCT visitor_hash) c FROM pageviews WHERE ts >= ?", (since,)).fetchone()["c"]
        ev = db.execute("SELECT COUNT(*) c FROM events WHERE ts >= ?", (since,)).fetchone()["c"]
        dl = db.execute("SELECT COUNT(*) c FROM events WHERE name='download_click' AND ts >= ?", (since,)).fetchone()["c"]
        gh = db.execute("SELECT COUNT(*) c FROM events WHERE name='github_click' AND ts >= ?", (since,)).fetchone()["c"]

        pv_today = db.execute("SELECT COUNT(*) c FROM pageviews WHERE ts >= ?", (today,)).fetchone()["c"]
        uv_today = db.execute("SELECT COUNT(DISTINCT visitor_hash) c FROM pageviews WHERE ts >= ?", (today,)).fetchone()["c"]
        dl_today = db.execute("SELECT COUNT(*) c FROM events WHERE name='download_click' AND ts >= ?", (today,)).fetchone()["c"]

    return {
        "period": period,
        "pv": pv, "uv": uv, "events": ev, "downloads": dl, "github": gh,
        "today": {"pv": pv_today, "uv": uv_today, "downloads": dl_today},
    }


@app.get("/api/pageviews")
async def api_pageviews(period: str = "7d", _=Depends(_verify_admin)):
    days = _period_to_days(period)
    since = (datetime.utcnow() - timedelta(days=days)).strftime("%Y-%m-%d %H:%M:%S")

    with _get_db() as db:
        rows = db.execute(
            "SELECT DATE(ts) d, COUNT(*) pv, COUNT(DISTINCT visitor_hash) uv FROM pageviews WHERE ts >= ? GROUP BY d ORDER BY d",
            (since,),
        ).fetchall()

    return [{"date": r["d"], "pv": r["pv"], "uv": r["uv"]} for r in rows]


@app.get("/api/events")
async def api_events(period: str = "7d", _=Depends(_verify_admin)):
    days = _period_to_days(period)
    since = (datetime.utcnow() - timedelta(days=days)).strftime("%Y-%m-%d %H:%M:%S")

    with _get_db() as db:
        rows = db.execute(
            "SELECT name, COUNT(*) cnt FROM events WHERE ts >= ? GROUP BY name ORDER BY cnt DESC",
            (since,),
        ).fetchall()

    return [{"name": r["name"], "count": r["cnt"]} for r in rows]


@app.get("/api/funnel")
async def api_funnel(period: str = "7d", _=Depends(_verify_admin)):
    days = _period_to_days(period)
    since = (datetime.utcnow() - timedelta(days=days)).strftime("%Y-%m-%d %H:%M:%S")

    steps = ["proof", "efficiency", "how", "privacy", "features", "faq", "cta"]
    with _get_db() as db:
        rows = db.execute(
            """SELECT json_extract(data, '$.section') sec, COUNT(DISTINCT visitor_hash) uv
               FROM events WHERE name='scroll_depth' AND ts >= ?
               GROUP BY sec""",
            (since,),
        ).fetchall()

    counts = {r["sec"]: r["uv"] for r in rows}
    return [{"step": s, "visitors": counts.get(s, 0)} for s in steps]


@app.get("/api/referrers")
async def api_referrers(period: str = "7d", _=Depends(_verify_admin)):
    days = _period_to_days(period)
    since = (datetime.utcnow() - timedelta(days=days)).strftime("%Y-%m-%d %H:%M:%S")

    with _get_db() as db:
        rows = db.execute(
            """SELECT CASE WHEN referrer = '' THEN '(direct)' ELSE referrer END ref,
                      COUNT(*) cnt
               FROM pageviews WHERE ts >= ?
               GROUP BY ref ORDER BY cnt DESC LIMIT 20""",
            (since,),
        ).fetchall()

    return [{"referrer": r["ref"], "count": r["cnt"]} for r in rows]


@app.get("/api/devices")
async def api_devices(period: str = "7d", _=Depends(_verify_admin)):
    days = _period_to_days(period)
    since = (datetime.utcnow() - timedelta(days=days)).strftime("%Y-%m-%d %H:%M:%S")

    with _get_db() as db:
        browsers = db.execute(
            "SELECT browser name, COUNT(*) cnt FROM pageviews WHERE ts >= ? GROUP BY browser ORDER BY cnt DESC",
            (since,),
        ).fetchall()
        oses = db.execute(
            "SELECT os name, COUNT(*) cnt FROM pageviews WHERE ts >= ? GROUP BY os ORDER BY cnt DESC",
            (since,),
        ).fetchall()
        devices = db.execute(
            "SELECT device name, COUNT(*) cnt FROM pageviews WHERE ts >= ? GROUP BY device ORDER BY cnt DESC",
            (since,),
        ).fetchall()

    return {
        "browsers": [{"name": r["name"], "count": r["cnt"]} for r in browsers],
        "os": [{"name": r["name"], "count": r["cnt"]} for r in oses],
        "devices": [{"name": r["name"], "count": r["cnt"]} for r in devices],
    }


# --- Startup ---
@app.on_event("startup")
async def startup():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    _init_db()


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8100)

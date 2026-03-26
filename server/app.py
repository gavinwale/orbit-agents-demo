"""FastAPI application — serves frontend, handles auth, streams sim events via SSE."""

import asyncio
import json
import logging
import queue
from pathlib import Path

from fastapi import FastAPI, Depends, Request
from fastapi.responses import HTMLResponse, JSONResponse, Response, StreamingResponse
from fastapi.staticfiles import StaticFiles

from server.auth import check_password, require_auth
from server.sim_manager import SimManager

logging.basicConfig(
    level=logging.INFO,
    format="  %(asctime)s  %(levelname)-7s  %(name)s  %(message)s",
    datefmt="%H:%M:%S",
)
for _lib in ("httpx", "httpcore", "urllib3", "openai"):
    logging.getLogger(_lib).setLevel(logging.WARNING)

logger = logging.getLogger("server")

ROOT = Path(__file__).parent.parent.resolve()
FRONTEND = ROOT / "frontend"

app = FastAPI(title="OrbitAgents Demo")
sim = SimManager()


# ── Pages ─────────────────────────────────────────────────────────────────────

@app.get("/", response_class=HTMLResponse)
async def index():
    return (FRONTEND / "index.html").read_text()


@app.get("/dashboard", response_class=HTMLResponse)
async def dashboard(request: Request):
    token = request.cookies.get("session") or request.query_params.get("token")
    if not token:
        return HTMLResponse('<script>location.href="/"</script>')
    return (FRONTEND / "dashboard.html").read_text()


# ── Auth ──────────────────────────────────────────────────────────────────────

@app.post("/api/auth")
async def auth(request: Request):
    body = await request.json()
    password = body.get("password", "")
    token = check_password(password)
    if not token:
        return JSONResponse({"error": "Wrong password"}, status_code=401)
    response = JSONResponse({"ok": True})
    response.set_cookie("session", token, httponly=True, samesite="lax", max_age=86400)
    return response


# ── Sim control ───────────────────────────────────────────────────────────────

@app.get("/api/sim/status")
async def sim_status():
    return JSONResponse(sim.status())


@app.post("/api/sim/start")
async def sim_start(_=Depends(require_auth)):
    if sim.start():
        return JSONResponse({"ok": True, "msg": "Simulation starting..."})
    return JSONResponse({"ok": False, "msg": "Simulation already running"}, status_code=409)


@app.post("/api/sim/stop")
async def sim_stop(_=Depends(require_auth)):
    sim.stop()
    return JSONResponse({"ok": True, "msg": "Simulation stopped"})


# ── SSE event stream ─────────────────────────────────────────────────────────

@app.get("/api/events")
async def events(request: Request, _=Depends(require_auth)):
    if not sim.state:
        return JSONResponse({"error": "No simulation running"}, status_code=404)

    q = sim.state.subscribe()

    async def event_generator():
        try:
            while True:
                if await request.is_disconnected():
                    break
                try:
                    event = q.get_nowait()
                    yield f"data: {json.dumps(event)}\n\n"
                except queue.Empty:
                    await asyncio.sleep(0.1)
        finally:
            sim.state.unsubscribe(q)

    return StreamingResponse(
        event_generator(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


# ── State snapshot ────────────────────────────────────────────────────────────

@app.get("/api/state")
async def state(_=Depends(require_auth)):
    if not sim.state or not sim._cfg:
        return JSONResponse({})
    return JSONResponse(sim.state.dashboard_snapshot(sim._cfg))


# ── Report ────────────────────────────────────────────────────────────────────

@app.get("/api/report", response_class=HTMLResponse)
async def report(_=Depends(require_auth)):
    if sim.last_report:
        return HTMLResponse(sim.last_report)
    return HTMLResponse("<h1>No report yet</h1><p>Run a simulation first.</p>")


# Serve static assets AFTER all routes (so / doesn't get intercepted)
app.mount("/static", StaticFiles(directory=str(FRONTEND)), name="static")

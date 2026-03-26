"""HTTP + SSE dashboard server for OrbitAgents."""

import json
import logging
import queue
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

logger = logging.getLogger(__name__)

AGENTS_DIR = Path(__file__).parent.parent.resolve()


def _make_handler(state, cfg):
    """Factory that closes over state and cfg so the handler class is re-usable."""

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass  # suppress default request logging; use structured logs instead

        def do_GET(self):
            if self.path in ("/", "/dashboard"):
                self._serve(AGENTS_DIR / "templates" / "dashboard.html", "text/html")

            elif self.path == "/events":
                self._sse()

            elif self.path == "/state.json":
                self._json(state.dashboard_snapshot(cfg))

            elif self.path == "/report":
                rp = AGENTS_DIR / "last_report.html"
                if rp.exists():
                    self._serve(rp, "text/html")
                else:
                    self._text(404, "Report not ready — run the simulation first.")

            elif self.path == "/report-live":
                self._serve_report_live()

            elif self.path == "/news":
                body = ("\n".join(state.news_log) or "No breaking news yet.").encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                self.wfile.write(body)

            else:
                self._text(404, "not found")

        # ── Response helpers ──────────────────────────────────────────────────

        def _serve(self, path: Path, content_type: str):
            if not path.exists():
                self._text(404, str(path))
                return
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.end_headers()
            self.wfile.write(path.read_bytes())

        def _json(self, data: dict):
            body = json.dumps(data).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(body)

        def _text(self, code: int, msg: str):
            self.send_response(code)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(msg.encode())

        def _serve_report_live(self):
            from reports.generator import generate_html
            body = generate_html(state.report_snapshot(cfg)).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(body)

        # ── SSE stream ────────────────────────────────────────────────────────

        def _sse(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()

            q = state.subscribe()
            try:
                while True:
                    try:
                        event = q.get(timeout=25)
                        self.wfile.write(f"data: {json.dumps(event)}\n\n".encode())
                        self.wfile.flush()
                    except queue.Empty:
                        # Keep-alive ping so the browser doesn't close the connection
                        self.wfile.write(b": ping\n\n")
                        self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                state.unsubscribe(q)

    return Handler


class _QuietServer(ThreadingHTTPServer):
    """Suppress harmless connection-reset errors from the default error handler."""

    def handle_error(self, request, client_address):
        import sys
        exc = sys.exc_info()[1]
        if isinstance(exc, (ConnectionResetError, BrokenPipeError)):
            return
        super().handle_error(request, client_address)


def start(state, cfg: dict, port: int) -> ThreadingHTTPServer:
    """Start the dashboard server in a daemon thread. Returns the server instance."""
    handler = _make_handler(state, cfg)
    server  = _QuietServer(("127.0.0.1", port), handler)
    threading.Thread(target=server.serve_forever, daemon=True, name="dashboard").start()
    logger.info("Dashboard: http://localhost:%d", port)
    return server

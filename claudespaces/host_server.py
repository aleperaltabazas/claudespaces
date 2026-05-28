import json
import os
import shlex
import signal
import socket
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

from claudespaces import workspaces

PID_FILE = Path.home() / ".claudespaces" / "host_bridge.pid"
LOG_FILE = Path.home() / ".claudespaces" / "host_bridge.log"


def handle_run(op_name: str, args, operations: dict) -> tuple[int, dict]:
    """Core request handler logic — returns (status_code, response_dict)."""
    if op_name not in operations:
        return 400, {"error": f"unknown operation: {op_name!r}"}

    op = operations[op_name]
    cmd_parts = shlex.split(op["command"])

    if isinstance(args, list):
        named = dict(zip(op.get("args", []), args))
    else:
        named = args

    cmd = [part.format_map(named) for part in cmd_parts]

    if op.get("async", False):
        subprocess.Popen(
            cmd,
            start_new_session=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return 200, {"status": "ok"}

    result = subprocess.run(cmd, capture_output=True, text=True)
    return 200, {
        "stdout": result.stdout,
        "stderr": result.stderr,
        "exit_code": result.returncode,
    }


def _make_handler(operations: dict):
    class BridgeHandler(BaseHTTPRequestHandler):
        def log_message(self, format, *args):
            pass

        def do_POST(self):
            if self.path != "/run":
                self.send_error(404)
                return
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length))
            code, response = handle_run(
                body.get("op", ""), body.get("args", {}), operations
            )
            payload = json.dumps(response).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    return BridgeHandler


def run_server(port: int, operations: dict) -> None:
    server = HTTPServer(("127.0.0.1", port), _make_handler(operations))
    server.serve_forever()


def is_running(port: int) -> bool:
    with socket.socket() as s:
        return s.connect_ex(("127.0.0.1", port)) == 0


def start_server() -> None:
    """Spawn the bridge server as a background process and record its PID."""
    from claudespaces.host_config import load_host_bridge
    bridge = load_host_bridge()
    if is_running(bridge["port"]):
        return
    PID_FILE.parent.mkdir(parents=True, exist_ok=True)
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(LOG_FILE, "a") as log:
        proc = subprocess.Popen(
            [sys.executable, "-m", "claudespaces.host_server"],
            stdout=subprocess.DEVNULL,
            stderr=log,
        )
    PID_FILE.write_text(str(proc.pid))


def stop_server_if_last(stopped_name: str) -> None:
    """Kill the bridge if no workspaces other than stopped_name are still running."""
    remaining = [
        w for w in workspaces.all_workspaces()
        if w["name"] != stopped_name and w["status"] == "running"
    ]
    if remaining:
        return
    if not PID_FILE.exists():
        return
    pid = int(PID_FILE.read_text().strip())
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    PID_FILE.unlink(missing_ok=True)


if __name__ == "__main__":
    from claudespaces.host_config import load_host_bridge
    bridge = load_host_bridge()
    run_server(bridge["port"], bridge["operations"])

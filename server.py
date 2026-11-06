"""Computer-use agent server.

    uv run server.py            # http://localhost:8787
    uv run server.py --port 9000
    uv run server.py --provider claude       # default model for goals (LM Studio otherwise)

Three APIs, all thin over BAML:

  Execute (this process drives the screen, one goal at a time):
    POST /api/execute                  {"goal": "...", "max_steps": 30, "provider"?: "lmstudio"|"claude", "model"?: "..."}
    GET  /api/execute                  active run, queue, recent local runs
    POST /api/execute/<run_id>/cancel  stop a queued or running goal
    POST /api/execute/<run_id>/answer  {"answer": "..."} reply to the agent's question (ask_user)
    POST /api/execute/<run_id>/message {"text": "..."} steer: the agent reads it next turn

  Query (`baml query` over the Boundary cloud project in baml.toml):
    GET  /api/query/runs?limit=50      run summaries, newest first
    GET  /api/query/runs/<run_id>      one run, step by step
    POST /api/query/sql                {"sql": "SELECT ..."} -> rows (read-only)

  Models: GET /api/models  vision models in LM Studio, plus Claude if ANTHROPIC_API_KEY is set

  Home: GET / serves the React app in web/; GET /runs/... serves screenshots.

Cloud queries authenticate with BOUNDARY_API_KEY if it's set, else with your
`baml auth login` session.
"""

import argparse
import json
import mimetypes
import queue
import sys
import threading
import time
import traceback
import webbrowser
from dataclasses import dataclass, field, fields
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import baml_sdk as b
import agent
from baml_bridge import set_unhandled_spawn_error_handler


# A failed `spawn { ... }` that nothing awaited (e.g. the second query in
# list_runs when Boundary is briefly unreachable) ends the process by default.
# A server should log it and keep serving instead.
def _report_spawn_error(error: BaseException, cancelled: bool) -> None:
    if not cancelled:
        print("unobserved BAML spawn error (server keeps running):", file=sys.stderr)
        traceback.print_exception(error)


set_unhandled_spawn_error_handler(_report_spawn_error)

ROOT = Path(__file__).parent
WEB = ROOT / "web"
RUNS = ROOT / "runs"
RECENT_LIMIT = 20
# The dashboard's <title>: the browser window showing it starts with this.
DASHBOARD_TITLE = "Computer Use"
DASHBOARD_URL = "http://127.0.0.1:8787"  # set from --host/--port in main()
# A run out of steps waits this long for "continue" before it stops.
EXTEND_WAIT_SECONDS = 30 * 60
# Bring the user back to the dashboard when a run reaches one of these.
SUMMON_STATES = ("done", "gave_up", "out_of_steps", "error", "needs_input", "needs_steps")

# The browser closed the connection before we answered: it reloaded, switched
# runs, or a poll was superseded while a slow `baml query` ran. Harmless.
# (Windows reports this as WinError 10053, ConnectionAbortedError.)
CLIENT_GONE = (BrokenPipeError, ConnectionResetError, ConnectionAbortedError)


class RunCancelled(Exception):
    """Raised inside look/act to stop a run. BAML treats it as an abort."""


@dataclass
class Job:
    run_id: str
    goal: str
    max_steps: int
    model: dict  # run_task kwargs: provider, model, base_url
    # queued | running | needs_input | needs_steps | done | gave_up | out_of_steps | error | cancelled
    state: str = "queued"
    queued_at: float = field(default_factory=time.time)
    started_at: float | None = None
    ended_at: float | None = None
    step: int = 0
    latest_shot: str | None = None
    summary: str | None = None
    error: str | None = None
    # The agent's open question (ask_user), while state == "needs_input".
    question: str | None = None
    options: list[str] = field(default_factory=list)
    # Steering messages: {text, sent_at, delivered_step} (None until the agent reads it).
    messages: list[dict] = field(default_factory=list)
    cancel: threading.Event = field(default_factory=threading.Event, repr=False)
    answers: queue.Queue = field(default_factory=queue.Queue, repr=False)
    # Extra steps granted while state == "needs_steps" (0 = stop).
    extensions: queue.Queue = field(default_factory=queue.Queue, repr=False)

    PRIVATE = ("cancel", "answers", "extensions")

    def public(self) -> dict:
        return {f.name: getattr(self, f.name) for f in fields(self) if f.name not in self.PRIVATE}


class Executor:
    """Runs goals one at a time: there's only one screen and one mouse."""

    def __init__(self) -> None:
        self.jobs: dict[str, Job] = {}
        self.pending: queue.Queue[Job] = queue.Queue()
        self.active: Job | None = None
        self.lock = threading.Lock()
        threading.Thread(target=self._worker, daemon=True, name="executor").start()

    def submit(self, goal: str, max_steps: int, model: dict) -> Job:
        job = Job(run_id=b.new_run_id(), goal=goal, max_steps=max_steps, model=model)
        with self.lock:
            self.jobs[job.run_id] = job
        self.pending.put(job)
        return job

    def cancel(self, run_id: str) -> Job | None:
        job = self.jobs.get(run_id)
        if job and job.state in ("queued", "running"):
            job.cancel.set()
            if job.state == "queued":
                job.state = "cancelled"
        return job

    def status(self) -> dict:
        with self.lock:
            jobs = sorted(self.jobs.values(), key=lambda j: j.queued_at, reverse=True)
            return {
                "active": self.active.public() if self.active else None,
                "queue": [j.public() for j in jobs if j.state == "queued"][::-1],
                "recent": [j.public() for j in jobs if j.state not in ("queued", "running")][:RECENT_LIMIT],
            }

    def _worker(self) -> None:
        while True:
            job = self.pending.get()
            if job.cancel.is_set():
                continue
            with self.lock:
                self.active = job
            job.state, job.started_at = "running", time.time()
            try:
                outcome = b.run_task(
                    job.goal, self._look(job), self._act(job),
                    ask=self._ask(job), inbox=self._inbox(job), extend=self._extend(job),
                    max_steps=job.max_steps, run_id=job.run_id, **job.model,
                )
                job.state, job.summary = outcome.status, outcome.summary
            except Exception as e:  # cancel, failsafe, or a model/provider error
                job.state = "cancelled" if job.cancel.is_set() else "error"
                job.error = f"{type(e).__name__}: {e}".splitlines()[0][:500]
                if job.state == "error":
                    traceback.print_exc()
            finally:
                job.ended_at = time.time()
                with self.lock:
                    self.active = None
                summon(job)

    # look/act wrap the traced host functions with cancel checks and progress.
    def _look(self, job: Job):
        def look(path: str) -> b.Screenshot:
            if job.cancel.is_set():
                raise RunCancelled("cancelled from the dashboard")
            shot = agent.look(path)
            job.step += 1
            job.latest_shot = path
            return shot
        return look

    def _ask(self, job: Job):
        """Pause the run on the agent's question until the dashboard answers."""
        def ask(question: str, options: list[str]) -> str:
            job.question, job.options, job.state = question, list(options), "needs_input"
            summon(job)
            try:
                while True:
                    if job.cancel.is_set():
                        raise RunCancelled("cancelled from the dashboard")
                    try:
                        return job.answers.get(timeout=0.5)
                    except queue.Empty:
                        continue
            finally:
                job.question, job.options, job.state = None, [], "running"
        return ask

    def _extend(self, job: Job):
        """Out of steps: pause until the dashboard grants more (or stops the run)."""
        def extend(used: int) -> int:
            job.state = "needs_steps"
            summon(job)
            deadline = time.time() + EXTEND_WAIT_SECONDS
            try:
                while time.time() < deadline:
                    if job.cancel.is_set():
                        raise RunCancelled("cancelled from the dashboard")
                    try:
                        more = max(0, int(job.extensions.get(timeout=0.5)))
                    except queue.Empty:
                        continue
                    job.max_steps += more
                    return more
                return 0  # nobody answered: stop as out_of_steps
            finally:
                job.state = "running"
        return extend

    def extend(self, run_id: str, steps: int) -> Job | None:
        job = self.jobs.get(run_id)
        if not job or job.state != "needs_steps":
            return None
        job.extensions.put(steps)
        return job

    def _inbox(self, job: Job):
        """Steering messages sent since the agent last checked."""
        def inbox() -> list[str]:
            with self.lock:
                fresh = [m for m in job.messages if m["delivered_step"] is None]
                for m in fresh:
                    m["delivered_step"] = job.step
            return [m["text"] for m in fresh]
        return inbox

    def answer(self, run_id: str, text: str) -> Job | None:
        job = self.jobs.get(run_id)
        if not job or job.state != "needs_input":
            return None
        job.answers.put(text)
        return job

    def steer(self, run_id: str, text: str) -> Job | None:
        job = self.jobs.get(run_id)
        if not job or job.state not in ("queued", "running", "needs_input", "needs_steps"):
            return None
        with self.lock:
            job.messages.append({"text": text, "sent_at": time.time(), "delivered_step": None})
        return job

    def _act(self, job: Job):
        def act(op) -> None:
            if job.cancel.is_set():
                raise RunCancelled("cancelled from the dashboard")
            agent.act(op)
        return act


def summon(job: Job) -> None:
    """Bring the user back to the dashboard when a run ends or needs them:
    focus the browser window showing it, or open the run page if there's none."""
    if job.state not in SUMMON_STATES:
        return
    try:
        if not agent.bring_to_front(DASHBOARD_TITLE):
            webbrowser.open(f"{DASHBOARD_URL}/#/runs/{job.run_id}")
    except Exception:  # never let focusing a window break a run
        traceback.print_exc()


EXECUTOR = Executor()
DEFAULT_MODEL: dict = {"provider": "lmstudio"}


def dump(model) -> object:
    if isinstance(model, list):
        return [dump(m) for m in model]
    if hasattr(model, "model_dump"):
        return model.model_dump(mode="json")
    return model


class Handler(BaseHTTPRequestHandler):
    server_version = "computer-use/0.1"

    # ---- plumbing ----

    def log_message(self, fmt, *args) -> None:
        if "/api/" in self.path and self.command == "GET":
            return  # polling is noisy
        super().log_message(fmt, *args)

    def send_json(self, body: object, status: int = 200) -> None:
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def send_file(self, path: Path, base: Path) -> None:
        path = path.resolve()
        if not path.is_relative_to(base.resolve()) or not path.is_file():
            return self.send_json({"error": "not found"}, 404)
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", mimetypes.guess_type(path.name)[0] or "application/octet-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self) -> dict:
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def guard(self, fn) -> None:
        try:
            fn()
        except CLIENT_GONE:
            pass  # the browser moved on mid-request; nobody to answer
        except Exception as e:
            traceback.print_exc()
            try:
                self.send_json({"error": f"{type(e).__name__}: {e}"}, 500)
            except CLIENT_GONE:
                pass

    # ---- routes ----

    def do_GET(self) -> None:
        url = urlparse(self.path)
        parts = [p for p in url.path.split("/") if p]
        match parts:
            case ["api", "execute"]:
                self.send_json(EXECUTOR.status())
            case ["api", "models"]:
                def models():
                    choices = dump(b.available_models(base_url=DEFAULT_MODEL.get("base_url")))
                    choices["default"] = DEFAULT_MODEL
                    self.send_json(choices)
                self.guard(models)
            case ["api", "query", "runs"]:
                limit = int(parse_qs(url.query).get("limit", ["50"])[0])
                self.guard(lambda: self.send_json(dump(b.list_runs(limit=limit))))
            case ["api", "query", "runs", run_id]:
                def detail():
                    run = b.get_run(run_id)
                    self.send_json(dump(run) if run else {"error": "no such run yet"}, 200 if run else 404)
                self.guard(detail)
            case ["runs", *rest]:
                self.send_file(RUNS.joinpath(*rest), RUNS)
            case []:
                self.send_file(WEB / "index.html", WEB)
            case _:
                self.send_file(WEB.joinpath(*parts), WEB)

    def do_POST(self) -> None:
        parts = [p for p in urlparse(self.path).path.split("/") if p]
        match parts:
            case ["api", "execute"]:
                body = self.body()
                goal = (body.get("goal") or "").strip()
                if not goal:
                    return self.send_json({"error": "goal is required"}, 400)
                model = dict(DEFAULT_MODEL)
                if body.get("provider"):
                    model = {"provider": body["provider"], "platform": agent.PLATFORM}
                    if "base_url" in DEFAULT_MODEL and body["provider"] == "lmstudio":
                        model["base_url"] = DEFAULT_MODEL["base_url"]
                if body.get("model"):
                    model["model"] = body["model"]
                if model["provider"] not in ("lmstudio", "claude"):
                    return self.send_json({"error": f"unknown provider {model['provider']!r}"}, 400)
                if model["provider"] == "claude" and not any(
                    o.provider == "claude" for o in b.available_models().options
                ):
                    return self.send_json({"error": "Claude needs ANTHROPIC_API_KEY set on the server"}, 400)
                job = EXECUTOR.submit(goal, int(body.get("max_steps") or 30), model)
                self.send_json(job.public(), 202)
            case ["api", "execute", run_id, "answer"]:
                text = (self.body().get("answer") or "").strip()
                job = EXECUTOR.answer(run_id, text) if text else None
                self.send_json(job.public() if job else {"error": "nothing to answer (or empty answer)"}, 200 if job else 409)
            case ["api", "execute", run_id, "extend"]:
                try:
                    steps = int(self.body().get("steps", 0))
                except (TypeError, ValueError):
                    return self.send_json({"error": "steps must be a whole number"}, 400)
                if not 0 <= steps <= 500:
                    return self.send_json({"error": "steps must be between 0 and 500"}, 400)
                job = EXECUTOR.extend(run_id, steps)
                self.send_json(job.public() if job else {"error": "run isn't waiting for more steps"}, 200 if job else 409)
            case ["api", "execute", run_id, "message"]:
                text = (self.body().get("text") or "").strip()
                job = EXECUTOR.steer(run_id, text) if text else None
                self.send_json(job.public() if job else {"error": "run isn't active (or empty message)"}, 200 if job else 409)
            case ["api", "execute", run_id, "cancel"]:
                job = EXECUTOR.cancel(run_id)
                self.send_json(job.public() if job else {"error": "no such job"}, 200 if job else 404)
            case ["api", "query", "sql"]:
                sql = (self.body().get("sql") or "").strip()
                self.guard(lambda: self.send_json(b.query_rows(sql)))
            case _:
                self.send_json({"error": "not found"}, 404)


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address) -> None:
        # Disconnects while streaming static files/JSON aren't errors.
        if isinstance(sys.exc_info()[1], CLIENT_GONE):
            return
        super().handle_error(request, client_address)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8787)
    agent.add_model_flags(p)
    a = p.parse_args()
    DEFAULT_MODEL.clear()
    DEFAULT_MODEL.update(agent.model_kwargs(a))
    global DASHBOARD_URL
    DASHBOARD_URL = f"http://{a.host}:{a.port}"
    RUNS.mkdir(exist_ok=True)
    print(f"computer-use: http://{a.host}:{a.port}  (default model: {DEFAULT_MODEL})")
    if agent.TRACE_MODE == "local":
        print(f"traces: local, in {agent.PROJECT_TRACES}")
    else:
        print("traces: Boundary cloud (baml.toml [boundary] project)")
    Server((a.host, a.port), Handler).serve_forever()


if __name__ == "__main__":
    main()

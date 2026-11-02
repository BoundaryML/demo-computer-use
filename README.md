# demo-computer-use

A computer-use agent for macOS, Windows, and Linux where **BAML is the brain** and Python only does what BAML can't: take screenshots and move the mouse and keyboard. It runs on local open-source vision models through LM Studio by default, or on Claude. A live dashboard, built on `baml query`, shows every step: the screenshot the model saw, every option it considered, the one it chose, and exactly where it clicked.

```
uv run server.py          # http://127.0.0.1:8787, then type a goal
```

## How it works

```
Python (agent.py)                 BAML (baml_src/)
─────────────────                 ─────────────────────────────────────────────
look(path) -> Screenshot  ◀──┐    run_task(goal, look, act)
act(op)                   ◀──┤      loop:
                             ├──────  shot = look(...)
                             │        Decide(goal, notes, history, screenshot) -> Decision
                             │          observation, verdict on the last step,
                             │          candidates, remember, plan, action, expectation
                             └──────  for op in action.ops(shot): act(op)
```

- **One loop, in BAML.** Python passes `look` and `act` into `run_task` as callables, both traced with `@trace.instrument`, so a run is one trace tree.
- **Typed action space** (`agent/actions.baml`): `click`, `double_click`, `type`, `key`, `scroll`, `drag`, `hover`, `open_app`, `open_url`, `wait`, `done`, `give_up`. Each action compiles itself to screen-space ops; Python never does coordinate math.
- **The decision schema does the reasoning.** The model writes, in order: what it sees, whether its last action worked, the candidate moves with screen positions, facts to `remember`, its plan, the action, and what it expects to see next.
- **Memory.** Facts the model saves (text to copy, names, numbers) are fed back every turn. Without this, it loses information as soon as it switches apps and ping-pongs between them.
- **Loop detection.** Warnings when the same action repeats, keeps coming back, keeps failing, or the step budget is nearly spent.
- **Coordinate spaces.** Claude answers in screenshot pixels. Qwen3-VL answers on a 0–1000 grid. `Pilot.view()` handles both.
- **Cross-platform** (`screen/platform.baml`). Python reports the OS; BAML compiles each action for it. The prompt names the OS and its shortcut modifier (`cmd` on macOS, `ctrl` elsewhere). Key names map per OS, so a model's `cmd+l` becomes `ctrl+l` on Windows. Apps and URLs open the native way:

  | | `open_app` | `open_url` |
  |---|---|---|
  | macOS | `open -a App` | `open URL` |
  | Windows | Win, type the name, Enter | Win+R, type the URL, Enter |
  | Linux | Super, type the name, Enter | `xdg-open URL` |

## Setup

Needs [uv](https://docs.astral.sh/uv/) and the [BAML CLI](https://boundaryml.com) (`brew install baml` on macOS).

```bash
uv sync
baml generate                 # writes the typed Python SDK (baml_sdk/)
```

Permissions:
- **macOS:** grant your terminal **Accessibility** and **Screen Recording** (System Settings → Privacy & Security).
- **Windows:** no setup, but input can't reach elevated (admin) windows unless the agent runs elevated too.
- **Linux:** an X11 session (pyautogui doesn't support Wayland), plus `scrot` for screenshots.

macOS is tested end to end. Windows and Linux are untested on real machines: their action compilation is unit-tested, and the Windows path was dry-run through the full loop.

**Models**

- **LM Studio (default):** download `qwen3-vl-4b-instruct` and start the local server (Settings → Local API server). The default URL is `http://127.0.0.1:1235/v1`; change it with `--base-url`. Give the model a context length of at least 8192.
- **Claude:** set `ANTHROPIC_API_KEY`. The UI only offers Claude when the key is set.

**Traces.** The mode is picked at startup, and the server prints which one it chose:
- **Boundary cloud:** used when `BOUNDARY_API_KEY` is a real key, or `baml auth login` is verified. Set `[boundary] project` in `baml.toml` to your `org/project`.
- **Local:** used when `BOUNDARY_API_KEY=local`, or when there are no cloud credentials. Traces go to this project's `.baml/`, where the dashboard queries them.

## Run

```bash
uv run server.py                                  # dashboard + API at http://127.0.0.1:8787
uv run server.py --provider claude                # make Claude the default

uv run agent.py "Open Calculator and compute 12 * 34"
uv run agent.py --model qwen3-vl-8b-instruct "..."
uv run agent.py --provider claude "..."
```

Slam the mouse into a screen corner to abort a run.

## Server API

| | |
|---|---|
| `POST /api/execute` | `{"goal", "max_steps"?, "provider"?, "model"?}` queues a goal (one at a time: there's one mouse) |
| `GET /api/execute` | active run, queue, recent local runs |
| `POST /api/execute/<run_id>/cancel` | cancel |
| `GET /api/query/runs` | run summaries from `baml query` |
| `GET /api/query/runs/<run_id>` | one run, step by step |
| `POST /api/query/sql` | `{"sql": "SELECT ..."}`, read-only |
| `GET /api/models` | LM Studio vision models, plus Claude if a key is set |

The frontend (`web/`) is a client-side React app with no build step.

## Layout

```
agent.py                  Python host: look/act + CLI
server.py                 HTTP server: executor + query API + static frontend
web/                      React dashboard
baml_src/
  screen/platform.baml    per-OS key names, shortcut modifier, app/URL launching
  clients.baml            model selection (Pilot): LM Studio / Claude, coordinate spaces
  screen/ops.baml         screen ops, coordinate mapping, key aliases
  agent/actions.baml      action space; each action compiles to ops
  agent/decide_prompt.baml  the decision prompt + schema
  agent/agent.baml        the loop: memory, history, loop detection, outcomes
  api/query.baml          typed `baml query` client (cloud or local)
  api/runs.baml           run list / run detail for the dashboard
  api/models.baml         available models
```

Tests run offline, with no model calls: `baml test`.

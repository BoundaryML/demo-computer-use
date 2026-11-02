"""Computer-use agent host: Python's eyes and hands, BAML's brain.

BAML (baml_src/) runs the whole loop: deciding, history, loop detection,
compiling actions to screen-space ops. Python hands it two callables for what
BAML can't do itself: `look` (screenshot) and `act` (mouse/keyboard). Both
are traced, so they show up nested inside the BAML run in `baml query`.

    uv run agent.py "Open Safari and search for the weather in Tokyo"
    uv run agent.py --max-steps 15 "..."
    uv run agent.py --model qwen/qwen3-vl-8b "..."       # another LM Studio model
    uv run agent.py --provider claude "..."             # Claude instead of a local model

Abort any time by slamming the mouse into a screen corner (pyautogui failsafe)
or with Ctrl-C.
"""

import argparse
import subprocess
import sys
import time

import os
from pathlib import Path

import pyautogui
from PIL import Image, ImageDraw

# BOUNDARY_API_KEY=local records traces on this machine instead of the cloud.
# By default the bridge writes them to the shared ~/.baml store (every
# project's runs: slow to query). Point it at this project's .baml/, which is
# where `baml query --local` reads. Must run before baml_sdk is imported.
if os.environ.get("BOUNDARY_API_KEY") == "local" and "SINAI_BAML_HOME" not in os.environ:
    os.environ["SINAI_BAML_HOME"] = os.environ.get("BAML_HOME", str(Path.home() / ".baml"))
    os.environ["BAML_HOME"] = str(Path(__file__).resolve().parent / ".baml")

import baml_sdk as b
from baml_sdk import trace

pyautogui.FAILSAFE = True
pyautogui.PAUSE = 0.05


@trace.instrument(trace.span(inputs=True))
def look(path: str, max_width: int = 1280) -> b.Screenshot:
    """Grab the screen in logical points, mark the cursor, downscale for the model."""
    sw, sh = pyautogui.size()
    img = pyautogui.screenshot().resize((sw, sh), Image.LANCZOS)  # Retina -> points
    # macOS screenshots omit the pointer; the model needs it for hovers/drags.
    cx, cy = pyautogui.position()
    d = ImageDraw.Draw(img)
    d.ellipse((cx - 6, cy - 6, cx + 6, cy + 6), outline=(255, 0, 0), width=2)
    d.line((cx - 10, cy, cx + 10, cy), fill=(255, 0, 0))
    d.line((cx, cy - 10, cx, cy + 10), fill=(255, 0, 0))
    if sw > max_width:
        img = img.resize((max_width, round(sh * max_width / sw)), Image.LANCZOS)
    img.convert("RGB").save(path, "PNG", optimize=True)
    return b.Screenshot(path=path, width=img.width, height=img.height,
                        screen_width=sw, screen_height=sh)


def type_text(text: str) -> None:
    if text.isascii():
        # System Events types shifted characters (*, @, ?) correctly;
        # pyautogui.write drops the shift on macOS. Text goes in as argv,
        # never spliced into the script, so it can't break out of the string.
        subprocess.run(
            ["osascript", "-e", "on run argv",
             "-e", 'tell application "System Events" to keystroke (item 1 of argv)',
             "-e", "end run", text],
            check=True, capture_output=True, timeout=60,
        )
    else:  # keystroke can't type non-ASCII reliably; paste it.
        subprocess.run(["pbcopy"], input=text.encode(), check=True)
        pyautogui.hotkey("command", "v")


@trace.instrument(trace.span(inputs=True))
def act(op) -> None:
    """Run one op exactly as BAML compiled it. No logic lives here."""
    match op.op:
        case "click":
            pyautogui.click(op.x, op.y, clicks=op.count, interval=0.08, button=op.button)
        case "move":
            pyautogui.moveTo(op.x, op.y, duration=0.15)
        case "drag":
            pyautogui.moveTo(op.from_x, op.from_y)
            pyautogui.dragTo(op.to_x, op.to_y, duration=0.4, button="left")
        case "type":
            type_text(op.text)
        case "key":
            pyautogui.hotkey(*op.keys, interval=0.05)
        case "scroll":
            pyautogui.moveTo(op.x, op.y)
            if op.dy:
                pyautogui.scroll(op.dy)
            if op.dx:
                pyautogui.hscroll(op.dx)
        case "open":
            subprocess.run(["open", *op.args], check=True, capture_output=True, timeout=30)
        case "sleep":
            time.sleep(op.seconds)
        case other:
            raise ValueError(f"unknown op {other}")


def add_model_flags(p: argparse.ArgumentParser) -> None:
    p.add_argument("--provider", choices=["lmstudio", "claude"], default="lmstudio",
                   help="lmstudio (default): a local open-source VLM; claude: Claude Sonnet")
    p.add_argument("--model", help="model id, e.g. qwen3-vl-4b-instruct (default) or claude-sonnet-5-5")
    p.add_argument("--base-url", help="LM Studio server URL (default http://127.0.0.1:1235/v1)")


def model_kwargs(args) -> dict:
    kw = {"provider": args.provider}
    if args.model:
        kw["model"] = args.model
    if args.base_url:
        kw["base_url"] = args.base_url
    return kw


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("goal")
    p.add_argument("--max-steps", type=int, default=30)
    add_model_flags(p)
    args = p.parse_args()

    try:
        outcome = b.run_task(args.goal, look, act, max_steps=args.max_steps, **model_kwargs(args))
    except pyautogui.FailSafeException:
        print("aborted: mouse moved to a screen corner")
        return 130
    for s in outcome.steps:
        print(f"#{s.index} [{s.verdict}] {s.decision.action.action}: {s.decision.plan}")
    print(f"\n{outcome.run_id} [{outcome.status}] {outcome.summary}")
    print(f"details: uv run server.py, then open http://127.0.0.1:8787/#/runs/{outcome.run_id}")
    return 0 if outcome.status == "done" else 1


if __name__ == "__main__":
    sys.exit(main())

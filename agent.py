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
import pyperclip
from PIL import Image, ImageDraw

# Where traces go. Decided once, here, before baml_sdk is imported:
#   cloud: BOUNDARY_API_KEY is a real key, or `baml auth login` is verified.
#   local: BOUNDARY_API_KEY=local, or no cloud credentials at all.
# Without cloud credentials BAML would quietly record to the shared ~/.baml
# store (every project's runs: slow to query) while `baml query` reads this
# project's .baml/, so the dashboard showed nothing. In local mode, pin both
# to this project's .baml/.
PROJECT_TRACES = Path(__file__).resolve().parent / ".baml"


def _trace_mode() -> str:
    key = os.environ.get("BOUNDARY_API_KEY", "").strip()
    if key:
        return "local" if key == "local" else "cloud"
    try:
        status = subprocess.run(["baml", "auth", "status"], capture_output=True, text=True, timeout=30)
        return "cloud" if "(verified)" in status.stdout + status.stderr else "local"
    except (OSError, subprocess.SubprocessError):
        return "local"


TRACE_MODE = _trace_mode()
if TRACE_MODE == "local" and "COMPUTER_USE_BAML_HOME" not in os.environ:
    os.environ["BOUNDARY_API_KEY"] = "local"
    os.environ["COMPUTER_USE_BAML_HOME"] = os.environ.get("BAML_HOME", str(Path.home() / ".baml"))
    os.environ["BAML_HOME"] = str(PROJECT_TRACES)

import baml_sdk as b
from baml_sdk import trace

# BAML compiles actions to this OS's keys and launchers (baml_src/screen/platform.baml).
PLATFORM = {"darwin": "macos", "win32": "windows"}.get(sys.platform, "linux")
PASTE = ("command", "v") if PLATFORM == "macos" else ("ctrl", "v")

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
    if not text.isascii():
        # Typing can't produce non-ASCII reliably anywhere; paste it.
        pyperclip.copy(text)
        pyautogui.hotkey(*PASTE)
    elif PLATFORM == "macos":
        # System Events types shifted characters (*, @, ?) correctly;
        # pyautogui.write drops the shift on macOS. Text goes in as argv,
        # never spliced into the script, so it can't break out of the string.
        subprocess.run(
            ["osascript", "-e", "on run argv",
             "-e", 'tell application "System Events" to keystroke (item 1 of argv)',
             "-e", "end run", text],
            check=True, capture_output=True, timeout=60,
        )
    else:
        pyautogui.write(text, interval=0.01)


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
        case "open":  # macOS
            subprocess.run(["open", *op.args], check=True, capture_output=True, timeout=30)
        case "launch":  # Linux (xdg-open)
            subprocess.Popen(op.argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        case "sleep":
            time.sleep(op.seconds)
        case other:
            raise ValueError(f"unknown op {other}")


def bring_to_front(title_prefix: str) -> bool:
    """Bring the browser tab or window whose title starts with `title_prefix`
    (the dashboard) to the front. Returns False when nothing matched or focus
    couldn't be moved, so the caller can open the page instead."""
    try:
        if PLATFORM == "windows":
            return _front_windows(title_prefix)
        if PLATFORM == "macos":
            return _front_macos(title_prefix)
    except (OSError, subprocess.SubprocessError):
        pass
    return False


# macOS: browsers that expose their tabs to AppleScript, by process name. These
# can switch to the dashboard tab even when it isn't the active one.
_MAC_TAB_BROWSERS = {
    "Google Chrome": "chromium", "Arc": "chromium", "Brave Browser": "chromium",
    "Microsoft Edge": "chromium", "Safari": "safari",
}
_MAC_FIND_TAB = {
    "chromium": """
on run argv
  tell application "{app}"
    repeat with w in windows
      set i to 0
      repeat with t in tabs of w
        set i to i + 1
        if title of t starts with (item 1 of argv) then
          set active tab index of w to i
          set index of w to 1
          activate
          return "front"
        end if
      end repeat
    end repeat
  end tell
end run""",
    "safari": """
on run argv
  tell application "{app}"
    repeat with w in windows
      repeat with t in tabs of w
        if name of t starts with (item 1 of argv) then
          set current tab of w to t
          set index of w to 1
          activate
          return "front"
        end if
      end repeat
    end repeat
  end tell
end run""",
}
# Any other app (e.g. Firefox): match window titles through System Events. That
# only sees each window's active tab, and needs the Accessibility permission the
# agent already has.
_MAC_FIND_WINDOW = """
on run argv
  tell application "System Events"
    repeat with p in (processes whose background only is false)
      try
        repeat with w in windows of p
          if name of w starts with (item 1 of argv) then
            perform action "AXRaise" of w
            set frontmost of p to true
            return "front"
          end if
        end repeat
      end try
    end repeat
  end tell
end run"""


def _osascript(script: str, *args: str) -> bool:
    # Arguments go in as argv, never spliced into the script.
    r = subprocess.run(["osascript", "-e", script, *args], capture_output=True, text=True, timeout=15)
    return r.stdout.strip() == "front"


def _front_macos(title_prefix: str) -> bool:
    for app, kind in _MAC_TAB_BROWSERS.items():
        # Only ask running browsers: telling an app that isn't running launches it.
        running = subprocess.run(["pgrep", "-x", app], capture_output=True).returncode == 0
        if running and _osascript(_MAC_FIND_TAB[kind].replace("{app}", app), title_prefix):
            return True
    return _osascript(_MAC_FIND_WINDOW, title_prefix)


def front_view():
    """What's in front right now (window, or browser tab on macOS), so it can be
    put back with `restore_view` after a pause. None when it can't be told."""
    try:
        if PLATFORM == "windows":
            return _win32()[0].GetForegroundWindow() or None
        if PLATFORM == "macos":
            return _front_view_macos()
    except (OSError, subprocess.SubprocessError):
        pass
    return None


def restore_view(view) -> bool:
    """Put back what `front_view` saw: after the user answers in the dashboard,
    the agent should be looking at its own app again, not the dashboard."""
    if view is None:
        return False
    try:
        if PLATFORM == "windows":
            return _focus_hwnd(view)
        if PLATFORM == "macos":
            return _restore_view_macos(view)
    except (OSError, subprocess.SubprocessError):
        pass
    return False


_MAC_FRONT_APP = """
tell application "System Events"
  set p to first application process whose frontmost is true
  return (bundle identifier of p) & linefeed & (name of p)
end tell"""
_MAC_FRONT_TAB = {
    "chromium": 'tell application "{app}" to return (id of front window as text) & linefeed & (active tab index of front window as text)',
    "safari": 'tell application "{app}" to return (id of front window as text) & linefeed & (index of current tab of front window as text)',
}
_MAC_RESTORE_TAB = {
    "chromium": """
on run argv
  tell application "{app}"
    set w to window id ((item 1 of argv) as integer)
    set active tab index of w to ((item 2 of argv) as integer)
    set index of w to 1
    activate
  end tell
  return "front"
end run""",
    "safari": """
on run argv
  tell application "{app}"
    set w to window id ((item 1 of argv) as integer)
    set current tab of w to tab ((item 2 of argv) as integer) of w
    set index of w to 1
    activate
  end tell
  return "front"
end run""",
}
_MAC_ACTIVATE = """
on run argv
  tell application id (item 1 of argv) to activate
  return "front"
end run"""


def _front_view_macos() -> dict | None:
    r = subprocess.run(["osascript", "-e", _MAC_FRONT_APP], capture_output=True, text=True, timeout=15)
    bundle_id, _, app = r.stdout.strip().partition("\n")
    if not bundle_id:
        return None
    view = {"bundle_id": bundle_id, "app": app}
    kind = _MAC_TAB_BROWSERS.get(app)
    if kind:  # a browser: remember the tab too, since the dashboard may share its window
        t = subprocess.run(["osascript", "-e", _MAC_FRONT_TAB[kind].replace("{app}", app)],
                           capture_output=True, text=True, timeout=15)
        window_id, _, tab = t.stdout.strip().partition("\n")
        if window_id and tab:
            view.update(kind=kind, window_id=window_id, tab=tab)
    return view


def _restore_view_macos(view: dict) -> bool:
    if "kind" in view and _osascript(_MAC_RESTORE_TAB[view["kind"]].replace("{app}", view["app"]),
                                     view["window_id"], view["tab"]):
        return True
    return _osascript(_MAC_ACTIVATE, view["bundle_id"])


def _win32():
    import ctypes
    from ctypes import wintypes

    user32, kernel32 = ctypes.windll.user32, ctypes.windll.kernel32
    user32.GetWindowTextLengthW.argtypes = [wintypes.HWND]
    user32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
    user32.IsWindow.argtypes = [wintypes.HWND]
    user32.IsWindowVisible.argtypes = [wintypes.HWND]
    user32.IsIconic.argtypes = [wintypes.HWND]
    user32.ShowWindow.argtypes = [wintypes.HWND, ctypes.c_int]
    user32.SetForegroundWindow.argtypes = [wintypes.HWND]
    user32.BringWindowToTop.argtypes = [wintypes.HWND]
    user32.GetForegroundWindow.restype = wintypes.HWND
    user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
    user32.GetWindowThreadProcessId.restype = wintypes.DWORD
    user32.AttachThreadInput.argtypes = [wintypes.DWORD, wintypes.DWORD, wintypes.BOOL]
    return user32, kernel32


def _focus_hwnd(hwnd) -> bool:
    user32, kernel32 = _win32()
    if not user32.IsWindow(hwnd):
        return False
    if user32.IsIconic(hwnd):
        user32.ShowWindow(hwnd, 9)  # SW_RESTORE
    # Windows lets only the foreground thread hand off focus: borrow its input
    # queue for the switch, then give it back.
    fg_thread = user32.GetWindowThreadProcessId(user32.GetForegroundWindow(), None)
    me = kernel32.GetCurrentThreadId()
    attached = fg_thread and fg_thread != me and user32.AttachThreadInput(me, fg_thread, True)
    try:
        user32.BringWindowToTop(hwnd)
        user32.SetForegroundWindow(hwnd)
    finally:
        if attached:
            user32.AttachThreadInput(me, fg_thread, False)
    return user32.GetForegroundWindow() == hwnd


def _front_windows(title_prefix: str) -> bool:
    import ctypes
    from ctypes import wintypes

    user32, _ = _win32()
    found: list[int] = []

    @ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def visit(hwnd, _):
        if user32.IsWindowVisible(hwnd):
            n = user32.GetWindowTextLengthW(hwnd)
            buf = ctypes.create_unicode_buffer(n + 1)
            user32.GetWindowTextW(hwnd, buf, n + 1)
            if buf.value.startswith(title_prefix):
                found.append(hwnd)
                return False  # stop: windows enumerate top-most first
        return True

    user32.EnumWindows(visit, 0)
    return bool(found) and _focus_hwnd(found[0])


def extend_in_terminal(used: int) -> int:
    """Out of steps on the CLI: ask how many more to allow (0 or Enter stops)."""
    answer = input(f"\nOut of steps after {used}. How many more? (Enter to stop) > ").strip()
    return int(answer) if answer.isdigit() else 0


def ask_in_terminal(question: str, options: list[str]) -> str:
    """ask_user from the CLI: pick a numbered option or type an answer."""
    print(f"\n? {question}")
    for i, option in enumerate(options, 1):
        print(f"  {i}. {option}")
    answer = input("> ").strip()
    if answer.isdigit() and 1 <= int(answer) <= len(options):
        return options[int(answer) - 1]
    return answer


def add_model_flags(p: argparse.ArgumentParser) -> None:
    p.add_argument("--provider", choices=["lmstudio", "claude"], default="lmstudio",
                   help="lmstudio (default): a local open-source VLM; claude: Claude Sonnet (or --model for Opus)")
    p.add_argument("--model", help="model id, e.g. qwen3-vl-4b-instruct (default), claude-sonnet-5-5 or claude-opus-5-5")
    p.add_argument("--base-url", help="LM Studio server URL (default http://127.0.0.1:1235/v1)")


def model_kwargs(args) -> dict:
    kw = {"provider": args.provider, "platform": PLATFORM}
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
        outcome = b.run_task(
            args.goal, look, act, ask=ask_in_terminal, extend=extend_in_terminal,
            max_steps=args.max_steps, **model_kwargs(args)
        )
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

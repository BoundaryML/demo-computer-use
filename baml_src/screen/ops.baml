// The contract between the BAML brain and the Python hands.
//
// Python sends a `Screenshot` in and gets `Op`s back. Ops are dumb, already in
// logical screen points, with keys already normalized: the host executes them
// verbatim, with no coordinate math or key aliasing of its own.

// Screenshots are downscaled to this width before the model sees them.
// ~1280px is where vision models click most accurately.
const SHOT_MAX_WIDTH = 1280;

class Point {
    x: int,
    y: int,
}

class Screenshot {
    path: string,
    // Pixel size of the image the model sees.
    width: int,
    height: int,
    // Logical size of the real screen, which ops are expressed in.
    screen_width: int,
    screen_height: int,

    function image(self) -> image throws baml.errors.Io | baml.errors.InvalidArgument {
        image.from_file(self.path, "image/png")
    }

    // Maps a pixel in this screenshot to a screen point, clamped on-screen.
    function to_screen(self, x: int, y: int) -> Point {
        let sx = x * 1.0 * self.screen_width / self.width;
        let sy = y * 1.0 * self.screen_height / self.height;
        Point { x: clamp(sx, 0, self.screen_width - 1), y: clamp(sy, 0, self.screen_height - 1) }
    }
}

function clamp(v: float, lo: int, hi: int) -> int {
    let i = v.iround() catch (e) {
        baml.errors.InvalidArgument => lo
    };
    match (i) {
        let n if n < lo => lo,
        let n if n > hi => hi,
        let n => n,
    }
}

class ClickOp {
    op: "click",
    x: int,
    y: int,
    button: "left" | "right" | "middle",
    count: int,
}

class MoveOp {
    op: "move",
    x: int,
    y: int,
}

class DragOp {
    op: "drag",
    from_x: int,
    from_y: int,
    to_x: int,
    to_y: int,
}

class TypeOp {
    op: "type",
    text: string,
}

// A chord: every key held together, e.g. ["command", "l"].
class KeyOp {
    op: "key",
    keys: string[],
}

// Positive dy scrolls up, positive dx scrolls right.
class ScrollOp {
    op: "scroll",
    x: int,
    y: int,
    dx: int,
    dy: int,
}

// Arguments for macOS `open`.
class OpenOp {
    op: "open",
    args: string[],
}

class SleepOp {
    op: "sleep",
    seconds: float,
}

type Op = ClickOp | MoveOp | DragOp | TypeOp | KeyOp | ScrollOp | OpenOp | SleepOp;

// Model-friendly key names -> pyautogui key names.
const KEY_ALIASES: map<string, string> = {
    "cmd": "command",
    "meta": "command",
    "super": "command",
    "win": "command",
    "opt": "option",
    "alt": "option",
    "control": "ctrl",
    "return": "enter",
    "esc": "escape",
    "del": "delete",
    "arrowup": "up",
    "arrowdown": "down",
    "arrowleft": "left",
    "arrowright": "right",
    "page_up": "pageup",
    "page_down": "pagedown",
    "spacebar": "space",
};

// "Cmd + Shift+T" -> ["command", "shift", "t"]
function chord(keys: string) -> KeyOp {
    let parts = keys.split("+")
        .map((k) -> {
            k.trim().to_lower_case()
        })
        .filter((k) -> {
            k.length() > 0
        })
        .map((k) -> {
            KEY_ALIASES.get(k) ?? k
        });
    KeyOp { op: "key", keys: parts }
}

test "to_screen scales screenshot pixels to screen points and clamps" {
    let shot = Screenshot { path: "x.png", width: 1280, height: 720, screen_width: 1920, screen_height: 1080 };
    assert.equal(shot.to_screen(640, 360), Point { x: 960, y: 540 });
    assert.equal(shot.to_screen(1279, 719), Point { x: 1919, y: 1079 });
    assert.equal(shot.to_screen(5000, -10), Point { x: 1919, y: 0 })
}

test "chord normalizes aliases, case, and spacing" {
    assert.equal(chord("Cmd + Shift+T").keys, ["command", "shift", "t"]);
    assert.equal(chord("enter").keys, ["enter"]);
    assert.equal(chord("ctrl+alt+del").keys, ["ctrl", "option", "delete"])
}

// What differs by operating system: key names, the primary shortcut
// modifier, and how apps and URLs are opened. The host tells BAML which OS it
// runs on; actions compile to that OS's ops, so the host stays OS-agnostic
// apart from the primitives themselves.

type Platform = "macos" | "windows" | "linux";

// Pauses inside launch sequences, while a launcher or dialog opens.
const LAUNCHER_SETTLE_SECONDS = 0.8;

// Key names the model might use -> pyautogui names, the same on every OS.
const COMMON_KEYS: map<string, string> = {
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

const MAC_KEYS: map<string, string> = {
    "cmd": "command",
    "meta": "command",
    "super": "command",
    "win": "command",
    "windows": "command",
    "opt": "option",
    "alt": "option",
};

// Elsewhere a "cmd" shortcut means the primary modifier, Ctrl (cmd+l -> ctrl+l).
const WINDOWS_KEYS: map<string, string> = {
    "cmd": "ctrl",
    "command": "ctrl",
    "meta": "win",
    "super": "win",
    "windows": "win",
    "opt": "alt",
    "option": "alt",
};

const LINUX_KEYS: map<string, string> = {
    "cmd": "ctrl",
    "command": "ctrl",
    "meta": "winleft",
    "super": "winleft",
    "win": "winleft",
    "windows": "winleft",
    "opt": "alt",
    "option": "alt",
};

class Os {
    platform: Platform,

    function label(self) -> string {
        match (self.platform) {
            "macos" => "macOS",
            "windows" => "Windows",
            "linux" => "Linux",
        }
    }

    // The modifier for everyday shortcuts (copy, address bar, new tab).
    function primary(self) -> string {
        match (self.platform) {
            "macos" => "cmd",
            "windows" | "linux" => "ctrl",
        }
    }

    function key_name(self, key: string) -> string {
        let os_keys = match (self.platform) {
            "macos" => MAC_KEYS,
            "windows" => WINDOWS_KEYS,
            "linux" => LINUX_KEYS,
        };
        os_keys.get(key) ?? COMMON_KEYS.get(key) ?? key
    }

    // "Cmd + Shift+T" -> ["command", "shift", "t"] on macOS, ["ctrl", "shift", "t"] elsewhere.
    function chord(self, keys: string) -> KeyOp {
        let parts = keys
            .split("+")
            .map((k) -> { k.trim().to_lower_case() })
            .filter((k) -> { k.length() > 0 })
            .map((k) -> { self.key_name(k) });
        KeyOp { op: "key", keys: parts }
    }

    function open_app(self, name: string) -> Op[] {
        match (self.platform) {
            "macos" => [OpenOp { op: "open", args: ["-a", name] }],
            // Start menu / Activities search: open it, type the name, launch the top hit.
            "windows" | "linux" => self.launcher(name),
        }
    }

    function open_url(self, url: string) -> Op[] {
        match (self.platform) {
            "macos" => [OpenOp { op: "open", args: [url] }],
            // The Run dialog opens a URL in the default browser.
            "windows" => [
                self.chord("win+r"),
                SleepOp { op: "sleep", seconds: LAUNCHER_SETTLE_SECONDS },
                TypeOp { op: "type", text: url },
                self.chord("enter"),
            ],
            "linux" => [LaunchOp { op: "launch", argv: ["xdg-open", url] }],
        }
    }

    function launcher(self, query: string) -> Op[] {
        [
            self.chord("super"),
            SleepOp { op: "sleep", seconds: LAUNCHER_SETTLE_SECONDS },
            TypeOp { op: "type", text: query },
            SleepOp { op: "sleep", seconds: LAUNCHER_SETTLE_SECONDS },
            self.chord("enter"),
        ]
    }
}

test "chords map to each OS's key names" {
    let mac = Os { platform: "macos" };
    let win = Os { platform: "windows" };
    assert.equal(mac.chord("Cmd + Shift+T").keys, ["command", "shift", "t"]);
    assert.equal(win.chord("Cmd + Shift+T").keys, ["ctrl", "shift", "t"]);
    assert.equal(win.chord("win+r").keys, ["win", "r"]);
    assert.equal(mac.chord("ctrl+alt+del").keys, ["ctrl", "option", "delete"]);
    assert.equal(win.chord("ctrl+alt+del").keys, ["ctrl", "alt", "delete"]);
    assert.equal(Os { platform: "linux" }.chord("super").keys, ["winleft"])
}

test "apps and URLs open the native way on each OS" {
    let mac = Os { platform: "macos" };
    let win = Os { platform: "windows" };
    assert.equal(mac.open_app("Notes"), [OpenOp { op: "open", args: ["-a", "Notes"] }]);
    let launch = win.open_app("Notepad");
    assert.equal(launch[0], KeyOp { op: "key", keys: ["win"] });
    assert.equal(launch[2], TypeOp { op: "type", text: "Notepad" });
    assert.equal(win.open_url("https://example.com")[0], KeyOp { op: "key", keys: ["win", "r"] });
    assert.equal(Os { platform: "linux" }.open_url("https://example.com"), [LaunchOp { op: "launch", argv: ["xdg-open", "https://example.com"] }])
}

// The agent's action space: what the model may choose each turn. The
// `action` literal is the discriminator the model writes. Coordinates are
// pixels in the screenshot the model was shown; `Command.ops` compiles each
// action to screen-space `Op`s for the Python host to run.
//
// Design notes:
// - Pointer actions carry `target`, a name for what's under the pointer. It
//   makes the model commit to an element before picking a pixel (better
//   grounding), and it makes traces readable.
// - OpenApp / OpenUrl skip the most error-prone part of computer use (finding
//   and clicking icons) by going through the OS launcher (platform.baml).
// - Done / GiveUp end the run and compile to nothing.

const MAX_WAIT_SECONDS = 10;
const MAX_SCROLL = 15;

interface Command {
    function ops(self, shot: Screenshot, os: Os) -> Op[] throws never;
}

class Click {
    action: "click",
    target: string @description("The element being clicked, e.g. 'Safari address bar'"),
    x: int,
    y: int,
    button: "left" | "right" | "middle",

    implements Command {
        function ops(self, shot: Screenshot, os: Os) -> Op[] {
            let p = shot.to_screen(self.x, self.y);
            [ClickOp { op: "click", x: p.x, y: p.y, button: self.button, count: 1 }]
        }
    }

    implements baml.ToString {
        function to_string(self) -> string {
            `${self.button} click "${self.target}" at (${self.x}, ${self.y})`
        }
    }
}

class DoubleClick {
    action: "double_click",
    target: string,
    x: int,
    y: int,

    implements Command {
        function ops(self, shot: Screenshot, os: Os) -> Op[] {
            let p = shot.to_screen(self.x, self.y);
            [ClickOp { op: "click", x: p.x, y: p.y, button: "left", count: 2 }]
        }
    }

    implements baml.ToString {
        function to_string(self) -> string {
            `double click "${self.target}" at (${self.x}, ${self.y})`
        }
    }
}

class TypeText {
    action: "type",
    text: string @description(
        "Typed into whatever has keyboard focus. Click the field first if it isn't focused.",
    ),
    press_enter: bool @description("Press Enter after typing"),

    implements Command {
        function ops(self, shot: Screenshot, os: Os) -> Op[] {
            let typed: Op[] = [TypeOp { op: "type", text: self.text }];
            if (self.press_enter) {
                typed.push(os.chord("enter"));
            }
            typed
        }
    }

    implements baml.ToString {
        function to_string(self) -> string {
            let enter = if (self.press_enter) {
                " + enter"
            } else {
                ""
            };
            `type "${self.text}"${enter}`
        }
    }
}

class PressKeys {
    action: "key",
    keys: string @description(
        "A key or chord joined with '+', e.g. 'enter', 'escape', 'tab', 'down', 'cmd+l' (macOS) or 'ctrl+l' (Windows/Linux)",
    ),

    implements Command {
        function ops(self, shot: Screenshot, os: Os) -> Op[] {
            [os.chord(self.keys)]
        }
    }

    implements baml.ToString {
        function to_string(self) -> string {
            `press ${self.keys}`
        }
    }
}

class Scroll {
    action: "scroll",
    x: int @description("Pointer position: scrolling applies to the pane under it"),
    y: int,
    direction: "up" | "down" | "left" | "right",
    amount: int @description("Scroll clicks, 1-15. ~5 is about half a page"),

    implements Command {
        function ops(self, shot: Screenshot, os: Os) -> Op[] {
            let p = shot.to_screen(self.x, self.y);
            let n = clamp(self.amount * 1.0, 1, MAX_SCROLL);
            let d = match (self.direction) {
                "up" => Point { x: 0, y: n },
                "down" => Point { x: 0, y: 0 - n },
                "left" => Point { x: 0 - n, y: 0 },
                "right" => Point { x: n, y: 0 },
            };
            [ScrollOp { op: "scroll", x: p.x, y: p.y, dx: d.x, dy: d.y }]
        }
    }

    implements baml.ToString {
        function to_string(self) -> string {
            `scroll ${self.direction} ${self.amount} at (${self.x}, ${self.y})`
        }
    }
}

class Drag {
    action: "drag",
    target: string,
    from_x: int,
    from_y: int,
    to_x: int,
    to_y: int,

    implements Command {
        function ops(self, shot: Screenshot, os: Os) -> Op[] {
            let a = shot.to_screen(self.from_x, self.from_y);
            let b = shot.to_screen(self.to_x, self.to_y);
            [DragOp { op: "drag", from_x: a.x, from_y: a.y, to_x: b.x, to_y: b.y }]
        }
    }

    implements baml.ToString {
        function to_string(self) -> string {
            `drag "${self.target}" (${self.from_x}, ${self.from_y}) -> (${self.to_x}, ${self.to_y})`
        }
    }
}

class Hover {
    action: "hover",
    target: string,
    x: int,
    y: int,

    implements Command {
        function ops(self, shot: Screenshot, os: Os) -> Op[] {
            let p = shot.to_screen(self.x, self.y);
            [MoveOp { op: "move", x: p.x, y: p.y }]
        }
    }

    implements baml.ToString {
        function to_string(self) -> string {
            `hover "${self.target}" at (${self.x}, ${self.y})`
        }
    }
}

class OpenApp {
    action: "open_app",
    name: string @description("App name as the OS shows it, e.g. 'Safari', 'Notes' (macOS); 'Notepad', 'Microsoft Edge' (Windows)"),

    implements Command {
        function ops(self, shot: Screenshot, os: Os) -> Op[] {
            os.open_app(self.name)
        }
    }

    implements baml.ToString {
        function to_string(self) -> string {
            `open app ${self.name}`
        }
    }
}

class OpenUrl {
    action: "open_url",
    url: string @description("Opens in the default browser"),

    implements Command {
        function ops(self, shot: Screenshot, os: Os) -> Op[] {
            os.open_url(self.url)
        }
    }

    implements baml.ToString {
        function to_string(self) -> string {
            `open ${self.url}`
        }
    }
}

class Wait {
    action: "wait",
    seconds: int @description("1-10. Use while something loads"),

    implements Command {
        function ops(self, shot: Screenshot, os: Os) -> Op[] {
            [SleepOp { op: "sleep", seconds: clamp(self.seconds * 1.0, 1, MAX_WAIT_SECONDS) * 1.0 }]
        }
    }

    implements baml.ToString {
        function to_string(self) -> string {
            `wait ${self.seconds}s`
        }
    }
}

class Done {
    action: "done",
    summary: string @description("What was accomplished, and the answer if the goal asked a question"),

    implements baml.ToString {
        function to_string(self) -> string {
            `done: ${self.summary}`
        }
    }
}

class GiveUp {
    action: "give_up",
    reason: string @description(
        "Why the goal can't be finished: blocked by login, captcha, missing info, needs a human decision, ...",
    ),

    implements baml.ToString {
        function to_string(self) -> string {
            `give up: ${self.reason}`
        }
    }
}

type Move = Click
    | DoubleClick
    | TypeText
    | PressKeys
    | Scroll
    | Drag
    | Hover
    | OpenApp
    | OpenUrl
    | Wait;

type Action = Move | Done | GiveUp;

test "actions compile to screen-space ops" {
    let shot = Screenshot { path: "x.png", width: 1280, height: 720, screen_width: 1920, screen_height: 1080 };
    let click = Click { action: "click", target: "OK", x: 100, y: 100, button: "left" };
    assert.equal(
        click.ops(shot, Os { platform: "macos" }),
        [ClickOp { op: "click", x: 150, y: 150, button: "left", count: 1 }],
    );
    let typed = TypeText { action: "type", text: "hi", press_enter: true };
    assert.equal(typed.ops(shot, Os { platform: "windows" }).length(), 2);
    let down = Scroll { action: "scroll", x: 0, y: 0, direction: "down", amount: 99 };
    assert.equal(down.ops(shot, Os { platform: "macos" }), [ScrollOp { op: "scroll", x: 0, y: 0, dx: 0, dy: 0 - MAX_SCROLL }])
}

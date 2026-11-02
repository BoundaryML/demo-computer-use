// The agent loop. Python hands BAML two callables, its eyes and hands:
//
//     outcome = run_task(goal, look, act)
//
//   look(path) -> Screenshot   save a screenshot to `path` and describe it
//   act(op)                    perform one screen-space op
//
// Everything else happens here: deciding, history, loop detection, and
// compiling actions to ops. One run is one call, so the trace is one tree:
// run_loop > turn > Decide, with the host's look/act spans nested inside.

const DEFAULT_MAX_STEPS = 30;
// Steps shown to the model in full; older ones collapse to a count.
const HISTORY_WINDOW = 15;
// The same action this many times in a row counts as stuck.
const REPEAT_LIMIT = 3;
// Actions examined for back-and-forth loops (A B A B ...).
const CYCLE_WINDOW = 6;
const CYCLE_REPEATS = 3;
// Most notes kept for the model; older ones drop off.
const MAX_NOTES = 20;
// Consecutive replies that don't fit the schema before the run gives up.
const MAX_BAD_REPLIES = 3;
const BAD_REPLY_HINT = "Your last reply didn't match the required JSON. Use only the listed values: verdict is one of succeeded, failed, unclear, first_step; action.action is one of click, double_click, type, key, scroll, drag, hover, open_app, open_url, wait, done, give_up.";
// Lets the UI settle after acting, before the next screenshot.
const SETTLE_SECONDS = 0.8;
// Host exception classes that stop the run instead of being reported to the
// model: the pyautogui failsafe (mouse slammed into a corner) and a cancel.
const HOST_ABORTS = ["FailSafeException", "RunCancelled"];

class StepRecord {
    index: int,
    screenshot: string,
    decision: Decision,
    ops: Op[],
    // Filled in on the next turn: did this step's action work?
    verdict: "succeeded" | "failed" | "unclear" | "pending",
    // The host's error executing ops, if any.
    error: string?,

    implements baml.ToString {
        function to_string(self) -> string {
            let e = self.error;
            let err = if (e) {
                ` | EXECUTION ERROR: ${e}`
            } else {
                ""
            };
            `#${self.index} ${self.decision.action} | expected: ${self.decision.expectation} | result: ${self.verdict}${err}`
        }
    }
}

class Run {
    id: string,
    goal: string,
    dir: string,
    max_steps: int,
    pilot: Pilot,
    os: Os,
    steps: StepRecord[],
    // Facts the model chose to remember (Decision.remember), oldest first.
    notes: string[],

    function remember(self, facts: string[]) -> void {
        for (let f in facts) {
            let fact = f.trim();
            if (fact && !self.notes.includes(fact)) {
                self.notes.push(fact);
            }
        }
        if (self.notes.length() > MAX_NOTES) {
            self.notes = self.notes.slice(self.notes.length() - MAX_NOTES, self.notes.length());
        }
    }

    function history(self) -> string {
        let n = self.steps.length();
        if (n == 0) {
            return "(none yet)";
        }
        let start = if (n > HISTORY_WINDOW) {
            n - HISTORY_WINDOW
        } else {
            0
        };
        let shown = self.steps.slice(start, n).map((s) -> {
            s.to_string()
        });
        let omitted: string[] = if (start > 0) {
            [`(${start} earlier steps omitted)`]
        } else {
            []
        };
        omitted.concat(shown).join("\n")
    }

    // Nudges for the model when the loop looks unhealthy.
    function warnings(self) -> string[] {
        let out: string[] = [];
        let recent = self.steps.slice(self.steps.length() - REPEAT_LIMIT, self.steps.length());
        let repeated = recent.length() == REPEAT_LIMIT
            && recent.every((s) -> {
                s.decision.action.to_string() == recent[0].decision.action.to_string()
            });
        if (repeated) {
            out.push(
                `You've repeated "${recent[0].decision.action}" ${REPEAT_LIMIT} times. It isn't working; do something different.`,
            );
        }
        let failing = recent.length() == REPEAT_LIMIT
            && recent.every((s) -> {
                s.verdict == "failed" || s.error != null
            });
        if (failing) {
            out.push(
                "The last several actions failed. Step back: re-read the screen, and consider a different approach or give_up.",
            );
        }
        if (self.oscillating()) {
            out.push(
                "You're going back and forth between the same few actions without progress. Stop switching: use your NOTES (save what you need with remember), then take a different route or give_up.",
            );
        }
        let left = self.max_steps - self.steps.length();
        if (left <= 3) {
            out.push(`Only ${left} step(s) left. Finish, or give_up with what you learned.`);
        }
        out
    }

    // True when one action keeps coming back within the last CYCLE_WINDOW
    // steps, e.g. "open app Messages" every other turn while the turns in
    // between vary. The same-action-in-a-row check can't see that loop.
    function oscillating(self) -> bool {
        let n = self.steps.length();
        if (n < CYCLE_WINDOW) {
            return false;
        }
        let actions = self.steps.slice(n - CYCLE_WINDOW, n).map((s) -> { s.decision.action.to_string() });
        actions.some((a) -> {
            actions.filter((b) -> { b == a }).length() >= CYCLE_REPEATS
        })
    }

    // Records the previous step's outcome now that we can see its effect.
    function close_last(
        self,
        verdict: "succeeded" | "failed" | "unclear" | "first_step",
        error: string?,
    ) -> void {
        let last = self.steps.at(self.steps.length() - 1);
        if (!last) {
            return;
        }
        last.error = error;
        last.verdict
            = match (verdict) {
                "first_step" => "unclear",
                let v => v,
            };
    }
}

class Act {
    kind: "act",
    step: int,
    ops: Op[],
}

class Outcome {
    kind: "finished",
    run_id: string,
    goal: string,
    status: "done" | "gave_up" | "out_of_steps",
    summary: string,
    steps: StepRecord[],
}

// ---- Public API (called from Python) ----

function run_task(
    goal: string,
    look: (path: string) -> Screenshot,
    act: (op: Op) -> void throws baml.errors.HostCallable,
    max_steps: int = DEFAULT_MAX_STEPS,
    runs_dir: string = "runs",
    run_id: string? = null,
    provider: Provider = "lmstudio",
    model: string? = null,
    base_url: string? = null,
    platform: Platform = "macos",
) -> Outcome {
    let id = run_id ?? new_run_id();
    let pilot = Pilot.new(provider = provider, model = model, base_url = base_url);
    let run = Run {
        id: id,
        goal: goal,
        dir: `${runs_dir}/${id}`,
        max_steps: max_steps,
        pilot: pilot,
        os: Os { platform: platform },
        steps: [],
        notes: [],
    };
    baml.fs.mkdir(run.dir, baml.fs.MkdirOptions { recursive: true });
    log.info(`[${id}] goal: ${goal} (model ${pilot.label()})`);
    run_loop(
        run,
        look,
        act,
        $trace = trace.span(inputs = false).context(metadata = { "run_id": id, "goal": goal, "model": pilot.label(), "platform": platform }),
    )
}

function new_run_id() -> string {
    `run-${baml.time.Instant.now().to_timestamp_milliseconds()}`
}

// ---- The loop ----

function run_loop(
    run: Run,
    look: (path: string) -> Screenshot,
    act: (op: Op) -> void throws baml.errors.HostCallable,
) -> Outcome {
    let last_error: string? = null;
    let bad_replies = 0;
    while (true) {
        let index = run.steps.length() + 1;
        //# Look
        let shot = look(`${run.dir}/step-${index}.png`, $trace = trace.context(metadata = { "step": index }));
        //# Decide. A reply that doesn't fit the schema (small local models
        //# invent action names) is fed back as an error, not a crash.
        let next = turn(
            run,
            shot,
            last_error,
            $trace = trace.span(output = true).context(metadata = { "step": index }),
        ) catch (e) {
            let p: ai.errors.ParseFailed => {
                bad_replies += 1;
                if (bad_replies >= MAX_BAD_REPLIES) {
                    throw p
                }
                last_error = BAD_REPLY_HINT;
                continue;
            }
        };
        bad_replies = 0;
        //# Act, or stop
        match (next) {
            let done: Outcome => {
                return done;
            },
            let a: Act => {
                last_error
                    = perform(
                        a,
                        act,
                        $trace = trace.span(inputs = true).context(metadata = { "step": index }),
                    );
            },
        }
    }
}

function turn(run: Run, shot: Screenshot, last_error: string?) -> Act | Outcome {
    //# Out of budget: stop before spending another model call
    if (run.steps.length() >= run.max_steps) {
        run.close_last("unclear", last_error);
        return outcome(run, "out_of_steps", `Stopped after ${run.max_steps} steps without finishing.`);
    }
    //# Look at the screen and decide
    let index = run.steps.length() + 1;
    let view = run.pilot.view(shot);
    let decision = Decide@spec(
        run.goal,
        run.history(),
        run.notes,
        run.warnings().concat(
            if (last_error) {
                [`The last action failed to execute: ${last_error}`]
            } else {
                []
            },
        ),
        shot.image(),
        view.width,
        view.height,
        run.pilot.coords,
        run.os.platform,
    ).call(client = run.pilot.client);
    run.close_last(decision.verdict, last_error);
    run.remember(decision.remember ?? []);
    log.info(`[${run.id}] #${index} ${decision.action}`);
    //# Compile the action to ops, or finish
    let action = decision.action;
    let ops: Op[] = match (action) {
        let m: Move => compile(m, view, run.os),
        _ => [],
    };
    run.steps.push(
        StepRecord {
            index: index,
            screenshot: shot.path,
            decision: decision,
            ops: ops,
            verdict: "pending",
            error: null,
        },
    );
    match (action) {
        let d: Done => outcome(run, "done", d.summary),
        let g: GiveUp => outcome(run, "gave_up", g.reason),
        _ => {
            Act {
                kind: "act",
                step: index,
                ops: ops.concat([SleepOp { op: "sleep", seconds: SETTLE_SECONDS }]),
            }
        },
    }
}

// Runs one step's ops through the host. A failing op stops the rest; its
// error goes back to the model next turn instead of crashing the run.
function perform(a: Act, act: (op: Op) -> void throws baml.errors.HostCallable) -> string? {
    for (let op in a.ops) {
        act(op) catch (e) {
            let h: baml.errors.HostCallable => {
                // The host's kill switch (mouse slammed into a corner): stop, don't recover.
                if (HOST_ABORTS.includes(h.class_name)) {
                    throw h
                }
                return `${h.class_name}: ${h.message}`;
            }
        };
    }
    null
}

function compile(m: Move, shot: Screenshot, os: Os) -> Op[] {
    let c: Command = m;
    c.ops(shot, os)
}

function outcome(
    run: Run,
    status: "done" | "gave_up" | "out_of_steps",
    summary: string,
) -> Outcome {
    log.info(`[${run.id}] ${status}: ${summary}`);
    Outcome {
        kind: "finished",
        run_id: run.id,
        goal: run.goal,
        status: status,
        summary: summary,
        steps: run.steps,
    }
}

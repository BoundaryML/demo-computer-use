// Offline tests for the loop's bookkeeping and the decision schema: no model calls.

function sample_decision(
    action: Action,
    verdict: "succeeded" | "failed" | "unclear" | "first_step",
) -> Decision {
    Decision {
        observation: "screen",
        verdict: verdict,
        candidates: [],
        remember: [],
        plan: "plan",
        action: action,
        expectation: "something happens",
    }
}

function sample_step(
    index: int,
    action: Action,
    verdict: "succeeded" | "failed" | "unclear" | "pending",
) -> StepRecord {
    StepRecord {
        index: index,
        screenshot: `step-${index}.png`,
        decision: sample_decision(action, "unclear"),
        ops: [],
        verdict: verdict,
        error: null,
    }
}

function sample_run(steps: StepRecord[], max_steps: int) -> Run {
    Run { id: "run-test", goal: "test", dir: "runs/run-test", max_steps: max_steps, pilot: Pilot.new(), os: Os { platform: "macos" }, steps: steps, notes: [] }
}

test "a reply with candidates and a union action parses into a Decision" {
    let shot = image.from_base64("aaa", "image/png");
    let d = Decide@spec("goal", "", [], [], [], [], "", shot, 1, 1280, 720, "pixels", "macos").parse(
        `
            {
                    "observation": "Safari is open",
                    "verdict": "first_step",
                    "candidates": [
                        {"label": "Address bar", "x": 640, "y": 52, "reason": "type the URL", "chosen": true},
                        {"label": "press cmd+l", "x": null, "y": null, "reason": "same, by keyboard", "chosen": false}
                    ],
                    "remember": [],
        "plan": "go to the site",
                    "action": {"action": "click", "target": "Address bar", "x": 640, "y": 52, "button": "left"},
                    "expectation": "address bar focused"
                }
        `,
    );
    assert.is_type<Click>(d.action);
    assert.equal(d.candidates.length(), 2);
    assert.equal(d.candidates[1].x, null)
}

test "repeating the same action trips the stuck warning" {
    let key = PressKeys { action: "key", keys: "enter" };
    let run = sample_run(
        [
            sample_step(1, key, "unclear"),
            sample_step(2, key, "unclear"),
            sample_step(3, key, "unclear"),
        ],
        30,
    );
    assert.is_true(
        run.warnings().some((w) -> {
            w.includes("repeated")
        }),
    )
}

test "consecutive failures trip the step-back warning" {
    let a = PressKeys { action: "key", keys: "a" };
    let b = PressKeys { action: "key", keys: "b" };
    let run = sample_run([sample_step(1, a, "failed"), sample_step(2, b, "failed"), sample_step(3, a, "failed")], 30);
    let w = run.warnings();
    assert.is_true(
        w.some((x) -> {
            x.includes("Step back")
        }),
    );
    assert.is_true(
        !w.some((x) -> {
            x.includes("repeated")
        }),
    )
}

test "a healthy run gets no warnings until the budget runs low" {
    let a = Wait { action: "wait", seconds: 1 };
    assert.equal(sample_run([sample_step(1, a, "succeeded")], 30).warnings(), []);
    assert.equal(sample_run([sample_step(1, a, "succeeded")], 3).warnings().length(), 1)
}

// Writes a stand-in screenshot so trajectory() can load step images.
function frame_steps(n: int) -> StepRecord[] {
    baml.fs.mkdir("runs/_test", baml.fs.MkdirOptions { recursive: true });
    let steps: StepRecord[] = [];
    let i = 0;
    while (i < n) {
        i += 1;
        let path = `runs/_test/step-${i}.png`;
        baml.fs.write(path, "png");
        let step = sample_step(i, Wait { action: "wait", seconds: i }, "succeeded");
        step.screenshot = path;
        steps.push(step);
    }
    steps
}

test "past steps replay as screenshots, oldest ones as text" {
    let run = sample_run(frame_steps(4), 30);
    run.pilot.frames = 2;
    let past = run.trajectory();
    assert.equal(past.map((p) -> { p.step }), [3, 4]);
    assert.contains(run.earlier(), "#1 wait 1s");
    assert.contains(run.earlier(), "#2 wait 2s");
    assert.is_true(!run.earlier().includes("#3"));
    assert.equal(sample_run(frame_steps(2), 30).earlier(), "")
}

test "an execution error shows up on the next replayed turn" {
    let steps = frame_steps(3);
    steps[1].error = "click failed";
    let run = sample_run(steps, 30);
    run.pilot.frames = 30;
    let past = run.trajectory();
    assert.equal(past[1].feedback, "");
    assert.contains(past[2].feedback, "click failed")
}

// The trajectory must be a stable prefix: rendering step N's request must
// start with exactly what step N-1's request sent, cache marker last.
test "the trajectory renders as cacheable conversation turns" {
    let claude = Pilot.new(provider = "claude");
    let run = sample_run(frame_steps(3), 30);
    run.pilot = claude;
    let shot = image.from_base64("aaa", "image/png");
    let body = Decide@spec("g", run.earlier(), run.trajectory(), [], ["use Slack"], [], "", shot, 4, 1280, 720, "pixels", "macos")
        .build_request(client = claude.client)
        .body
        .to_string();
    let msgs = baml.json.path<json[]>(baml.json.parse(body), ".messages");
    // 3 x (screenshot, decision) + current; the goal shares the first user turn
    assert.equal(msgs.length(), 7);
    assert.equal(baml.json.path<string>(msgs[5], ".role"), "assistant");
    assert.contains(baml.json.stringify(msgs[5]), "cache_control");
    assert.is_true(!baml.json.stringify(msgs[4]).includes("cache_control"));
    assert.contains(baml.json.stringify(msgs[6]), "MESSAGE FROM THE USER (follow it; it overrides your plan): use Slack")
}

test "ask_user parses, and without a human the model is told so" {
    let shot = image.from_base64("aaa", "image/png");
    let d = Decide@spec("message Bob hi", "", [], [], [], [], "", shot, 1, 1280, 720, "pixels", "macos").parse(`{
        "observation": "desktop", "verdict": "first_step", "candidates": [], "remember": [],
        "plan": "find out which app", "expectation": "an answer",
        "action": {"action": "ask_user", "question": "Which app should I use to message Bob?", "options": ["Messages", "Slack"]}
    }`);
    assert.is_type<AskUser>(d.action);
    let q = Ask { kind: "ask", step: 1, question: "Which app?", options: [] };
    assert.equal(consult(q, null), NO_ONE_TO_ASK);
    let answer = consult(q, (question, options) -> { " Slack " });
    assert.equal(answer, `You asked the user "Which app?" and they answered: Slack`)
}

test "close_last records the verdict and error on the previous step" {
    let run = sample_run([sample_step(1, Wait { action: "wait", seconds: 1 }, "pending")], 30);
    run.close_last("failed", "boom");
    assert.equal(run.steps[0].verdict, "failed");
    assert.equal(run.steps[0].error, "boom")
}

// Steps 13-18 of run-1793589007197: back to Messages every other turn,
// with a different Messenger click in between each time.
test "returning to the same app every other turn is caught as a loop" {
    let back: Action = OpenApp { action: "open_app", name: "Messages" };
    let between: Action[] = [
        Click { action: "click", target: "Messenger Search field", x: 330, y: 194, button: "left" },
        Click { action: "click", target: "Chunying Su", x: 318, y: 247, button: "left" },
        Click { action: "click", target: "Messenger message box", x: 850, y: 667, button: "left" },
    ];
    let steps = [0, 1, 2].flat_map((i) -> {
        [sample_step(2 * i + 1, back, "succeeded"), sample_step(2 * i + 2, between[i], "succeeded")]
    });
    let run = sample_run(steps, 30);
    assert.is_true(run.oscillating());
    assert.is_true(run.warnings().some((w) -> { w.includes("back and forth") }))
}

test "varied progress is not a loop" {
    let steps = [1, 2, 3, 4, 5, 6].map((i) -> {
        sample_step(i, Wait { action: "wait", seconds: i }, "succeeded")
    });
    assert.is_true(!sample_run(steps, 30).oscillating())
}

test "remembered facts persist, dedupe, and ignore blanks" {
    let run = sample_run([], 30);
    run.remember(["joke: Why don't scientists trust atoms?", " "]);
    run.remember(["joke: Why don't scientists trust atoms?", "contact: Chunying Su"]);
    assert.equal(run.notes, ["joke: Why don't scientists trust atoms?", "contact: Chunying Su"])
}

test "a reply cut off at the output limit is retried with a hint; refusals are not" {
    assert.equal(finish_hint(ai.content.StopReason.MaxTokens), CUT_OFF_HINT);
    assert.is_true(finish_hint(ai.content.StopReason.Refused) == null);
    assert.is_true(finish_hint(ai.content.StopReason.Failed) == null)
}

test "the cut-off hint reaches the model on the retry" {
    let claude = Pilot.new(provider = "claude");
    let shot = image.from_base64("aaa", "image/png");
    let body = Decide@spec("g", "", [], [], [], [CUT_OFF_HINT], "", shot, 1, 1280, 720, "pixels", "windows")
        .build_request(client = claude.client)
        .body
        .to_string();
    assert.contains(body, "Reply with exactly one JSON object and nothing after it.")
}

test "an extended step budget tells the model it has more steps and where to go back to" {
    let h = more_steps_hint(10, 30);
    assert.contains(h, "10 more steps (30 in total)");
    assert.contains(h, "switch back to the app you were working in")
}

test "the prompt says the dashboard comes back on its own" {
    let claude = Pilot.new(provider = "claude");
    let shot = image.from_base64("aaa", "image/png");
    let body = Decide@spec("g", "", [], [], [], [], "", shot, 1, 1280, 720, "pixels", "windows")
        .build_request(client = claude.client)
        .body
        .to_string();
    assert.contains(body, "Don't spend steps switching back to it")
}

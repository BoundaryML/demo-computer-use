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
    let d = Decide@spec("goal", "(none yet)", [], [], shot, 1280, 720, "pixels", "macos").parse(
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

test "history shows the newest steps and counts the rest" {
    let a = Wait { action: "wait", seconds: 1 };
    let steps: StepRecord[] = [];
    let i = 0;
    while (i < HISTORY_WINDOW + 2) {
        i += 1;
        steps.push(sample_step(i, a, "succeeded"));
    }
    let h = sample_run(steps, 50).history();
    assert.is_true(h.starts_with("(2 earlier steps omitted)"));
    assert.contains(h, `#${HISTORY_WINDOW + 2} wait 1s`)
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

// The query API: run history and live progress, built from `baml query` over
// the recorded traces. The server returns these classes as JSON.
//
// Liveness: a span reaches the cloud when it *finishes*, so a running
// `run_loop` is invisible until the end. Its finished steps aren't: each
// `Decide` carries the run's `run_id`/`goal` metadata. A run with steps but no
// finished `run_loop` is therefore still running, or its host died (stale).

const DEFAULT_RUN_LIMIT = 50;
// A run with no new step for this long, and no outcome, is presumed dead.
const STALE_AFTER_SECONDS = 300;

// ---- Rows (one class per query; columns map to fields by name) ----

class StepAggRow {
    run_id: string,
    goal: string?,
    model: string?,
    started: string,
    last_seen: string,
    steps: int,
    input_tokens: int?,
    output_tokens: int?,
}

class FinishRow {
    run_id: string,
    goal: string?,
    started: string,
    ended: string,
    duration_ns: int,
    span_status: string,
    outcome_status: string?,
    summary: string?,
    error_type: string?,
    error_message: string?,
}

class DecideRow {
    run_id: string,
    step: int,
    duration: int,
    status: string,
    decision: Decision?,
    warnings: string[]?,
    input_tokens: int?,
    output_tokens: int?,
    calls: int?,
    error_type: string?,
    grid_width: int?,
    grid_height: int?,
    user_messages: string[]?,
}

// An ask_user step: the note recorded from the human's answer.
class ConsultRow {
    run_id: string,
    step: int,
    duration: int,
    answer: string?,
}

class LookRow {
    run_id: string,
    step: int,
    duration: int,
    shot: Screenshot?,
}

class PerformRow {
    run_id: string,
    step: int,
    duration: int,
    ops: Op[]?,
    error: string?,
}

// ---- API types ----

type RunStatus = "running" | "stale" | "done" | "gave_up" | "out_of_steps" | "error";

class RunSummary {
    run_id: string,
    goal: string,
    // "provider:model"; null for runs recorded before model selection.
    model: string?,
    status: RunStatus,
    started: string,
    last_seen: string,
    duration_ns: int?,
    steps: int,
    input_tokens: int,
    output_tokens: int,
    summary: string?,
    error: string?,
}

class StepDetail {
    step: int,
    decide_status: string,
    decide_ns: int,
    look_ns: int?,
    act_ns: int?,
    decision: Decision?,
    decide_error: string?,
    // The model's verdict on this step, given on the next turn.
    verdict: string,
    screenshot: Screenshot?,
    ops: Op[],
    exec_error: string?,
    warnings: string[],
    input_tokens: int,
    output_tokens: int,
    model_calls: int,
    // The coordinate space the model answered in (screenshot pixels, or a
    // 0-1000 grid). Overlays position candidates against this.
    grid_width: int?,
    grid_height: int?,
    // Steering messages the model received on this step.
    user_messages: string[],
    // For an ask_user step: what the human answered.
    answer: string?,
}

class RunDetail {
    run: RunSummary,
    steps: StepDetail[],
}

// ---- Queries ----

const USAGE_COLUMNS = `
    total_usage[0]['input_tokens'] AS input_tokens,
    total_usage[0]['output_tokens'] AS output_tokens,
    total_usage[0]['calls'] AS calls
`;

function run_filter(run_id: string?) -> string {
    if (run_id) {
        return `AND context_metadata['run_id'] = ${sql_str(run_id)}`;
    }
    ""
}

function step_aggregates(run_id: string?, limit: int) -> StepAggRow[] {
    query<StepAggRow>(
        `
            SELECT context_metadata['run_id'] AS run_id, min(context_metadata['goal']) AS goal,
                   min(context_metadata['model']) AS model,
                   min(start_time) AS started, max(end_time) AS last_seen, count(*) AS steps,
                   sum(total_usage[0]['input_tokens']) AS input_tokens,
                   sum(total_usage[0]['output_tokens']) AS output_tokens
            FROM spans
            WHERE span_name = 'user.Decide' AND span_type = 'function' ${run_filter(run_id)}
            GROUP BY context_metadata['run_id']
            HAVING min(context_metadata['goal']) IS NOT NULL
            ORDER BY started DESC LIMIT ${limit}
        `,
    )
}

function finished_runs(run_id: string?, limit: int) -> FinishRow[] {
    query<FinishRow>(
        `
            SELECT context_metadata['run_id'] AS run_id, context_metadata['goal'] AS goal,
                   start_time AS started, end_time AS ended, duration AS duration_ns,
                   status AS span_status,
                   output_value['status'] AS outcome_status, output_value['summary'] AS summary,
                   error_value['error']['$class'] AS error_type,
                   coalesce(error_value['error']['message'], error_value['error']['raw_body']) AS error_message
            FROM spans
            WHERE span_name = 'user.run_loop' AND span_type = 'function' ${run_filter(run_id)}
            ORDER BY start_time DESC LIMIT ${limit}
        `,
    )
}

function step_rows<T>(span_filter: string, columns: string, run_id: string) -> T[] {
    query<T>(
        `
            SELECT context_metadata['run_id'] AS run_id, context_metadata['step'] AS step,
                   duration, ${columns}
            FROM spans
            WHERE ${span_filter} AND span_type = 'function' ${run_filter(run_id)}
            ORDER BY start_time
        `,
    )
}

// ---- Merging ----

function run_status(fin: FinishRow?, last_seen: string) -> RunStatus {
    if (fin) {
        return match (fin.outcome_status) {
            "done" => "done",
            "gave_up" => "gave_up",
            "out_of_steps" => "out_of_steps",
            _ => "error",
        };
    }
    let seen = baml.time.Instant.parse(last_seen) catch (e) {
        baml.errors.ParseError => {
            return "running";
        }
    };
    if (seen.elapsed().to_seconds() > STALE_AFTER_SECONDS * 1n) {
        "stale"
    } else {
        "running"
    }
}

function summarize(id: string, agg: StepAggRow?, fin: FinishRow?) -> RunSummary {
    let started = fin?.started ?? agg?.started ?? "";
    let last_seen = fin?.ended ?? agg?.last_seen ?? started;
    let error = fin?.error_message ?? fin?.error_type;
    RunSummary {
        run_id: id,
        goal: fin?.goal ?? agg?.goal ?? "(unknown goal)",
        model: agg?.model,
        status: run_status(fin, last_seen),
        started: started,
        last_seen: last_seen,
        duration_ns: fin?.duration_ns,
        steps: agg?.steps ?? 0,
        input_tokens: agg?.input_tokens ?? 0,
        output_tokens: agg?.output_tokens ?? 0,
        summary: fin?.summary,
        error: error,
    }
}

function merge(aggs: StepAggRow[], fins: FinishRow[]) -> RunSummary[] {
    let ids: string[] = [];
    for (
        let id in aggs
            .map((a) -> {
                a.run_id
            })
            .concat(
                fins.map((f) -> {
                    f.run_id
                }),
            )
    ) {
        if (!ids.includes(id)) {
            ids.push(id);
        }
    }
    ids
        .map((id) -> {
            summarize(
                id,
                aggs.find((a) -> {
                    a.run_id == id
                }),
                fins.find((f) -> {
                    f.run_id == id
                }),
            )
        })
        .sort_by_key((r) -> {
            r.started
        })
        .reverse()
}

function step_detail(
    d: DecideRow,
    next: DecideRow?,
    look: LookRow?,
    perform: PerformRow?,
    consult: ConsultRow?,
) -> StepDetail {
    let decision = d.decision;
    StepDetail {
        step: d.step,
        decide_status: d.status,
        decide_ns: d.duration,
        look_ns: look?.duration,
        act_ns: perform?.duration,
        decision: decision,
        decide_error: d.error_type,
        verdict: next?.decision?.verdict?.to_string()
            ?? (
                if (decision) {
                    "final"
                } else {
                    "failed"
                }
            ),
        screenshot: look?.shot,
        ops: perform?.ops ?? [],
        exec_error: perform?.error,
        warnings: d.warnings ?? [],
        input_tokens: d.input_tokens ?? 0,
        output_tokens: d.output_tokens ?? 0,
        model_calls: d.calls ?? 1,
        grid_width: d.grid_width,
        grid_height: d.grid_height,
        user_messages: d.user_messages ?? [],
        answer: consult?.answer,
    }
}

// ---- Public API (called from the server) ----

function list_runs(limit: int = DEFAULT_RUN_LIMIT) -> RunSummary[] {
    //# Step aggregates and finished runs, queried in parallel
    let aggs = spawn { step_aggregates(null, limit) };
    let fins = spawn { finished_runs(null, limit) };
    merge(await aggs, await fins).slice(0, limit)
}

function get_run(run_id: string) -> RunDetail? {
    //# Five queries in parallel: the run, then each step's model call, screenshot, and actions
    let aggs = spawn { step_aggregates(run_id, 1) };
    let fins = spawn { finished_runs(run_id, 1) };
    let decides = spawn {
        step_rows<DecideRow>(
            "span_name = 'user.Decide'",
            `
                status, output_value AS decision, input_args['warnings'] AS warnings, input_args['width'] AS grid_width, input_args['height'] AS grid_height, input_args['user_messages'] AS user_messages,
                             error_value['error']['$class'] AS error_type, ${USAGE_COLUMNS}
            `,
            run_id,
        )
    };
    let looks = spawn { step_rows<LookRow>("span_name LIKE 'python:%:look:%'", "output_value AS shot", run_id) };
    let performs = spawn {
        step_rows<PerformRow>(
            "span_name = 'user.perform'",
            "input_args['a']['ops'] AS ops, output_value AS error",
            run_id,
        )
    };
    let consults = spawn {
        step_rows<ConsultRow>("span_name = 'user.consult'", "output_value AS answer", run_id)
    };
    //# Join by step number
    let run = merge(await aggs, await fins).at(0)
        ?? return null;
    let ds = (await decides).sort_by_key((d) -> {
        d.step
    });
    let ls = await looks;
    let ps = await performs;
    let cs = await consults;
    let steps = ds.map((d) -> {
        step_detail(
            d,
            ds.find((n) -> {
                n.step == d.step + 1
            }),
            ls.find((l) -> {
                l.step == d.step
            }),
            ps.find((p) -> {
                p.step == d.step
            }),
            cs.find((c) -> {
                c.step == d.step
            }),
        )
    });
    RunDetail { run: run, steps: steps }
}

test "a run with steps but no finished loop is running, then stale" {
    let agg = StepAggRow {
        run_id: "r1",
        goal: "g",
        started: "2026-01-01T00:00:00Z",
        last_seen: baml.time.Instant.now().to_string(),
        steps: 2,
        input_tokens: 10,
        output_tokens: 5,
    };
    assert.equal(merge([agg], [])[0].status, "running");
    let old = StepAggRow { ...agg, last_seen: "2026-01-01T00:00:00Z" };
    assert.equal(merge([old], [])[0].status, "stale")
}

test "a finished loop sets status and summary; ids from either side are kept" {
    let agg = StepAggRow {
        run_id: "r1",
        goal: "g",
        started: "2026-01-01T00:00:00Z",
        last_seen: "2026-01-01T00:00:09Z",
        steps: 3,
        input_tokens: null,
        output_tokens: null,
    };
    let fin = FinishRow {
        run_id: "r1",
        goal: "g",
        started: "2026-01-01T00:00:00Z",
        ended: "2026-01-01T00:00:10Z",
        duration_ns: 10,
        span_status: "return",
        outcome_status: "done",
        summary: "ok",
        error_type: null,
        error_message: null,
    };
    let crashed = FinishRow {
        ...fin,
        run_id: "r2",
        started: "2026-01-02T00:00:00Z",
        span_status: "user_error",
        outcome_status: null,
        summary: null,
        error_type: "RunCancelled",
    };
    let runs = merge([agg], [fin, crashed]);
    assert.equal(runs.length(), 2);
    assert.equal(runs[0].run_id, "r2");
    assert.equal(runs[0].status, "error");
    assert.equal(runs[0].error, "RunCancelled");
    assert.equal(runs[1].status, "done");
    assert.equal(runs[1].steps, 3)
}

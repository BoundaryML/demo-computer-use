// Sinai: live dashboard for the computer-use agent.
//
// Client-side only (React + htm, no build step). Talks to server.py:
//   /api/execute      local executor: what's running/queued right now (fast, polled often)
//   /api/query/...    run history + per-step detail from `baml query` (polled while live)

import React, { useCallback, useEffect, useMemo, useRef, useState } from "https://esm.sh/react@18.3.1";
import { createRoot } from "https://esm.sh/react-dom@18.3.1/client";
import htm from "https://esm.sh/htm@3.1.1";

const html = htm.bind(React.createElement);

// ---- polling cadence (ms) ----
const EXEC_POLL = 1500;
const LIST_POLL_LIVE = 4000;
const LIST_POLL_IDLE = 20000;
const DETAIL_POLL_LIVE = 2500;
// Cloud ingestion lags a few seconds: keep polling briefly after a run ends.
const SETTLE_AFTER_END = 15000;

const LIVE = new Set(["running", "queued"]);

// ---- helpers ----

async function api(path, opts = {}) {
  const res = await fetch(path, {
    ...opts,
    headers: { "Content-Type": "application/json", ...(opts.headers || {}) },
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw Object.assign(new Error(body.error || res.statusText), { status: res.status });
  return body;
}

// Polls `fn` every `delay(data)` ms; waits for each response before scheduling the next.
function usePoll(fn, delay, deps) {
  const [state, setState] = useState({ data: null, error: null, loading: true });
  const ref = useRef(state);
  ref.current = state;
  const [nonce, setNonce] = useState(0);
  useEffect(() => {
    let alive = true;
    let timer;
    setState((s) => ({ ...s, loading: true }));
    const tick = async () => {
      let next;
      try {
        const data = await fn();
        next = { data, error: null, loading: false };
      } catch (error) {
        next = { data: ref.current.data, error, loading: false };
      }
      if (!alive) return;
      setState(next);
      const d = delay(next.data, next.error);
      if (d != null) timer = setTimeout(tick, d);
    };
    tick();
    return () => {
      alive = false;
      clearTimeout(timer);
    };
  }, [...deps, nonce]);
  return [state, () => setNonce((n) => n + 1)];
}

function useHashRoute() {
  const read = () => {
    const m = location.hash.match(/^#\/runs\/(.+)$/);
    return m ? decodeURIComponent(m[1]) : null;
  };
  const [runId, setRunId] = useState(read);
  useEffect(() => {
    const on = () => setRunId(read());
    window.addEventListener("hashchange", on);
    return () => window.removeEventListener("hashchange", on);
  }, []);
  const go = useCallback((id) => {
    location.hash = id ? `#/runs/${encodeURIComponent(id)}` : "#/";
  }, []);
  return [runId, go];
}

const secs = (ns) => (ns == null ? "—" : `${(ns / 1e9).toFixed(1)}s`);
const ms = (s) => (s == null ? "—" : `${s.toFixed(1)}s`);
const kfmt = (n) => (n == null ? "—" : n < 1000 ? `${n}` : `${(n / 1000).toFixed(1)}k`);
const pct = (part, whole) => (whole > 0 ? `${Math.min(100, (part / whole) * 100)}%` : "0%");
const shotUrl = (path) => (path ? `/${path}` : null);

function ago(iso) {
  if (!iso) return "";
  const s = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
  if (s < 60) return `${Math.floor(s)}s ago`;
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  return new Date(iso).toLocaleDateString();
}

function actionLabel(a) {
  if (!a) return "";
  switch (a.action) {
    case "click": return `${a.button} click “${a.target}”`;
    case "double_click": return `double click “${a.target}”`;
    case "type": return `type “${a.text}”${a.press_enter ? " ⏎" : ""}`;
    case "key": return `press ${a.keys}`;
    case "scroll": return `scroll ${a.direction} ×${a.amount}`;
    case "drag": return `drag “${a.target}”`;
    case "hover": return `hover “${a.target}”`;
    case "open_app": return `open app ${a.name}`;
    case "open_url": return `open ${a.url}`;
    case "wait": return `wait ${a.seconds}s`;
    case "done": return "done";
    case "give_up": return "give up";
    default: return a.action;
  }
}

// Where on the screenshot the action pointed (screenshot pixels).
function actionPoints(a) {
  if (!a) return [];
  if ("x" in a && "y" in a) return [{ x: a.x, y: a.y }];
  if (a.action === "drag") return [{ x: a.from_x, y: a.from_y }, { x: a.to_x, y: a.to_y }];
  return [];
}

function opLabel(op) {
  switch (op.op) {
    case "click": return `click ${op.button} ×${op.count} @ ${op.x},${op.y}`;
    case "move": return `move @ ${op.x},${op.y}`;
    case "drag": return `drag ${op.from_x},${op.from_y} → ${op.to_x},${op.to_y}`;
    case "type": return `type ${JSON.stringify(op.text)}`;
    case "key": return `key ${op.keys.join("+")}`;
    case "scroll": return `scroll dx=${op.dx} dy=${op.dy} @ ${op.x},${op.y}`;
    case "open": return `open ${op.args.join(" ")}`;
    case "sleep": return `sleep ${op.seconds}s`;
    default: return JSON.stringify(op);
  }
}

// ---- small components ----

function Status({ status }) {
  const label = { gave_up: "gave up", out_of_steps: "out of steps" }[status] || status;
  return html`<span className=${`pill pill-${status}`}>${LIVE.has(status) && html`<i className="pulse" />`}${label}</span>`;
}

function Kpi({ label, value, hint }) {
  return html`<div className="kpi" title=${hint || ""}><div className="kpi-v">${value}</div><div className="kpi-l">${label}</div></div>`;
}

// ---- left rail ----

function Composer({ onSubmitted }) {
  const [goal, setGoal] = useState("");
  const [maxSteps, setMaxSteps] = useState(20);
  // "provider|model"; empty until the model list loads.
  const [choice, setChoice] = useState("");
  const [models, setModels] = useState(null);
  useEffect(() => {
    let alive = true;
    const load = () => api("/api/models").then((m) => {
      if (!alive) return;
      setModels(m);
      setChoice((cur) => {
        const keys = m.options.map((o) => `${o.provider}|${o.model}`);
        if (keys.includes(cur)) return cur;
        const d = m.default || {};
        const preferred = m.options.find((o) => o.provider === d.provider && (!d.model || o.model === d.model));
        return preferred ? `${preferred.provider}|${preferred.model}` : keys[0] || "";
      });
    }).catch(() => alive && setModels({ options: [], lmstudio_note: "Couldn't load models from the server." }));
    load();
    const t = setInterval(load, 15000);  // picks up models loaded/downloaded in LM Studio
    return () => { alive = false; clearInterval(t); };
  }, []);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState(null);
  const submit = async (e) => {
    e?.preventDefault();
    if (!goal.trim() || busy) return;
    setBusy(true);
    setErr(null);
    try {
      const job = await api("/api/execute", { method: "POST", body: JSON.stringify({ goal, max_steps: maxSteps, provider: choice.split("|")[0], model: choice.split("|").slice(1).join("|") }) });
      setGoal("");
      onSubmitted(job);
    } catch (e) {
      setErr(e.message);
    } finally {
      setBusy(false);
    }
  };
  return html`
    <form className="card composer" onSubmit=${submit}>
      <label htmlFor="goal" className="eyebrow">New goal</label>
      <textarea
        id="goal"
        rows="3"
        placeholder="e.g. Open Safari, go to news.ycombinator.com and tell me the top story"
        value=${goal}
        onInput=${(e) => setGoal(e.target.value)}
        onKeyDown=${(e) => (e.metaKey || e.ctrlKey) && e.key === "Enter" && submit()}
      />
      <div className="composer-row">
        <div className="composer-opts">
          <label className="steps-input">Steps
            <input type="number" min="1" max="100" value=${maxSteps} onInput=${(e) => setMaxSteps(+e.target.value || 20)} />
          </label>
          <select className="model-select" value=${choice} onChange=${(e) => setChoice(e.target.value)} aria-label="Model" disabled=${!models?.options?.length}>
            ${!models && html`<option value="">Loading models…</option>`}
            ${models && !models.options.length && html`<option value="">No models available</option>`}
            ${models?.options?.some((o) => o.provider === "lmstudio") && html`
              <optgroup label="LM Studio (local)">
                ${models.options.filter((o) => o.provider === "lmstudio").map((o) => html`
                  <option key=${o.model} value=${`lmstudio|${o.model}`}>${o.label}${o.loaded ? "" : " (loads on first use)"}</option>`)}
              </optgroup>`}
            ${models?.options?.some((o) => o.provider === "claude") && html`
              <optgroup label="Anthropic">
                ${models.options.filter((o) => o.provider === "claude").map((o) => html`
                  <option key=${o.model} value=${`claude|${o.model}`}>${o.label}</option>`)}
              </optgroup>`}
          </select>
        </div>
        <button className="btn primary" disabled=${!goal.trim() || busy || !choice}>${busy ? "Starting…" : "Run ⌘⏎"}</button>
      </div>
      ${err && html`<p className="error-text">${err}</p>`}
      ${models?.lmstudio_note && html`<p className="warn-box">${models.lmstudio_note}</p>`}
      <p className="hint">The agent takes over this Mac's mouse and keyboard. Slam the pointer into a screen corner to abort.</p>
    </form>`;
}

function RunList({ runs, selected, onSelect, filter, setFilter, error }) {
  const shown = runs.filter((r) => !filter || r.goal.toLowerCase().includes(filter.toLowerCase()));
  return html`
    <section className="card list">
      <div className="list-head">
        <span className="eyebrow">Runs</span>
        <input className="search" placeholder="Filter…" value=${filter} onInput=${(e) => setFilter(e.target.value)} />
      </div>
      ${error && html`<p className="error-text small">Query failed: ${error.message}</p>`}
      ${!shown.length && html`<p className="muted small pad">No runs yet.</p>`}
      <ul>
        ${shown.map((r) => html`
          <li key=${r.run_id}>
            <button className=${`run-row ${r.run_id === selected ? "selected" : ""}`} onClick=${() => onSelect(r.run_id)}>
              <div className="run-row-top"><${Status} status=${r.status} /><span className="muted small">${ago(r.started)}</span></div>
              <div className="run-goal">${r.goal}</div>
              <div className="muted small">${r.steps} steps · ${kfmt(r.input_tokens + r.output_tokens)} tok${r.duration_ns ? ` · ${secs(r.duration_ns)}` : ""}</div>
              ${r.model && html`<div className="model-tag">${r.model}</div>`}
            </button>
          </li>`)}
      </ul>
    </section>`;
}

// ---- run detail ----

function Screenshot({ step, hover, setHover }) {
  const shot = step.screenshot;
  const d = step.decision;
  const [missing, setMissing] = useState(false);
  if (!shot) return html`<div className="noshot">no screenshot recorded</div>`;
  if (missing) return html`<div className="noshot">${shot.path.split("/").pop()} isn't on this machine</div>`;
  // Positions are in the model's coordinate space: screenshot pixels, or a 0-1000 grid.
  const gw = step.grid_width || shot.width;
  const gh = step.grid_height || shot.height;
  const at = (x, y) => ({ left: pct(x, gw), top: pct(y, gh) });
  return html`
    <a className="shot" href=${shotUrl(shot.path)} target="_blank" rel="noreferrer">
      <img src=${shotUrl(shot.path)} alt=${`Step ${step.step} screenshot`} loading="lazy" onError=${() => setMissing(true)} />
      ${(d?.candidates || []).map((c, i) => c.x != null && c.y != null && html`
        <span
          key=${i}
          className=${`cand ${c.chosen ? "chosen" : ""} ${hover === i ? "hot" : ""}`}
          style=${at(c.x, c.y)}
          title=${`${c.label}: ${c.reason}`}
          onMouseEnter=${() => setHover(i)}
          onMouseLeave=${() => setHover(null)}
        >${i + 1}</span>`)}
      ${actionPoints(d?.action).map((p, i) => html`<span key=${`t${i}`} className="target" style=${at(p.x, p.y)} />`)}
    </a>`;
}

function Candidates({ step, hover, setHover }) {
  const cands = step.decision?.candidates || [];
  if (!cands.length) return null;
  return html`
    <div>
      <h4>Options considered</h4>
      <ol className="cands">
        ${cands.map((c, i) => html`
          <li
            key=${i}
            className=${`${c.chosen ? "chosen" : ""} ${hover === i ? "hot" : ""}`}
            onMouseEnter=${() => setHover(i)}
            onMouseLeave=${() => setHover(null)}
          >
            <span className="cnum">${i + 1}</span>
            <div>
              <strong>${c.label}</strong>
              ${c.chosen && html` <span className="pill pill-done">chosen</span>`}
              ${c.x == null && html` <span className="tag">no screen target</span>`}
              <div className="muted small">${c.reason}</div>
            </div>
          </li>`)}
      </ol>
    </div>`;
}

function StepCard({ step }) {
  const [hover, setHover] = useState(null);
  const d = step.decision;
  if (!d) {
    return html`
      <article className="card step" id=${`step-${step.step}`}>
        <h3><span className="num">#${step.step}</span> model call failed</h3>
        <p className="error-text">${step.decide_error || step.decide_status}</p>
      </article>`;
  }
  const finishing = d.action.action === "done" || d.action.action === "give_up";
  return html`
    <article className="card step" id=${`step-${step.step}`}>
      <${Screenshot} step=${step} hover=${hover} setHover=${setHover} />
      <div className="step-info">
        <h3><span className="num">#${step.step}</span> ${actionLabel(d.action)}</h3>
        <div className="meta">
          <${Status} status=${step.verdict === "final" ? (finishing ? "done" : "unclear") : step.verdict} />
          <span>model ${secs(step.decide_ns)}</span>
          ${step.act_ns != null && html`<span>act ${secs(step.act_ns)}</span>`}
          <span>${kfmt(step.input_tokens)} in / ${kfmt(step.output_tokens)} out</span>
          ${step.model_calls > 1 && html`<span className="warn-text">${step.model_calls} model calls</span>`}
        </div>
        ${step.warnings.map((w, i) => html`<p key=${i} className="warn-box">⚠ ${w}</p>`)}
        ${finishing && html`<p className="final">${d.action.summary || d.action.reason}</p>`}
        <${Candidates} step=${step} hover=${hover} setHover=${setHover} />
        <dl>
          <dt>Saw</dt><dd>${d.observation}</dd>
          <dt>Last step</dt><dd>${d.verdict.replace("_", " ")}</dd>
          <dt>Plan</dt><dd>${d.plan}</dd>
          <dt>Expects</dt><dd>${d.expectation}</dd>
        </dl>
        ${step.ops.length > 0 && html`<ul className="ops">${step.ops.map((o, i) => html`<li key=${i}>${opLabel(o)}</li>`)}</ul>`}
        ${step.exec_error && html`<p className="error-text">Execution error: ${step.exec_error}</p>`}
      </div>
    </article>`;
}

function Timeline({ steps }) {
  const total = (s) => (s.look_ns || 0) + s.decide_ns + (s.act_ns || 0);
  const longest = Math.max(1, ...steps.map(total));
  return html`
    <section className="card timeline">
      <div className="tl-head">
        <span className="eyebrow">Where the time went</span>
        <span className="legend"><i className="seg look" />screenshot <i className="seg decide" />model <i className="seg act" />act + settle</span>
      </div>
      ${steps.map((s) => html`
        <a key=${s.step} className="tl-row" href=${`#step-${s.step}`} onClick=${(e) => {
          e.preventDefault();
          document.getElementById(`step-${s.step}`)?.scrollIntoView({ behavior: "smooth", block: "start" });
        }}>
          <span className="tl-num">#${s.step}</span>
          <span className="tl-bar">
            <i className="seg look" style=${{ width: pct(s.look_ns || 0, longest) }} />
            <i className="seg decide" style=${{ width: pct(s.decide_ns, longest) }} />
            <i className="seg act" style=${{ width: pct(s.act_ns || 0, longest) }} />
          </span>
          <span className="tl-val">${secs(total(s))}</span>
        </a>`)}
    </section>`;
}

// What the local executor knows about this run, ahead of the cloud.
function LivePanel({ job, cloudSteps, onCancel }) {
  const [cancelling, setCancelling] = useState(false);
  if (!job) return null;
  const pending = job.state === "queued";
  const elapsed = job.started_at ? Date.now() / 1000 - job.started_at : null;
  return html`
    <section className="card live">
      <div className="live-head">
        <div>
          <span className="eyebrow">${pending ? "Queued" : "Live on this Mac"}</span>
          <h3>${pending ? "Waiting for the screen…" : `Step ${job.step} in progress`}</h3>
          <p className="muted small">
            ${pending ? "Another goal is running." : `${ms(elapsed)} elapsed · ${cloudSteps} step${cloudSteps === 1 ? "" : "s"} recorded so far (traces land a few seconds behind)`}
          </p>
        </div>
        <button className="btn danger" disabled=${cancelling} onClick=${async () => {
          setCancelling(true);
          await onCancel(job.run_id).finally(() => setCancelling(false));
        }}>${cancelling ? "Cancelling…" : "Cancel"}</button>
      </div>
      ${job.latest_shot && html`
        <div className="live-shot">
          <img src=${`${shotUrl(job.latest_shot)}?t=${job.step}`} alt="Latest screenshot" />
        </div>`}
    </section>`;
}

function RunDetail({ runId, job, onCancel, listEntry }) {
  const [endedAt, setEndedAt] = useState(null);
  const jobLive = job && LIVE.has(job.state);
  useEffect(() => {
    if (!jobLive && job) setEndedAt(Date.now());
  }, [jobLive]);

  const [{ data, error, loading }] = usePoll(
    () => api(`/api/query/runs/${encodeURIComponent(runId)}`),
    (d, err) => {
      const live = jobLive || d?.run?.status === "running" || (err?.status === 404 && listEntry?.status !== "stale");
      const settling = endedAt && Date.now() - endedAt < SETTLE_AFTER_END;
      return live || settling ? DETAIL_POLL_LIVE : null;
    },
    [runId, jobLive],
  );

  const run = data?.run;
  const steps = data?.steps || [];
  const goal = run?.goal || job?.goal || listEntry?.goal || runId;
  const status = jobLive ? job.state : run?.status || job?.state || listEntry?.status;
  const modelNs = steps.reduce((a, s) => a + s.decide_ns, 0);
  const wallNs = run?.duration_ns ?? (run ? new Date(run.last_seen) - new Date(run.started) : 0) * 1e6;
  const calls = steps.reduce((a, s) => a + s.model_calls, 0);

  return html`
    <div className="detail">
      <header className="detail-head">
        <p className="eyebrow mono">${runId}${run?.started ? ` · ${new Date(run.started).toLocaleString()}` : ""}${run?.model || job?.model?.model || job?.model?.provider ? ` · ${run?.model || job.model.model || job.model.provider}` : ""}</p>
        <h1>${goal}</h1>
        <div className="outcome">
          ${status && html`<${Status} status=${status} />`}
          <span>${run?.summary || run?.error || job?.summary || job?.error || ""}</span>
        </div>
      </header>

      ${jobLive && html`<${LivePanel} job=${job} cloudSteps=${steps.length} onCancel=${onCancel} />`}

      ${error && error.status !== 404 && html`<p className="error-text">Query failed: ${error.message}</p>`}
      ${!data && loading && html`<div className="card skeleton">Querying traces…</div>`}
      ${!data && error?.status === 404 && !jobLive && html`<div className="card empty">No steps recorded for this run yet.</div>`}

      ${run && html`
        <section className="kpis">
          <${Kpi} label="steps" value=${steps.length} />
          <${Kpi} label="wall time" value=${secs(wallNs)} />
          <${Kpi} label="time in model" value=${wallNs ? `${Math.round((modelNs / wallNs) * 100)}%` : "—"} />
          <${Kpi} label="tokens in / out" value=${`${kfmt(run.input_tokens)} / ${kfmt(run.output_tokens)}`} />
          <${Kpi} label="parse repairs" value=${Math.max(0, calls - steps.length)} hint="Extra model calls when a reply didn't match the schema" />
        </section>`}
      ${steps.length > 0 && html`<${Timeline} steps=${steps} />`}
      <section className="steps">
        ${steps.map((s) => html`<${StepCard} key=${s.step} step=${s} />`)}
      </section>
    </div>`;
}

function Welcome() {
  return html`
    <div className="welcome">
      <h1>Pick a run, or start one</h1>
      <p className="muted">Each step shows the screenshot the model saw, every option it considered (numbered), the one it chose (red), and exactly where it clicked (dashed ring).</p>
    </div>`;
}

// ---- app ----

function App() {
  const [runId, go] = useHashRoute();
  const [filter, setFilter] = useState("");

  const [{ data: exec }, refreshExec] = usePoll(() => api("/api/execute"), () => EXEC_POLL, []);
  const anyLocalLive = !!(exec?.active || exec?.queue?.length);

  const [{ data: cloudRuns, error: listError }, refreshList] = usePoll(
    () => api("/api/query/runs?limit=100"),
    (runs) => (anyLocalLive || runs?.some((r) => r.status === "running") ? LIST_POLL_LIVE : LIST_POLL_IDLE),
    [anyLocalLive],
  );

  // Local jobs first (they exist before the cloud has seen them), then cloud history.
  const runs = useMemo(() => {
    const local = [exec?.active, ...(exec?.queue || [])].filter(Boolean);
    const cloud = cloudRuns || [];
    const seen = new Set(cloud.map((r) => r.run_id));
    const merged = cloud.map((r) => {
      const j = local.find((l) => l.run_id === r.run_id);
      return j ? { ...r, status: j.state } : r;
    });
    const fresh = local
      .filter((j) => !seen.has(j.run_id))
      .map((j) => ({
        run_id: j.run_id, goal: j.goal, status: j.state, steps: j.step ? j.step - 1 : 0,
        started: new Date(j.queued_at * 1000).toISOString(), input_tokens: 0, output_tokens: 0, duration_ns: null,
      }));
    return [...fresh, ...merged];
  }, [exec, cloudRuns]);

  const allJobs = [exec?.active, ...(exec?.queue || []), ...(exec?.recent || [])].filter(Boolean);
  const job = allJobs.find((j) => j.run_id === runId) || null;

  const onSubmitted = (j) => {
    refreshExec();
    go(j.run_id);
  };
  const onCancel = async (id) => {
    await api(`/api/execute/${encodeURIComponent(id)}/cancel`, { method: "POST" });
    refreshExec();
    refreshList();
  };

  return html`
    <div className="app">
      <header className="topbar">
        <a className="brand" href="#/"><span className="logo" />Sinai<span className="muted"> · computer-use agent</span></a>
        <span className="muted small mono">${anyLocalLive ? html`<i className="pulse" /> agent running` : "idle"}</span>
      </header>
      <div className="layout">
        <aside className="rail">
          <${Composer} onSubmitted=${onSubmitted} />
          <${RunList} runs=${runs} selected=${runId} onSelect=${go} filter=${filter} setFilter=${setFilter} error=${listError} />
        </aside>
        <main className="main">
          ${runId
            ? html`<${RunDetail} key=${runId} runId=${runId} job=${job} onCancel=${onCancel} listEntry=${runs.find((r) => r.run_id === runId)} />`
            : html`<${Welcome} />`}
        </main>
      </div>
    </div>`;
}

createRoot(document.getElementById("root")).render(html`<${App} />`);

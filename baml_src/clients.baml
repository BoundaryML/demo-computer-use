// The model that drives the agent ("pilot"). Open-source vision models served
// by LM Studio are the default; Claude is one flag away.
//
//     uv run agent.py "goal"                                   # LM Studio, Qwen3-VL 4B
//     uv run agent.py --model qwen/qwen3-vl-8b "goal"          # another LM Studio model
//     uv run agent.py --provider claude "goal"                 # Claude Sonnet

// LM Studio's OpenAI-compatible server (Settings -> Local API server). Its
// stock port is 1234; this machine's is set to 1235. Override with --base-url.
const LMSTUDIO_URL = "http://127.0.0.1:1235/v1";
// Qwen3-VL 4B Instruct: the strongest ~4B open VLM at finding UI elements.
const LMSTUDIO_MODEL = "qwen3-vl-4b-instruct";
const CLAUDE_MODEL = "claude-sonnet-5-5";
// Retries cover transient network and 5xx failures; one blip shouldn't end a run.
const MODEL_ATTEMPTS = 4;
const MAX_OUTPUT_TOKENS = 4096;
// Local models on a laptop can take a while per screenshot.
const LOCAL_TIMEOUT_SECONDS = 300;
// Past screenshots replayed to the model each turn. Claude caches the
// trajectory, so it gets the whole run; a 4B local model's context can't.
const CLAUDE_FRAMES = 30;
const LOCAL_FRAMES = 2;

type Provider = "lmstudio" | "claude";

// How a model expresses screen positions:
// - "pixels": pixels of the screenshot it was shown (Claude).
// - "per_mille": a 0-1000 grid over the screenshot, whatever its size. The
//   Qwen VL family is trained this way; asking it for pixels makes it misclick.
type Coords = "pixels" | "per_mille";

const PER_MILLE = 1000;

class Pilot {
    provider: Provider,
    model: string,
    coords: Coords,
    // How many past screenshots the model sees (see CLAUDE_FRAMES).
    frames: int,
    client: ai.Client,

    function new(provider: Provider = "lmstudio", model: string? = null, base_url: string? = null) -> Self {
        match (provider) {
            "lmstudio" => {
                let m = model ?? LMSTUDIO_MODEL;
                let local = openai.GenericClient.new(
                    model = m,
                    base_url = base_url ?? LMSTUDIO_URL,
                    // LM Studio ignores the key, but the client wants one.
                    api_key = "lm-studio",
                    timeout = baml.time.Duration.from_seconds(LOCAL_TIMEOUT_SECONDS),
                    max_tokens = MAX_OUTPUT_TOKENS,
                );
                Pilot {
                    provider: provider,
                    model: m,
                    coords: coords_for(m),
                    frames: LOCAL_FRAMES,
                    client: ai.clients.Retry.new(inner = local, max_attempts = MODEL_ATTEMPTS),
                }
            },
            "claude" => {
                let m = model ?? CLAUDE_MODEL;
                let claude = anthropic.Client.new(model = m, api_key = env.ANTHROPIC_API_KEY, max_tokens = MAX_OUTPUT_TOKENS);
                Pilot {
                    provider: provider,
                    model: m,
                    coords: "pixels",
                    frames: CLAUDE_FRAMES,
                    client: ai.clients.Retry.new(inner = claude, max_attempts = MODEL_ATTEMPTS),
                }
            },
        }
    }

    // The coordinate space the model answers in, as a screenshot of that size.
    // Actions compile against this view, so the mapping to screen points stays
    // in one place (Screenshot.to_screen).
    function view(self, shot: Screenshot) -> Screenshot {
        match (self.coords) {
            "pixels" => shot,
            "per_mille" => Screenshot { ...shot, width: PER_MILLE, height: PER_MILLE },
        }
    }

    function label(self) -> string {
        `${self.provider}:${self.model}`
    }
}

// Qwen2.5-VL answered in pixels; Qwen3-VL (and later) use the 0-1000 grid.
function coords_for(model: string) -> Coords {
    let m = model.to_lower_case();
    if (m.includes("qwen2.5") || m.includes("qwen2_5")) {
        return "pixels";
    }
    if (m.includes("qwen")) {
        return "per_mille";
    }
    "pixels"
}

// Static client for the playground and tests; runs pick a Pilot at runtime.
client Default = openai.GenericClient.new(model = LMSTUDIO_MODEL, base_url = LMSTUDIO_URL, api_key = "lm-studio");

test "pilots default to LM Studio with the Qwen3-VL 0-1000 grid" {
    let p = Pilot.new();
    assert.equal(p.label(), "lmstudio:qwen3-vl-4b-instruct");
    assert.equal(p.coords, "per_mille");
    assert.equal(Pilot.new(provider = "claude").coords, "pixels");
    assert.equal(coords_for("qwen/qwen2.5-vl-7b"), "pixels");
    assert.equal(coords_for("google/gemma-3-4b"), "pixels")
}

test "a per-mille answer maps to the same screen point as pixels" {
    let shot = Screenshot { path: "x.png", width: 1280, height: 720, screen_width: 1920, screen_height: 1080 };
    let view = Pilot.new().view(shot);
    assert.equal(view.to_screen(500, 500), Point { x: 960, y: 540 });
    assert.equal(view.to_screen(500, 500), shot.to_screen(640, 360))
}

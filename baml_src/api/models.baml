// Which models the UI can offer right now: vision models available in LM
// Studio, plus Claude only when ANTHROPIC_API_KEY is set.

const LMSTUDIO_PROBE_SECONDS = 3;

class ModelOption {
    provider: Provider,
    model: string,
    label: string,
    // LM Studio: whether it's in memory now (a cold model loads on first use).
    loaded: bool,
}

class ModelChoices {
    options: ModelOption[],
    // Why LM Studio contributed nothing, if it didn't (shown in the UI).
    lmstudio_note: string?,
}

// LM Studio's native REST listing (/api/v0/models) reports each model's type,
// unlike the OpenAI-style /v1/models; only "vlm" models can read screenshots.
class LmStudioModel {
    id: string,
    type: string,
    state: string?,
}

class LmStudioList {
    data: LmStudioModel[],
}

function lmstudio_models(base_url: string) -> LmStudioModel[] throws baml.errors.Io | baml.errors.Timeout | baml.json.DecodeError | baml.json.ParseError {
    // http://host:1235/v1 -> http://host:1235/api/v0/models
    let host = base_url.replace("/v1", "");
    let res = baml.http.fetch(`${host}/api/v0/models`, timeout = baml.time.Duration.from_seconds(LMSTUDIO_PROBE_SECONDS));
    baml.json.decode<LmStudioList>(res.text()).data
}

function available_models(base_url: string? = null) -> ModelChoices {
    let url = base_url ?? LMSTUDIO_URL;
    let note: string? = null;
    //# Local vision models from LM Studio
    let local: LmStudioModel[] = lmstudio_models(url) catch (e) {
        _ => {
            note = `LM Studio isn't reachable at ${url}. Start its local server.`;
            []
        }
    };
    let vlms = local
        .filter((m) -> { m.type == "vlm" })
        .map((m) -> {
            ModelOption { provider: "lmstudio", model: m.id, label: m.id, loaded: m.state == "loaded" }
        })
        .sort_by_key((o) -> {
            // The default model first, then loaded ones.
            if (o.model == LMSTUDIO_MODEL) { 0 } else if (o.loaded) { 1 } else { 2 }
        });
    if (!vlms && !note) {
        note = `No vision model in LM Studio yet. Download ${LMSTUDIO_MODEL}.`;
    }
    //# Claude, only with a key
    let key = baml.env.get("ANTHROPIC_API_KEY") catch (e) {
        _ => null
    };
    let claude: ModelOption[] = if (key) {
        [
            ModelOption { provider: "claude", model: CLAUDE_MODEL, label: "Claude Sonnet", loaded: true },
            ModelOption { provider: "claude", model: CLAUDE_OPUS_MODEL, label: "Claude Opus", loaded: true },
        ]
    } else {
        []
    };
    ModelChoices { options: vlms.concat(claude), lmstudio_note: note }
}

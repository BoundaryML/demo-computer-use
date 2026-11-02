// A typed client over `baml query`: SQL in, BAML classes out.
//
// Recorded values come back as JSON tagged with their class, so a row
// decodes straight into the same types the agent used (`Decision`,
// `Outcome`, `Op`, ...). Queries go to the project's Boundary cloud project
// (baml.toml [boundary]), so the dashboard shows runs from any machine.

const QUERY_WALL = "60s";

class QueryFailed {
    sql: string,
    stderr: string,

    implements baml.ToString {
        function to_string(self) -> string {
            `baml query failed: ${self.stderr}\n${self.sql}`
        }
    }
}

// Where recordings are read from. With BOUNDARY_API_KEY=local, runs record on
// this machine instead of the cloud, into the project's .baml/ (agent.py
// points the bridge's BAML_HOME there), which `baml query --local` reads.
// `baml` itself must still run with the real BAML_HOME to find its toolchain.
class QuerySource {
    args: string[],
    env: map<string, string>?,
}

function env_or_null(name: string) -> string? {
    baml.env.get(name) catch (e) {
        _ => null
    }
}

function query_source() -> QuerySource {
    if (env_or_null("BOUNDARY_API_KEY") != "local") {
        return QuerySource { args: [], env: null };
    }
    let real_home = env_or_null("SINAI_BAML_HOME");
    QuerySource {
        args: ["--local", "--agent-skill-check", "off"],
        // PATH too: with an env override, the program lookup otherwise can't find `baml`.
        env: if (real_home) { { "BAML_HOME": real_home, "PATH": env_or_null("PATH") ?? "" } } else { null },
    }
}

// Runs one SELECT and returns each row as {column: value}.
function query_rows(
    sql: string,
) -> map<string, json>[] throws QueryFailed | baml.errors.Io | baml.errors.Timeout | baml.json.ParseError | baml.json.PathError {
    let src = query_source();
    let out = baml.sys.exec(
        "baml",
        ["query", "--format", "json", "--max-wall", QUERY_WALL].concat(src.args).concat([sql]),
        baml.sys.ProcessOptions { cwd: null, env: src.env, timeout_ms: null, stdin: null, stderr: null },
    );
    if (!out.ok()) {
        throw QueryFailed { sql: sql, stderr: out.stderr.to_string() }
    }
    let doc = baml.json.parse(out.stdout.to_string());
    let columns = baml.json.path<map<string, json>[]>(doc, ".columns").map((c) -> {
        baml.json.path_or<string>(c, ".name", "")
    });
    baml.json.path<json[][]>(doc, ".rows").map((row) -> {
        let m: map<string, json> = {};
        let i = 0;
        for (let name in columns) {
            m.set(name, row.at(i) ?? null);
            i += 1;
        }
        m
    })
}

// Rows that don't decode (recorded before a schema change) are skipped with
// a warning, so one old run can't take down the whole dashboard.
function query<T>(sql: string) -> T[] {
    query_rows(sql).filter_map((row) -> {
        baml.json.to<T>(row) catch (e) {
            let err: baml.json.DecodeError => {
                log.warn(`skipping row ${row.get("run_id") ?? ""}: ${err}`);
                null
            }
        }
    })
}

// A SQL string literal.
function sql_str(s: string) -> string {
    `'${s.replace_all("'", "''")}'`
}

function sql_list(xs: string[]) -> string {
    xs
        .map((x) -> {
            sql_str(x)
        })
        .join(", ")
}

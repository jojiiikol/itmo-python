---
name: prometheus-monitoring
description: "Query Prometheus/PromQL and wire Prometheus MCP into Hermes."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  hermes:
    tags: [prometheus, promql, metrics, monitoring, mcp, observability, grafana, thanos]
---

# Prometheus Monitoring

## When to Use

- The user asks a question about metrics, target health, PromQL, or what
  Prometheus is scraping.
- The user wants a Prometheus MCP server connected to Hermes, or reports a
  Prometheus MCP `test` failing.
- Any monitoring task where Prometheus is the data source (Grafana, Thanos,
  VictoriaMetrics, Mimir expose the same `/api/v1/*` API).

Two paths: raw HTTP API (always works, no setup) and MCP (richer tool surface
for the agent).

## Step 0 — Verify Prometheus is reachable before anything else

Always `curl` the API directly first. This separates "Prometheus is down"
from "the MCP wiring is wrong" — the two causes look identical from a failed
`hermes mcp test`.

```bash
curl -s -m 8 -o /dev/null -w "HTTP %{http_code}\n" http://HOST:PORT/-/healthy
curl -s -m 8 "http://HOST:PORT/api/v1/query?query=up"
```

`HTTP 200` + `{"status":"success",...}` means Prometheus is fine and any
remaining problem is in the client/MCP config. Use this same API path to
answer metric questions when no MCP server is configured — an instant query
always works.

## Wiring a Prometheus MCP server into Hermes

**An MCP server is a local subprocess, NOT a service to deploy.** `npx`-based
MCP servers are launched by Hermes on startup; never tell the user to stand up
a separate container or daemon for a stdio MCP server.

Use the CLI, which connects and discovers tools before saving:

```bash
export PATH=/opt/hermes/bin:$PATH   # if `hermes` is not on PATH; find it with `find / -name hermes -type f -perm -u+x`
hermes mcp add prometheus \
  --command npx \
  --env PROMETHEUS_URL=http://HOST:PORT \
  --args -y prometheus-mcp@latest stdio     # --args MUST be last
hermes mcp test prometheus                  # expect: Connected + N tools, exit 0
```

Resulting config block:

```yaml
mcp_servers:
  prometheus:
    command: npx
    args: [-y, prometheus-mcp@latest, stdio]
    env:
      PROMETHEUS_URL: http://HOST:PORT
    enabled: true
```

Tools register under the qualified name `mcp__<server>__<tool>` — the agent
calls `mcp__prometheus__prometheus_query`, not the bare `prometheus_query` the
server advertises. Get the exact names from `hermes mcp list` or the
`MCP server 'prometheus' (stdio): registered N tool(s): ...` line in
`$HERMES_HOME/logs/agent.log` before telling the user what is available.

Tools only load in a **new session** — the toolset is fixed at session start.
`hermes mcp add` prints "Start a new session to use these tools" for this reason:
a session that is already running (including the one that configured the server)
will NOT see the tools, even though `hermes mcp list` says `enabled` and
`hermes mcp test` passes. Use `/reload-mcp` to re-read MCP config live, but a
fresh session is the reliable path.

## Verify MCP end-to-end (beyond `hermes mcp test`)

`hermes mcp test` proves the subprocess starts and lists tools. It does NOT
prove the agent can call them. To prove that, spawn a fresh one-shot session and
check the log, not the child's prose summary:

```bash
export PATH=/opt/hermes/bin:$PATH
hermes chat -m <model> --provider <provider> -Q -q \
  "Use ONLY the mcp__prometheus__* tools (never curl, never terminal) to run
   prometheus_query 'up' and prometheus_list_targets; quote the raw values."
grep -E "mcp__prometheus" "$HERMES_HOME/logs/agent.log" | tail
```

Success is `agent.tool_executor: tool mcp__prometheus__prometheus_query
completed` lines. Pass `-m`/`--provider` explicitly — a spawned child inherits
the configured default model, and a stale default aborts the whole run with
`Unknown model` before any tool is reached.

## Pitfalls

- **Verify the npm package name before writing config.** A guessed name fails
  as a silent connection error, not an obvious 404. Confirm with
  `npm view <pkg> version` (404 = does not exist) and read the package README
  for its real `command`/`args`/env contract. `prometheus-mcp` is a valid
  package; `@prometheus/mcp-server` is not — the official Go server at
  `github.com/prometheus/prometheus-mcp` is a released binary, not that npm
  scope.
- **Never paste `--args` into the YAML args list.** CLI flag syntax is not
  YAML list syntax. A config that grew from a copied shell command ends up with
  literal `- --args` entries that break the launch. Write plain scalar list
  items: `args: [-y, pkg, stdio]`.
- **`PROMETHEUS_URL` is an env var, not a `--flag`.** Different Prometheus MCP
  servers take the endpoint differently (env var vs `--prometheus.url=`). Read
  the specific package's README instead of assuming the flag pattern.
- **Check `enabled: true`.** `hermes mcp add` writes it; a hand-written or
  previously disabled block leaves `enabled: false` and the server never
  connects even though it is present in the file.
- **`hermes mcp remove <name>` and `hermes mcp add` are interactive** — pipe
  `y` (`printf 'y\n' |`) or run through a TTY, otherwise they hang waiting on
  the confirmation / "Enable all N tools?" prompt.
- **MCP tools are *local* tools — one per `tool_call`.** Sending several in one
  `tool_call` is rejected with `tool_call takes exactly one entry for local
  tools`. Issue them sequentially; batching is only for connector tools. Do not
  diagnose this as a broken MCP server — retry one at a time.
- **A `test` pass is not a callability proof.** Registration, enablement, and a
  successful `test` can all be true while the running session still has zero
  Prometheus tools. Check the actual tool name in the log before claiming the
  agent can query via MCP.

## Editing `config.yaml`

- The `patch`/`write_file` tools **refuse** to touch the Hermes config file
  (security block). Use `hermes mcp add` / `hermes mcp remove` / `hermes config
  set` instead — do not hand-edit `mcp_servers` yourself.
- The live config path is `$HERMES_HOME/config.yaml`, which is **not**
  `~/.hermes/config.yaml` — resolve it from `$HERMES_HOME`.
- The bundled `hermes-agent` skill documents MCP config shape generally (the
  `mcp_servers` block, stdio vs HTTP transport, tool filtering). Load it for
  the general reference; this skill carries the Prometheus-specific recipe.

## Reading results

- `up == 0` on a scrape target means Prometheus **cannot** scrape it — report
  that plainly (target down / unreachable); it is not a query error. Always
  distinguish "my query failed" from "the metrics are not being collected".
- Prefer one instant query to confirm a fact; use `query_range` only for trends.
- When an app metric returns `{"resultType":"vector","result":[]}`, that means
  **the series is not being collected** (target down or metric never exposed),
  not that the value is zero. Zero shows up as an explicit `"0"` on a series
  that does exist.

### Bounded status check ("what's up with Prometheus?")

For a health question rather than a metric question, run a fixed four-probe
battery and report it as a state, not an exploration: build info, target health,
metric-name inventory, and the series count.

```bash
B=http://HOST:PORT
curl -s "$B/-/healthy"                                  # 200 + "Prometheus Server is Healthy."
curl -s "$B/api/v1/status/buildinfo"                    # version, revision, buildDate, goVersion
curl -s "$B/api/v1/targets"                             # health/lastError/lastScrape per target
curl -s --get --data-urlencode 'query=count by (__name__) ({__name__!=""})' "$B/api/v1/query"
```

Read `version` from the live buildinfo, never from memory or the user's notes —
Prometheus gets upgraded in place and the version is a fact about the running
server.

The last probe is the one that makes the answer unambiguous. When the target is
down, `count by (__name__)` returns exactly the five service-internal series
(`up`, `scrape_duration_seconds`, `scrape_samples_scraped`,
`scrape_samples_post_metric_relabeling`, `scrape_series_added`) — an inventory of
five names is the fingerprint of "nothing is being scraped", and showing it is
far more convincing than stating the target is down. Say which five they are and
that all of them describe Prometheus scraping itself.

Report the state as "reachable at version N, target X down since <lastScrape>,
TSDB holds only the five scrape-internal series" — then name the fix (bring the
exporter up, or add the correct target) rather than re-explaining the API.

## Analyzing metrics for problems

For "inspect the metrics / are there problems?" questions, work a fixed battery
and interpret ratios rather than reading single values — saturating counters and
sampling artifacts make a point-in-time snapshot misleading. See
`references/metrics-triage.md` for the query set and the interpretation rules
(availability fraction, counter resets, histogram coverage vs event counts,
producer/consumer imbalance, and default-exporter noise).
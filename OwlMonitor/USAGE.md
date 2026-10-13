# Using Owl Monitor from the terminal

While the Owl Monitor app is running it hosts a local hub (Unix socket at
`~/Library/Application Support/OwlMonitor/dm.sock`). Any terminal — or a Claude Code instance —
can drive it with the `owl-monitor` CLI instead of running the dev server directly.

## Commands

| Command | What it does |
|---------|--------------|
| `owl-monitor up [path] [--gb N] [--wait]` | Start + supervise a project (default: cwd). **Idempotent** — a no-op that reports the port if already running. Auto-detects pnpm/npm + framework. `--gb N` overrides the heap (and pins it). `--wait` blocks until the server is HTTP-ready and prints its URL (or exits non-zero with the failure cause). (`run` is an alias.) |
| `owl-monitor build [path]` | Build the project. **Pauses all active dev servers while building** (to free RAM) and relaunches them after. **Synchronous** — waits for the build, prints the tail of its output + a `✅`/`❌` verdict, and exits non-zero on failure. On failure it also prints `↳ full build log: <path>`; read the **whole** error with `owl-monitor logs [path] --build`. In auto mode the build heap autoscales **4 → 6 → 8** on OOM (independent from the dev server; learned level persisted). See `docs/HEAP-AND-BUILD.md`. |
| `owl-monitor status [--json]` | List **every known** project (idle or running) with state + port. `--json` adds a machine-readable array with `ready`, `url`, `pid`, `exitCode`, `lastError`, `logPath`, `buildLogPath` — everything an agent needs to operate and diagnose. |
| `owl-monitor stop [path] [--all]` | Stop one project's server (default: cwd), or `--all` of them. |
| `owl-monitor restart [path]` | Relaunch the project's server. Works from **any** state — including `Failed`/`Idle` (relaunches), not just a live server. |
| `owl-monitor remove [path]` | Stop the server and **forget** the project (removes it from `projects.json`). Aliases: `rm`, `forget`. |
| `owl-monitor logs [path] [-f]` | Print, or follow with `-f`, **that project's own** dev-server log (default: cwd). One log file per project. |
| `owl-monitor logs [path] --build` | Print the **whole** output of the last build for that project — the full error, not the tail `owl-monitor build` shows. |
| `owl-monitor version` | Print the version (aliases: `-v`, `--version`). |
| `owl-monitor docs` | Print help (aliases: `--help`, `-h`). |

Paths default to the current directory and are resolved to **absolute**. Invalid input fails loudly:
a path that isn't a project folder (no `package.json` / Deno config) is rejected; unknown flags and a
malformed `--gb` (non-positive / non-integer) error with a clear message and a non-zero exit. The Dev
Monitor app hosts the hub; if it isn't running the CLI **starts it automatically** (via LaunchServices)
and waits for the hub before issuing the command.

## Readiness — don't poll the port yourself

A dev server often prints `Local: http://localhost:PORT` long before it actually accepts HTTP (e.g.
~25s of Vite/Nuxt compilation). Owl Monitor stays `Launching…` during warm-up and only flips to
`Running` after the **first successful HTTP probe** — it never recycles during warm-up. So:

- `owl-monitor up --wait` blocks until ready and prints `ready: http://localhost:PORT/` (or the cause on failure).
- `owl-monitor status --json` exposes `ready` (bool) and `url` — read those instead of `curl`-ing the port.

## Diagnosing a failure — without reading internal files

When a server fails, `status --json` carries the cause so you can self-correct:

- `state` — e.g. `Failed: out of memory — relaunch with more heap (e.g. owl-monitor up --gb 8)`
- `exitCode` — the last process exit code
- `lastError` — a human-readable cause with a remedy when known (OOM is detected and the heap fix is suggested)

For a **build** failure the server fields don't carry the compiler error — the build tail is printed by
`owl-monitor build`, and the complete output (real error header included, not just the tail) is at
`owl-monitor logs [path] --build`.

```jsonc
// owl-monitor status --json
[
  { "name": "MiddleSpace", "path": "…/MiddleSpace", "state": "Running · :3000",
    "ready": true, "url": "http://localhost:3000/", "pid": 12345, "port": 3000,
    "logPath": "…/OwlMonitor/logs/MiddleSpace-CA6AA3C8.log" }
]
```

## Memory (heap)

The heap maps to `NODE_OPTIONS=--max-old-space-size`. It is **deterministic**:

- **Auto** (default): the project's *learned* level — 4 GB to start, climbing on each out-of-memory and
  remembered — never a stale stored value. (This is the fix for the 1 GB → OOM bug.) With several
  servers running it is trimmed to an even share of the RAM left after macOS (**Settings → General →
  Memory → Share RAM between servers**): on an 8 GB Mac, 4 GB alone, 3 GB each for two, 2 GB each for
  three — never below what the project already ran out of memory at.
- **Manual**: `owl-monitor up --gb N` pins an explicit value (and turns auto off).
- Always **floored** at 2 GB and **capped at physical RAM**. If you ask for more than the machine
  has, the launch reports it: `launched X (Nuxt, 8 GB — capped from 99 GB to fit 8 GB RAM)`; when the
  shared-RAM budget trimmed it, it says so too: `launched X (Nuxt, 3 GB — shared: trimmed from 4 GB so
  the servers running fit 8 GB RAM)`.
- **OOM recovery**: a crash that looks like a V8 out-of-memory is retried once with a bigger heap; if
  it still can't fit, the server is left `Failed` with an OOM `lastError` suggesting `--gb`.

## Supervision

- **One supervised server per project**, keyed by path — several projects run at once. `up` is
  idempotent per project; `status` lists them all.
- **Hang detection**: a server that stops responding is recycled (kill tree + relaunch).
- **Crash auto-revive**: a server that *was* healthy then dies is auto-restarted with exponential
  backoff (1s, 2s, 4s), bounded to 3 attempts per stable run — and the **port is pinned** across
  restarts so it doesn't drift (3000 → 3001). A server that never became healthy (a config error) is
  left `Failed` rather than looped.
- **No port collisions**: a project with no fixed port gets a concrete free one that no sibling session
  holds or is about to bind, and keeps it across restarts while it's still free.
- **No zombie servers**: every launch is tagged `OWL_MONITOR_PROJECT=<id>:<kind>`. If Owl Monitor quits
  unexpectedly, the next launch finds the trees it left running, stops them and starts them again under
  supervision (a notification says which); a 30 s sweep catches stragglers. A leader that dies first has
  its children swept at once. Untagged processes — a server you started yourself — are never touched.
- **Idle servers** (opt-in, **Settings → General → Memory → Stop idle servers**): a dev server or preview
  with no connection from outside and no output for the chosen time is stopped, with a notification.
- A notification subsystem failure can never take the app down — supervision is crash-proof.

## Logs

Each project has its **own** dev-server log file under `~/Library/Application Support/OwlMonitor/logs/`
(`<name>-<id>.log`), retained across runs (a crash log survives the next launch). `owl-monitor logs
[path]` resolves and prints it; `-f` follows it live.

Builds get their **own** file too (`<name>-<id>.build.log`, rewritten fresh each build), holding the
**complete** build output — the in-app terminal pane and the `owl-monitor build` tail only show a
slice, so a big tool dump (e.g. a Rollup `watchFiles` object) can push the real message off the top.
`owl-monitor logs [path] --build` prints the whole thing.

## For Claude Code / agents in other terminals

Route dev servers and JS builds through the app instead of running them directly:

```bash
owl-monitor up --wait     # instead of `npm run dev` / `pnpm dev` / `nuxt dev` — blocks, prints the URL
owl-monitor build         # instead of `npm run build` (runs alongside the server); ✅/❌ + non-zero on failure
owl-monitor logs --build  # after a ❌ build: the WHOLE error, not just the printed tail
owl-monitor status --json # ready/url/pid/exitCode/lastError per project (parseable)
```

so Owl Monitor supervises each one — auto-recycle on hang, auto-revive on crash, live resource
graphs, notifications — and you keep every server under one observable place.

This is enforced machine-wide by a **Claude Code hook** that hard-blocks raw `npm run dev` /
`nuxt dev` / framework builds and points back at `owl-monitor` (with `--help` / `status --json` for the
full surface). See [`integrations/claude/`](../integrations/claude/) to install it. Because the app is
launched by LaunchServices (its environment has no `CLAUDECODE`/`AI_AGENT` vars), routing through it
also sidesteps Nuxt's agent-only dev-lock; servers are additionally spawned with `NUXT_IGNORE_LOCK=1`.

## Notes

- Editing `projects.json` by hand does **not** hot-reload — the app reads it at launch (and prunes
  entries whose folder no longer exists). Use the CLI (`up` / `remove`) instead of editing the file.
- A server you start **outside** the app is still identified in the activity table and menu-bar list
  as *project :port* (in **indigo**, vs blue for supervised ones) — but it isn't supervised: only
  servers started through Owl Monitor are health-probed, recycled and auto-revived.

<div align="center">

<img src="brand/Logo-light.png" alt="Owl Monitor" width="128">

# Owl Monitor

**A native macOS app that launches, supervises, and auto-recycles your JS/TS dev servers — so a hung Nuxt process never pins a CPU core again.**

Live resource graphs · hang detection · crash auto-revive · zero zombie servers · RAM shared fairly on 8 GB Macs · build runner · a hub every terminal routes through · Claude-powered diagnostics.

[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-000000?logo=apple&logoColor=white)](#requirements)
[![Swift 6.3](https://img.shields.io/badge/Swift-6.3-F05138?logo=swift&logoColor=white)](#requirements)
![SwiftUI · Liquid Glass](https://img.shields.io/badge/SwiftUI-Liquid%20Glass-2C7EF8)
![Claude](https://img.shields.io/badge/Claude-integrated-D97757)
[![CI](https://github.com/damiandania/Owl-Monitor/actions/workflows/ci.yml/badge.svg)](https://github.com/damiandania/Owl-Monitor/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

[Features](#features) · [Quick start](#quick-start) · [CLI](#command-line-interface) · [How it works](#under-the-hood) · [Architecture](docs/ARCHITECTURE.md)

</div>

---

Owl Monitor runs your dev servers the way a production process manager runs services: it **launches** them with the right heap, **watches** CPU/memory/health in real time, **recycles** them when they hang, **revives** them when they crash, and gives you **one place** — app, notch bar, or CLI — to see and control every server across every project.

> **Why it exists.** A doubled `npm` wrapper once left an orphaned Nuxt process listening on `:3000` but unresponsive — pinning a CPU core and dragging the whole Mac down, with nothing obvious to kill. Owl Monitor does that supervision properly and *visibly*, so it can't happen quietly again.

> **Built for small Macs.** Owl Monitor is tuned for machines where **RAM is the bottleneck** — an 8 GB Mac juggling a dev server, a production build, an editor and a browser. It actively manages that scarcity instead of leaving you to babysit Activity Monitor: heap that **autoscales** to what each project actually needs (and remembers it), heaps **shared** so several servers together still fit in RAM, idle servers **stopped** automatically if you want, dev servers **paused** to make room for a build, **no zombie servers** left holding memory, and a **pressure system** that frees RAM *before* the machine grinds to a halt or the kernel starts SIGKILLing your build.

<div align="center">
  <img src="docs/screenshots/dashboard.png" alt="Owl Monitor — a supervised dev server with live CPU / memory / swap meters and an integrated terminal" width="760" />
  <br />
  <sub>A supervised server running with live CPU / memory / swap meters and its own terminal tab — the sidebar lists every project, each with a live status dot.</sub>
</div>

---

## Features

### 🚀 Detect &amp; launch
- **Auto-detects** the package manager (npm · pnpm · yarn · bun · deno) and framework (Nuxt · Next · Astro · SvelteKit · Remix · SolidStart · Angular · Qwik · Vite · Express) per project — and launches **any** project that has a `dev` script regardless. Framework-specific env (e.g. `NUXT_IGNORE_LOCK` for Nuxt, `ASTRO_DEV_BACKGROUND=0` to keep Astro 7 in the foreground) is applied only where it belongs.
- **Launches** the dev server with a deterministic heap size (`--max-old-space-size`), streaming its log live.
- **Per-project settings** (gear on each sidebar row): **Memory / Port / Package**, each with an **Auto** toggle (on by default) — flip it off for a manual value via slider, field, or package picker.
- **Per-project environment variables** — an editor of `KEY`/`value` rows, injected (shell-safe) into the dev server, preview, build, and worker on their next launch. The app's own `PORT` / `NODE_OPTIONS` win on a name clash. Keys must be valid variable names (anything else is dropped, never passed to the shell), and **values never reach a log**: the `$ …` launch line shown in the terminal, written to disk and read by `owl-monitor logs` prints them as `•••`.
- **No port collisions** — a project without a fixed port gets a concrete free one, skipping ports its sibling projects hold or are about to bind (so two projects launched together can't both land on `:3000`), and keeps it across restarts while it's still free. "Free" is checked by asking the kernel over loopback — IPv4 *and* IPv6, so a Vite/Astro server bound only to `[::1]` counts.

### 📊 Live activity &amp; metrics
- System **CPU / Memory / Swap** bars plus an Activity-Monitor-style table showing **only** the processes with real impact.
- **Live timeline charts** (Swift Charts) — a collapsible section graphs whole-machine CPU/Memory/Swap over the last ~5 minutes, and each project's dashboard shows its supervised tree's **CPU & RAM** history (hover to read a point). Toggle with **Show timeline charts** in Settings.
- **Every supervised server is its own identified row** — *MiddleSpace :3000* in **blue** — trees are never merged. A dev server running **outside** the app is identified the same way in **purple** (*MiddleSpace :3001*) so you can tell it apart at a glance; it's shown, not supervised. Detection is **runtime-based**: *any* Node / Bun / Deno process listening on a port shows up (Express, Fastify, Nest, plain `node`, …), not just the known frameworks.
- CPU is per-core (100% = one core, like Activity Monitor); a **"% of machine"** toggle re-expresses it as a share of total capacity.
- Generic helpers (`node`, *Code Helper*) are named from each extension's own `package.json` `displayName` — e.g. *Vue (Official)*, *ESLint*, *Tailwind CSS IntelliSense*.
- **Claude Code's own shells are surfaced** — every `/bin/zsh -c` its Bash tool runs, with background **monitors** (polling loops it leaves watching for a condition) labelled apart from one-shot shells (red, Claude mark). They're **closeable** right from the table.

### 🩺 Health, recovery &amp; resilience
- **Hang detection + auto-recycle** — HTTP-probes the server; after consecutive failures it kills the whole process tree (orphans included) and relaunches.
- **Crash auto-revive** — a server that *was* healthy then dies restarts with bounded backoff (1s → 2s → 4s, capped at 3 tries per stable run), with the **port pinned** so it doesn't drift.
- **OOM autoscaling** — in **auto** mode the heap starts at 4 GB and climbs **4 → 6 → 8** on each V8 out-of-memory, and the learned level is **remembered per project** so the next launch starts there instead of replaying the crashes. The dev server and the build keep **separate** learned levels. → [`docs/HEAP-AND-BUILD.md`](docs/HEAP-AND-BUILD.md)
- **Crash-proof supervision** — a managed server (or even the notification subsystem) failing can never take the app down with it.

### 🧟 No zombie servers
A "zombie" is a server Owl Monitor started but no longer supervises — still holding its port and its RAM, invisible in the app. Both ways they appear were reproduced on a real machine, and both are closed:
- **Every process Owl Monitor starts is tagged.** Launches carry `OWL_MONITOR_PROJECT=<project>:<kind>` in their environment, and every child inherits it — so ownership is *certain*, read from the process itself, never guessed from a command line. Anything untagged (a server you started yourself, your editor) is never touched.
- **If Owl Monitor quits unexpectedly** (a crash, Force Quit), its servers keep running on their own. On the next launch it finds them, stops them, and **starts them again under supervision** — a notification says which ones were recovered. After that, the same sweep runs every 30 s as a safety net.
- **If a server's main process dies first**, its children (bundler workers, esbuild, a Next.js render worker) used to be left behind. Now the whole tree is swept the moment the leader exits — dev server, preview, build and worker alike.
- The tag is read through `KERN_PROCARGS2`, which needed two fixes to be reliable: Node's `process.title` zero-fills the argument block (hiding the environment of the `npm`/`next-server` leaders), and macOS hides the environment of Apple's own binaries entirely — so a tree whose root is `sh` or `make` is recognised through its **session** instead, which only our processes can be in.

### 🧯 Pressure response
Reclaims memory **before** the machine stalls — both when it's detected as *stuck* (CPU pinned, or memory full and swapping, for a sustained window) **and proactively around every build**:
- **Heaps share the RAM.** `--max-old-space-size` is a ceiling, not a reservation — but V8 grows a heap lazily all the way up to it before collecting hard, so three servers at the usual 4 GB add up to 12 GB of ceilings on an 8 GB Mac and macOS swaps long before any of them feels pressure. With **Share RAM between servers** (Settings → General → Memory, on by default), each launch in auto mode gets an even share of what's left after 3 GB for macOS: alone it keeps its 4 GB, two servers get **3 GB** each, three get **2 GB**. It only ever lowers a heap, never below 2 GB, and never below a level the project already ran out of memory at — an OOM escalation records that as its floor. The CLI's `up` reply says when a heap was trimmed and why.
- **Idle servers stop themselves (optional).** **Stop idle servers** (Never · 15 min · 30 min · 1 h · 2 h) stops a dev server or preview nobody is using: no browser tab connected — its page load or HMR websocket shows up as a connection the server *accepted*, while its own outbound ones (a database, an API) don't count — and no output (a request, a rebuild after you save a file). A notification says how much it freed, with a **Restart** button.
- **One click hands RAM back.** **Server → Stop N Other Servers** (⌥⌘.) stops everything except the project you're on and reports roughly how much it freed.
- **Orphaned dev processes auto-close.** A dev server detected by its real binary in argv (`…/.bin/nuxt`, `vite/bin/vite`, `next dev`, …) that isn't in the managed tree is killed (SIGTERM → SIGKILL) and a **notification** lists what was closed. The managed server, editor, and system are excluded.
- **Everything else stays a suggestion.** A sidebar panel surfaces other heavy processes — a fast **Haiku** evaluation of what's worth killing — each with a red **skull** button you press yourself. Critical processes (editor, WindowServer, Finder, daemons, Owl Monitor itself) are never suggested or auto-closed.
- **Warns before you dig the hole.** Starting a server whose heap won't fit in free RAM — or when swap is already high — posts a **low-memory warning** (it never blocks the launch, just tells you). When other servers are running, the banner has a **Stop Other Servers** button that makes the room right there. A distinct **high-swap** alert fires once when swap climbs past ~60% so you can close idle projects before the Mac starts to stutter.

### 🔨 Build runner — tuned for tight RAM
- Runs the project's build as a **separate tracked tree** with its own Activity row and terminal tab; the **Build** button becomes a red **Stop build** while running. The CLI's `build` is **synchronous** — it waits for the build and reports the exit code plus a ✅/❌ verdict (so an agent or a script gets the real result).
- **The whole build error is never lost.** Each build's complete output is mirrored to its own log file, so `owl-monitor build`'s printed tail (and a big tool dump like a Rollup `watchFiles` object that can bury the real message) never hides it: on failure the CLI prints `↳ full build log: <path>`, and `owl-monitor logs --build` prints the entire thing.
- **Pauses all active dev servers** while building (relaunching them after): on an 8 GB Mac a build running alongside a multi-GB dev server gets SIGKILLed by the kernel before it can finish.
- **Autoscales the build heap** 4 → 6 → 8 on OOM, with its **own** learned level independent from the dev server's.
- **Frees RAM around the build**: surfaces the resource advisor to close heavy non-essential apps and watches memory pressure to act **before** the kernel jetsams the build. Workers and services a build leaves behind (esbuild, Turbopack, a Next.js build worker) are swept when it ends, so the dev server relaunched next gets that RAM back. → [`docs/HEAP-AND-BUILD.md`](docs/HEAP-AND-BUILD.md)

### 🖥️ Global terminal &amp; notch bar
- **Global terminal** — one resizable panel at the bottom of the detail pane with **one tab per running server and per build, across all projects** (*icon + project name + ✕*). **Claude Code's shells and monitors get tabs too** — each tab shows the command/script it runs and a **Stop** button. Each log pane supports **native click-drag selection across many lines** and a one-click **Copy** button (with a copied ✓ confirmation) that puts the whole log on the clipboard; a search field filters it live.
- **Global Activity** — the meters and process list always reflect the whole machine, not just the selected project.
- **Notch bar** — a single black strip that extends the notch's bezel: each active project appears on the left as its favicon (or framework icon) inside a status ring — **green** online, **magenta** serving a production preview, **orange** pulsing while starting, **blue** pulsing during a build, **red** stopped/failed, **yellow** when degraded — plus a pressure warning when the machine needs attention. The live **Claude quota** — 5-hour and 7-day usage — stays on the right. Hovering it opens the controls menu: every **online server** (status · uptime · **port**, e.g. *Dev Running · 1m 24s · :3000*, with Stop/Restart), every **build** in progress, any **external** servers, a Launch button and a CPU/memory snapshot — without opening the window. (macOS hides menu-bar icons *behind* the notch, so the status glyph moved here where it's always visible, even in fullscreen.)
- **Appearance** — app-wide **Theme** (System / Light / Dark) and a separate **Terminal** theme for the log panes. A running **preview** is magenta everywhere (run button, notch, sidebar), so it's never mistaken for the dev server.
- **Motion that explains, not decorates** — one small motion system (three durations, one curve) animates *events*: a server starting pops its button, a crash shakes it, the terminal's tab indicator slides, panels rise in. Live values (meters, CPU %, uptime) deliberately don't animate — that alone once cost ~17 % of a core. Everything collapses to a plain fade under **Reduce Motion**.

### ⌨️ Server menu &amp; shortcuts
Everything acts on the project selected in the sidebar:

| Shortcut | Action | Shortcut | Action |
|---|---|---|---|
| ⌘R | Start / Restart | ⌘O | Open in Browser |
| ⌘. | Stop | ⇧⌘C | Copy URL |
| ⌥⌘. | Stop N Other Servers | ⇧⌘E | Open in Editor |
| ⌘B | Build | ⌘K | Clear Log |
| ⇧⌘P | Preview Production Build | ⌘1 – ⌘9 | Jump to a project (sidebar order) |

Plus **Reveal in Finder**, and ⌘, for Settings.

### 🔌 CLI + central hub
- Drive everything from any terminal: `owl-monitor up` (idempotent) · `build` (**synchronous**; pauses servers + frees RAM) · `status [--json]` · `stop` · `restart` · `logs -f` · `logs --build` (the full error of the last build). **One supervised server per project**, several concurrently; the CLI **auto-starts the app** if the hub isn't running. Install it in one click from **Settings → Claude Code → Install CLI** (it's bundled in the app). → [CLI reference](#command-line-interface)

### 🤖 Claude integration
- **Routes other Claude Code sessions through the app** — a global `PreToolUse` hook hard-blocks raw dev servers (`npm run dev` / `nuxt dev` / …), framework **builds**, and production **previews** (`npm run preview` / `next start` / …), redirecting each to the matching `owl-monitor` command so every terminal's servers land in one supervised place. When it blocks a build, the message also tells the agent to read the full error with `owl-monitor logs --build` — so a failing build is diagnosable, not a truncated tail. → [`integrations/claude/`](integrations/claude/)
- **Agents coordinate instead of colliding** — if a build is in flight, `owl-monitor up`/`preview` won't interrupt it: it reports the build (elapsed + ETA), and with `--wait` **queues behind it** and starts the server once the build finishes. `status --json` exposes `building` so another Claude can see and wait.
- **External alerts** — set a **Slack / Discord / incoming-webhook** URL in Settings and every notification that passes your category toggles is also POSTed there (one JSON body carries both Slack's `text` and Discord's `content`). Best-effort — a down webhook never affects supervision.
- **Live Scan** (read-only) — the Doctor **watches** Owl Monitor + the machine for a chosen window (1 / 2 / 5 min, with a progress bar), then `claude` returns a **copyable** report: what every process is and *who it belongs to*, the activity over the window, any errors/bugs (correlated to the app's own source), and concrete improvement points. Never edits anything (`--permission-mode plan`, write tools disallowed).
- **Project diagnosis** (read-only) — one click explains why a project's server or build failed, reading its config + the supervisor's failure context; the report is copyable.
- **Resource advisor** (read-only) — Claude ranks the machine's heavy processes and proposes actions. Managed processes stop with one tap; **foreign processes are only closed after explicit confirmation — never auto-killed.**

---

## Quick start

```bash
# 1. Generate the Xcode project (from the repo root, where project.yml lives) and build the app
brew install xcodegen
xcodegen generate
xcodebuild -project OwlMonitor.xcodeproj -scheme OwlMonitor -configuration Debug \
  -derivedDataPath build build

# 2. Launch it
open "build/Build/Products/Debug/Owl Monitor.app"
```

Add a project from the sidebar, hit **Launch**, and the server comes up supervised with live graphs. To drive it from a terminal instead, see the [CLI](#command-line-interface).

### Download a release (no build needed)

Grab the latest build from [GitHub Releases](https://github.com/damiandania/Owl-Monitor/releases):

1. Download **`Owl Monitor-<version>.dmg`**, open it, and drag **Owl Monitor** into **Applications**.
2. The app is **unsigned** (no Apple Developer ID yet), so Gatekeeper blocks the first launch. Either **right-click the app → Open → Open**, or clear the quarantine flag once:
   ```bash
   xattr -dr com.apple.quarantine "/Applications/Owl Monitor.app"
   ```
3. Install the CLI — **easiest:** open **Owl Monitor → Settings → General → Claude Code → Install CLI**. The `owl-monitor` binary ships inside the app; the button symlinks it into `~/.local/bin` so the CLI always matches the app. (Manual alternative, from **`owl-monitor-<version>.zip`**:)
   ```bash
   unzip owl-monitor-<version>.zip && mkdir -p ~/.local/bin && cp owl-monitor ~/.local/bin/ && chmod +x ~/.local/bin/owl-monitor
   ```
   Make sure `~/.local/bin` is on your `PATH` (the button warns if it isn't).

**Requires macOS 26 or later** (the UI uses SwiftUI / Liquid Glass). The CLI auto-starts the app when the hub isn't already running.

### Install a release build

One command builds Release, signs with a **stable local certificate**, and installs the app to `/Applications` + the `owl-monitor` CLI to `~/.local/bin`:

```bash
bash tools/install-local.sh
```

**Why the stable signature matters.** macOS ties permission grants (Downloads, Music, Automation, …) to an app's code-signing identity. A plain *ad-hoc* signature (`CODE_SIGN_IDENTITY = -`) has no stable identity, so macOS keys the grants to the cdhash — and that changes on **every** build. Result: each reinstall looks like a brand-new app and you get re-prompted for all permissions.

**The fix is a one-time setup, then it's automatic for *every* build.** Run once:

```bash
bash tools/ensure-signing-cert.sh
```

It creates a self-signed cert in your login keychain and writes a git-ignored `tools/Signing.local.xcconfig`. From then on **any** build on this machine — `tools/install-local.sh`, a plain `xcodebuild`, or Xcode's Run button — signs with that same identity (via the optional `#include?` in `tools/Signing.xcconfig`), so the app's designated requirement is stable across rebuilds. Grant the permissions once and they stick. The first build pops a single keychain dialog — click **Always Allow** and later builds sign silently.

Without that local file (CI, a fresh clone) the include is a no-op and builds stay ad-hoc, so **CI and other contributors are unaffected**. For distribution outside this Mac, sign with a Developer ID and notarize (see `tools/package-release.sh`).

---

## Command-line interface

While the app is running it hosts a local hub (Unix socket). Any terminal — or a Claude Code session — can drive it with `owl-monitor` instead of running the dev server directly.

| Command | What it does |
|---|---|
| `owl-monitor up [path] [--gb N] [--wait]` | Start + supervise a project (default: cwd). **Idempotent**; `--gb N` pins the heap; `--wait` blocks until HTTP-ready and prints the URL. If a build is running, `--wait` **queues behind it**; without `--wait` it reports the build and exits (never interrupts it). |
| `owl-monitor preview [path] [--gb N] [--wait]` | Serve the **production build** (needs a `preview`/`start` script). Same build-coordination as `up`. |
| `owl-monitor build [path]` | Build the project (synchronous; ✅/❌ + non-zero on failure); adds a build tab. On failure prints `↳ full build log: <path>` — read it all with `logs --build`. |
| `owl-monitor status [--json]` | List every known project with state + port. `--json` adds `ready` · `url` · `pid` · `exitCode` · `lastError` · `logPath` · `buildLogPath` · `building` · `buildElapsed` · `buildETA`. |
| `owl-monitor stop [path] [--all]` | Stop one server (default: cwd), or `--all`. |
| `owl-monitor restart [path]` | Relaunch from **any** state — including `Failed` / `Idle`. |
| `owl-monitor remove [path]` | Stop and **forget** the project. Aliases: `rm`, `forget`. |
| `owl-monitor logs [path] [-f]` | Print, or follow with `-f`, that project's own dev-server log. |
| `owl-monitor logs [path] --build` | Print the **whole** last build's output — the full error, not the tail. |
| `owl-monitor version` · `docs` | Version (`-v`) · help (`-h`, `--help`). |

Paths default to the current directory and resolve to absolute. Invalid input fails loudly: a non-project folder is rejected; unknown flags and a malformed `--gb` exit non-zero with a clear message. Full details — readiness semantics, heap sizing, failure diagnostics — in **[OwlMonitor/USAGE.md](OwlMonitor/USAGE.md)**.

```jsonc
// owl-monitor status --json  →  everything an agent needs to operate and self-correct
[
  { "name": "MiddleSpace", "path": "…/MiddleSpace", "state": "Running · :3000",
    "ready": true, "url": "http://localhost:3000/", "pid": 12345, "port": 3000,
    "logPath": "…/OwlMonitor/logs/MiddleSpace-CA6AA3C8.log",
    "buildLogPath": "…/OwlMonitor/logs/MiddleSpace-CA6AA3C8.build.log" }
]
```

---

## Requirements

- **macOS 26+** and **Xcode 26+** (Swift 6.3).
- [**XcodeGen**](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) to generate the project.
- The app is **not sandboxed** — it spawns processes and reads system-wide info.

---

## Architecture

A non-sandboxed SwiftUI app (`@Observable @MainActor` state) plus a small CLI target; long-running work — output streaming, sampling, health probing — runs off the main actor and hops back via `AsyncStream`. Full write-up in **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**.

```
OwlMonitor/
  App/        @main App (single Window + notch-bar HUD), AppState
  Model/      Project, AppSettings, SessionState, MetricPoint, IPCProtocol
  Store/      ProjectStore (Application Support JSON)
  Core/       Detector, DevSession (supervisor + metrics + health), ProcessTree,
              OrphanReaper (zombie servers), MemoryGuard (heap budget, idle, warnings),
              SystemSampler (+ pressure detection), BuildRunner, IPCServer,
              Notifier, ClaudeRunner, ResourceAdvisor, LegacyMigration
  Sys/        spawn.c (posix_spawn SETSID + CLOEXEC), metrics.c (libproc/mach),
              ipc.c, dm_exc.m (ObjC exception shim) + bridging header
  Views/      RootSplitView, DashboardView, GlobalTerminalView, MenuBarView,
              QuotaHUD (the notch bar), ActivityView, Components/Motion (the motion system),
              ProcessTableView, BrandMark, settings + Claude sheets
  Resources/  Assets.xcassets (AppIcon + OwlLogo + skull + github), Info.plist
owl-monitor/  CLI target (IPC client, robust arg parsing in ArgParse.swift)
brand/        The artwork: app-icon.png (the icon), mini-logo-light/dark.svg (the in-app
              OwlLogo, one per appearance), Logo-light/dark.png (the full mark, for docs),
              favicon.svg (the square badge)
```

Every brand asset is designed artwork exported into `brand/`, and the app reads it from there — nothing
is drawn in code. After re-exporting `brand/app-icon.png`, refresh every size in the asset catalog with:

```bash
swift tools/make-icon.swift
```

`brand/mini-logo-light.svg` and `-dark.svg` are the mark shown in the sidebar and Settings. The asset
catalog holds both under `OwlLogo` and picks one per system appearance, keeping them as vectors so they
stay sharp at any size.

---

## Under the hood

A few non-obvious things this codebase gets right — each found and pinned down by the headless tests in [`tests/`](tests/):

- **`zsh -lc … exec`** (login, *not* interactive) so the user's PATH/fnm resolves, while avoiding the interactive `.zshrc` (p10k/fnm) that would reparent the real shell out of our process group. `exec` makes the dev process the session leader we spawned, so the whole tree stays enumerable and killable.
- **Enumeration by session id** (`getsid` + session-scoped pid scan), robust to process-group churn — so `killpg` reaps exactly what we measure.
- **CPU timebase conversion** — `proc_pid_rusage` returns CPU time in *mach* units on Apple Silicon (not nanoseconds); scaled via `mach_timebase_info` (1:1 on Intel).
- **Spawned servers don't inherit the IPC socket** — `POSIX_SPAWN_CLOEXEC_DEFAULT` (+ `FD_CLOEXEC` on the hub sockets) means a long-lived dev server can't hold the client socket open and block a cold-launch CLI call on `read()`.
- **Nuxt's dev-lock is agent-only** — `std-env` enables it whenever `CLAUDECODE` / `AI_AGENT` is set, so it fires inside Claude Code terminals. Servers spawn with `NUXT_IGNORE_LOCK=1`, and the app's own LaunchServices environment has no agent vars, so app-spawned servers never lock.
- **Astro 7 is forced to the foreground** — from v7, `astro dev` *auto-daemonizes* (detaches to the background, parent exits 0) when it detects an AI coding agent. A supervisor that expects a long-lived foreground process would read that instant exit as a crash and relaunch in a loop, so Astro servers spawn with `ASTRO_DEV_BACKGROUND=0` — Owl Monitor *is* the background supervisor.
- **External dev servers are identified, not just listed** — argv that *looks like* a dev server is labelled *project :port* (project from the path before `/node_modules/`, port from a `proc_pidfdinfo` scan for the LISTENing socket), flagged external, and shown but never supervised.
- **Notifications can't crash the app** — `UNUserNotificationCenter` can raise an Objective-C `NSException` (which Swift can't `try`/`catch`) on a bundle the daemon rejects, so every notification call is routed through a tiny ObjC `@try/@catch` shim (`dm_try`).
- **Deterministic heap sizing** — in auto mode the heap is the project's learned level (4 GB to start, climbing on OOM), trimmed by the shared-RAM budget when other servers run; never a stale stored value, floored at 2 GB, capped at physical RAM.
- **A stale EOF can't kill a relaunched server** — each output stream only ever cancels the reader of *its own* process. Before, the old process's end-of-file could land after a fast relaunch and close the *new* server's pipe, killing it with SIGPIPE (exit 13); a fixed pre-relaunch delay had been hiding the race.
- **The hub can't be wedged** — each accepted socket gets 5 s read/write timeouts and a request line is capped at 64 KB, so a client that connects and stalls can't block every later CLI call (or the main actor, on the reply).

---

## Testing

`bash tests/run-tests.sh` is the one command that verifies the whole project, in two phases (add `--unit` to skip the slower Phase 1):

- **Phase 1 — full compile.** Regenerates the project and builds *both* targets (app + CLI), catching SwiftUI/view errors the standalone suites can't.
- **Phase 2 — headless unit suites.** Each compiles the real source files standalone with `swiftc` (no Xcode host, no GUI): **spawn** · **metrics** · **detector** · **model** · **notifications** · **sampler** · **session** · **advisor** · **sleepguard** · **charts** · **memguard** · **argparse** · **git** · **hook** · **migration** · **procsupport** · **orphans** · **ipc**. They run against real processes and sockets — e.g. `orphans` builds zombie trees the way production leaves them (own session, dead leader, an Apple-binary root) and checks the reaper finds and kills exactly those, and nothing else.

When adding a feature, prefer extracting its decision logic into a pure (ideally `nonisolated static`) function so it's unit-testable here, then add or extend a suite. The Claude integrations reuse the same read-only `ClaudeRunner.run` path and were additionally verified live against the logged-in `claude` CLI.

---

<details>
<summary><b>Development history</b> — phase log (P0 → P11)</summary>

<br />

| Phase | Summary |
|---|---|
| **P0** — Scaffold | XcodeGen project (app + CLI), persistent project sidebar, Dock icon |
| **P1** — Launch &amp; log | Detector + supervisor (`posix_spawn` session, `killpg`), log streaming, port/ready parsing, `NODE_OPTIONS` |
| **P2** — Metrics &amp; charts | Per-process CPU/mem (`libproc`), system CPU/mem (`mach`), live Swift Charts |
| **P3** — Health &amp; recycle | HTTP health probe + strike state machine + automatic tree recycle |
| **P4** — Notifications | Native notifications (crash/hang/recycle/build) with sound |
| **P5** — Build runner | Run the project's build script as a tracked tree |
| **P6** — Hub + CLI + docs | Unix-socket hub + `owl-monitor` CLI + auto-start |
| **P7** — Claude reports | Read-only **Live Scan** (timed observation → copyable report), per-project failure diagnosis, and Claude-shell/monitor identification |
| **P8** — Polish &amp; dist | App icon, MenuBarExtra, Release → /Applications, CLI → `~/.local/bin` (ad-hoc signing) |
| **P9** — Resource advisor | Claude-recommended actions on heavy processes; confirm before closing foreign |
| **P9b** — Pressure auto-kill | Stuck-machine detection → auto-closes orphaned dev processes; others surfaced via fast Haiku eval + manual skull |
| **P10** — Multi-session orchestrator | One supervised server per project (concurrent), global terminal + Activity, build alongside server, external servers identified, single main window, theming, Claude routing hook |
| **P11** — Agent-operable CLI | Deterministic heap + OOM auto-retry, path validation, restart-from-any-state, per-project logs, `up --wait`, structured `status --json`, crash-proof supervision |

</details>

---

## Contributing

Contributions are welcome. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for how to build, run the test
suites, and submit a pull request, and [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the design.
This project follows a [Code of Conduct](CODE_OF_CONDUCT.md). To report a vulnerability, see the
[Security policy](SECURITY.md).

## License

Released under the [MIT License](LICENSE) — free to use, copy, modify, and distribute, provided the copyright notice is preserved. © 2026 Damian.

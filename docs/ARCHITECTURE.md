# Architecture

_Last updated: 2026-10-13 — PR #5._

Owl Monitor is a non-sandboxed SwiftUI app (Swift 6, macOS 26 SDK) plus a small CLI target.
State is `@Observable @MainActor`; long-running work (output streaming, sampling, health probing)
runs off the main actor and hops back through `AsyncStream`/`Task { @MainActor }`.

## Layers

### Sys/ — C interop
- **`spawn.c`** — `dm_spawn_session(command, cwd, &fd)`: `posix_spawn` of `/bin/zsh -lc <command>`
  with `POSIX_SPAWN_SETSID` (own session/pgid → `killpg` reaps the whole tree) and stdout+stderr
  merged into one pipe. The dev command is built as `… exec <devcmd>` so the spawned process
  *becomes* the dev server (the session leader), not a parent shell. `-lc` is login but
  **non-interactive** (no `.zshrc`), so the Node version-manager `PATH` (fnm/nvm) is supplied by
  `ShellEnvironment` (see Core/) rather than by the shell itself.
- **`ipc.c`** — Unix-socket hub primitives (`dm_ipc_listen`/`accept`/`connect`). `listen` probes for
  a live hub before reclaiming a socket, so a second instance can't steal it from a running one;
  only a stale socket is unlinked. Every accepted socket gets 5 s read/write timeouts, so a client
  that connects and stalls can't wedge the single accept thread (or the main actor, on a reply).
- **`metrics.c`** — `libproc`/`mach` shims:
  - `dm_proc_stat_for(pid)` → cumulative CPU ns (via `proc_pid_rusage`, scaled by
    `mach_timebase_info` because rusage CPU is in mach units on Apple Silicon) + `ri_phys_footprint`.
  - `dm_system_cpu_ticks` (`host_processor_info`), `dm_system_mem` (`host_statistics64` + `sysctl`),
    `dm_load_avg` (`getloadavg`).
  - `dm_session_pids(sid)` — every pid whose session id == `sid` (robust to p10k/fnm reparenting);
    `dm_child_pids` / `dm_pgrp_pids` kept as alternatives.
  - `dm_proc_env_value(pid, key)` — one variable from another process's environment
    (`KERN_PROCARGS2`). Skips the NUL run Node's `process.title` leaves in the argv block, and
    returns `-2` (not `-1`) when the process shows no environment at all — macOS hides it for Apple
    platform binaries (`sh`, `make`) with SIP on. `dm_proc_args` and it share a per-thread 1 MB
    buffer (`kern.argmax`) instead of allocating one per call.
  - `dm_proc_cwd(pid)` — the working directory (`PROC_PIDVNODEPATHINFO`); `dm_proc_start_time(pid)` —
    start time in µs, so a (pid, start time) pair names one process for good.
  - `dm_tree_inbound_count(tree, n, excludePeer)` — connections a process tree *accepted from
    outside itself*: ESTABLISHED sockets on a port the tree LISTENs on whose peer is neither another
    process of the tree (a bundler ↔ its worker) nor `excludePeer` (Owl Monitor's own health probe).
  - `dm_memory_pressure_level()` — the kernel's `kern.memorystatus_vm_pressure_level` (1 normal ·
    2 warning · 4 critical), the signal behind Activity Monitor's memory graph.

### Core/
- **`Detector`** — reads the lockfile + `package.json` to infer package manager, framework, dev/build
  commands and default heap. Pure, headless-testable. Frameworks: Nuxt · Next · Astro · SvelteKit ·
  Remix · SolidStart · Angular · Qwik · Vite · Express · Node (the Vite-based ones are matched first).
- **`HeapScaling`** — pure heap-autoscale policy: the **4 → 6 → 8 → …** ladder (clamped to RAM) + OOM
  detection, shared by the dev server and the build. See **`docs/HEAP-AND-BUILD.md`** for the whole
  heap/build story.
- **`MemoryGuard`** — pure, headless-tested memory policy: the shared-RAM heap budget
  (`budgetedHeapGB`), idle detection (`isIdle`), recognising the server's access-log echo of Owl
  Monitor's own health probe (`probeEchoPattern`), and the launch / swap warnings.
- **`ShellEnvironment`** — resolves the user's login+interactive shell `$PATH` (where fnm/nvm/asdf
  install their shims) and exports it into the process before each launch, so the non-interactive
  spawn shell can still find `node`/`npm`. Resolved fresh per launch (fnm's per-shell dir is
  ephemeral), with a short cache and a timeout.
- **`ProcessTree`** — `sessionMembers(of:)` enumerates the supervised tree by session id. It works
  after the leader has died too (our leaders are `setsid`, so the session id *is* the leader's pid,
  and every member keeps it once reparented to launchd) — which is what lets a dead leader's
  children be found and swept.
- **`OrphanReaper`** — finds and removes *zombie servers*: trees Owl Monitor started but no longer
  supervises (it crashed or was force-quit; a leader died before its children). Ownership is certain:
  every launch carries `OWL_MONITOR_PROJECT=<project id>:<kind>` (`ProcessSupport.ownershipTag`, kind
  = dev / preview / worker / build), inherited by every descendant. `scan(supervised:)` examines
  launchd's direct children (the root of every orphaned tree ends up there; a live tree hangs off
  Owl Monitor, so a server launching right now can't look orphaned), reads each one's tag and skips
  the `<id>:<kind>` pairs that have a live runner. A root whose environment macOS hides is identified
  by its **session** instead. `AppState.sweepOrphans(recover:)` runs it at launch — reaping *and
  relaunching* what was running — and every 30 s after (reaping only). It's cheap by design: one
  process-table pass per scan, one answer per session, each process's own tag read once per lifetime
  and cached by (pid, start time); only verdicts read from the root's own environment are cached,
  since a tagged process can join a session later.
- **`DevSession`** — the heart. Per project it:
  1. **Launches** via `dm_spawn_session`; streams the merged pipe through a `DispatchSource` →
     `AsyncStream` → main-actor consumer; parses the port (`Local: …:<port>`) and ready signal.
  2. **Samples** (every 2 s): sums CPU-time deltas and memory over the session, plus system CPU/mem,
     into a rolling `[MetricPoint]` buffer for Swift Charts.
  3. **Probes health** (HTTP GET, configurable interval/strikes): on consecutive failures →
     `recycle()` (kill tree via `killpg`, relaunch with the same heap). Distinguishes a manual
     `stop()` (→ Stopped) from a crash (→ Failed) from a recycle. On every exit it sweeps the dead
     leader's whole tree.
  4. **Picks the port**: an explicit `project.port` always wins; else the last port it bound if it is
     still free; else the first free port from 3000 that no sibling session reserved
     (`AppState.reservedPorts`, recorded from the moment a launch *starts*, so two projects launched
     together can't both take 3000). "Free" is a loopback connect probe over IPv4 **and** IPv6
     (TIME_WAIT-safe, and it sees a Vite/Astro server bound only to `[::1]`).
  5. **Autoscales the heap** on an out-of-memory exit: relaunches one rung up the 4 → 6 → 8 ladder
     (`HeapScaling`), and in auto mode persists the learned level so the next launch starts there.
     The build has the same autoscaler, driven from `AppState.runBuildAndWait`. See
     `docs/HEAP-AND-BUILD.md`.
- **`SpawnedProcess`** — the single owner of the spawn → `DispatchSource` (read + exit) →
  `AsyncStream<Chunk>` plumbing. `DevSession` and `BuildRunner` consume its `chunks` and layer their
  own policy on top (port detection + health for the server, nothing extra for a build). Supporting
  primitives: `ProcessSupport` (`decodeExitCode`, `gracefulKillTree`, `nodeHeapFlag`, the ownership
  tag, and the launch-command builders `envAssignments` / `displayCommand` — see Security below),
  `LineBuffer` (`\n`-splitting with partial-line carryover), `LogNoise` (the shared shell
  session-restore filter). Each output stream cancels the reader of *its own* process only: a stale
  EOF from a previous process used to land after a fast relaunch and close the new server's pipe
  (SIGPIPE, exit 13).
- **`BuildRunner`** — a one-shot tracked build process (same spawn/stream plumbing), reporting
  success/failure. A user-initiated `stop()` is not reported as a build *failure*. Records its
  start time + duration (the latter becomes the next build's progress-bar ETA). Resolves the login
  `PATH` (`ShellEnvironment`) before spawning — like `DevSession`, so a build that runs before any
  server still finds `node` — and mirrors its **full** output (fresh per build) to
  `Project.buildLogFileURL`, so the whole error outlives the capped in-memory buffer and the CLI's
  failure tail (`owl-monitor logs --build`).
- **`WorkerRunner`** — supervises a project's long-running background **worker** (a queue/job worker,
  `tsx watch …`): same spawn/stream plumbing as the build, but no port/health — it just runs and
  reports running / stopped / crashed.
- **Preview** — serving a production build (`npm run preview` / `next start`) reuses `DevSession`
  via a `commandOverride`, so it gets the same port/health/log supervision as the dev server.
- **`PressureManager`** — the machine-pressure subsystem: the "under pressure" state, the one-shot
  auto-close of orphaned dev processes (never a process carrying the ownership tag), and the kill
  suggestions (heuristic + Haiku, refined at most once per 3 min, with a 90 s timeout). Owned by
  `AppState` via an unowned back-reference. `systemUnderPressure` follows the sampler's live *stuck*
  state — plus, during a build, any suggestions — never an in-flight evaluation. The sampler's stuck
  rule (`SystemSampler.evaluatePressure`) trips on pinned non-build CPU, or on the kernel's memory
  pressure level reaching **critical** (the old `used ≥ 90 % && swap ≥ 50 %` rule was true most of the
  day on an 8 GB Mac, and cleared only below 85 % used); the percentages remain only as a fallback
  when the level can't be read.
- **`SystemSampler`** — samples every process (~2 Hz) off the main actor and publishes only what is
  visible at display precision (meters 0.1 GB / 1 %, the process list at 1 % CPU / 1 MB — `@Observable`
  notifies on every reassignment, equal or not). Names bare runtimes by what they run:
  `runtimeName` turns a `node` / `claude` / `npm exec …` whose argv is useless (they rewrite their
  own title) into "PRYCED/app · vue-tsc", "Claude Code · Owl-Monitor" from the `.bin/<tool>` or
  package in argv, the script's file name, and the path or working directory (`dm_proc_cwd`) for the
  project; a generic folder ("app") takes its parent; with nothing else it falls back to the owning
  app ("tool (Cursor)").
- **`AsyncJob<Output>`** — a one-at-a-time cancellable async job (latest result + running flag);
  backs the Doctor's three AI analyses, which used to duplicate the guard/flag/`Task`/cancel dance.

### App/
- **`AppState`** (`@MainActor @Observable`) — the root store, split across cohesive extensions:
  `AppState+Projects` (project CRUD + the per-project setters, all funneled through one
  `mutate(_:_:)` helper), `AppState+Builds` (the pause-servers → relieve-pressure → autoscale build
  orchestration), `AppState+Memory` (the heap budget applied at launch, idle auto-stop, "Stop Other
  Servers") and `AppState+Doctor` (the three AI analyses, backed by `AsyncJob`). Every
  notification is funneled through `route(_:)`; classification/wording lives in `NotificationPolicy`.

### Model/ · Store/
- `Project` (Codable, persisted to Application Support), `SessionState` (state machine),
  `MetricPoint` (one sample). `ProjectStore` loads/saves the project list.

### Views/
- `RootSplitView` (sidebar + dashboard), `ProjectSidebar`, `LogPaneView` (an AppKit `NSTextView`-backed
  terminal log — native multi-line selection + a copy-all button, over a live ANSI-colored feed),
  `Charts/MetricsGrid`.
- **`Components/Motion`** — the whole motion vocabulary in one place: three durations (0.15 / 0.28 /
  0.4 s), one fast-settling curve, `rise` / `pop` transitions, a one-shot `shake` (failure) and `pop`
  (success), and Reduce Motion decided here (travel collapses to a fade). Live, resampling values
  (meters, CPU %, uptime) are deliberately **not** animated: that cost ~17 % of a core while idle.
- **`ActivityView`** — the meters and the process list. The list is open by default, its height is
  set by dragging the handle under it (120–640 pt, `@AppStorage`, double-click resets), and its rows
  are `Equatable` on what they draw so a sampler tick re-renders only the rows that changed.
- **`QuotaHUD`** — the notch bar. On a display without a notch it is centered at the top (the
  top-right corner is where the system's status items live). Its menu is built when it opens and
  dropped when it closes: a hosting controller keeps its SwiftUI graph live even while closed.
- **`OwlMonitorApp`** — also the **Server** menu (`ServerCommands`): start/restart ⌘R, stop ⌘.,
  stop other servers ⌥⌘., build ⌘B, preview ⇧⌘P, open in browser ⌘O, copy URL ⇧⌘C, open in editor
  ⇧⌘E, clear log ⌘K, ⌘1–9 jump to a project. Double-click a sidebar project to start/stop its server;
  double-click a terminal tab to open that project.
- **`RunControl`** is the single source of a project's run-controls (dev, worker, build, preview):
  `AppState.runControls(for:)` lists them once, and the dashboard pills (`RunControlButton` driven by
  the shared `RunStatus`), the menu-bar rows and the terminal tabs all render that one list — so
  adding a new supervised process type makes it appear in every surface (and the menu-bar health
  glyph) automatically. `RunTimerBar` shows a server/worker uptime or a build's elapsed + ETA in the
  terminal pane.

## Security notes

- **Launch commands.** A project's env vars are spliced into the `zsh -lc` command line. Values are
  single-quoted; keys can't be, so only valid POSIX names are emitted (`isValidEnvKey`) and anything
  else is dropped. The `$ …` header each runner logs — to the in-app terminal, the on-disk log and
  `owl-monitor logs` — shows values as `•••` (`displayCommand`), because those logs are read by
  coding agents.
- **Claude calls.** The model id (read from `settings.json`) is passed as a positional parameter, never
  interpolated into the script; the CLI's stderr goes to `/dev/null` rather than an unread pipe (a
  chatty run filled it and hung the Doctor).
- **IPC.** Socket mode 0600 + `LOCAL_PEERCRED` uid check; a request line is capped at 64 KB and each
  accepted socket has 5 s timeouts.

## Concurrency model

- `DevSession` is `@MainActor @Observable`. Background producers (pipe reader, process-exit
  watcher) are `DispatchSource` handlers — now owned by `SpawnedProcess` — that capture **only
  Sendable values** and feed an `AsyncStream<Chunk>`; a single `@MainActor` task consumes and
  mutates state. Sampling and health run as `@MainActor` tasks with `Task.sleep`, cancelled on
  stop/recycle.

## Why these choices

See the "Technical notes" in the README — the `zsh -lc + exec`, session-id enumeration, and
mach-timebase fixes were each found via the headless tests in `tests/`.

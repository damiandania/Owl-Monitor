# Heap autoscaling & the build pipeline

This is the single page to read to understand how Owl Monitor decides **how much memory
(`--max-old-space-size`) to give a project**, how it **autoscales on out-of-memory**, how the
**build** runs, and how all of it is **persisted**. Start here; the file/line pointers at the end
take you to the code.

---

## 1. The problem it solves

A Node dev server or production build crashes with a *JavaScript heap out of memory* (V8 exit code
6) when its heap is too small. The right heap depends on the project and isn't known up front. Owl
Monitor handles this automatically: it **starts small, climbs on OOM, and remembers** the level that
worked — separately for the dev server and the build.

---

## 2. The heap injected at launch

Every project carries, in `Project` (persisted), **two independent heap configs** — one for the dev
server, one for the build. Each is either **manual** (a fixed GB value) or **auto** (managed by the
OOM autoscaler):

| Concern | Manual value | Auto level (learned) | Auto flag |
|---------|--------------|----------------------|-----------|
| Dev server | `memoryGB` | `autoHeapGB` | `memoryAuto` |
| Build | `buildMemoryGB` | `buildAutoHeapGB` | `buildMemoryAuto` |

The effective heap is computed by `Project.effectiveMemoryGB` (dev) and
`Project.effectiveBuildMemoryGB` (build):

```
effective = clamp( auto ? learnedLevel : manualValue ,  min = 2 GB ,  max = physical RAM )
```

It is injected as `NODE_OPTIONS=--max-old-space-size=<GB×1024>` by the launcher — `DevSession.start`
for the server, `BuildRunner.start` for the build.

> **The dev server and the build are independent.** A heavy production build can sit at 8 GB while
> the dev server stays at 4 — they never share a value.

### The shared-RAM budget (dev server and preview only)

`--max-old-space-size` is a *ceiling*, not a reservation, but V8 lets a heap grow lazily all the way
to it before collecting hard. Three servers at the usual 4 GB add up to 12 GB of ceilings on an 8 GB
Mac, so macOS swaps long before any one of them feels pressure. In **auto** mode (and with
**Settings → General → Memory → Share RAM between servers** on, the default) each launch therefore
gets an even share of what is left after a macOS reserve — `AppState.launchHeapGB` →
`MemoryGuard.budgetedHeapGB`:

```
reserve = max(3 GB, RAM / 4)                      # 3 GB on an 8 GB Mac
share   = round( (RAM − reserve) / (otherRunningServers + 1) )
launch  = max( floor,  min( learnedLevel, share ) )
```

| 8 GB Mac | servers running | each launch gets |
|---|---|---|
| alone | 0 others | 4 GB (its learned level) |
| two | 1 other | 3 GB |
| three | 2 others | 2 GB |

- It only ever **lowers** a heap — never above the learned level, never below the **floor**.
- The floor is what the project has *proven* it needs: `Project.heapFloorGB`, set by
  `AppState.recordHeapEscalation` whenever the OOM autoscaler climbs (`Project.devHeapFloorGB` /
  `previewHeapFloorGB` also treat an already-climbed learned level as proof). An OOM at 3 GB
  therefore raises the floor to the next rung, and the budget can't squeeze it back.
- Manual heaps, and **builds**, are never budgeted — a build runs with the other servers paused.
- A preview runs on the build level (see above) and is budgeted against the build floor.
- `owl-monitor up` / `preview` report the heap the server actually got
  (`DevSession.lastMemoryGB`) and say when it was trimmed
  (`— shared: trimmed from 4 GB so the servers running fit 8 GB RAM`).

---

## 3. The autoscaler — 4 → 6 → 8

All scaling policy lives in one place: **`HeapScaling`** (`Core/HeapScaling.swift`).

- **Ladder:** `steps = [4, 6, 8, 12, 16, 24]`, clamped to physical RAM — so on an 8 GB Mac it is
  4 → 6 → 8, while a bigger Mac keeps climbing. A project with no learned level yet starts at
  `firstGB = 4`.
- **`next(after:systemGB:)`** → the next step above the current heap that still fits physical RAM
  (ceiling = `min(24, RAM)`), or `nil` at the top.
- **`looksLikeOOM(logLines:exitCode:)`** → `true` if the exit code is 6 (V8 `FatalProcessOutOfMemory`)
  **or** the tail of the log contains a heap message (`heap out of memory`, `javascript heap`,
  `reached heap limit`, `allocation failed`). Robust to the exit code, which varies (SIGABRT 134,
  Nuxt 6, …).

### Dev server (`DevSession`)
On process exit, if it `looksLikeOOM` and there's a higher step, the session relaunches with that
step (`biggerHeap()` → `HeapScaling.next`). Each OOM climbs one rung; at 8 GB there's no higher rung,
so it falls through to the normal crash path. **In auto mode the new level is persisted** via the
`onHeapEscalated` callback → `AppState.recordHeapEscalation` (learned level **and** the budget
floor) → `projects.json`. The log is cleared on each
relaunch, so a stale OOM message can't trigger a second climb — only a *fresh* OOM does.

### Build (`AppState.runBuildAndWait`)
**First, the build pauses ALL active dev servers** (not just this project's — even another project's
server can starve the build on a small machine) and relaunches them after — deferred via a Task with
a short settle delay so it doesn't race the just-paused sessions' state transitions. This frees RAM:
on a RAM-starved Mac, a build running alongside a multi-GB dev server gets **SIGKILLed by the kernel**
before V8 reaches its own limit — which fails the build *and* defeats the autoscaler, because a
kernel SIGKILL is not a clean V8 OOM. With the servers paused the build gets the RAM, so a genuine
heap shortfall surfaces as a **clean V8 OOM (exit 6)** the autoscaler can act on. (Verified:
MiddleSpace built alongside its server → SIGKILL, no scaling; with the server paused → clean OOM at
4 GB → scaled to 6 GB → completed. Note: 8 GB RAM is marginal for a heavy build — the final Nitro
prerender phase can still be SIGKILLed by the kernel even at 6 GB; that's physical RAM, not heap, so
raising the heap wouldn't help.)

The build is a one-shot process (`BuildRunner`), so the **retry loop lives in `AppState`**: run the
build, and if it failed **and** the build is in auto mode **and** it `looksLikeOOM` **and** there's a
higher step → persist the next level (`setBuildAutoHeapGB`) and run again with the bigger heap. The
loop ends on success, on a non-OOM failure, in manual mode, or at the 8 GB ceiling. `runBuild` (the
UI Build button) just kicks off this same loop in a `Task`.

### RAM relief around the build (small-Mac survival)
8 GB is marginal for a heavy build (the final Nitro prerender spawns a *second* Node process), and
the kernel jetsams (SIGKILLs) the build once **swap** fills up. So besides pausing the dev servers,
the build also:
1. **Surfaces the resource advisor** (`PressureManager.evaluate`) so the heaviest non-essential apps
   can be closed (user-confirmed, never automatic), and auto-closes orphaned dev processes.
2. **Watches memory pressure during the build** (a Task polling `systemMemPercent` every 5 s): above
   ~85 % used it re-runs the advisor, acting **before** the kernel jetsams the build. Claude's part
   of that is throttled to once per 3 minutes inside `PressureManager`.
3. **Sweeps what the build leaves behind** when it ends (`BuildRunner.finish` →
   `ProcessSupport.gracefulKillTree`): bundler workers and services (esbuild, Turbopack, a Next.js
   build worker) can outlive the build's leader, and a leftover one holds the RAM the relaunched dev
   server needs.

> **What was removed, and why.** Builds used to `purge` the system memory cache and inject
> `--optimize-for-size`. Neither ever worked: `/usr/sbin/purge` (like `memory_pressure -S`) needs
> root and exits "Operation not permitted" for a normal app, so it only spawned a failing process;
> and V8 flags such as `--optimize-for-size` are **rejected** in `NODE_OPTIONS` ("not allowed in
> NODE_OPTIONS") and make Node exit immediately (code 9), failing every build. Only
> `--max-old-space-size` is injected. A user-level app can't make macOS drop its caches — the real
> levers are stopping processes (the paused servers, the advisor) and the shared-RAM budget above.

> **"Remembers the level that worked."** Because each climb is persisted *before* the retry, the
> learned level only ever goes up, and the next launch/build starts there instead of replaying the
> OOMs. It starts back at 4 only for a brand-new project (or one the user resets to a lower manual
> value).

---

## 4. Persistence — survives reinstalls

Everything is stored in **`~/Library/Application Support/OwlMonitor/projects.json`** (one JSON array
of `Project`), written by `ProjectStore.save` on every `AppState.persist()`. This path is **outside**
the `.app` bundle, so replacing `/Applications/Owl Monitor.app` with a new build **does not** touch
it — project config (including learned heap levels) carries across upgrades.

**Backward/forward compatible decoding** (`Project.init(from:)`): every field added over time is read
with `decodeIfPresent ?? default`, so an old `projects.json` still loads. The build-heap fields
default by **inheriting the dev config** of an existing project (`buildMemoryGB ?? memoryGB`,
`buildMemoryAuto ?? memoryAuto`) — so a project the user already tuned keeps that heap for the build
too — and the learned levels default to `firstGB` (4).

`persist()` is called on every change: the settings UI setters, the IPC `--gb` override, and each
autoscaler climb (`recordHeapEscalation` for the dev server, `setBuildAutoHeapGB` for the build).
`heapFloorGB` is optional and absent from older files (decoded as `nil`).

---

## 5. The build CLI is synchronous

`owl-monitor build [path]` **waits** for the build (including all autoscale retries) and prints the
tail of its output plus a verdict (`✅ build succeeded` / `❌ build failed`), exiting non-zero on
failure — instead of returning immediately with "building …". This lets a caller (or an agent) see
the real result.

How: the hub handler (`IPCServer.handle`, `case "build"`) is `async` and awaits
`AppState.runBuildAndWait`; when the build (and its retries) finish it writes the tail of the log
(40 lines on success, 200 on failure) as `ok` messages, then — on failure — the build-log path
(`↳ full build log: <path>`), then an `ok`/`error` verdict, and closes the socket. The CLI reads the
socket to EOF, prints each message, and exits non-zero on the trailing `error`.

**The whole error is never truncated away.** A tail can bury the real message under a big tool dump
(e.g. a Rollup `watchFiles` array of every server module). So `BuildRunner` also mirrors every build —
fresh per run — to `<name>-<id>.build.log` next to the dev-server log; it's exposed as `buildLogPath`
on `status` and printed in full by **`owl-monitor logs [path] --build`**. `BuildRunner` resolves the
login `PATH` (`ShellEnvironment`) before spawning, like `DevSession`, so a build that runs before any
server on a fresh app launch still finds `node` (no `exit 127`).

> The `--build` reader and `buildLogPath` field touch the CLI + shared `IPCProtocol`, so they *do*
> need the CLI rebuilt — but the CLI now ships **inside the app bundle** and is symlinked into
> `~/.local/bin` (Settings → Claude Code → **Install CLI**), so a fresh app build keeps them in lockstep.

---

## 6. The settings UI

`AppSettingsView` → per-project pane → **Server** section shows two heap rows:

- **Memory** — the dev-server heap (`memoryAuto` / `memoryGB`).
- **Build memory** — the build heap (`buildMemoryAuto` / `buildMemoryGB`), independent.

Each row is the shared `row(...)` helper: an **Auto** toggle on the right; when Auto is on it shows
the effective GB (the learned level), when off a manual GB picker. Bindings go through
`AppState.setBuildMemoryAuto` / `setBuildMemoryGB`. The row shows the *learned* level; what a launch
actually gets can be lower while other servers run (see the shared-RAM budget).

**Settings → General → Memory** holds the app-wide switches: the default heap for new projects,
**Share RAM between servers** (`AppSettings.shareHeapBudget`, on by default — its caption works out the
numbers for this Mac) and **Stop idle servers** (`AppSettings.idleStopMinutes`: never / 15 / 30 / 60 /
120 min; off by default). Idle means no connection from outside and no output — see
`AppState+Memory.checkIdleServers` in ARCHITECTURE.md.

---

## 7. How to verify it

- **Migration:** open a `projects.json` written by an older build, launch the app, change any
  setting (forces a save), and confirm the new fields appear (`autoHeapGB`, `buildMemoryGB`,
  `buildMemoryAuto`, `buildAutoHeapGB`).
- **Build autoscaling:** put a memory-heavy project's *build* in auto with `buildAutoHeapGB: 4`, run
  `owl-monitor build <path>`, and watch `buildAutoHeapGB` climb 4 → 6 → 8 in `projects.json` (it's
  re-written on each climb). On an 8 GB Mac a project that needs >8 GB will OOM at every rung and end
  in failure — that still **demonstrates** the ladder + persistence (the stored level reaches 8).
- **Dev autoscaling:** same idea with `memoryAuto: true`; an OOM relaunch bumps `autoHeapGB`.

---

## 8. Key files

| File | Role |
|------|------|
| `OwlMonitor/Core/HeapScaling.swift` | The ladder (4→6→8→…, clamped to RAM) + OOM detection. Single source of policy. |
| `OwlMonitor/Core/MemoryGuard.swift` | Pure memory policy: `budgetedHeapGB` / `reservedGB`, `isIdle`, probe-echo matching, launch/swap warnings. |
| `OwlMonitor/App/AppState+Memory.swift` | `launchHeapGB` (applies the budget at launch), idle auto-stop, the "Stop Other Servers" notification action. |
| `OwlMonitor/Model/Project.swift` | The heap fields (incl. `heapFloorGB`), Codable retro-compat, `effectiveMemoryGB` / `effectiveBuildMemoryGB`, the floors. |
| `OwlMonitor/Core/DevSession.swift` | Dev-server launch + OOM relaunch (`biggerHeap`, `onHeapEscalated`). |
| `OwlMonitor/Core/BuildRunner.swift` | One-shot build process; injects the heap, captures exit code + log. |
| `OwlMonitor/App/AppState.swift` | `launch`, `runBuild`/`runBuildAndWait` (build retry loop), the setters that persist. |
| `OwlMonitor/Core/IPCServer.swift` | Hub; the synchronous `build` handler. |
| `OwlMonitor/Views/AppSettingsView.swift` | The Memory / Build memory rows. |
| `OwlMonitor/Store/ProjectStore.swift` | Load/save `projects.json` in Application Support. |

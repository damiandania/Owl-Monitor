# Decisions

Dated, append-only log of technical decisions: the pattern chosen, the workaround, the constraint —
and why. Never rewrite an entry; supersede it with a new one. Started 2026-10-13 (PR #5) and backfilled
with the decisions of PRs #3–#5.

## Supervision

- **2026-10-13 — Ownership by environment tag, not by command line.** Every launch carries
  `OWL_MONITOR_PROJECT=<project id>:<kind>`; descendants inherit it. A process wearing it is certainly ours,
  so zombie cleanup can't hit a server the user started by hand. Command-line matching was the alternative
  and was rejected: it misfires on editors and language servers that merely mention a framework.
- **2026-10-13 — Orphans are looked for among launchd's direct children only.** The root of every orphaned
  tree ends up there; a live tree hangs off Owl Monitor, so a server launching right now can't be mistaken for
  an orphan.
- **2026-10-13 — Roots with a hidden environment are identified by session.** macOS hides the environment
  of Apple platform binaries (`sh`, `make`) with SIP on (`dm_proc_env_value` → `-2`). Every tree we spawn
  has its own session (`setsid`) and membership is only inherited, so a tagged member proves the root is ours.
- **2026-10-13 — Only verdicts from a root's own environment are cached** (by pid + start time). A verdict
  derived from the session can change when a tagged process joins later, so it is recomputed. A pid alone is
  never a key: pids are reused.
- **2026-10-13 — A dead leader's tree is swept on every exit** (dev, preview, build, worker). SIGKILL on a
  leader never reaches its children; `ProcessTree.sessionMembers` falls back to the leader's pid as the
  session id when the leader is gone.
- **2026-10-13 — Each output stream cancels only its own process's reader.** A stale EOF from the previous
  process, landing after a fast relaunch, closed the new server's pipe (SIGPIPE, exit 13). It was hidden by a
  fixed pre-relaunch delay until that delay was removed.
- **2026-10-13 — Ports are reserved when a launch starts, and "in use" is a loopback connect probe** over IPv4
  and IPv6. Reserving from the *bound* port left a window in which two projects launched together both took
  :3000; an fd-table walk couldn't see other users' processes or IPv6-only listeners.
- **2026-10-13 — `purge` and `--optimize-for-size` were removed.** `purge` needs root (a silent no-op for an
  app); V8 flags other than `--max-old-space-size` are rejected in `NODE_OPTIONS` and make Node exit at once.

## Memory (8 GB Macs)

- **2026-10-13 — Shared-RAM heap budget.** Auto-mode launches get `round((RAM − reserve) / (others + 1))`,
  reserve = `max(3 GB, RAM / 4)`, never above the learned level and never below the proven floor
  (`Project.heapFloorGB`, set by OOM escalation). `--max-old-space-size` is a ceiling V8 grows into lazily, so
  ceilings summing past RAM are what push the machine into swap. Builds are not budgeted (other servers are
  paused for them).
- **2026-10-13 — Idle means no connection from outside and no output.** Connections are counted per process
  *tree* and exclude the tree's own loopback traffic (node ↔ workerd) and Owl Monitor's keep-alive health
  probe; the access-log line a server prints for that probe doesn't count as output (`MemoryGuard
  .probeEchoPattern`). Without both exclusions a server never went idle. Off by default.
- **2026-10-13 — Memory pressure is the kernel's level, not `used %`.** `kern.memorystatus_vm_pressure_level`
  == critical trips the stuck state and anything below clears it. `used ≥ 90 % && swap ≥ 50 %` was true most of
  the day on an 8 GB Mac (the compressor counts as used, and swap stays full after a peak). The percentages
  survive only as a fallback when the level can't be read.
- **2026-10-13 — The pressure alert follows live state.** `systemUnderPressure` = stuck, or (during a build)
  suggestions exist. An in-flight Claude evaluation or leftover suggestions no longer count; the refinement has
  a 90 s timeout and its answer is dropped if no longer wanted.

## Security

- **2026-10-13 — Env var keys are validated, values are redacted in logs.** Keys can't be shell-quoted, so only
  POSIX names are emitted; the logged launch line prints values as `•••` because the logs are read by agents.
- **2026-10-13 — The Claude model id is a positional parameter (`"$1"`)**, never interpolated; its stderr is
  discarded, not piped unread (a chatty run filled the pipe and hung the Doctor).
- **2026-10-13 — The IPC hub bounds its input.** 64 KB per request line; 5 s read/write timeouts per accepted
  socket.

## UI and performance

- **2026-10-13 — Only events animate, never resampling values.** One motion vocabulary (`Motion.swift`);
  animating meters / CPU % / uptime cost ~17 % of a core while idle.
- **2026-10-13 — A card's shadow belongs to its background shape**, not the card: derived from the content's
  alpha it re-rasterized and re-blurred the whole card on every content change (~18 % CPU idle).
- **2026-10-13 — Publish observed state only when it changes at display precision.** `@Observable` notifies on
  every reassignment, equal or not; the process list now follows the same rule as the meters.
- **2026-10-13 — Rows are `Equatable` on what they draw**; a stored closure is never equal to another, which
  re-rendered every row on every tick.
- **2026-10-13 — The notch menu is built on open and dropped on close.** A hosting controller keeps its
  SwiftUI graph live while the popover is closed.
- **2026-10-13 — The tab strip's scrollers are forced off through KVO on the `NSScrollView`.**
  `.scrollIndicators(.hidden)` is ignored on macOS with a mouse attached, and SwiftUI re-applies its own
  scroller settings after a one-time fix.
- **2026-10-13 — Panel overshoots the screen top by 2 pt.** With the shape's top edge exactly on the screen
  edge, the top physical pixel row stayed uncovered (a hairline of wallpaper over the notch bar).
- **2026-10-13 — On a display without a notch, the bar is centered at the top**, not pinned to the corner where
  the system's status items are.
- **2026-10-13 — Bare runtimes are named from argv + working directory** (`SystemSampler.runtimeName`, pure):
  `claude` and `node` rewrite their title, so argv alone says nothing. A generic folder name ("app") takes its
  parent; with nothing else it falls back to the owning app.
- **2026-10-13 — The quota readout lets numbers win over error text.** `claude -p '/usage'` also runs the
  user's hooks, whose failures print into the same output; a missing CLI is `command not found: claude` /
  `claude: command not found` or exit 127 — never another program's.
- **2026-10-13 — Saved Claude model ids migrate to the same tier** (`AppSettings.currentModel`), so a retired
  id can't leave the picker blank or make every call fail.

## CLI for other programs

- **2026-10-14 — `awake add` extends rather than resets.** Adding to a running keep-awake pushes its deadline out
  without releasing the IOKit assertions (a release-and-retake could let the Mac sleep in between); on an
  indefinite one there is nothing to add. The reply is the state AFTER the action.
- **2026-10-14 — `quota` hides numbers when a provider is unusable**, as the notch does, and says why in `error`.
  Windows are classified by length (<= 1 day session, 6-8 days weekly) and anything else goes to `other` instead of
  being mislabelled — Codex's free plan reports a 30-day window. The Codex monitor starts on the first `quota` call
  (once, then self-refreshing) because it otherwise only runs when the notch is switched to GPT.
- **2026-10-14 — The notch's provider lives in `AppState`.** `shownQuotaSource` is the one source of truth for clicking the
  notch and `quota show|toggle`; the notch controller only redraws on `quotaSourceDidChange`. It was a private field of the
  controller, so nothing outside the view could read or set it. Still session-only (not persisted), as before.
- **2026-10-14 — The launch ETA is the median of the last 5 launches, and progress is split at the URL line.** One slow launch (first
  after a reboot, machine busy) would skew a last-value ETA; the median ignores it. `LaunchTiming.progress` runs elapsed/ETA but, when the
  moment the server prints its URL is known (stored per launch, median of 5), splits the bar there — a long compile followed by a quick
  finish no longer crawls then jumps. Capped at 0.95 so a long launch never shows 100 % before `ready`. CPU activity was rejected as a
  signal: noisy, and the URL line says more. The computed value is exposed (`launchProgress`) so clients don't reimplement it.
- **2026-10-14 — Port detection ignores command-echo lines** (`> …` from npm/pnpm, `$ …` from yarn). A URL inside a script (a `wait-on`
  target, a proxy) was taken for the port the server bound — and, found while timing launches, for the "URL printed" milestone.
- **2026-10-14 — A launch is timed to the first HTTP probe that answers, and only then.** A launch that crashes, is stopped, or
  is merely "assumed up" by the warm-up fallback records nothing, so a failed launch can't poison the ETA. Dev and preview are
  stored separately (`lastLaunchSeconds`, `lastPreviewLaunchSeconds`). `launchElapsed` exists only while *Launching…*: during a
  *Recycling…* back-off no launch is under way yet.
- **2026-10-14 — Force-close reaps by ownership tag only.** `stop --force` drops the project's runners (so it reads
  Idle and leaves the notch) and reaps tagged leftovers of that project; it never goes by folder or command line, so
  editors, terminals and Claude sessions there are safe. It is not `remove`.
- **2026-10-14 — `iconPath` shares the app's resolver.** `ProjectIconView.faviconPath` is what the window uses to pick
  a favicon, so the CLI and the app can't disagree.

## Tests

- **2026-10-13 — Suites poll with a bound instead of sleeping fixed times.** The orphan and session suites
  flaked at load average ~16; reparenting to launchd and log streaming take as long as the machine allows.
- **2026-10-13 — Platform-binary env visibility is checked, not assumed.** CI runners run with SIP off, where
  `/bin/sleep`'s environment is readable.

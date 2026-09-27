#!/usr/bin/env bash
# Owl Monitor test system — verifies the whole project still works:
#   Phase 1 — the app + CLI actually compile (catches SwiftUI/view errors the unit suites can't).
#   Phase 2 — headless unit suites for the C shims and the pure logic (fast, no Xcode host).
#
# Usage:
#   bash tests/run-tests.sh          # full check (build + units)
#   bash tests/run-tests.sh --unit   # units only (skip the slow build phase)
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/OwlMonitor"
SYS="$SRC/Sys"
HDR="$SYS/OwlMonitor-Bridging-Header.h"
BIN="$(mktemp -d)"
export SHELL_SESSIONS_DISABLE=1
fail=0
UNIT_ONLY=0
[ "${1:-}" = "--unit" ] && UNIT_ONLY=1

# ── Phase 1: full compile of both targets ───────────────────────────────────
if [ "$UNIT_ONLY" = 0 ]; then
  echo "── Phase 1: build app + CLI ────────────────────"
  ( cd "$ROOT" && xcodegen generate ) >/dev/null 2>&1
  for scheme in OwlMonitor owl-monitor; do
    if ( cd "$ROOT" && xcodebuild -project OwlMonitor.xcodeproj -scheme "$scheme" \
           -configuration Debug -derivedDataPath build build ) >"$BIN/build-$scheme.log" 2>&1; then
      echo "PASS $scheme compiles"
    else
      echo "FAIL $scheme build:"
      grep -E "error:" "$BIN/build-$scheme.log" | grep -v CoreSimulator | head
      fail=1
    fi
  done
  echo ""
fi

# ── Phase 2: headless unit suites ───────────────────────────────────────────
echo "── Phase 2: unit suites ────────────────────────"
build_run() {
  local name="$1"; shift
  echo "=== $name ==="
  if swiftc "$@" -o "$BIN/$name" 2>"$BIN/$name.err"; then
    "$BIN/$name" || fail=1
  else
    echo "COMPILE FAILED:"; grep -E "error:" "$BIN/$name.err" | head; fail=1
  fi
  echo ""
}

build_run spawn    "$ROOT/tests/spawn/main.swift" "$SYS/spawn.c" -import-objc-header "$HDR"
build_run metrics  "$ROOT/tests/metrics/main.swift" "$SYS/metrics.c" "$SYS/spawn.c" -import-objc-header "$HDR"
build_run detector "$ROOT/tests/detector/main.swift" "$SRC/Model/Project.swift" "$SRC/Core/Detector.swift" \
  "$SRC/Core/HeapScaling.swift"
build_run model    "$ROOT/tests/model/main.swift" "$SRC/Model/Project.swift" "$SRC/Core/Detector.swift" \
  "$SRC/Model/AppSettings.swift" "$SRC/Core/AppLog.swift" "$SRC/Core/HeapScaling.swift" \
  "$SRC/Core/JSONFileStore.swift" "$SRC/Store/ProjectStore.swift"
build_run notifications "$ROOT/tests/notifications/main.swift" \
  "$SRC/Model/NotificationItem.swift" "$SRC/Model/SupervisionEvent.swift" \
  "$SRC/Model/AppSettings.swift" "$SRC/Core/NotificationPolicy.swift" "$SRC/Core/AppLog.swift" \
  "$SRC/Core/JSONFileStore.swift" "$SRC/Model/PersistedEvent.swift" "$SRC/Core/EventStore.swift" \
  "$SRC/Core/WebhookNotifier.swift"
build_run sampler  "$ROOT/tests/sampler/main.swift" "$SRC/Core/SystemSampler.swift" \
  "$SRC/Core/ResourceAdvisor.swift" "$SRC/Core/ClaudeRunner.swift" \
  "$SRC/Model/SystemMetricPoint.swift" "$SRC/Core/MetricChartMath.swift" \
  "$SYS/metrics.c" "$SYS/spawn.c" -import-objc-header "$HDR"
build_run session  -enable-bare-slash-regex "$ROOT/tests/session/main.swift" \
  "$SRC/Model/Project.swift" "$SRC/Model/SessionState.swift" "$SRC/Model/MetricsSample.swift" \
  "$SRC/Model/SupervisionEvent.swift" \
  "$SRC/Core/Detector.swift" "$SRC/Core/ProcessTree.swift" "$SRC/Core/DevSession.swift" \
  "$SRC/Core/ShellEnvironment.swift" "$SRC/Core/HeapScaling.swift" \
  "$SRC/Core/BuildRunner.swift" "$SRC/Core/WorkerRunner.swift" "$SRC/Core/ANSI.swift" "$SRC/Core/AppLog.swift" \
  "$SRC/Core/ProcessSupport.swift" "$SRC/Core/LineBuffer.swift" "$SRC/Core/LogNoise.swift" \
  "$SRC/Core/SpawnedProcess.swift" "$SRC/Core/LogFilter.swift" \
  "$SYS/metrics.c" "$SYS/spawn.c" -import-objc-header "$HDR"
build_run advisor "$ROOT/tests/advisor/main.swift" \
  "$SRC/Core/ResourceAdvisor.swift" "$SRC/Core/ClaudeRunner.swift"
build_run sleepguard "$ROOT/tests/sleepguard/main.swift" "$SRC/Core/SleepGuard.swift"
build_run charts "$ROOT/tests/charts/main.swift" "$SRC/Core/MetricChartMath.swift"
build_run memguard "$ROOT/tests/memguard/main.swift" "$SRC/Core/MemoryGuard.swift"
build_run argparse "$ROOT/tests/argparse/main.swift" "$ROOT/owl-monitor/ArgParse.swift"
build_run git    "$ROOT/tests/git/main.swift" "$SRC/Core/GitInfo.swift"
build_run hook   "$ROOT/tests/hook/main.swift" "$SRC/Core/ClaudeHookInstaller.swift"
build_run migration "$ROOT/tests/migration/main.swift" "$SRC/Core/LegacyMigration.swift" \
  "$SRC/Core/ClaudeHookInstaller.swift" "$SRC/Core/CLIInstaller.swift" "$SRC/Core/AppLog.swift"
build_run procsupport "$ROOT/tests/procsupport/main.swift" "$SRC/Core/ProcessSupport.swift" \
  "$SRC/Core/ProcessTree.swift" "$SRC/Model/Project.swift" "$SRC/Core/Detector.swift" \
  "$SRC/Core/HeapScaling.swift" "$SYS/metrics.c" "$SYS/spawn.c" -import-objc-header "$HDR"
build_run orphans "$ROOT/tests/orphans/main.swift" "$SRC/Core/OrphanReaper.swift" \
  "$SRC/Core/ProcessSupport.swift" "$SRC/Core/ProcessTree.swift" "$SRC/Model/Project.swift" \
  "$SRC/Core/Detector.swift" "$SRC/Core/HeapScaling.swift" "$SYS/metrics.c" "$SYS/spawn.c" \
  -import-objc-header "$HDR"
build_run ipc    "$ROOT/tests/ipc/main.swift" "$SRC/Core/IPCIO.swift" "$SRC/Model/IPCProtocol.swift" \
  "$SYS/ipc.c" -import-objc-header "$HDR"

echo "────────────────────────────────────────────────"
[ "$fail" = 0 ] && echo "✅ ALL CHECKS PASSED" || echo "❌ SOME CHECKS FAILED"
exit $fail

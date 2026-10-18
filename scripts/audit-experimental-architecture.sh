#!/bin/sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

pass() { printf 'PASS %s\n' "$1"; }

# 1-2. Bounded multi-threaded scheduling with priorities and observability.
grep -q 'TaskPriority::Interactive' src/systembackend.cpp
grep -q 'TaskPriority::Background' src/systembackend.cpp
grep -q 'queue_\.size() >= maxPendingTasks_' src/runtime/task_scheduler.cpp
grep -q 'peakPendingTasks_' src/runtime/task_scheduler.cpp
! grep -q 'QtConcurrent' src/systembackend.cpp
! grep -q 'QFutureWatcher' src/systembackend.h
pass scheduler

# 3. One foreground user app; QML pages are destroyed on pop and external
# sessions conflict with the shell so they cannot render concurrently.
grep -q 'beginForegroundApp' qml/Main.qml
grep -q 'endForegroundApp' qml/Main.qml
test "$(grep -c 'StackView.destroyOnPop = true' qml/Main.qml)" -eq 3
grep -q 'StackView.onRemoved' qml/apps/PvZApp.qml
grep -q 'cachedSettings.StackView.destroyOnPop = false' qml/Main.qml
grep -q '^Conflicts=meow-os.service' systemd/meow-mindustry.service
pass foreground-session

# 4. Portable policy/HAL contracts may not depend on Qt or a concrete SoC.
grep -q 'class IDisplayHal' src/hal/hal_interfaces.h
grep -q 'class INetworkHal' src/hal/hal_interfaces.h
grep -q 'class IAudioHal' src/hal/hal_interfaces.h
grep -q 'class IStorageHal' src/hal/hal_interfaces.h
! grep -qE '#include <Q|Allwinner|Rockchip|RK[0-9]' src/hal/hal_interfaces.h
test -f config/hardware-profiles/a5e.env
test -f config/hardware-profiles/a733-generic.env
pass hal-portability

# 5. Semantic RGB tokens and status colors are code-level design contracts.
grep -q 'singleton DesignTokens' qml/components/qmldir
grep -q 'readonly property color success' qml/components/DesignTokens.qml
grep -q 'readonly property color warning' qml/components/DesignTokens.qml
grep -q 'readonly property color danger' qml/components/DesignTokens.qml
grep -q 'DesignTokens.surface' qml/components/PerformanceCpuCard.qml
pass rgb-design

# 6-7. Reproducible Git/CI build and strict gates; generated output stays out.
test -f .github/workflows/quality.yml
test -x scripts/build-runtime.sh
test -x scripts/verify-device.sh
grep -q 'MEOW_BUILD_JOBS' scripts/install-live.sh
grep -q '/verify/' .gitignore
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    ! git ls-files | grep -Eq '(^|/)(Makefile|build-runtime/|qrc_.*\.cpp|moc_.*\.cpp|.*\.o)$'
fi
./scripts/quality-gate.sh --strict >/dev/null
pass build-and-git

if [ "${1:-}" = "--live" ]; then
    ./scripts/verify-device.sh --performance-baseline
    pass real-device
fi

printf '%s\n' 'EXPERIMENTAL_ARCHITECTURE_ACCEPTANCE=PASS'

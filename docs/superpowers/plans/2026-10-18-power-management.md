# Power Management Implementation Plan

> **For agentic workers:** Use subagent-driven-development for independent components, with spec review then code-quality review; preserve the existing D-drive checkout and branch.

**Goal:** Implement the user-approved complete software power-management design without programming unknown battery/charger settings.

**Architecture:** Python read-only telemetry plus an independent safety supervisor publishes atomic JSON. Qt validates and consumes snapshots; native game launchers consult the same supervisor state. Hardware actions are isolated from pure policy tests.

**Tech Stack:** Python3 standard library, systemd247, Qt5.15/C++11/QML, unittest.

## Task 1 — Power daemon and policy

Files: create `scripts/meow_power/` package (telemetry, policy, hardware, daemon), `scripts/meow-power.py`, `tools/test-power-management.py`. Interface and thresholds are fixed in the approved spec.

- [ ] Write failing unittest cases asserting BQ RM(0x10)=1445/FCC(0x12)=3000/SOC49, signed negative current, unavailable reads, inconsistent SOC and charger conflict, no charger writes.
- [ ] Implement read-only Linux I2C_RDWR telemetry and atomic snapshots.
- [ ] Add fake-time tests: 80℃ for4s throttles, 85℃ for4s exits, <75℃ for30s releases; unavailable sensors never silently normalize a hot latch; low-voltage requires10s.
- [ ] Implement isolated CPU limiter with root-owned boot-specific snapshot, retry-safe restore and respect for external policy changes. Test rollback/restart with temporary sysfs fixture on D drive.
- [ ] Implement daemon and `--once`, `--allow-game`, `--restore` commands. Preflight checks schema, boot and6s freshness; tests use injected paths and do not modify hardware.
- [ ] Run `tmp/aqt-venv/Scripts/python.exe tools/test-power-management.py` and commit only these files.

## Task 2 — Qt and battery settings

Files: modify `src/systembackend.cpp/.h`, `qml/apps/SettingsApp.qml`, `qml/Main.qml`; add `src/power_snapshot_reader.h` and focused reader tests if useful. Preserve API compatibility and native PvZ entry.

- [ ] Add fixtures for valid/stale/wrong-boot JSON and verify rejection before implementation.
- [ ] Replace direct battery/charger I2C collection with snapshot reader; remove charger auto-configuration and software calibration application.
- [ ] Add `Q_PROPERTY(QVariantMap powerManagement ...)`; unknown defaults use-1, not10000/2400. Disable fake learning/calibration APIs, preserving backup files.
- [ ] Replace battery page fake calibration/learning blocks with truthful telemetry, source/confidence, service state and warnings. Show Unknown appropriately in status bar/current/power.
- [ ] Compile Windows Qt via `output/build-preview.ps1`, run reader/UI checks and commit owned files.

## Task 3 — Installation and launch integration

Files: add `systemd/meow-power.service`, `config/power-management.json`; modify `scripts/install-live.sh`, native game preflight and unit dependencies; add docs under `docs/`.

- [ ] Install Python entry/package/config, root-only persistent policy-state directory and world-readable runtime telemetry, enable service independently of desktop.
- [ ] Game preflight uses `python3 /opt/meow-os/bin/meow-power.py --allow-game`; Wants/After power service; reject stale or cooldown state with concrete message.
- [ ] Validate shell syntax, service unit files and fake preflight tests without physical display side effects.
- [ ] Run spec compliance review followed by code-quality review; fix findings before deploying.

## Task 4 — Device deployment and verification

- [ ] Preserve device binary, affected units/configs and old battery settings in `/home/radxa/power-management-backup`; local artifacts remain `D:/CodexWork/MeowOS/output` and task temps in `tmp`.
- [ ] Upload committed source archive to a separate device source folder; build Qt with `MEOW_BUILD_JOBS=1`, retaining existing desktop until build succeeds.
- [ ] Install daemon first and compare its read-only snapshot to BQ raw registers, without hardware register writes. Stop old desktop before leaving both owners active; new Qt is read-only.
- [ ] Install verified binary, restart services, verify fresh battery screen and error-free logs; record service remains active across desktop/game handoff. Do not deliberately heat device; validate intervention through unit tests.
- [ ] Update audit/results and rollback instructions, summarize actual limits and unresolved hardware uncertainties.

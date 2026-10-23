# Antigravity Agent Guidelines for KSCC (mySlowrollOS Control Center)

## Project Purpose
`myslowroll-cc` is the native Qt6 / KF6 Kirigami Control Center for openSUSE Slowroll, providing system maintenance, hardware telemetry, network profiles, Btrfs/Snapper recovery, atomic update integration, and system privacy controls.

---

## Strict Invariants and Prohibitions

1. **Mandatory Source Audit Before Build or Commit**:
   - Never run `build-rpm.sh`, install RPMs, or execute `git commit` based solely on compaction summaries or assumption of completed work.
   - Always run `git diff` and verify line-by-line that all requested code changes are physically present in the source files on disk.

2. **Triple Synchronization for Shipped Scripts & Assets**:
   - Every script or tool added or modified under `data/scripts/` (e.g. `privacy.sh`, `mic.sh`) must be registered in three places:
     1. Source location: `data/scripts/<name>.sh` (executable `chmod 0755`).
     2. CMake installer: `CMakeLists.txt` under `install(PROGRAMS data/scripts/<name>.sh DESTINATION ${CMAKE_INSTALL_DATADIR}/myslowroll-cc/scripts)`.
     3. RPM Spec: `packaging/myslowroll-cc.spec` in the `%files` section under `%{_datadir}/myslowroll-cc/scripts/<name>.sh`.
   - PolKit policies in `data/*.policy` must be kept in sync between `data/`, `CMakeLists.txt`, and the spec `%files`.

3. **Shipped Script Security and Process Isolation**:
   - Official/shipped scripts (`privacy`, `mic`) must be resolved exclusively from system paths (`/usr/share/myslowroll-cc/scripts`), preventing writable user directories from shadowing them.
   - Never kill or abruptly abort elevated `pkexec` processes; allow PolKit transactions sufficient timeout (`600000` ms for atomic-update, `120000` ms for boot/zypper).
   - Custom user scripts must be isolated using process groups (`setpgid`).

4. **Unified Sources Regeneration**:
   - Whenever any source file in `KSCC` is added, removed, or modified, regenerate the unified export:
     ```bash
     python3 generate-unified-sources.py
     cp myslowroll-cc-sorgenti-unificati.txt ../KSCC.txt
     rm -f myslowroll-cc-sorgenti-unificati.txt
     ```

5. **No Spec Drift & Clean Build Scripts**:
   - `KSCC-rpmlintrc` was retired; do not re-introduce it.
   - Single source of truth for versioning is `CMakeLists.txt` (`project(myslowroll-cc VERSION X.Y.Z)`).

---

## Mandatory Verification Suite

Before committing or releasing changes:
```bash
# 1. Clean build and unit test execution
cmake -B build -S .
cmake --build build
ctest --test-dir build --output-on-failure

# 2. Local RPM packaging
./build-rpm.sh

# 3. Unified sources sync
python3 generate-unified-sources.py
cp myslowroll-cc-sorgenti-unificati.txt ../KSCC.txt && rm -f myslowroll-cc-sorgenti-unificati.txt
```

# Session Notes

**Purpose:** Continuity between sessions. Each session reads this first and writes to it before closing out.

---

## ACTIVE TASK
**Task:** Implement Phase 2 of hamlib build pipeline — remaining 3 build targets
**Status:** Ready to implement
**Plan:** `docs/planning/hamlib-build-pipeline.md` (lines 205-237)
**Priority:** HIGH

### What You Must Do
1. Add 3 matrix entries to `.github/workflows/build.yml:17-21`:
   - `macos-13` / `macos-x86_64` / `hamlib-macos-x86_64.tar.gz`
   - `ubuntu-24.04` / `linux-x86_64` / `hamlib-linux-x86_64.tar.gz`
   - `ubuntu-24.04-arm` / `linux-arm64` / `hamlib-linux-arm64.tar.gz`
2. Add a Linux build dependencies step (conditional on `runner.os == 'Linux'`): `sudo apt-get update && sudo apt-get install -y automake autoconf libtool pkg-config`
3. Create `scripts/bundle-linux.sh` — copies rigctld + libhamlib.so* to staging, sets RPATH to `$ORIGIN/lib` using `patchelf`. Install `patchelf` in the Linux deps step.
4. Update the Bundle step to conditionally call `bundle-macos.sh` or `bundle-linux.sh` based on `runner.os`.
5. **macOS x86_64 gotcha:** Homebrew prefix is `/usr/local/` on Intel, not `/opt/homebrew/`. The bundle script already handles this dynamically (it reads from `otool -L`), so no changes needed there.
6. **Linux gotcha:** `nproc` works on Linux but `sysctl -n hw.ncpu` doesn't. Build step already has fallback: `$(sysctl -n hw.ncpu 2>/dev/null || nproc)`.
7. Push and verify all 4 matrix jobs go green.

### How You Will Be Evaluated
The user rates every session's handoff. Your handoff will be scored on:
1. Was the ACTIVE TASK block sufficient to orient the next session?
2. Were key files listed with line numbers?
3. Were gotchas and traps flagged?
4. Was the "what's next" actionable and specific?

---

*Session history accumulates below this line. Newest session at the top.*

### What Session 2 Did
**Deliverable:** Phase 1 — macOS ARM64 build workflow
**Started:** 2026-04-02
**Status:** COMPLETE

**What was produced:**
- `.github/workflows/build.yml` — GitHub Actions workflow with macOS ARM64 (macos-15) matrix entry
- `scripts/bundle-macos.sh` — dylib path rewriting + ad-hoc signing
- `scripts/verify.sh` — post-build verification (version, model list, dummy rig, library path check)
- GitHub repo `KJ5HST-LABS/hamlib` created and pushed

**Commits:**
- `6deb157` — feat: add macOS ARM64 build workflow for rigctld
- `4c9b2ef` — fix: rename install prefix to avoid INSTALL file collision

**CI Results (run 23920636103):**
- All steps green in 1m47s
- rigctld version: `Hamlib 5.0.0~git 2026-03-27T08:15:03Z SHA=0b2f36f 64-bit`
- Model list: 301 models (requirement: 300+)
- otool -L: `@loader_path/lib/libhamlib.5.dylib` + `/usr/lib/libSystem.B.dylib` only
- Archive size: 1.35 MB
- Dummy rig test: rigctld launched and ran, nc not available on runner (WARN, non-blocking)

**Key files:**
- `.github/workflows/build.yml:1-96` — full workflow
- `scripts/bundle-macos.sh:1-94` — dylib bundling (install_name_tool + codesign)
- `scripts/verify.sh:1-92` — verification tests
- `docs/planning/hamlib-build-pipeline.md:163-201` — Phase 1 spec

**Gotchas for next session:**
- macOS INSTALL file conflict: `--prefix=$PWD/install` collides with existing `INSTALL` file on case-insensitive FS. Fixed by using `dist/` — already in the committed workflow.
- `nc` (netcat) not available on macOS GitHub runners — dummy rig TCP test returns WARN, not FAIL. This is acceptable; the critical checks (version, model list, library paths) all pass.
- The workflow triggers on push to `main` — be aware each push will start a build. Consider adding `paths-ignore` if pushing non-workflow files.

**Session 1 Handoff Evaluation (by Session 2):**
- **Score: 9/10**
- **What helped:** Specific file list with line numbers, all 7 "What You Must Do" items were actionable and correct. The LIBTOOLIZE gotcha was critical — would have failed the bootstrap step without it.
- **What was missing:** Didn't flag the INSTALL file collision (understandable — it's a runtime discovery, not predictable from research). Could have mentioned that `pkg-config` is already installed on macos-15 runners (minor).
- **What was wrong:** Nothing — all claims were accurate.
- **ROI:** Yes, saved significant time. The configure flags worked on first attempt.

**Self-assessment:**
- (+) First attempt at build succeeded (configure, make, bootstrap all green)
- (+) Only one bug: INSTALL file collision — diagnosed and fixed in under 2 minutes
- (+) Bundle script correctly handles dynamic dylib discovery (not hardcoded version numbers)
- (+) Verify script is cross-platform ready for Phase 2
- (-) Didn't anticipate the INSTALL file collision despite knowing it was an autotools project
- (-) nc test doesn't work on GitHub runners — could have used a different approach (curl, bash /dev/tcp)
- Score: 8/10

### What Session 1 Did
**Deliverable:** Plan document for Hamlib rigctld build pipeline CI
**Started:** 2026-04-02
**Status:** COMPLETE

**What was produced:**
- `docs/planning/hamlib-build-pipeline.md` — 4-phase implementation plan for CI pipeline that builds `rigctld` from upstream Hamlib source for 4 targets (macOS ARM64/x86_64, Linux x86_64/ARM64) and publishes to GitHub Releases.

**Key decisions made (with user input):**
- Build from upstream `Hamlib/Hamlib` (no fork), track `master`, version configurable via `workflow_dispatch` input
- Target repo: `KJ5HST-LABS/hamlib` (not yet created)
- Both versioned releases and rolling `latest` tag
- Native ARM64 runners preferred (macos-15, ubuntu-24.04-arm)
- macOS x86_64 via `macos-13` runner (last Intel runner, will need migration plan when deprecated)
- Ad-hoc signing only, no hardened runtime, no notarization

**WSJT-X reference build evaluation:**
- Adopted: dual-release strategy, install_name_tool-before-signing lesson, otool/ldd verification pattern, softprops/action-gh-release@v2
- Skipped: dylibbundler (overkill for 1 lib), Qt handling, notarization, PKG installers, entitlements, certificate management

**Key files:**
- `docs/planning/hamlib-build-pipeline.md` — full plan (all phases, architecture decisions, risk assessment)
- `docs/PANELKIT_BINARY_REQUIREMENTS.md` — requirements spec (the input document)
- `SESSION_RUNNER.md` — session protocol (followed)
- `SAFEGUARDS.md` — safety rules (followed)

**Gotchas for next session:**
- macOS `libtool` != GNU `libtool`. Must `export LIBTOOLIZE=glibtoolize` before running Hamlib's `./bootstrap`.
- `install_name_tool` silently fails on already-signed binaries. Rewrite paths BEFORE `codesign`.
- Hardened runtime (`--options runtime`) + ad-hoc signing = SIGABRT. Do NOT combine them.
- Hamlib's `rigctld` is built in `tests/` directory, not `src/`. After `make install` it goes to `$PREFIX/bin/`.

**Self-assessment:**
- (+) Thorough research: evaluated reference build, upstream CI, runner availability, build system
- (+) Plan has concrete configure flags, bundle scripts, verification commands
- (+) Each phase has explicit DONE criteria and session boundary
- (+) Risk assessment covers known hazards
- (-) Could not verify configure flags against upstream HEAD (research was via agents reading the repo — flags should be re-verified in Phase 1)
- Score: 8/10

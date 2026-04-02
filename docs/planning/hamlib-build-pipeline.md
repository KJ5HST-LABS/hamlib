# Hamlib rigctld Build Pipeline Plan

**Date:** 2026-04-02
**Author:** Session 1
**Status:** DRAFT — not yet evidence-verified against upstream Hamlib CI

---

## Goal

Build a GitHub Actions CI pipeline in `KJ5HST-LABS/hamlib` that compiles `rigctld` from upstream `Hamlib/Hamlib` source and publishes 4 platform-specific archives as GitHub release assets. PanelKit's `HamlibInstaller.java` consumes these archives to provide zero-dependency radio control.

## Architecture Decisions

### 1. WSJT-X Reference Build Evaluation

**Decision: Adopt structure and lessons, not the workflow itself.**

The `KJ5HST-LABS/WSJT-X-MAC-ARM64` pipeline is a 552-line workflow handling CMake, Qt frameworks, Fortran, hardened runtime + notarization, and PKG installers. Our build is dramatically simpler:

| Concern | WSJT-X | hamlib |
|---------|--------|--------|
| Build system | CMake superbuild | Autotools (bootstrap/configure/make) |
| Dependencies | Qt5, fftw, boost, gfortran | None (minimal configure) |
| Signing | Developer ID + notarization | Ad-hoc only (`codesign -s -`) |
| Packaging | PKG installer + tarballs | Tarballs only |
| Library bundling | dylibbundler + Qt framework extraction + manual fixups | install_name_tool only (1 lib: libhamlib) |

**What we adopt from it:**
- Dual-release strategy (versioned tag + rolling `latest`)
- `install_name_tool` before signing (not after — it silently fails on signed binaries)
- Verification via `otool -L` / `ldd` to catch external references
- `softprops/action-gh-release@v2` for release publishing
- Separate build job + release job pattern

**What we skip:**
- dylibbundler (overkill for 1 library)
- Qt framework handling, gfortran discovery, entitlements
- Hardened runtime, notarization, PKG construction
- Certificate management (ad-hoc signing needs no secrets)

### 2. Runner Strategy

| Target | Runner | Rationale |
|--------|--------|-----------|
| macOS ARM64 | `macos-15` | Native Apple Silicon, GA |
| ~~macOS x86_64~~ | ~~`macos-13`~~ | **DROPPED** — runner retired by GitHub; Apple ending x86 support |
| Linux x86_64 | `ubuntu-24.04` | Standard GA runner |
| Linux ARM64 | `ubuntu-24.04-arm` | Native ARM64, GA since early 2025 |

All targets build natively — no cross-compilation needed. This means we can run verification tests (rigctld --version, rigctld -l) on every target.

### 3. Build Configuration

Minimal Hamlib build — no bindings, no optional libraries:

```bash
./bootstrap
./configure \
  --prefix="$PWD/install" \
  --enable-shared=yes \
  --enable-static=no \
  --enable-silent-rules \
  --enable-html-matrix=no \
  --enable-usrp=no \
  --enable-winradio=no \
  --with-cxx-binding=no \
  --with-indi=no \
  --with-libusb=no \
  --with-lua-binding=no \
  --with-perl-binding=no \
  --with-python-binding=no \
  --with-readline=no \
  --with-tcl-binding=no \
  --with-xml-support=no
make -j$(nproc)
make install
```

Shared-only (`--enable-static=no`) because:
- PanelKit expects `lib/libhamlib.dylib` (or `.so`) alongside `rigctld`
- Static linking would bake libhamlib into rigctld but we'd lose the shared lib for any future consumers
- The requirements doc specifies the `lib/` directory layout

### 4. Library Bundling Strategy

**macOS:** After `make install`, the installed `rigctld` will reference libhamlib via an absolute path (e.g., `/Users/runner/work/.../install/lib/libhamlib.5.dylib`). Fix with:

```bash
# Rewrite rigctld's reference to libhamlib
install_name_tool -change \
  "$PREFIX/lib/libhamlib.5.dylib" \
  "@loader_path/lib/libhamlib.5.dylib" \
  rigctld

# Rewrite libhamlib's install name (identity)
install_name_tool -id \
  "@loader_path/libhamlib.5.dylib" \
  lib/libhamlib.5.dylib

# Ad-hoc sign AFTER path rewriting
codesign -s - --force rigctld
codesign -s - --force lib/libhamlib.5.dylib
codesign -s - --force lib/libhamlib.dylib  # symlink target if different
```

**Do NOT** use `--options runtime` (hardened runtime) with ad-hoc signing — this causes SIGABRT, as documented in the WSJT-X build and the requirements doc.

**Linux:** Set RPATH during configure:

```bash
./configure ... LDFLAGS="-Wl,-rpath,\$ORIGIN/lib"
```

Or post-build with `patchelf --set-rpath '$ORIGIN/lib' rigctld`. The binary will find `libhamlib.so` relative to itself.

### 5. Archive Layout

Each archive extracts flat (no wrapper directory):

```
rigctld
lib/
  libhamlib.dylib -> libhamlib.5.dylib    # (macOS symlink)
  libhamlib.5.dylib                        # (macOS actual)
  # OR
  libhamlib.so -> libhamlib.so.5           # (Linux symlink)
  libhamlib.so.5 -> libhamlib.so.5.0.0     # (Linux versioned)
  libhamlib.so.5.0.0                       # (Linux actual)
```

Create with: `tar czf hamlib-<target>.tar.gz -C staging/ rigctld lib/`

### 6. Version Configuration

The workflow accepts a `hamlib_version` input (default: `master`). This can be:
- `master` — latest development
- A git tag like `4.5.5` — specific release
- A commit SHA — pinned build

```yaml
on:
  workflow_dispatch:
    inputs:
      hamlib_version:
        description: 'Hamlib git ref (tag, branch, or SHA)'
        default: 'master'
        required: false
```

### 7. Release Strategy

Two releases per build:
1. **Versioned release** — tag derived from Hamlib version + build number (e.g., `v4.5.5-1` or `vmaster-20260402`)
2. **Rolling `latest` release** — tag `latest`, always overwritten with newest build

Both contain the same 4 archives. The `latest` tag gives PanelKit a stable download URL.

---

## Implementation Phases

### Phase 1: Repository Setup + macOS ARM64 Build

**Deliverable:** Working GitHub Actions workflow that builds rigctld for macOS ARM64, produces a verified archive, and uploads it as a workflow artifact.

**Files to create:**
- `.github/workflows/build.yml` — the CI workflow (build job only, no release yet)
- `scripts/bundle-macos.sh` — library path rewriting + ad-hoc signing
- `scripts/verify.sh` — post-build verification (the test from requirements doc)

**Steps:**
1. Create the `KJ5HST-LABS/hamlib` GitHub repo (user action — `gh repo create`)
2. Write the workflow with a single matrix entry: `macos-15` / `macos-arm64`
3. Build job: install deps, clone upstream, bootstrap, configure (minimal), make, make install
4. Bundle: copy rigctld + lib/ to staging, run bundle-macos.sh
5. Verify: run verify.sh (rigctld --version, rigctld -l, dummy rig test)
6. Upload archive as workflow artifact

**DONE looks like:**
- Workflow runs green on `macos-15`
- Archive extracts flat, rigctld launches, `--version` works, `-l` lists 300+ models
- `otool -L rigctld` shows only `@loader_path/lib/` and system libs (no `/opt/homebrew/`, no absolute paths)

**Verification commands:**
```bash
# Trigger workflow
gh workflow run build.yml

# Check run status
gh run list --workflow=build.yml

# Download artifact and test locally
gh run download <run-id>
mkdir /tmp/hamlib-test && tar xzf hamlib-macos-arm64.tar.gz -C /tmp/hamlib-test
/tmp/hamlib-test/rigctld --version
/tmp/hamlib-test/rigctld -l | wc -l
otool -L /tmp/hamlib-test/rigctld
```

**This phase is one session. Close out when done.**

---

### Phase 2: Remaining Build Targets

**Deliverable:** Expand the build matrix to all 4 targets. All produce verified archives.

**Files to modify:**
- `.github/workflows/build.yml` — add 3 matrix entries
- `scripts/bundle-linux.sh` — new script for Linux RPATH + verification

**Matrix additions:**

| Runner | Target | Bundle Script |
|--------|--------|---------------|
| `macos-13` | `macos-x86_64` | `bundle-macos.sh` (same script) |
| `ubuntu-24.04` | `linux-x86_64` | `bundle-linux.sh` |
| `ubuntu-24.04-arm` | `linux-arm64` | `bundle-linux.sh` (same script) |

**macOS x86_64:** Same build + bundle as ARM64, just runs on Intel runner. The only difference is brew paths (`/usr/local/` instead of `/opt/homebrew/`).

**Linux:** Build deps via apt (`automake autoconf libtool pkg-config`). Bundle script sets RPATH and copies libs. Verify with `ldd` (should show only libc, libm, libpthread, libdl).

**DONE looks like:**
- All 4 matrix jobs green
- 4 verified archives as workflow artifacts
- Each archive passes the full verification test from the requirements doc

**Verification commands:**
```bash
gh workflow run build.yml
gh run list --workflow=build.yml
# Download each artifact and run verify.sh
```

**This phase is one session. Close out when done.**

---

### Phase 3: Release Publishing

**Deliverable:** Add a release job that publishes all 4 archives to GitHub Releases.

**Files to modify:**
- `.github/workflows/build.yml` — add `release` job

**Release job:**
- Runs on `ubuntu-latest`, depends on all build jobs
- Downloads all 4 artifacts
- Computes release tag:
  - If triggered with a Hamlib version tag: `v{version}-{run_number}` (e.g., `v4.5.5-1`)
  - If triggered with `master`: `vmaster-{date}` (e.g., `vmaster-20260402`)
- Creates versioned release using `softprops/action-gh-release@v2`
- Creates/overwrites `latest` release with same assets

**DONE looks like:**
- Workflow creates a GitHub Release with all 4 `.tar.gz` files
- `latest` tag exists and points to the newest release
- Download URLs match the pattern expected by `HamlibInstaller.java`:
  `https://github.com/KJ5HST-LABS/hamlib/releases/download/<tag>/hamlib-<target>.tar.gz`

**Verification commands:**
```bash
gh release list
gh release view latest
# Download from release URL and verify
curl -L https://github.com/KJ5HST-LABS/hamlib/releases/download/latest/hamlib-macos-arm64.tar.gz -o test.tar.gz
```

**This phase is one session. Close out when done.**

---

### Phase 4: PanelKit Integration

**Deliverable:** Update `HamlibInstaller.java` URL constants to point to the new repo/release.

**Files to modify (in panelkit-api repo):**
- `plugins/hamlib-radio/backend/.../HamlibInstaller.java` — update 4 URL constants

**DONE looks like:**
- PanelKit can download and install rigctld from the new GitHub release
- The dummy rig test passes when launched through PanelKit

**This phase is one session. Close out when done.**

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| macOS x86_64 runner deprecation | HIGH (Apple phasing out Intel) | MEDIUM — builds stop working | Monitor GitHub's runner deprecation notices. When macos-13 is removed, either drop x86_64 target or cross-compile from ARM64 |
| Upstream Hamlib API break on master | LOW | MEDIUM — build fails | Pin to known-good version in workflow_dispatch default. CI failure is visible and fixable |
| libhamlib has undocumented runtime deps | LOW | HIGH — binary crashes on clean machines | Verification script tests in isolation. `otool -L` / `ldd` check catches hidden deps |
| GitHub ARM64 Linux runner unavailable for private repos | LOW (repo is public) | LOW | Cross-compilation fallback documented in Phase 2 |
| Ad-hoc signed binary triggers Gatekeeper on first run | MEDIUM | LOW — PanelKit already handles this | Requirements doc notes this is expected. PanelKit uses `xattr -cr` or user approves manually |

## macOS Autotools Gotcha

On macOS runners, the system `libtool` is Apple's version, not GNU libtool. Homebrew installs GNU libtool as `glibtool` / `glibtoolize`. Hamlib's `bootstrap` script needs:

```bash
export LIBTOOLIZE=glibtoolize
./bootstrap
```

This is a known issue in Hamlib's own macOS CI. Must be handled in the workflow.

## File Inventory

**Files this pipeline creates (all in KJ5HST-LABS/hamlib):**

| File | Purpose |
|------|---------|
| `.github/workflows/build.yml` | Main CI workflow |
| `scripts/bundle-macos.sh` | macOS library path rewriting + ad-hoc signing |
| `scripts/bundle-linux.sh` | Linux RPATH verification + lib copying |
| `scripts/verify.sh` | Post-build verification (all platforms) |
| `docs/PANELKIT_BINARY_REQUIREMENTS.md` | Requirements spec (already exists) |
| `CLAUDE.md` | Updated with build/test commands |

**File modified in panelkit-api (Phase 4):**

| File | Change |
|------|--------|
| `plugins/hamlib-radio/backend/.../HamlibInstaller.java` | Update 4 URL constants |

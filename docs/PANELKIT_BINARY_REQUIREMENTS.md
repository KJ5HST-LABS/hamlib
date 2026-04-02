# PanelKit Hamlib Binary Build Requirements

## Purpose

PanelKit's Hamlib Radio plugin downloads pre-built `rigctld` binaries at runtime so users don't need Homebrew, apt, or any package manager. This document specifies the build artifact requirements so the Hamlib build pipeline produces binaries that PanelKit can consume directly.

## Consumer

**PanelKit plugin:** `plugins/hamlib-radio/backend/.../HamlibInstaller.java`

The installer downloads a platform-specific archive from a GitHub release URL, extracts it to `~/Library/Application Support/PanelKit/bin/hamlib/` (macOS), `%APPDATA%/PanelKit/bin/hamlib/` (Windows), or `~/.local/share/panelkit/bin/hamlib/` (Linux), and runs `rigctld --version` to verify.

## Required Build Targets

Four platform archives, each published as a GitHub release asset:

| Target | Archive Name | Format |
|--------|-------------|--------|
| macOS ARM64 (Apple Silicon) | `hamlib-macos-arm64.tar.gz` | tar.gz |
| macOS x86_64 (Intel) | `hamlib-macos-x86_64.tar.gz` | tar.gz |
| Linux x86_64 | `hamlib-linux-x86_64.tar.gz` | tar.gz |
| Linux ARM64 | `hamlib-linux-arm64.tar.gz` | tar.gz |

**Windows:** Not needed from this repo. PanelKit already downloads the official `hamlib-w64-*.zip` from `github.com/Hamlib/Hamlib/releases`.

## Archive Layout

Each tar.gz must extract with this flat structure (no top-level directory wrapper):

```
rigctld                  # The binary (executable, no extension on Unix)
lib/                     # Optional: bundled shared libraries
  libhamlib.dylib        # (macOS) or libhamlib.so (Linux)
  libhamlib.4.dylib      # versioned symlinks as needed
  ...                    # any other runtime dependencies
```

**Critical:** The archive must extract flat into the destination directory. When PanelKit runs `tar xzf hamlib-macos-arm64.tar.gz -C /path/to/hamlib/`, the result must be:

```
/path/to/hamlib/rigctld
/path/to/hamlib/lib/libhamlib.dylib
```

Not:

```
/path/to/hamlib/hamlib-macos-arm64/rigctld    # WRONG — nested directory
```

## Binary Requirements

### rigctld

- Must be a **statically linked** or **self-contained** binary (bundled libs in `lib/`)
- Must not depend on libraries outside the archive (no system libhamlib, no Homebrew paths)
- Must respond to `rigctld --version` with a zero or non-zero exit (used for verification)
- Must respond to `rigctld -l` with the tab-separated model list (used to populate the radio selector)

### macOS-Specific

- **Code signing:** Ad-hoc sign at minimum (`codesign -s -`). Unsigned binaries trigger Gatekeeper prompts
- **Library paths:** Use `@loader_path/lib/` or `@rpath/lib/` for bundled dylibs. Run `install_name_tool` to rewrite any absolute paths baked in during compilation
- **Hardened runtime:** Do NOT enable hardened runtime (`--options runtime`) unless you also sign with entitlements. Hardened runtime + ad-hoc signing causes SIGABRT on launch (same issue hit with jt9 ARM64 builds)
- **Universal binaries:** Not required. Separate ARM64 and x86_64 archives are preferred over fat binaries to keep download size small
- **Rosetta 2:** PanelKit detects architecture mismatch (error code 86) and tells users to install Rosetta. But native ARM64 builds are strongly preferred

### Linux-Specific

- **Library paths:** Set `RPATH` to `$ORIGIN/lib` during linking so the binary finds bundled libs relative to itself
- **Minimal system dependencies:** Should only depend on libc, libm, libpthread, libdl (standard glibc). No libusb unless bundled
- **Static alternative:** Fully static linking is acceptable if it produces a working binary

## Verification Test

After building, verify each archive works in isolation:

```bash
# Create a clean temp directory (simulates PanelKit's bin/hamlib/)
mkdir /tmp/hamlib-test
tar xzf hamlib-macos-arm64.tar.gz -C /tmp/hamlib-test

# Verify binary exists and is executable
test -x /tmp/hamlib-test/rigctld

# Verify it launches (should print version and exit)
/tmp/hamlib-test/rigctld --version

# Verify model list works (should print 300+ lines)
/tmp/hamlib-test/rigctld -l | wc -l

# Verify it can start a dummy rig (model 1 = Hamlib Dummy, no hardware needed)
/tmp/hamlib-test/rigctld -m 1 -t 14532 &
RIGCTLD_PID=$!
sleep 1
echo "+\quit" | nc localhost 14532  # Should respond with frequency
kill $RIGCTLD_PID

# Clean up
rm -rf /tmp/hamlib-test
```

## GitHub Release Structure

Publish all four archives under a single GitHub release. The release tag can be `latest` (overwritten on each build) or versioned (e.g., `v4.7.0-1`).

PanelKit's `HamlibInstaller.java` references these URLs as constants:

```java
private static final String MAC_ARM64_URL = "https://github.com/KJ5HST-LABS/<repo>/releases/download/<tag>/hamlib-macos-arm64.tar.gz";
private static final String MAC_X86_64_URL = "https://github.com/KJ5HST-LABS/<repo>/releases/download/<tag>/hamlib-macos-x86_64.tar.gz";
private static final String LINUX_X86_64_URL = "https://github.com/KJ5HST-LABS/<repo>/releases/download/<tag>/hamlib-linux-x86_64.tar.gz";
private static final String LINUX_ARM64_URL = "https://github.com/KJ5HST-LABS/<repo>/releases/download/<tag>/hamlib-linux-arm64.tar.gz";
```

Once the repo name, tag, and archive names are finalized, update these four constants in `HamlibInstaller.java` and the plugin is fully wired.

## Build Reference

The jt9/wsprd ARM64 build at `KJ5HST-LABS/WSJT-X-MAC-ARM64` follows an identical pattern and can serve as a reference for the CI workflow. Key lessons from that build:

1. `install_name_tool` silently fails on ad-hoc signed binaries — rewrite library paths before signing
2. Library glob `*.dylib` can miss libraries without the `.dylib` extension (e.g., QtCore) — enumerate explicitly
3. Hardened runtime requires JIT entitlement for Fortran binaries — use `--options runtime` only with proper entitlements
4. Test the binary on a clean machine (no Homebrew, no dev tools) to catch hidden dependencies

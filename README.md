# Patched CEF for IronRDP

This repository holds patches, not a CEF fork. **No binary release has been
produced or validated here yet.** The manual build and draft-release workflow
is an initial, unverified integration. It never publishes a release.
Only the upstream IronRDP custom build on macOS ARM64 is documented as
validated; Linux and Windows patched runtimes remain unverified.

## Pins and provenance

`pins.json` records the immutable CEF, Chromium, depot_tools, cef-rs and
IronRDP revisions. CEF's pinned `CHROMIUM_BUILD_COMPATIBILITY.txt` specifies
Chromium `refs/tags/156.0.8078.88` and depot_tools
`132599ebbd8d22d1b1bd5ea703a6d3bc493edd71`. The pinned cef-rs workspace version
is `156.4.0+156.0.26`, corresponding to CEF
`156.0.26+g8ea0c73+chromium-156.0.8078.88`.
The Chromium tag resolves to `8954d18543712dc11b97c3aca0a6e714aa2d7dcd`.

The five unchanged patches match the `ironrdp-browser` branch and come from
[IronRDP server/cef/patches at 692c34cf](https://github.com/Devolutions/IronRDP/tree/692c34cf429a704f7bc5d99188b5be6b961043d7/server/cef/patches).
IronRDP is licensed under MIT or Apache-2.0; the corresponding license texts
are included. `scripts/cef.py` verifies their original Git blob identities.
Update those identities deliberately when changing patches.

| Order | Tree | Patch |
| --- | --- | --- |
| 1 | CEF | `isolated-clipboard.patch` |
| 2 | CEF | `remote-devices-cef.patch` |
| 3 | Chromium | `remote-devices-chromium.patch` |
| 4 | Chromium | `in-process-audio-shutdown.patch` |
| 5 | Chromium, POSIX only | `disable-chromium-shutdown-signals.patch` |

`python3 scripts/cef.py check-patches` downloads only the touched pinned
upstream files, verifies patch identities and applies all patches in order.
This does not simulate CEF's own Chromium patches, compile CEF, check exports,
or validate runtime behavior. The Actions exporter smoke test uses a synthetic
Linux archive to check flattening and metadata; it is not a native CEF build.

## Build (manual, experimental)

Use an isolated, trusted native machine following the
[pinned CEF automated build requirements](https://github.com/chromiumembedded/cef/blob/8ea0c73b5dbed1389c8dafb911a98c41246bb8cb/docs/automated_build_setup.md):
at least 16 GiB RAM and 200 GiB free disk, plus the platform toolchain and
dependencies. Chromium builds can require substantially more. Do not use a
standard hosted runner or run a checkout on a shared machine.

The `Manual native build` workflow requires an explicitly provisioned
self-hosted runner with labels `cef-build`, OS (`Linux`, `macOS`, or `Windows`)
and native architecture (`x64` or `arm64`), and Python 3, Git, and `nm` (or
Visual Studio's `dumpbin` on Windows) on PATH.
Provision no runner for untrusted PRs. It runs only when manually dispatched
against `master`; it is not automatically dispatched by pushes or PRs.
Alternatively run on a prepared native host:

```sh
python3 scripts/cef.py build --directory /path/to/new/owned/build-directory --arch arm64
```

The directory must not exist and its parent must exist. It is never cleaned or
reused. The script verifies the downloaded pinned automation script's Git blob,
syncs without building, verifies all three checkouts, applies patches, then
forces CEF's build/distribution step and GN regeneration without updating.
The output should be in `chromium/src/cef/binary_distrib`; inspect and test it
before distribution.

After a build, the workflow checks the expected custom library exports and
standard archive name, then creates a **draft** GitHub Release containing
the original archive, `SHA256SUMS`, and `manifest.json` with upstream pins,
repository revision and patch identities. Each platform run creates its own
unique draft. Export checks are not runtime validation: review and test each
candidate before publishing. The draft is created in a separate hosted job;
the trusted build runner does not receive release-write permission. These
steps have not yet been exercised on a suitably provisioned runner. CEF and
Chromium may change files during their own patching; a lightweight source check
is not sufficient proof that a complete build will succeed.

## Consumption and release gate

An ordinary CEF `binary_distrib` directory is **not** a cef-rs `CEF_PATH`.
Use `export-cef-dir` built from pinned
[cef-rs](https://github.com/tauri-apps/cef-rs/tree/9aa78c450489eddb828eb982eaee6c104a89d348/export-cef-dir)
with the standard-named minimal `.tar.bz2`, e.g.
`export-cef-dir --archive <archive> --target <rust-target> <new-output-dir>`.
Keep the canonical archive basename and top-level directory. Export creates
the flattened layout and `archive.json`; use a separate path per patched
release and set `CEF_PATH` to that output. Invalid or too-new `archive.json`
can cause this cef-rs revision to download **stock CEF** instead. Never infer
patch identity from CEF's API hash or `archive.json`; verify the custom exports
and record the patch revision and artifact checksum separately. The IronRDP
server rejects stock CEF at startup.

On macOS, the pinned cef-rs exporter/consumer copies regular files but not
framework symlinks. A production integration must materialize and validate
the framework layout without losing sandbox/bootstrap resources. Smoke-test
the exported directory and IronRDP `package-cef` on each native target, then
run the upstream `e2e.py`, `clipboard.py`, `devices.py`, and `shutdown.py`
tests as applicable. Coordinate any cef-rs/CEF upgrade with the consumer.
Do not publish until these checks and patch-specific exports are verified.

## Updates

The daily watcher compares the pinned release branch head with the pinned CEF
revision and maintains one open issue for review. It does not update pins,
create PRs, trigger builds, or ship binaries. Milestone upgrades require an
explicit decision and coordinated consumer changes.

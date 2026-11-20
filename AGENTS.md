# Repository instructions

- Use PowerShell for repository-owned scripts instead of Python. Migrate the
  existing Python orchestration; upstream CEF and depot_tools still require
  their own Python tools.
- Use Apple Silicon GitHub-hosted runners for both macOS build architectures.
- Releases include macOS; `skip-macos` builds and releases only Linux and
  Windows when macOS runners are unavailable. Keep the macOS build support.

## Rebasing the patches onto a new upstream release

The **Fix patches** workflow asks for this when `scripts/rebase-patches.ps1`
cannot merge a patch into a new CEF or Chromium release on its own. The branch
you start from has the new release in `pins.json` and the pins the current
patches apply to in `rebase-request.json`.

1. If `.rebase/state.json` does not exist, run
   `pwsh scripts/rebase-patches.ps1 -Start`. It downloads every file the
   patches touch at both revisions, applies or three-way merges each patch in
   order, and stops at the first patch that conflicts.
2. For each conflicted file it lists under `.rebase/<tree>/work/`:
   - Compare what the patch changes (`.rebase/<tree>/old/<n-1>/<path>` against
     `.rebase/<tree>/old/<n>/<path>`) with what upstream changed
     (`.rebase/<tree>/old/0/<path>` against `.rebase/<tree>/new/<path>`).
   - Edit the work file so it holds the new upstream code with the same change
     the patch makes. Each conflict block shows the new upstream code, then
     the old upstream code after `|||||||`, then the patch's version after
     `=======`. Remove every marker.
   - Keep every behavior the patch adds and adapt it to upstream's renames,
     moved code and changed signatures. Do not drop or weaken a change because
     it is hard to port, do not add features, and do not change upstream code
     the patch did not change.
3. Run `pwsh scripts/rebase-patches.ps1 -Continue`. Repeat from step 2 until it
   reports that all patches are rebased. It then rewrites `patches/*.patch`,
   checks that they apply in order to the new upstream files, and updates the
   patch blob identities in `scripts/candidate.ps1`.
4. Commit only `patches/*.patch` and `scripts/candidate.ps1`. Never edit
   `patches/*.patch` by hand, and never change workflows, scripts, pins or
   anything else. The workflow takes only the patch files from your branch.
5. In the commit message, explain each conflict you resolved: what upstream
   changed and how the patch's change was carried over.

## Reviewing patch changes

The patches add IronRDP's isolated clipboard, remote camera, microphone, media
and WebAuthn hooks, and in-process audio and shutdown fixes to CEF and
Chromium. A rebased patch must keep every behavior of the previous version:
the same exported `cef_isolated_clipboard_*` and `cef_remote_*` functions, the
same hooks at the equivalent upstream call sites, and no new behavior.

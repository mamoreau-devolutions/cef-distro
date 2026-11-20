# Copilot instructions

Follow `AGENTS.md`.

## Code review of automated patch rebases

Pull requests from branches named `auto/cef-*` move the CEF and Chromium pins
to a new upstream release and carry the patches in `patches/` onto it. Nobody
reviews them after you; your review decides whether the release is built and
published.

- Compare each changed `patches/*.patch` with its version on `master`. The
  only acceptable differences are adaptations to upstream changes: new context
  lines, renamed symbols, moved code, changed signatures.
- Approve only when every patch keeps every behavior it had: the same exported
  `cef_isolated_clipboard_*` and `cef_remote_*` functions with the same
  semantics, the same hooks at the equivalent upstream call sites, the same
  isolation of the clipboard from the operating system, and no new behavior,
  no removed checks, and no weakened error handling.
- Request changes, rather than approve, when a hunk was dropped, a check or
  restriction was removed or loosened, a change reaches code unrelated to the
  patch's purpose, or you cannot tell from the diff that behavior is kept.
- `pins.json` changes must only move `cef_commit`, `cef_version`,
  `chromium_tag`, `chromium_commit`, `depot_tools_commit` and
  `automate_git_blob`, and `scripts/candidate.ps1` changes must only update
  patch blob identities.

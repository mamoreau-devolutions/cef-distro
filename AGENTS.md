# Repository instructions

- Use PowerShell for repository-owned scripts instead of Python. Migrate the
  existing Python orchestration; upstream CEF and depot_tools still require
  their own Python tools.
- Use Apple Silicon GitHub-hosted runners for both macOS build architectures.
- macOS releases are deferred (use `skip-macos`), not dropped: keep the macOS
  build support so it can resume later.

# Repository instructions

- Use PowerShell for repository-owned scripts instead of Python. Migrate the
  existing Python orchestration as it is changed; upstream CEF and depot_tools
  still require their own Python tools.
- Use Apple Silicon GitHub-hosted runners for both macOS build architectures.

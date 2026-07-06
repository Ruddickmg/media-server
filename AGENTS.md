# Agent Instructions

## Documentation Conventions

### README.md

Contains only:
- Setup/installation instructions
- Connection URLs and access methods
- User-facing configuration options
- Post-deploy steps (things a user must do after deploying)

### Implementation-specific Details

Belong as Nix comments alongside the code that configures them. Examples:
- Systemd hardening directives — comment in the service module, not in README
- declarr sync configuration — comment in `modules/declarr.nix`
- Tailscale serve path setup — comment in `modules/services/tailscale.nix`
- API key derivation — comment in the module that defines the key derivation

### Why

- README stays concise, focused on what a human needs to know
- Code stays self-documenting — the implementation and its rationale live together
- No stale documentation — comments next to code get updated when code changes

### This File

Records project-wide conventions for LLM agents. Update it when new patterns are established.

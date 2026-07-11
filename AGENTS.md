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

## Never Commit

Do not commit, push, or create PRs. The user handles version control manually. Make edits only; tell the user what was changed and let them decide when to commit.

## Remote Server

The target server is remote. This machine is a development workstation. Nix config changes are edited here, pushed to git, and applied on the remote via `nixos-rebuild switch`. Do not attempt to run the system commands (systemctl, journalctl, ss, etc.) to check service state — those won't reflect the remote server.

## NixOS configuration declaration

Prefer declarative NixOS options over scripts whenever possible. Use `networking.nftables.tables` instead of shelling out to `nft`, and `boot.kernel.sysctl` instead of writing sysctl config files via `writeText`/`environment.etc`. Prefer `networking.firewall` options over ad-hoc firewall scripting. Reserve scripts (`writeShellScript`, `ExecStartPre/Post`) only for bugs and mitigation that cannot be expressed declaratively (e.g. netavark cleanup workaround).

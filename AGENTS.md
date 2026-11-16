# Agent Instructions

## Documentation Conventions

### README.md

Contains only:
- Setup/installation instructions
- Connection URLs and access methods
- User-facing configuration options
- Post-deploy steps (things a user must do after deploying)

Omit automatic steps from the README.md: anything the system does on its own must not be documented as a user step. Only tell users what they need to do — never describe setup that happens automatically.

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

The target server is remote. This machine is a development workstation. Nix config changes are edited here, pushed to git, and applied on the remote via `nixos-rebuild switch`.

This workstation is NOT the remote server:
- Do NOT run system commands (systemctl, journalctl, ss, ps, etc.) to check service state — those won't reflect the remote.
- Do NOT attempt a full-flake build or eval locally — `hosts/media-server/hardware-configuration.nix` is intentionally absent, so the system closure cannot be built here. Only isolated module checks (e.g. `nix-instantiate --parse`, rendering a module with a stub config) are possible.
- Diagnose remote runtime issues only from logs the user pastes. Verification of fixes happens only after the user pushes and runs `nixos-rebuild switch` on the remote.

## Hardware Configuration

DO NOT touch `hosts/media-server/hardware-configuration.nix`. It is generated on the target host system via `nixos-generate-config` and is intentionally untracked in git. It is not meant to be edited, committed, or synthesized on the development workstation.

## NixOS configuration declaration

Prefer declarative NixOS options over scripts whenever possible. Use `networking.nftables.tables` instead of shelling out to `nft`, and `boot.kernel.sysctl` instead of writing sysctl config files via `writeText`/`environment.etc`. Prefer `networking.firewall` options over ad-hoc firewall scripting. Reserve scripts (`writeShellScript`, `ExecStartPre/Post`) only for bugs and mitigation that cannot be expressed declaratively (e.g. netavark cleanup workaround).

## /media union hardlink invariants

Everything that hardlinks or renames media files goes through the `/media` mergerfs union (never the raw `/mnt/ssd` / `/mnt/hdd*` branch mounts — those are two different filesystem views and `link(2)` between them is EXDEV). mergerfs places the link on the source file's branch itself. Two rules keep this working:

- **Primary group `media`, not supplementary.** A FUSE request header carries only the caller's primary gid, and mergerfs (< 2.42) switches fsuid/fsgid to it for branch-side operations — supplementary groups and capabilities (e.g. CAP_FOWNER) do not cross. With `fs.protected_hardlinks=1`, hardlinking a file you don't own then requires the file to be group-writable by that primary gid. Every media-touching service (sonarr, radarr, lidarr, bazarr, unpackerr, deluge, plex, cross-seed) runs with primary group `media` for this reason.
- **One `ReadWritePaths` bind per link/rename scope.** Under `ProtectSystem=strict` (or any mount-namespacing option), each `ReadWritePaths` entry becomes a separate bind mount, and `link(2)`/`rename(2)` fail with EXDEV across different bind mounts even on the same filesystem (the kernel compares vfsmounts, not st_dev). List a single common ancestor (e.g. `/media/data`) instead of per-tree entries.

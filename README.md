# Media Server — NixOS Flake

NixOS configuration for a media server running Plex, Deluge, and the *arr suite with security hardening and fully automated service configuration.

## Architecture

```
Deluge ──► /media/downloads/completed/
                  │
             Unpackerr (extracts .rar/.zip/.7z)
                  │
     ┌────────────┼────────────┐
     ▼            ▼            ▼
   Sonarr       Radarr      Lidarr
   (TV)        (Movies)    (Music)
     │            │
     └─────┬──────┘
           ▼
        Bazarr (subtitles)
           │
           ▼
         Plex
```

### Filesystem layout (Btrfs subvolumes)

```
1TB SSD
├── /boot        (ESP, vfat, 512M)
├── swap         (8G)
└── Btrfs volume (rest, ~991G)
    ├── @         → /              — root OS
    ├── @nix      → /nix           — nix store (noatime)
    ├── @state    → /var/lib       — app state / Plex metadata
    ├── @log      → /var/log       — logs
    └── @media    → /media         — bulk storage
        ├── downloads/
        │   ├── incomplete/   # Deluge active downloads
        │   └── completed/    # Finished downloads (watched by Unpackerr)
        ├── movies/           # Managed by Radarr
        ├── tv/               # Managed by Sonarr
        └── music/            # Managed by Lidarr
```

All services share the `media` group for file access.

## Headless Server

The following are configured automatically:

| Setting | Behavior |
|---------|----------|
| **SSH** | OpenSSH with key-only auth (`PasswordAuthentication=false`), socket-activated. `media-server` user keys are set declaratively — see [SSH key setup](#ssh-key-setup) |
| **Console** | Auto-login to `media-server` user on tty1 — no password needed |
| **Lid close** | Ignored — system stays running |
| **Suspend / Hibernate** | Disabled entirely — all sleep targets masked |
| **Power/Sleep keys** | Ignored |
| **CPU governor** | `performance` (always plugged in) |
| **Sudo** | Disabled entirely — no user has sudo access |


## Quick Start

### 1. Boot the NixOS ISO

Boot the target machine with the [NixOS minimal ISO](https://nixos.org/download).

### 2. Clone the flake

```bash
nix-shell -p git
git clone <repo-url> /mnt/etc/nixos
```

### 3. Set the target disk

Edit `hosts/media-server/disko.nix` and change the `device` path to match your disk (e.g. `/dev/nvme0n1` or `/dev/sda`).

### 4. Partition and format

```bash
sudo nix run --extra-experimental-features nix-command --extra-experimental-features flakes github:nix-community/disko -- --mode disko /mnt/etc/nixos/hosts/media-server/disko.nix
```

This creates the partition table, filesystems, and Btrfs subvolumes, then mounts everything.

### 5. Generate hardware config

```bash
nixos-generate-config --root /mnt --dir hosts/media-server --no-filesystems
```

This overwrites `hosts/media-server/hardware-configuration.nix` with the autodetected kernel modules for your machine. The `--no-filesystems` flag prevents generating `fileSystems` and `swapDevices` entries — disko handles those declaratively.

### 6. Install

```bash
sudo nixos-install --flake /mnt/etc/nixos#media-server
```

Set the root password when prompted.

### 7. Reboot

```bash
sudo reboot
```

### 8. Create Tailscale auth key

Before `nixos-install`, place a reusable Tailscale auth key on the install media:

```bash
mkdir -p /mnt/etc/nixos/secrets
echo "tskey-auth-<your-auth-key>" > /mnt/etc/nixos/secrets/tailscale-auth
chmod 600 /mnt/etc/nixos/secrets/tailscale-auth
```

Generate the auth key from the [Tailscale admin console](https://login.tailscale.com/admin/settings/keys) — use a **reusable** key so it persists across rebuilds. The `secrets/` directory is gitignored and never committed to the repository.

On first boot, `tailscaled` reads this key and joins your tailnet automatically. No interactive `tailscale up` needed.

### SSH key setup

Public keys are committed to the repo and baked into the system at build time.

1. **Generate a key pair**:
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/media-server
   ```

2. **Copy the public key** and add it to `hosts/media-server/default.nix`:
   ```bash
   cat ~/.ssh/media-server.pub
   ```
   ```nix
   media-server.headless.authorizedKeys = [
     "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL4J... user@laptop"
   ];
   ```

3. **Deploy** — `nixos-rebuild switch` installs the key to `media-server`'s `authorized_keys`.

4. **Connect**:
   ```bash
   ssh -i ~/.ssh/media-server media-server@<machine-ip>
   ```

The private key (`~/.ssh/media-server`) is yours alone — never commit it. The public key (`~/.ssh/media-server.pub`) is safe to commit; it's meant to be shared.

## Post-Deploy Steps

These steps require the web UIs — they involve credentials you provide (indexer accounts) or external service configuration (Plex).

### Prowlarr — add indexers

1. Open `http://<machine-ip>:9696`
2. Add your torrent indexers (requires your account credentials for each indexer)

Indexers added in Prowlarr are automatically synced to Sonarr, Radarr, and Lidarr via the pre-configured application connections.

### Seeding and ratio management

Deluge's global seeding ceiling is set intentionally high (`stop_seed_ratio = 3.0`, `seed_time_limit = 14` days) as a safety net for manually-added torrents. It should never be hit by *arr-managed torrents — those are handled per-indexer.

For each indexer, set realistic seed goals in Prowlarr's **Settings → Indexers** (select an indexer → **Show Advanced**). Prowlarr syncs these to all connected *arrs automatically. The *arr will remove the torrent from Deluge when the goal is met, well before the global ceiling kicks in.

### Plex — add libraries

1. Open `http://<machine-ip>:32400/web`
2. Claim your server
3. Add libraries:
   - **Movies** → `/media/movies`
   - **TV Shows** → `/media/tv`
   - **Music** → `/media/music`

### Seerr — media request portal

Seerr provides a clean UI for friends and family to request movies and TV shows, which flow through Sonarr and Radarr automatically.

On first deploy, Seerr is pre-configured with Sonarr and Radarr connections (API keys, hostnames, default quality profiles, and root folders). The setup wizard is skipped entirely.

1. Open `http://<tailscale-ip>:5055`
2. Sign in with your **Plex account** (Seerr uses Plex for authentication)
3. Grant Seerr access to your Plex server when prompted
4. Review pre-filled settings at **Settings → Services** — connections to Sonarr and Radarr are already in place
5. Configure user permissions and notification settings as desired

> If you add custom quality profiles in Sonarr/Radarr later, update the profile selection in Seerr's service settings to match.

## Security Architecture

### Access model

The firewall uses two tiers:

| Tier | Services | How to access | Auth |
|------|----------|---------------|------|
| **Tailscale-only** | Sonarr, Radarr, Lidarr, Prowlarr, Bazarr, Unpackerr, Deluge, Seerr | Via Tailscale IP (`http://100.x.x.x:<port>`) | Plex OAuth (Seerr) / Tailscale identity only |
| **Open port** | Plex (32400) | Direct via LAN IP or public IP; Plex app/TV app | Plex.tv account auth |

**Plex** has `openFirewall = true` by default because it's designed to be shared with friends and family. They connect via the Plex app on their TV, phone, or browser — no Tailscale needed. Plex handles authentication itself (Plex.tv accounts).

> **DLNA note:** Plex also opens UDP ports 1900 (DLNA) and 5353 (mDNS) for local device discovery. DLNA broadcasts your library to any device on your LAN without authentication. This is fine for a home network. If you want to disable it, turn off DLNA in Plex's settings.

**All other services** are locked down to Tailscale only — their ports are not opened on any physical interface. You access them via the Tailscale IP (e.g., `http://100.x.x.x:8989` for Sonarr). To expose them on LAN as well, set the service's `openFirewall = true` or add ports to the interface directly:

```nix
networking.firewall.interfaces."enp0s3".allowedTCPPorts = [ 8989 7878 ];
```

### Authentication

Forms authentication is **disabled by default** — all *arr services (Sonarr, Radarr, Lidarr, Prowlarr) start with no login prompt, and declarr connects to them via API without credentials. Access is restricted via the Tailscale-only firewall.

To re-enable form-based authentication:

```nix
media-server.security.enableAuthentication = true;
```

### Systemd hardening

All services apply the following hardening directives where compatible:

| Directive | Purpose |
|-----------|---------|
| `ProtectHome=true` | No access to `/home` |
| `PrivateTmp=true` | Isolated `/tmp` |
| `NoNewPrivileges=true` | Block privilege escalation |
| `CapabilityBoundingSet=` | Drop all capabilities |
| `ProtectKernelTunables=true` | Read-only kernel tunables |
| `ProtectKernelModules=true` | No kernel module access |
| `ProtectControlGroups=true` | Read-only cgroups |
| `RestrictRealtime=true` | No realtime scheduling |
| `SystemCallArchitectures=native` | Only native syscalls |
| `PrivateDevices=true` | Minimal device access |
| `LockPersonality=true` | Lock execution domain |
| `RestrictNamespaces=true` (where supported) | Block namespace creation |

Plex skips `CapabilityBoundingSet` for transcoding compatibility.

### VPN confinement (Deluge)

Deluge can be isolated in a dedicated network namespace with a WireGuard VPN to anonymize torrent traffic. This provides a built-in kill switch — if the VPN drops, Deluge loses all network connectivity.

Enable it by:

1. Placing a WireGuard configuration file from a VPN provider on the server (e.g., `/etc/nixos/secrets/vpn.conf`)
2. Enabling the feature:

```nix
{
  media-server.vpn.enable = true;
  media-server.vpn.wireguardConfig = "/etc/nixos/secrets/vpn.conf";
  media-server.deluge.vpnConfinement = true;
}
```

When VPN confinement is active, a proxy service (`proxy-deluge`) forwards the Deluge daemon port (58846) from the root namespace so the thin client can still connect. The proxy is available on `127.0.0.1:58846`.

## Service Reference

| Service | Port | Config file | API key location |
|---------|------|-------------|------------------|
| Deluge (daemon) | 58846 | `/var/lib/deluge/auth` | N/A (firewall-enforced) |
| Deluge (web UI) | 8112 | — | — |
| Sonarr | 8989 | `/var/lib/sonarr/config.xml` | `config.media-server.apiKeys.sonarr` |
| Radarr | 7878 | `/var/lib/radarr/config.xml` | `config.media-server.apiKeys.radarr` |
| Lidarr | 8686 | `/var/lib/lidarr/config.xml` | `config.media-server.apiKeys.lidarr` |
| Prowlarr | 9696 | `/var/lib/prowlarr/config.xml` | `config.media-server.apiKeys.prowlarr` |
| Bazarr | 6767 | `/var/lib/bazarr/config/config.ini` | set automatically from Sonarr/Radarr keys |
| Unpackerr | — | `/var/lib/unpackerr/unpackerr.conf` | configured via *arr API keys (auto-extraction); metrics endpoint disabled by default |
| Seerr | 5055 | `/var/lib/seerr/settings.json` | pre-seeded (Plex OAuth login) |
| Plex | 32400 | `/var/lib/plex` | N/A |
| declarr | — | `/var/lib/declarr` | auto-configured from `config.media-server.apiKeys.*` |

## Customization

### Disk device

The target disk is set in `hosts/media-server/disko.nix` — change `device` to match your hardware before running disko:

```nix
disko.devices.disk.main.device = "/dev/nvme0n1";  # or /dev/sda, /dev/vda, etc.
```

### API keys

Keys are derived deterministically from the hostname. To override any of them, set the option in your host config:

```nix
{ ... }: {
  media-server.apiKeys.sonarr = "my-custom-key";
}
```

To use external secret files (keeping keys out of the repo entirely):

```nix
{ ... }: {
  media-server.apiKeys.sonarr = builtins.readFile ./secrets/sonarr-key;
}
```

Then add `secrets/` to `.gitignore`.

### Firewall

The host firewall blocks all inbound traffic on physical interfaces by default. Only the `tailscale0` and `lo` interfaces are trusted. Each service exposes its port on the tailnet only unless `openFirewall = true` is set.

To restrict further, see the firewall section under [Security Architecture](#security-architecture).

### VPN provider WireGuard config

The VPN confinement module expects a standard WireGuard `.conf` file. You generate this on any machine (your laptop, a desktop, wherever), then copy the resulting file to the server via `scp`.

> **The `.conf` file contains a PrivateKey — treat it as a secret and never commit it to the repository.**

#### NordVPN

NordVPN uses a proprietary NordLynx protocol (based on WireGuard) and does not distribute `.conf` files directly. The [`wgnord`](https://search.nixos.org/packages?show=wgnord) tool (available in nixpkgs 24.11) generates one from your access token.

**1. Create an access token**

Go to [NordVPN access tokens](https://my.nordaccount.com/dashboard/nordvpn/access-tokens/) and generate a new token.

**2. Generate a WireGuard `.conf` file**

Run this on any machine with Nix (your laptop, a desktop, etc.):

```bash
# Enter a shell with wgnord and its dependencies
nix shell nixpkgs#wgnord nixpkgs#wireguard-tools nixpkgs#openresolv

# Set up the template
sudo mkdir -p /var/lib/wgnord
sudo curl -o /var/lib/wgnord/template.conf \
  https://raw.githubusercontent.com/phirecc/wgnord/master/template.conf

# Log in with your NordVPN access token
sudo wgnord l "your-access-token"

# Generate the config for a specific country (e.g. us, de, nl)
sudo wgnord c us

# The config is now at /etc/wireguard/wgnord.conf
```

If your local machine isn't NixOS (e.g. Ubuntu with Nix installed), the `nix shell` command works identically.

**3. Copy to the server**

```bash
scp /etc/wireguard/wgnord.conf media-server:/etc/nixos/secrets/vpn.conf
```

On the server:

```bash
sudo chmod 600 /etc/nixos/secrets/vpn.conf
```

**4. (Optional) Clean up wgnord state on your local machine**

```bash
sudo rm -rf /var/lib/wgnord /etc/wireguard/wgnord.conf /etc/wireguard/wgnord.key
```

## Auto-Updates

A systemd timer runs every 15 minutes: `git fetch origin` + `git merge --ff-only` + `nixos-rebuild switch`. The service checks for uncommitted changes before pulling, so local modifications won't be overwritten.

## Nix Store Maintenance

Garbage collection runs daily, removing generations older than 30 days:

```nix
nix.gc = {
  automatic = true;
  dates = "daily";
  options = "--delete-older-than 30d";
};
```

The store is also automatically optimised after every build to deduplicate identical files:

```nix
nix.settings.auto-optimise-store = true;
```

With aggressive GC, the `/nix` subvolume (50G allocated, pooled via Btrfs) stays well within bounds for a headless server.

## Automated Configuration

On first boot, [declarr](https://github.com/upidapi/declarr) runs automatically after all *arr services start and configures the following via their REST APIs:

| What | Details |
|------|---------|
| **Deluge download client** | Added to Sonarr, Radarr, and Lidarr |
| **Root folders** | `/media/tv` (Sonarr), `/media/movies` (Radarr), `/media/music` (Lidarr) |
| **Prowlarr applications** | Sonarr, Radarr, and Lidarr registered with full sync |
| **Prowlarr app profiles** | Standard, Automatic, and Interactive Search profiles created |
| **Authentication** | Disabled by default — no login prompts |

Additionally, Bazarr and Unpackerr are pre-configured via their config files on first start with the appropriate *arr API keys and connections. Seerr is pre-configured with Sonarr and Radarr connections.

No manual service-to-service configuration is needed.


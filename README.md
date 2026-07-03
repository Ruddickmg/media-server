# Media Server — NixOS Flake

NixOS configuration for a media server running Plex, Deluge, and the *arr suite with security hardening.

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

This machine is a repurposed laptop running as a dedicated server. The following are configured automatically:

| Setting | Behavior |
|---------|----------|
| **SSH** | OpenSSH with key-only auth (`PasswordAuthentication=false`), socket-activated |
| **Lid close** | Ignored — system stays running |
| **Suspend / Hibernate** | Disabled entirely — all sleep targets masked |
| **Power/Sleep keys** | Ignored |
| **CPU governor** | `performance` (always plugged in) |
| **Sudo** | Passwordless for `wheel` group members |

### Auto-power-on after power loss

> **BIOS/firmware setting — not configurable from NixOS.**

To make the laptop boot automatically when plugged in after a power loss, you must set the **"After Power Loss"** (or *"AC Recovery" / "Restore on AC Power Loss"*) option in your BIOS setup to **"Power On"** or **"Last State"**. This is typically found in the *Power Management* menu. Not all laptops support this feature.

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
sudo nix run github:nix-community/disko -- --mode disko /mnt/etc/nixos/hosts/media-server/disko.nix
```

This creates the partition table, filesystems, and Btrfs subvolumes, then mounts everything.

### 5. Generate hardware config

```bash
nixos-generate-config --root /mnt --dir /mnt/etc/nixos/hosts/media-server
```

This overwrites `hosts/media-server/hardware-configuration.nix` with the autodetected kernel modules for your machine. Disko handles `fileSystems` and `swap` — the generated config only needs `boot.initrd.availableKernelModules`.

### 6. Install

```bash
sudo nixos-install --flake /mnt/etc/nixos#media-server
```

Set the root password when prompted.

### 7. Reboot

```bash
sudo reboot
```

### 8. Authenticate Tailscale

```bash
tailscale up --accept-routes
```

Once authenticated, the server is reachable via the Tailscale IP rather than exposing ports on your LAN.

## Post-Deploy Steps

These steps require the web UIs — they involve credentials you provide (indexer accounts) or state stored in application databases (connection configs).

### Form authentication setup

If `media-server.security.enableAuthentication = true` (default), the *arr web UIs require a username and password on first visit. Set these via each service's web UI before configuring them.

### Deluge thin client

1. Read the auto-generated password:
   ```bash
   journalctl -u deluged.service | grep "localclient"
   ```
   Or check the option value:
   ```bash
   nix eval '.#nixosConfigurations.media-server.config.media-server.credentials.delugePassword'
   ```

2. Connect with the Deluge Thin Client:
   - Daemon host: `<machine-ip>` or `<tailscale-ip>`
   - Port: `58846`
   - Username: `localclient`
   - Password: *(from step 1)*

### Prowlarr — add indexers

1. Open `http://<machine-ip>:9696`
2. Add your torrent indexers (requires your account credentials for each indexer)

### Sonarr, Radarr, Lidarr — connect to Deluge

For each service:

1. Open its web UI:
   - Sonarr: `http://<machine-ip>:8989`
   - Radarr: `http://<machine-ip>:7878`
   - Lidarr: `http://<machine-ip>:8686`
2. Go to **Settings → Download Clients → Add**
3. Select **Deluge**
4. Set:
   - Host: `127.0.0.1`
   - Port: `58846`
   - Password: *(Deluge password from above)*
   - Category: `sonarr`, `radarr`, or `lidarr` (match the app)
5. Test and save

### Seeding and ratio management

Deluge's global seeding ceiling is set intentionally high (`stop_seed_ratio = 3.0`, `seed_time_limit = 14` days) as a safety net for manually-added torrents. It should never be hit by *arr-managed torrents — those are handled per-indexer.

For each indexer, set realistic seed goals in Sonarr, Radarr, and Lidarr:

1. Go to **Settings → Indexers**
2. Click an indexer, then **Show Advanced** (top right)
3. Set **Seed Ratio** and/or **Seed Time** (e.g. `2.0` or `72` hours)
4. Repeat for each indexer

Prowlarr can sync these settings to all connected *arrs from **Settings → Apps** if you enable **Sync Seed Ratio** / **Sync Seed Time** on each app. Once configured, the *arr will remove the torrent from Deluge when the goal is met, well before the global ceiling kicks in.

### Prowlarr — sync to Sonarr, Radarr, Lidarr

1. Open `http://<machine-ip>:9696`
2. Go to **Settings → Apps**
3. Add Sonarr, Radarr, and Lidarr as applications:
   - Each connects to `http://127.0.0.1:<port>`
   - API key: found in `/var/lib/<service>/config.xml` on the server, or via:
     ```bash
     nix eval '.#nixosConfigurations.media-server.config.media-server.apiKeys.sonarr'
     ```

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
| **Tailscale-only** | Sonarr, Radarr, Lidarr, Prowlarr, Bazarr, Unpackerr, Deluge, Seerr | Via Tailscale IP (`http://100.x.x.x:<port>`) | Plex OAuth (Seerr) / Forms auth + Tailscale identity |
| **Open port** | Plex (32400) | Direct via LAN IP or public IP; Plex app/TV app | Plex.tv account auth |

**Plex** has `openFirewall = true` by default because it's designed to be shared with friends and family. They connect via the Plex app on their TV, phone, or browser — no Tailscale needed. Plex handles authentication itself (Plex.tv accounts).

> **DLNA note:** Plex also opens UDP ports 1900 (DLNA) and 5353 (mDNS) for local device discovery. DLNA broadcasts your library to any device on your LAN without authentication. This is fine for a home network. If you want to disable it, turn off DLNA in Plex's settings.

**All other services** are locked down to Tailscale only — their ports are not opened on any physical interface. You access them via the Tailscale IP (e.g., `http://100.x.x.x:8989` for Sonarr). To expose them on LAN as well, set the service's `openFirewall = true` or add ports to the interface directly:

```nix
networking.firewall.interfaces."enp0s3".allowedTCPPorts = [ 8989 7878 ];
```

### Form-based authentication

All *arr services (Sonarr, Radarr, Lidarr, Prowlarr) are configured to use Forms authentication. On the first visit to each web UI, you must set an admin username and password. This can be disabled per-service by setting:

```nix
media-server.security.enableAuthentication = false;
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

Plex skips `CapabilityBoundingSet` and `MemoryDenyWriteExecute` for transcoding compatibility.

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
| Deluge (daemon) | 58846 | `/var/lib/deluge/auth` | N/A (password-based) |
| Deluge (web UI) | 8112 | — | — |
| Sonarr | 8989 | `/var/lib/sonarr/config.xml` | `config.media-server.apiKeys.sonarr` |
| Radarr | 7878 | `/var/lib/radarr/config.xml` | `config.media-server.apiKeys.radarr` |
| Lidarr | 8686 | `/var/lib/lidarr/config.xml` | `config.media-server.apiKeys.lidarr` |
| Prowlarr | 9696 | `/var/lib/prowlarr/config.xml` | `config.media-server.apiKeys.prowlarr` |
| Bazarr | 6767 | `/var/lib/bazarr/config/config.ini` | set automatically from Sonarr/Radarr keys |
| Unpackerr | — | — | folder-based (no API config needed) |
| Seerr | 5055 | `/var/lib/seerr/settings.json` | pre-seeded via `disko` (Plex OAuth login) |
| Plex | 32400 | `/var/lib/plex` | N/A |

## Customization

### Disk device

The target disk is set in `hosts/media-server/disko.nix` — change `device` to match your hardware before running disko:

```nix
disko.devices.disk.main.device = "/dev/nvme0n1";  # or /dev/sda, /dev/vda, etc.
```

### API keys and passwords

Keys are derived deterministically from the hostname. To override any of them, set the option in your host config:

```nix
{ ... }: {
  media-server.apiKeys.sonarr = "my-custom-key";
  media-server.credentials.delugePassword = "my-password";
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

A systemd timer runs daily: `git pull --ff-only` + `nixos-rebuild switch`. The service checks for uncommitted changes and unclean working trees before pulling, so local modifications won't be overwritten.

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

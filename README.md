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

Directory layout on the NixOS machine:

```
/media/
├── downloads/
│   ├── incomplete/   # Deluge active downloads
│   └── completed/    # Finished downloads (watched by Unpackerr)
├── movies/           # Managed by Radarr
├── tv/               # Managed by Sonarr
└── music/            # Managed by Lidarr
```

All services share the `media` group for file access.

## Quick Start

### 1. Clone on the target NixOS machine

```bash
git clone <repo-url> /etc/nixos
```

### 2. Generate hardware config

```bash
nixos-generate-config --dir /etc/nixos/hosts/media-server
```

This overwrites `hosts/media-server/hardware-configuration.nix` with the autodetected hardware config for your machine.

### 3. Rebuild

```bash
nixos-rebuild switch --flake /etc/nixos
```

### 4. Authenticate Tailscale

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

## Security Architecture

### Remote access via Tailscale

All services listen on `0.0.0.0` but the host firewall blocks all external interfaces by default. The `tailscale0` interface is trusted, so traffic from the tailnet is allowed. This means you access the web UIs via the Tailscale IP (e.g., `http://100.x.x.x:8989`).

To access from the same physical network (LAN), override the firewall:

```nix
networking.firewall.interfaces."enp0s3".allowedTCPPorts = [ 32400 8989 7878 8686 9696 6767 ];
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
| Plex | 32400 | `/var/lib/plex` | N/A |

## Customization

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

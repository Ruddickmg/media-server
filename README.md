# Media Server — NixOS Flake

NixOS configuration for a media server running Plex, Deluge, and the *arr suite with security hardening and fully automated service configuration.

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

### 5. Generate hardware config

```bash
nixos-generate-config --root /mnt --dir hosts/media-server --no-filesystems
```

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

The private key (`~/.ssh/media-server`) is yours alone — never commit it.

## HTTPS Access

The *arr web UIs are served over HTTPS with automatically-provisioned Let's Encrypt certificates via **Tailscale Serve**. Tailscale terminates TLS and proxies to a local Caddy instance, which routes by path prefix to each service.

| URL | Service |
|-----|---------|
| `https://media-server.tailbac0df.ts.net` | Seerr |
| `https://media-server.tailbac0df.ts.net/seerr` | Seerr |
| `https://media-server.tailbac0df.ts.net/prowlarr` | Prowlarr |
| `https://media-server.tailbac0df.ts.net/sonarr` | Sonarr |
| `https://media-server.tailbac0df.ts.net/radarr` | Radarr |
| `https://media-server.tailbac0df.ts.net/lidarr` | Lidarr |
| `https://media-server.tailbac0df.ts.net/bazarr` | Bazarr |
| `https://media-server.tailbac0df.ts.net:19999` | Netdata |
| `https://media-server.tailbac0df.ts.net:6789`  | Gotify |

The hostname is the machine's MagicDNS name (check `tailscale status` for yours).

> **Prerequisite:** Enable **HTTPS Certificates** in the Tailscale admin console (DNS → HTTPS Certificates). Without this, Tailscale Serve cannot provision TLS certificates.

## Post-Deploy Steps

### Prowlarr — add indexers

1. Open `https://media-server.tailbac0df.ts.net/prowlarr`
2. Add your torrent indexers (requires your account credentials for each indexer)

Indexers added in Prowlarr are automatically synced to Sonarr, Radarr, and Lidarr via the pre-configured application connections.

### Seeding and ratio management

Deluge's global seeding ceiling is set intentionally high (`stop_seed_ratio = 3.0`, `seed_time_limit = 30` days) as a safety net for manually-added torrents. It should never be hit by *arr-managed torrents — those are handled per-indexer.

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

On first deploy, Seerr is pre-configured with Sonarr and Radarr connections.

1. Open `https://media-server.tailbac0df.ts.net/seerr`
2. Sign in with your **Plex account** (Seerr uses Plex for authentication)
3. Configure user permissions and notification settings as desired

> If you add custom quality profiles in Sonarr/Radarr later, update the profile selection in Seerr's service settings to match.

### Gotify — push notifications

Gotify receives alert notifications from Netdata (service failures, high CPU/RAM/disk usage) and from the NixOS auto-update (build succeeded).

1. Open `https://media-server.tailbac0df.ts.net:6789`
2. Log in with the default credentials: `admin` / `admin`
3. Go to **Apps** and click **Create Application**
4. Name it `Media Server Alerts` and click **Create**
5. Copy the generated token
6. On the server, save the token:
   ```bash
   echo "<your-token>" | sudo tee /etc/nixos/secrets/gotify-token
   ```
7. The token is read at runtime — no rebuild is required.
   - **Netdata and the auto-update script** read the file live and will start sending alerts immediately.
   - **Sonarr, Radarr, Lidarr, and Prowlarr** will pick up the Gotify notification connection on their next declarr sync (or restart the `declarr` service to force it: `systemctl restart declarr`).

## Security Architecture

### Access model

| Tier | Services | How to access | Auth |
|------|----------|---------------|------|
| **Tailscale HTTPS** | Prowlarr, Sonarr, Radarr, Lidarr, Bazarr, Seerr (path-based) | `https://media-server.tailbac0df.ts.net/<service>` (path-based via Tailscale Serve + Caddy) | Tailscale identity |
| **Tailscale HTTPS** | Netdata, Gotify (port-based) | `https://media-server.tailbac0df.ts.net:<port>` (direct via Tailscale Serve) | Tailscale identity |
| **Tailscale RPC** | Deluge (daemon) | `media-server:58846` (native Deluge RPC protocol) | `localclient:deluge` (auth file) |
| **Tailscale-only** | Unpackerr | internal only | N/A |
| **Open port** | Plex (32400) | Direct via LAN IP or public IP; Plex app | Plex.tv account auth |

**Plex** has `openFirewall = true` by default because it's designed to be shared with friends and family.

> **DLNA note:** Plex also opens UDP ports 1900 (DLNA) and 5353 (mDNS) for local device discovery. DLNA broadcasts your library to any device on your LAN without authentication. If you want to disable it, turn off DLNA in Plex's settings.

All *arr apps bind exclusively to `127.0.0.1` — they have no direct network listener. Web UI access goes through **Tailscale Serve** which terminates TLS, then a local Caddy reverse proxy routes by path prefix to the correct service.

**Deluge** is accessed via its native RPC protocol on port 58846. The thin client (`deluge-gtk` / `deluge-console`) connects over Tailscale — fully encrypted.

**Bazarr and Seerr** are routed through Caddy and Tailscale Serve — same HTTPS URLs as the *arr apps. **Unpackerr** has no web UI (internal only).

To expose any service on LAN as well, set its `openFirewall = true`:

```nix
networking.firewall.interfaces."enp0s3".allowedTCPPorts = [ 8989 7878 ];
```

For VPN confinement details, see [VPN confinement](#vpn-confinement).

## Service Reference

| Service | Port | Access |
|---------|------|--------|
| Plex | 32400 | `http://<lan-ip>:32400/web` or Plex app |
| Seerr | 5055 | `https://media-server.tailbac0df.ts.net/seerr` |
| Seerr | 5055 | `https://media-server.tailbac0df.ts.net` |
| Deluge (daemon) | 58846 | `media-server:58846` (thin client RPC) |
| Prowlarr | 9696 | `https://media-server.tailbac0df.ts.net/prowlarr` |
| Sonarr | 8989 | `https://media-server.tailbac0df.ts.net/sonarr` |
| Radarr | 7878 | `https://media-server.tailbac0df.ts.net/radarr` |
| Lidarr | 8686 | `https://media-server.tailbac0df.ts.net/lidarr` |
| Bazarr | 6767 | `https://media-server.tailbac0df.ts.net/bazarr` |
| Netdata | 19999 | `https://media-server.tailbac0df.ts.net:19999` |
| Gotify | 6789 | `https://media-server.tailbac0df.ts.net:6789` |

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

### VPN confinement

Deluge can be isolated in a dedicated network namespace with a WireGuard VPN to anonymize torrent traffic. This provides a built-in kill switch — if the VPN drops, Deluge has no network access.

A proxy service (`proxy-deluge`) forwards the daemon port (58846) from the root namespace so the thin client can still connect.

The module expects a standard WireGuard `.conf` file. This file contains a PrivateKey — **treat it as a secret and never commit it to the repository.**

#### Generating a config (Proton VPN)

Proton VPN provides standard WireGuard `.conf` files directly from their web dashboard.

1. Log in at [account.protonvpn.com](https://account.protonvpn.com)
2. Go to **Account → Downloads → WireGuard configuration**
3. Select a **P2P** server (double-arrow icon)
4. Enable **NAT-PMP (port forwarding)** under VPN options
5. Download the `.conf` file
6. Copy the private key to the server to a file in `/etc/nixos/secrets/vpn-key`
7. set permissions for key:
```bash
ssh media-server sudo chmod 600 /etc/nixos/secrets/vpn-key
```

#### Enabling

Open `hosts/media-server/default.nix` and copy the non-secret fields from the wireguard configuration into the `vpn` block:

```nix
media-server = {
  vpn.enable = true;
  vpn.privateKeyFile = "/etc/nixos/secrets/vpn-key";
  # If your provider assigns both IPv4 and IPv6 addresses, pass both as a list.
  vpn.address = [ "10.2.0.2/32" "2a07:b944::2:2/128" ];  # from [Interface] Address
  vpn.peerPublicKey = "...";                            # from [Peer] PublicKey
  vpn.endpoint = "...";                                 # from [Peer] Endpoint
  vpn.dns = [ "10.2.0.1" "2a07:b944::2:1" ];            # from [Interface] DNS
  deluge.vpnConfinement = true;
};
```

#### Port forwarding

When `deluge.vpnConfinement` is enabled, Deluge runs inside the VPN namespace and its BitTorrent listen port is refreshed automatically from Proton's NAT-PMP every ~45 s. You do not need to configure the port manually. The thin client is unaffected — it still connects to the daemon RPC port (`58846`) through `proxy-deluge`.

## Auto-Updates

A systemd timer runs every 15 minutes: `git fetch origin` + `git merge --ff-only` + `nixos-rebuild switch`. The service checks for uncommitted changes before pulling, so local modifications won't be overwritten.

# Media Server — NixOS Flake

NixOS configuration for a media server running Plex, Deluge, and the *arr suite.

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

### 4. Add your SSH public key

Public keys are committed to the repo and baked into the system at build time, so add yours before installing:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/media-server
cat ~/.ssh/media-server.pub
```

Add the output to `hosts/media-server/default.nix`:

```nix
media-server.headless.authorizedKeys = [
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIL4J... user@laptop"
];
```

The private key (`~/.ssh/media-server`) is yours alone — never commit it. To add a key after installation, edit the same list and run `nixos-rebuild switch`.

### 5. Create the Tailscale auth key

Place a reusable Tailscale auth key on the install media before installing:

```bash
mkdir -p /mnt/etc/nixos/secrets
echo "tskey-auth-<your-auth-key>" > /mnt/etc/nixos/secrets/tailscale-auth
chmod 600 /mnt/etc/nixos/secrets/tailscale-auth
```

Generate the auth key from the [Tailscale admin console](https://login.tailscale.com/admin/settings/keys) — use a **reusable** key so it persists across rebuilds. The `secrets/` directory is gitignored and never committed to the repository.

### 6. Partition and format

```bash
sudo nix run --extra-experimental-features nix-command --extra-experimental-features flakes github:nix-community/disko -- --mode disko /mnt/etc/nixos/hosts/media-server/disko.nix
```

### 7. Generate hardware config

```bash
nixos-generate-config --root /mnt --dir hosts/media-server --no-filesystems
```

### 8. Install

```bash
sudo nixos-install --flake /mnt/etc/nixos#media-server
```

Set the root password when prompted.

### 9. Reboot

```bash
sudo reboot
```

## Connecting

SSH is key-only (no passwords). Connect as the `media-server` user:

```bash
ssh -i ~/.ssh/media-server media-server@<machine-ip>
```

### Terminal sessions with tuios

The server ships [tuios](https://tuios.dev) (v0.9.3). You can run it on the server after logging in, or attach to sessions on the server from tuios running on your own machine — with nothing nested. Run these on your **local** machine (tuios ≥ 0.8.0):

```bash
# Add the server once. `media-server` is its MagicDNS name.
tuios hosts add media-server media-server@media-server
# or let tuios fill the address from the tailnet:
tuios hosts add media-server --tailnet

# Start the server's tuios daemon if it is not running (on demand; no systemd service).
tuios hosts test media-server --start

# Draw a session running on the server in your local client, or create one.
tuios attach --host media-server
tuios new --host media-server work
```

tuios reaches the server over ssh on the tailnet — there is no extra port to open. If your tailnet's SSH rules use check mode, approve the login once when prompted.

Running `tuios` directly on the server after `ssh` also works and starts the same per-user daemon; sessions survive an SSH drop and reattach with `tuios attach`. See `tuios --help` and the [tuios docs](https://tuios.dev) for keybindings and hosts.

### Service access

| Service | Port | Access | Auth |
|---------|------|--------|------|
| Prowlarr | 9696 | `https://media-server.tailbac0df.ts.net/prowlarr` | Tailscale admin |
| Sonarr | 8989 | `https://media-server.tailbac0df.ts.net/sonarr` | Tailscale admin |
| Radarr | 7878 | `https://media-server.tailbac0df.ts.net/radarr` | Tailscale admin |
| Lidarr | 8686 | `https://media-server.tailbac0df.ts.net/lidarr` | Tailscale admin |
| Bazarr | 6767 | `https://media-server.tailbac0df.ts.net/bazarr` | Tailscale admin |
| autobrr | 7474 | `https://media-server.tailbac0df.ts.net/autobrr` | Tailscale admin |
| Seerr | 5055 | `https://media-server.tailbac0df.ts.net/seerr` (also root `/`) | Plex sign-in (all Tailscale users) |
| Profilarr | 6865 | `https://media-server.tailbac0df.ts.net:6868` | Onboarding wizard |
| Beszel | 8090 | `https://media-server.tailbac0df.ts.net:28090` | Beszel login |
| Gotify | 6789 | `https://media-server.tailbac0df.ts.net:6789` | Gotify login |
| Plex | 32400 | `http://<lan-ip>:32400/web` or the Plex app | Plex.tv account |
| Deluge | 58846 | `media-server:58846` (thin client RPC) | Deluge auth file |
| Unpackerr | — | internal only | — |

The hostname is the machine's MagicDNS name (check `tailscale status` for yours).

> **Prerequisite:** Enable **HTTPS Certificates** in the Tailscale admin console (DNS → HTTPS Certificates). Without this, the HTTPS URLs above cannot provision TLS certificates.

**Admin-only access:** Prowlarr, Sonarr, Radarr, Lidarr, Bazarr, and autobrr are restricted to Tailscale users listed in `media-server.administrators` (defaults to `["ruddickmg@gmail.com"]`). Seerr is open to all Tailscale users so family members can make requests. To change the admin list:

```nix
media-server.administrators = [ "your@email.com" ];
```

**Plex** is reachable directly (LAN or public IP) because it is designed to be shared; Plex.tv account auth applies. To expose any other service on the LAN as well, see [Firewall](#firewall).

> **DLNA note:** Plex also opens UDP ports 1900 (DLNA) and 5353 (mDNS) for local device discovery, which broadcasts your library to any device on the LAN without authentication. Turn off DLNA in Plex's settings to stop this.

## Post-Deploy Steps

### Prowlarr — add indexers

1. Open `https://media-server.tailbac0df.ts.net/prowlarr`
2. Add your torrent indexers (requires your account credentials for each indexer)

### autobrr — add IRC indexers

1. Open `https://media-server.tailbac0df.ts.net/autobrr`
2. Go to **Settings → Indexers → Add New Indexer** and add your trackers' IRC announce channels and account credentials

### Seeding and ratio management

Deluge has no seeding limits by default. To set a global safety net, configure the optional limits in your host config:

```nix
media-server.deluge.seedRatioLimit = 3.0;   # stop at 3.0 share ratio
media-server.deluge.seedTimeLimit = 86400;   # stop after 60 days (in minutes)
```

Either or both can be set independently. When unset, there is no limit.

For each indexer, set realistic seed goals in Prowlarr's **Settings → Indexers** (select an indexer → **Show Advanced**).

### Disk-space download guard

Deluge halts downloads when free disk space runs low (preventing the disk-full failure that can corrupt the system). By default it stops downloads when free space on `/media` drops below **5 GB** and resumes when it recovers above **10 GB**, checking every minute.

To adjust, configure in your host config:

```nix
media-server.deluge.diskGuard.thresholdGiB = 8;   # halt below 8 GB free
media-server.deluge.diskGuard.resumeGiB = 15;     # resume above 15 GB free
media-server.deluge.diskGuard.intervalMins = 5;   # check every 5 minutes
media-server.deluge.diskGuard.notify = false;     # disable Gotify alerts
```

### Deleting media completely

Deleting a file from the library leaves its hard links behind — the copy in `/media/downloads/completed` (and the cross-seed link in `/media/downloads/xseeds`) — so disk space is never freed. To remove a file or a whole movie/show folder together with every hard link:

```bash
delete-media /media/movies/Some\ Movie\ (2020)
```

The command lists every hard link it found, asks for confirmation, deletes them all, and prunes the emptied folders. Remove the torrent from Deluge first if it is still seeding.

**Deleting from the Plex UI** also removes every hard link, so no Plex settings are needed for this to work. Verify with `journalctl -u delete-media-watch` after a deletion.

### Plex — add libraries

1. Open `http://<machine-ip>:32400/web`
2. Claim your server
3. Add libraries:
   - **Movies** → `/media/movies`
   - **TV Shows** → `/media/tv`
   - **Music** → `/media/music`

### Plex — hardware transcoding

The server hardware-transcodes with the host CPU's integrated GPU (Intel Quick Sync). Turn it on in the dashboard:

1. Open **Settings → Transcoder** in the Plex web UI
2. Enable **Use hardware-accelerated video**
3. Under **Transcoder quality**, pick **Custom** and choose the **Intel (QSV)** setting

**If you move the server to a different computer, re-check the driver config.** The graphics driver in `modules/graphics.nix` is pinned to the CPU the box shipped with, and the wrong one means Plex silently drops back to software transcoding. Check the new host with `lspci | grep -i vga`, then update `modules/graphics.nix`:

| New host GPU | Change in `modules/graphics.nix` |
| --- | --- |
| Intel Broadwell (2014) or newer | No change — `intel-media-driver` is correct |
| Intel older than Broadwell | Swap `intel-media-driver` for `intel-vaapi-driver` (unmaintained; decode only) |
| NVIDIA or AMD | Different driver entirely — `intel-media-driver` will not work, and NVIDIA also needs a nonfree driver enabled |

To confirm the driver loaded after any change:

```bash
nix shell nixpkgs#vainfo -c vainfo
```

`Driver version: Intel iHD` in the output means Plex can use the GPU. If that command reports no driver at all, the config is wrong for the host. Plex falls back to software automatically for anything the hardware cannot handle.

### Seerr — media request portal

Seerr provides a clean UI for friends and family to request movies and TV shows, which flow through Sonarr and Radarr automatically.

1. Open `https://media-server.tailbac0df.ts.net/seerr`
2. Sign in with your **Plex account** (Seerr uses Plex for authentication)
3. Configure user permissions and notification settings as desired

> Profilarr manages quality profiles and custom formats for Sonarr and Radarr. After configuring profiles in Profilarr, update the profile selection in Seerr's service settings to match.

### Beszel — monitoring hub

Access the dashboard at `https://media-server.tailbac0df.ts.net:28090`.

**Admin credentials** (configurable, simple defaults):
- Email: `ruddickmg@gmail.com` (default — change via `media-server.beszel.adminEmail`)
- Password: `admin` (default — change via `media-server.beszel.adminPassword`)

Override them in your host configuration:

```nix
media-server.beszel.adminEmail = "your@email.com";
media-server.beszel.adminPassword = "your-password";
```

> **Changing credentials:** these values are only consumed when the hub first initializes its data directory. To change them, delete `/var/lib/beszel-hub/beszel_data` and restart `beszel-hub.service`.

### Gotify — push notifications

Access the notification dashboard at `https://media-server.tailbac0df.ts.net:6789` (login: `admin` / `admin`).

For Beszel monitoring alerts, configure a notification in the Beszel web UI (Settings → Notifications) with the Shoutrrr format `gotify://127.0.0.1:6789/<your-token>?priority=1`.

### Profilarr — quality profiles and custom formats

Profilarr manages quality profiles and custom formats for Radarr and Sonarr via a web UI. It connects to curated databases (Dictionarry, TRaSH Guides) and syncs configurations directly to your *arr instances.

1. Open `https://media-server.tailbac0df.ts.net:6868`
2. Complete the onboarding wizard (set username/password)
3. Go to **Databases** and link the **Dictionarry** repository (already pre-configured)
4. Import the profiles you want (e.g., `1080p Quality`, `2160p Quality`)
5. Go to **Sync** and push profiles to both instances

> **Note:** Declarr no longer manages quality profiles or custom formats. It only handles base configuration (API keys, download clients, root folders, notifications). All profile management is done through Profilarr.

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

Each service exposes its port on the tailnet only unless `openFirewall = true` is set. To expose a service on the LAN as well, set `openFirewall = true` in its host config or open the port directly:

```nix
networking.firewall.interfaces."enp0s3".allowedTCPPorts = [ 8989 7878 ];
```

### VPN confinement

Deluge can be isolated in a dedicated network namespace with a WireGuard VPN to anonymize torrent traffic. This provides a built-in kill switch — if the VPN drops, Deluge has no network access.

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

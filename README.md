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

Then replace the storage placeholders in `hosts/media-server/storage-paths.nix` with the real HDD mount points and `/dev/disk/by-id/...` device paths (see [Storage layout](#storage-layout)).

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

## Files & secrets

The system expects the flake at `/etc/nixos` and reads a few files from fixed locations. `secrets/` and `hardware-configuration.nix` are gitignored, so they live only on the server.

| Path | Contents | How it gets there |
|------|----------|-------------------|
| `/etc/nixos` | This flake — the system rebuilds from it and auto-update pulls into it | `git clone` the repo there before installing ([step 2](#2-clone-the-flake)) |
| `/etc/nixos/hosts/media-server/disko.nix` | Disk layout | You edit `device` before installing ([step 3](#3-set-the-target-disk)) |
| `/etc/nixos/hosts/media-server/storage-paths.nix` | SSD/HDD mount points and device IDs | You replace the placeholders before the first switch ([step 3](#3-set-the-target-disk)) |
| `/etc/nixos/hosts/media-server/default.nix` | Includes your SSH public key(s) | You add them before installing ([step 4](#4-add-your-ssh-public-key)) |
| `/etc/nixos/hosts/media-server/hardware-configuration.nix` | Host hardware config | Generated on the host by `nixos-generate-config` ([step 7](#7-generate-hardware-config)); gitignored |
| `/etc/nixos/secrets/tailscale-auth` | Reusable Tailscale auth key | You create it before installing ([step 5](#5-create-the-tailscale-auth-key)); gitignored |
| `/etc/nixos/secrets/vpn-key` | WireGuard private key | You create it before enabling VPN (see [VPN confinement](#vpn-confinement)); gitignored |
| `/etc/nixos/secrets/gotify-token` | Gotify app token for notifications | Created automatically on first boot — do not add it |

The clone must leave the repo at `/etc/nixos` and tracking `origin/main`: the auto-update service pulls that branch on the server, so changes made on your workstation are pushed and then applied automatically.

## Storage layout

Media lives on two tiers joined into a single `/media` view:

| Path | What it is |
|------|------------|
| `/mnt/ssd` | SSD cache (`@media` btrfs subvolume). New downloads land here. |
| `/mnt/hdd1`, `/mnt/hdd2`, … | Data HDDs in the JBOD enclosure, one ext4 filesystem each |
| `/mnt/hddpool` | mergerfs union of the data HDDs (backing pool) |
| `/mnt/parity1` | SnapRAID parity disk |
| `/media` | mergerfs union of `/mnt/ssd` then `/mnt/hddpool` — the path every service uses |
| `/nas` | bind mount of `/media/data/nas/public` — public SMB share |
| `/nas-private` | bind mount of `/media/data/nas/private` — private SMB share |

Everything lives under `data/` so a tree can be moved between tiers as a unit:

```
/media/data/torrents/incomplete   active downloads (SSD only)
/media/data/torrents/complete     finished torrents (SSD, moved to the HDDs when cold)
/media/data/torrents/xseeds       cross-seed hard links
/media/data/library/movies
/media/data/library/tv
/media/data/library/music
/media/data/nas/public            public NAS share
/media/data/nas/private           private NAS share
```

`/media` fills the SSD first and only spills to the HDD pool when the SSD has less than 50 GiB free. A mover checks usage every 15 minutes, compares NAS files and media files in one least-recently-accessed queue, moves whole hard-link sets together, starts at 85% SSD usage, and keeps going until it is below 60%. A file that appears never to have been read since it was written gets a two-week grace period; if the normal queue cannot reach 60%, those files are moved oldest-first by modification time instead of leaving the SSD under pressure (see [SSD-to-HDD mover](#ssd-to-hdd-mover)).

### Set the real paths and devices

`hosts/media-server/storage-paths.nix` is the single source of truth for the mounts. Replace the placeholders before the first switch on a host:

```nix
{
  ssd = "/mnt/ssd";
  hddPool = "/mnt/hddpool";
  unified = "/media";

  hddDisks = {
    hdd1 = {
      mountPoint = "/mnt/hdd1";
      device = "/dev/disk/by-id/ata-WDC_WD240EDAZZ-...";   # ls -l /dev/disk/by-id/
    };
  };

  parityDisks = { };
  parityFiles = [ "/mnt/parity1/snapraid.parity" ];
}
```

Use `/dev/disk/by-uuid/...` (the filesystem UUID from `blkid`) or `/dev/disk/by-id/...` so the disk order in the enclosure does not matter. Format a new data disk as ext4, for example:

```bash
sudo mkfs.ext4 -L hdd1 /dev/disk/by-id/ata-WDC_WD240EDAZZ-...
```

Add each additional data disk to `hddDisks`; both mergerfs pools pick it up automatically.

### SSD-to-HDD mover

The mover checks every 15 minutes to see how much space there is on the ssd. If the usage has gone above 85%, then it will move data onto the hdd drives until the ssd usage is below 60%.

To change the thresholds or schedule, set them in your host config:

```nix
media-server.storage.ssdReserveGiB = 50; # keep this much SSD free for new writes

media-server.storage.tiering = {
  enable = true;
  highPercent = 85;            # start a pass at or above this SSD usage
  lowPercent = 50;             # keep moving until the SSD is below this usage
  minFreeGiB = 150;            # never fill an HDD past this reserve
  checkIntervalMinutes = 15;   # how often to check for bursts
  neverAccessedGraceDays = 14; # grace period for files never read since written
  time = "02:00";              # additional full-pass OnCalendar time
};
```

Preview what it would move without changing anything:

```bash
sudo media-tier --dry-run
```

Run it now instead of waiting for the timer:

```bash
sudo systemctl start media-tier
journalctl -u media-tier -f
```

The mover pauses Deluge for the duration and resumes it afterwards. Because it resumes every torrent, torrents you paused manually will also resume.

### SnapRAID parity

SnapRAID is preconfigured but disabled. It protects the HDD data disks against a disk failure; the SSD is not covered. NAS data under `data/nas` is covered by the same array. To enable it:

1. Add the parity disk to `hosts/media-server/storage-paths.nix`:

   ```nix
   parityDisks = {
     parity1 = {
       mountPoint = "/mnt/parity1";
       device = "/dev/disk/by-id/ata-WDC_WD240EDAZZ-...";
     };
   };
   ```

   The parity disk must be at least as large as the largest data disk.

2. Format it:

   ```bash
   sudo mkfs.ext4 -L parity1 /dev/disk/by-id/ata-WDC_WD240EDAZZ-...
   ```

3. Enable it in `hosts/media-server/default.nix`:

   ```nix
   media-server.storage.snapraid.enable = true;
   ```

4. Apply the configuration, then create the initial parity:

   ```bash
   sudo nixos-rebuild switch --flake /etc/nixos#media-server
   sudo snapraid sync
   ```

After that, sync runs nightly at 04:00 and scrub runs weekly (8% of the array, only blocks older than 10 days). Sync and scrub skip a run when a disk is missing, and never run while the mover is active.

## Connecting

SSH is key-only (no passwords). Connect as the `media-server` user:

```bash
ssh -i ~/.ssh/media-server media-server@<machine-ip>
```

### Terminal sessions with tuios

The server ships [tuios](https://tuios.dev). You can run it on the server after logging in, or attach to sessions on the server from tuios running on your own machine — with nothing nested. Run these on your **local** machine (tuios ≥ 0.8.0):

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

### NAS shares (SMB)

SMB is reachable only over the tailnet

| Share | URL | Access |
|-------|-----|--------|
| `public` | `smb://media-server/public` | TCP 445, guest read/write |
| `library` | `smb://media-server/library` | TCP 445, guest read-only |
| `private` | `smb://media-server:1445/private` | TCP 1445, guest read/write, hidden from browse lists |
| `public` | `smb://media-server:1445/public` | TCP 1445, guest read/write |
| `library` | `smb://media-server:1445/library` | TCP 1445, guest read/write |


> **Prerequisite:** Enable **HTTPS Certificates** in the Tailscale admin console (DNS → HTTPS Certificates). Without this, the HTTPS URLs above cannot provision TLS certificates.

**Admin-only access:** Prowlarr, Sonarr, Radarr, Lidarr, Bazarr, and autobrr are restricted to Tailscale users listed in `media-server.administrators` (defaults to `["ruddickmg@gmail.com"]`). Seerr is open to all Tailscale users so family members can make requests. To change the admin list:

```nix
media-server.administrators = [ "your@email.com" ];
```

**Plex** is reachable directly (LAN or public IP) because it is designed to be shared; Plex.tv account auth applies. To expose any other service on the LAN as well, see [Firewall](#firewall).

> **DLNA note:** Plex also opens UDP ports 1900 (DLNA) and 5353 (mDNS) for local device discovery, which broadcasts your library to any device on the LAN without authentication. Turn off DLNA in Plex's settings to stop this.

## Post-Deploy Steps

### Tailscale ACL for SMB access

SMB has no passwords: all shares are guest-accessible at the Samba layer, and Tailscale ACLs are the only control over which peers reach each listener. In the Tailscale admin console, grant TCP **445** to everyone who should use `public`/`library`, and TCP **1445** only to peers that may mount `private`:

```json
[
  {
    "action": "accept",
    "src": ["*"],
    "dst": ["media-server:445"]
  },
  {
    "action": "accept",
    "src": ["moon@example.com"],
    "dst": ["media-server:1445"]
  }
]
```

Replace `*` with a narrower user/group if needed, and replace `moon@example.com` with your Tailscale login or device tag. Remove any broader rule that exposes both ports to everyone.

If an SMB password was set on the server previously, remove the stale Samba account:

```bash
sudo smbpasswd -x moon
```

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

Deluge halts downloads when free disk space runs low (preventing the disk-full failure that can corrupt the system). By default it stops downloads when free space on the SSD cache mount (`/mnt/ssd`) drops below **5 GB** and resumes when it recovers above **10 GB**, checking every minute. The guard watches the SSD, not the `/media` union, because downloads land on the SSD first.

To adjust, configure in your host config:

```nix
media-server.deluge.diskGuard.checkPath = "/mnt/ssd";  # mount whose free space is monitored
media-server.deluge.diskGuard.thresholdGiB = 8;   # halt below 8 GB free
media-server.deluge.diskGuard.resumeGiB = 15;     # resume above 15 GB free
media-server.deluge.diskGuard.intervalMins = 5;   # check every 5 minutes
media-server.deluge.diskGuard.notify = false;     # disable Gotify alerts
```

### Deleting media completely

The SMB `library` share is read-only, so media cannot be deleted over the NAS. Delete over SSH instead.

Deleting a file from the library leaves its hard links behind — the copy in `/media/data/torrents/complete` (and the cross-seed link in `/media/data/torrents/xseeds`) — so disk space is never freed. To remove a file or a whole movie/show folder together with every hard link:

```bash
delete-media /media/data/library/movies/Some\ Movie\ (2020)
```

The command lists every hard link it found, asks for confirmation, deletes them all, and prunes the emptied folders. Remove the torrent from Deluge first if it is still seeding.

**Deleting from the Plex UI** also removes every hard link, so no Plex settings are needed for this to work. Verify with `journalctl -u delete-media-watch` after a deletion.

### Plex — add libraries

1. Open `http://<machine-ip>:32400/web`
2. Claim your server
3. Add libraries:
   - **Movies** → `/media/data/library/movies`
   - **TV Shows** → `/media/data/library/tv`
   - **Music** → `/media/data/library/music`

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
ssh media-server

# with super user privileges
chmod 600 /etc/nixos/secrets/vpn-key
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

## CI binary cache (Cachix, optional)

The local packages in `pkgs/` pin versions ahead of nixpkgs, so CI compiles them from source on every run unless you provide a binary cache. To set one up:

1. Create a free cache at [cachix.org](https://www.cachix.org) and note its **name** and **public key** (cache settings → Public Key).
2. Create an API token with push permission (cachix.org → tokens).
3. In CircleCI → Project Settings → Environment Variables, add:
   - `CACHIX_CACHE` — the cache name
   - `CACHIX_PUBLIC_KEY` — the cache's public key
   - `CACHIX_AUTH_TOKEN` — the API token

Without these, CI simply builds everything from source (slower, but nothing breaks).

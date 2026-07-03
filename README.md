# Media Server — NixOS Flake

NixOS configuration for a media server running Plex, Deluge, and the *arr suite.

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

## Post-Deploy Steps

These steps require the web UIs — they involve credentials you provide (indexer accounts) or state stored in application databases (connection configs).

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
   - Daemon host: `<machine-ip>`
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

All service ports are opened in the default config. To restrict access to your LAN only, override in your host config:

```nix
networking.firewall.interfaces."enp0s3".allowedTCPPorts = [
  # ... services you want exposed on LAN
];
# Or use a wireguard interface for remote access
```

## Auto-Updates

A systemd timer runs daily: `git pull --ff-only` + `nixos-rebuild switch`. The service checks for uncommitted changes and unclean working trees before pulling, so local modifications won't be overwritten.

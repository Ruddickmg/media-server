{
  lib,
  pkgs,
  config,
  ...
}:
let
  inherit (lib)
    mkForce
    mkIf
    mkMerge
    mkOption
    optionals
    types
    ;
  cfg = config.media-server.deluge;
  vpnNs = config.media-server.vpn.namespace;
  useVpn = cfg.vpnConfinement && config.media-server.vpn.enable;
  downloadSpeedLabel =
    if cfg.downloadSpeed < 0 then "unlimited" else "${toString cfg.downloadSpeed} KiB/s";

  blocklistUrl = "https://github.com/colindean/transmission-blocklist/releases/latest/download/blocklist.gz";

  blocklistConfig = pkgs.writeText "blocklist.conf" (
    builtins.toJSON {
      url = blocklistUrl;
      load_on_start = true;
      check_after_days = 3;
      timeout = 600;
      try_times = 3;
      whitelisted = [ ];
    }
  );

  # ltConfig — Deluge plugin for direct libtorrent tuning.
  #
  # Deluge 2.2.0 ships libtorrent 2.0.12. Its disk I/O uses mmap and the kernel
  # page cache, so libtorrent's old user-space cache knobs (cache_size,
  # cache_expiry, use_read_cache, coalesce_*, read/write_cache_line_size, ...)
  # are deprecated and do nothing here. They are deliberately absent.
  #
  # Deluge core.conf owns the settings it exposes (rate limits, connections,
  # upload slots, active torrents). ltConfig applies settings on plugin enable,
  # after PreferencesManager has applied core.conf, so duplicating those keys
  # here would silently override the declarative Deluge values. Only
  # libtorrent-specific knobs live in this map.
  ltconfigPkg = pkgs.callPackage ../../pkgs/deluge-ltconfig { };

  ltconfigConf = pkgs.writeText "ltconfig.conf" (
    builtins.toJSON {
      apply_on_start = true;
      settings = {
        active_dht_limit = 600;
        active_tracker_limit = 2000;
        aio_threads = 16;
        alert_queue_size = 10000;
        allow_multiple_connections_per_ip = false;
        allowed_fast_set_size = 0;
        checking_mem_usage = 2048;
        choking_algorithm = 0;
        close_redundant_connections = true;
        dht_upload_rate_limit = 20000;
        file_pool_size = 500;
        # libtorrent 2.0 split hash threads out of aio_threads. These only
        # affect full rechecks, but make them quick on the SSD tier.
        hashing_threads = 4;
        inactivity_timeout = 60;
        listen_queue_size = 3000;
        max_allowed_in_request_queue = 2000;
        max_failcount = 1;
        max_http_recv_buffer_size = 6291456;
        max_out_request_queue = 1500;
        max_peer_recv_buffer_size = 5242880;
        max_queued_disk_bytes = 7340032;
        max_rejects = 10;
        mixed_mode_algorithm = 0;
        no_atime_storage = true;
        peer_timeout = 20;
        # Ask for adjacent 4 MiB piece extents: less random I/O on downloads
        # with small piece sizes.
        piece_extent_affinity = true;
        request_timeout = 10;
        send_buffer_low_watermark = 1048576;
        send_buffer_watermark = 3145728;
        send_buffer_watermark_factor = 150;
      };
    }
  );
in
{
  options.media-server.deluge = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Deluge headless daemon";
    };
    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open ports in firewall for Deluge";
    };
    vpnConfinement = mkOption {
      type = types.bool;
      default = false;
      description = "Run Deluge inside the VPN network namespace";
    };
    seedRatioLimit = mkOption {
      type = types.float;
      default = -1.0;
      description = ''
        Stop seeding when global share ratio reaches this value.
        Set to -1.0 to disable ratio-based seeding limit.
        *arr-managed torrents are removed earlier by per-indexer goals.
      '';
    };
    seedTimeLimit = mkOption {
      type = types.int;
      default = -1;
      description = ''
        Stop seeding after this many minutes.
        Set to -1 to disable time-based seeding limit.
        *arr-managed torrents are removed earlier by per-indexer goals.
      '';
    };
    authUsername = mkOption {
      type = types.str;
      default = "media-server";
      description = "Username for Deluge Web UI / console authentication";
    };
    downloadSpeed = mkOption {
      type = types.float;
      default = -1.0;
      description = ''
        Global maximum download speed in KiB/s. -1.0 means unlimited: with a
        4 Gbps symmetric line there is no reason to engage libtorrent's rate
        limiter, which adds overhead even at high limits.
      '';
    };
    uploadSpeed = mkOption {
      type = types.float;
      default = -1.0;
      description = ''
        Global maximum upload speed in KiB/s. -1.0 means unlimited.
      '';
    };
    natpmpGateway = mkOption {
      type = types.str;
      default = "10.2.0.1";
      description = "VPN NAT-PMP gateway IP address";
    };
    diskGuard = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Halt Deluge downloads when free disk space drops below the threshold";
      };
      checkPath = mkOption {
        type = types.str;
        # Downloads land on the SSD first (the union's first branch), so guard
        # the SSD, not the union: mergerfs statfs reports one branch's free
        # space and would hide a full cache disk behind a nearly empty HDD.
        default = (config.media-server.storage or { ssdPath = "/media"; }).ssdPath;
        description = "Filesystem path whose free space is monitored";
      };
      thresholdGiB = mkOption {
        type = types.int;
        # At 4 Gbps (~500 MB/s) a 5 GiB margin is gone in ~10 seconds. Keep a
        # margin well above the SSD reserve (50 GiB) but below the tiering
        # critical threshold, so a runaway download is caught before the disk
        # mover or a full filesystem becomes the emergency brake.
        default = 100;
        description = "Halt downloads when free space on checkPath drops below this many GiB";
      };
      resumeGiB = mkOption {
        type = types.int;
        default = 200;
        description = "Resume downloads once free space on checkPath recovers above this many GiB (hysteresis)";
      };
      intervalSeconds = mkOption {
        type = types.int;
        default = 10;
        description = "How often (in seconds) the disk-space guard checks free space";
      };
      notify = mkOption {
        type = types.bool;
        default = true;
        description = "Send a Gotify notification when downloads are halted or resumed";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        # Deluge must never run with a route to the WAN. `useVpn` is
        # vpnConfinement && vpn.enable, so without this assertion either flag
        # being off would silently run the daemon (and deluge-web) in the root
        # namespace, where it would leak torrent traffic.
        assertion = cfg.vpnConfinement && config.media-server.vpn.enable;
        message = "media-server.deluge requires media-server.deluge.vpnConfinement = true and media-server.vpn.enable = true; refusing to run Deluge outside the VPN namespace.";
      }
    ];

    services.deluge = {
      enable = true;
      declarative = true;
      web.enable = true;
      config = {
        daemon_port = 58846;
        allow_remote = true;
        enabled_plugins = [
          "Label"
          "Blocklist"
          "ltConfig"
          "Execute"
        ];
        download_location = "/media/data/torrents/incomplete";
        move_completed = true;
        move_completed_path = "/media/data/torrents/complete";
        copy_torrent_file = false;
        del_copy_torrent_file = false;
        prioritize_first_last_pieces = false;
        random_port = false;
        listen_ports = [
          6881
          6881
        ];
        # Deluge/libtorrent uses OS-assigned ephemeral ports for outgoing
        # connections by default. Explicitly setting outgoing_ports is not
        # recommended: it limits the number of concurrent peers and breaks
        # reconnection to the same client due to socket TIME_WAIT. See
        # libtorrent docs: https://libtorrent.org/reference-Settings.html

        # Peer discovery — irrelevant behind VPN/Tailscale; private trackers
        # require DHT/PEX/LSD disabled. Disabling DHT also disables magnet
        # metadata fetching. Keys are Deluge core.conf keys (preferencesmanager
        # maps them to libtorrent enable_dht/enable_pex/enable_lsd).
        upnp = false;
        natpmp = false;
        lsd = false;
        dht = false;
        utpex = false;

        # Bandwidth. Values are KiB/s; -1 means unlimited. Deluge maps these to
        # libtorrent's download_rate_limit/upload_rate_limit, so -1 avoids the
        # rate limiter entirely rather than setting a very high cap.
        max_download_speed = cfg.downloadSpeed;
        max_upload_speed = cfg.uploadSpeed;

        # Connections. These and the queue limits below are the single source
        # of truth: ltConfig must not duplicate them, because its apply_on_start
        # settings are applied after this config and would silently win.
        max_connections_global = 2000;
        max_connections_per_torrent = 100;
        max_connections_per_second = 100;
        max_upload_slots_global = -1;
        max_upload_slots_per_torrent = -1;
        max_half_open_connections = 100;
        # Don't let torrents with no payload traffic hold an active slot.
        dont_count_slow_torrents = true;

        # No Deluge cache settings: libtorrent 2.0 uses mmap with the kernel
        # page cache and ignores cache_size/cache_expiry.

        # Queue — *arrs remove their own torrents via per-indexer goals
        max_active_limit = 200;
        max_active_downloading = 5;
        max_active_seeding = 100;

        # Seeding: *arrs set their own per-indexer goals; Cleanuparr owns removal
        # and source-file deletion. Deluge may stop torrents at a ratio, but must
        # never delete them itself or the hard-linked copies stay behind.
        stop_seed_at_ratio = cfg.seedRatioLimit != -1.0;
        stop_seed_ratio = cfg.seedRatioLimit;
        seed_time_limit = cfg.seedTimeLimit;
        share_ratio_limit = cfg.seedRatioLimit;
        remove_seed_at_ratio = false;
        auto_managed = true;
      };
      authFile = pkgs.writeText "deluge-auth" ''
        localclient:deluge:10
        ${cfg.authUsername}:deluge:10
      '';
      user = "deluge";
      # Primary group media, not deluge: it is the group a new inode gets, and
      # the *arrs (Group=media) must be able to read what Deluge writes. Relying
      # on the destination directory's setgid bit only covers directories the
      # tmpfiles skeleton already created.
      group = "media";
      dataDir = "/var/lib/deluge";
    };

    users.users.deluge = {
      extraGroups = [ "media" ];
    };

    users.groups.deluge = {
      gid = 83;
    };

    systemd.services.deluged = mkMerge [
      {
        preStart = lib.mkAfter ''
          # Restore torrent state from backup if corrupted or empty.
          # An empty pickle dict serializes to < 100 bytes; any smaller file
          # means Deluge wrote an empty state on a previous failed shutdown.
          # Only restore if the backup is valid (passes gzip integrity check).
          STATE_DIR="${config.services.deluge.dataDir}/.config/deluge/state"
          STATE_FILE="$STATE_DIR/torrents.state"
          BACKUP_FILE="${config.services.deluge.dataDir}/backup/deluge-state.tar.gz"
          if [ -f "$BACKUP_FILE" ] && gzip -t "$BACKUP_FILE" 2>/dev/null; then
            if [ -f "$STATE_FILE" ]; then
              size=$(stat -c%s "$STATE_FILE" 2>/dev/null || echo 0)
              if [ "$size" -lt 100 ] 2>/dev/null; then
                tar -xzf "$BACKUP_FILE" -C "${config.services.deluge.dataDir}/.config/deluge" 2>/dev/null || true
              fi
            else
              tar -xzf "$BACKUP_FILE" -C "${config.services.deluge.dataDir}/.config/deluge" 2>/dev/null || true
            fi
          fi

          cp ${blocklistConfig} ${config.services.deluge.dataDir}/.config/deluge/blocklist.conf

          # Install ltConfig plugin egg and declarative config
          configDir="${config.services.deluge.dataDir}/.config/deluge"
          mkdir -p "$configDir/plugins"
          cp -f ${ltconfigPkg}/share/deluge/plugins/*.egg "$configDir/plugins/"
          cp ${ltconfigConf} "$configDir/ltconfig.conf"
        '';
        # The union (and therefore the torrent trees) must be mounted first.
        # Include the branch mounts and /media itself so deluged waits for the
        # SSD, HDD pool, and union before starting. nofail on those mounts means
        # boot can proceed without a detached disk; this keeps deluged from
        # touching a partial mount tree when that happens.
        unitConfig.RequiresMountsFor = [
          "/media"
          "/mnt/ssd"
          "/mnt/hdd1"
          "/media/data/torrents/incomplete"
          "/media/data/torrents/complete"
        ];
        serviceConfig = {
          # nixpkgs already sets UMask=0002, keeping files group-writable so
          # the *arr apps can hardlink and delete them.
          ProtectHome = true;
          PrivateTmp = true;
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          LockPersonality = true;
          KeyringMode = "private";
          RestrictSUIDSGID = true;
          RestrictRealtime = true;
          SystemCallArchitectures = "native";
          LimitNOFILE = mkForce 65536;
          TimeoutStopSec = 180;
          ReadWritePaths = [
            "/var/lib/deluge"
            "/media/data/torrents"
            # Allow the Execute plugin's subprocess to connect to the cross-seed
            # webhook UNIX socket. ProtectSystem=strict remounts /run read-only;
            # the kernel rejects connect() to a socket on a read-only mount, so
            # the socket dir must be a read-write bind mount here.
            "/run/cross-seed"
          ];
        };
      }
      (mkIf useVpn {
        after = [
          "create-netns-${vpnNs}.service"
          # Order after the tunnel so the namespace has a default route before
          # the daemon starts shuffling torrents. Deliberately only `wants`:
          # deluged has Restart=on-success, so Requires/BindsTo/PartOf on the
          # wireguard unit would stop it on a tunnel restart and leave it dead.
          # The namespace itself is the kill switch (lo + wg only, no veth).
          "wireguard-wg-${vpnNs}.service"
        ];
        requires = [ "create-netns-${vpnNs}.service" ];
        wants = [ "wireguard-wg-${vpnNs}.service" ];
        serviceConfig = {
          NetworkNamespacePath = "/var/run/netns/${vpnNs}";
          BindReadOnlyPaths = [ "/etc/netns/${vpnNs}/resolv.conf:/etc/resolv.conf" ];
        };
      })
    ];

    # Label plugin labels. *arr apps only create labels when the download client
    # is saved/tested (label.add); at grab time they only call label.set_torrent,
    # which throws "Unknown Label" if the label is missing. Declare them so grabs
    # can't silently fail again — they were lost once in the config-dir reset
    # incidents. Cleanuparr also creates/moves torrents into the unlinked label
    # when no library hardlink remains. "f" creates the file only if absent,
    # preserving torrent->label mappings and manual labels. Runs after nixpkgs'
    # "10-deluged" config-dir rule (lexicographic order).
    systemd.tmpfiles.settings."90-deluge-labels" = {
      "${config.services.deluge.dataDir}/.config/deluge/label.conf".f = {
        mode = "0644";
        user = "deluge";
        group = "deluge";
        argument = builtins.toJSON {
          file = 1;
          format = 1;
          torrent_labels = { };
          labels = {
            radarr = { };
            tv-sonarr = { };
            lidarr = { };
            cross-seed = { };
            cleanuparr-unlinked = { };
          };
        };
      };
    };

    # Execute plugin: pre-seed the "Torrent Complete" command so the cross-seed
    # on-completion webhook works with no Web UI step. Config format matches the
    # plugin's ConfigManager defaults (commands are [id, event, command]
    # arrays; event is the string "complete"; args passed to the script are
    # $1=infoHash $2=name $3=download_location). "f" creates the file only if
    # absent, preserving commands added via the UI. Runs after nixpkgs'
    # "10-deluged" config-dir rule (lexicographic order).
    systemd.tmpfiles.settings."90-deluge-execute" = {
      "${config.services.deluge.dataDir}/.config/deluge/execute.conf".f = {
        mode = "0644";
        user = "deluge";
        group = "deluge";
        argument = builtins.toJSON {
          file = 1;
          format = 1;
          commands = [
            [
              "cross-seed-on-complete"
              "complete"
              "/run/current-system/sw/bin/cross-seed-on-complete"
            ]
          ];
        };
      };
    };

    systemd.sockets.proxy-deluge = mkIf useVpn {
      description = "Socket for proxy to Deluge daemon in VPN namespace";
      listenStreams = [ "58846" ];
      wantedBy = [ "sockets.target" ];
    };

    systemd.services.proxy-deluge = mkIf useVpn {
      description = "Proxy Deluge daemon from VPN namespace to root namespace";
      requires = [
        "deluged.service"
        "proxy-deluge.socket"
      ];
      after = [
        "deluged.service"
        "proxy-deluge.socket"
      ];
      serviceConfig = {
        NetworkNamespacePath = "/var/run/netns/${vpnNs}";
        BindReadOnlyPaths = [ "/etc/netns/${vpnNs}/resolv.conf:/etc/resolv.conf" ];
        User = "deluge";
        Group = "deluge";
        LimitNOFILE = mkForce 65536;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        CapabilityBoundingSet = [ "" ];
        ProtectHome = true;
        RemoveIPC = true;
        KeyringMode = "private";
        RestrictSUIDSGID = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
        LockPersonality = true;
        RestrictNamespaces = true;
        ProtectClock = true;
        PrivateMounts = true;
        PrivateDevices = true;
        ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd --connections-max=4096 --exit-idle-time=5min 127.0.0.1:58846";
      };
    };

    # deluge-web does not connect to deluged unless told to: WebApi.enable()
    # only calls web.connect() when web.conf's `default_daemon` is set, and a
    # dropped connection is never retried (`_on_client_disconnect` just stops
    # components). Nothing ever writes `default_daemon`, so on every boot the
    # frontend sits at connected:false with torrents:null until someone clicks
    # Connect in the UI. The *arrs read that as an empty Deluge, drop the
    # completed downloads from their queue, and never import them.
    #
    # Seed `default_daemon` from the host list so each start connects by itself,
    # and make the frontend follow the daemon's lifecycle so a deluged restart
    # cannot leave it holding a dead connection.
    #
    # The frontend runs in the VPN namespace alongside the daemon, then is
    # proxied back to the root namespace for the *arr apps.
    systemd.services.delugeweb = mkIf useVpn {
      partOf = [ "deluged.service" ];
      after = [ "create-netns-${vpnNs}.service" ];
      requires = [ "create-netns-${vpnNs}.service" ];
      preStart = ''
        configDir="${config.services.deluge.dataDir}/.config/deluge"
        hostlist="$configDir/hostlist.conf"
        webconf="$configDir/web.conf"

        # deluge-web generates hostlist.conf on first run with a random host id.
        # Seed the local daemon entry when it is missing so the id below exists
        # on the very first start too.
        if [ ! -f "$hostlist" ]; then
          printf '%s\n' '{"hosts": [["localdaemon", "127.0.0.1", 58846, "localclient", "deluge"]]}' > "$hostlist"
        fi

        # Merge instead of replacing: web.conf also holds the UI settings,
        # session store and password hash that deluge-web rewrites at runtime.
        # Deluge stores its config as two consecutive JSON objects (version
        # then data); jq's filter runs over both and keeps that layout.
        hostId=$(${pkgs.jq}/bin/jq -r '.hosts[0][0] // empty' "$hostlist" 2>/dev/null || true)
        if [ -n "$hostId" ]; then
          if [ -f "$webconf" ]; then
            if ${pkgs.jq}/bin/jq --arg id "$hostId" '.default_daemon = $id' "$webconf" > "$webconf.new" 2>/dev/null; then
              mv -f "$webconf.new" "$webconf"
            else
              rm -f "$webconf.new"
            fi
          else
            ${pkgs.jq}/bin/jq -n --arg id "$hostId" '{default_daemon: $id}' > "$webconf"
          fi
        fi

        # deluged is Type=simple, so `after` only guarantees the process was
        # spawned, not that its RPC port is bound. A connect failure at startup
        # is permanent (no retry), so wait for the port before starting.
        for _ in $(${pkgs.coreutils}/bin/seq 60); do
          if (exec 3<>/dev/tcp/127.0.0.1/58846) 2>/dev/null; then break; fi
          sleep 1
        done
      '';
      serviceConfig = {
        Restart = "always";
        RestartSec = 5;

        NetworkNamespacePath = "/var/run/netns/${vpnNs}";
        BindReadOnlyPaths = [ "/etc/netns/${vpnNs}/resolv.conf:/etc/resolv.conf" ];
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = [ "" ];
        ProtectSystem = "strict";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
        PrivateDevices = true;
        LockPersonality = true;
        RestrictNamespaces = true;
        ProtectClock = true;
        PrivateMounts = true;
        RemoveIPC = true;
        KeyringMode = "private";
        RestrictSUIDSGID = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        MemoryDenyWriteExecute = true;
        ReadWritePaths = [
          "/var/lib/deluge"
        ];
      };
    };

    systemd.sockets.proxy-deluge-web = mkIf useVpn {
      description = "Socket for proxy to Deluge Web UI in VPN namespace";
      listenStreams = [ "8112" ];
      wantedBy = [ "sockets.target" ];
    };

    systemd.services.proxy-deluge-web = mkIf useVpn {
      description = "Proxy Deluge Web UI from VPN namespace to root namespace";
      requires = [
        "delugeweb.service"
        "proxy-deluge-web.socket"
      ];
      after = [
        "delugeweb.service"
        "proxy-deluge-web.socket"
      ];
      serviceConfig = {
        NetworkNamespacePath = "/var/run/netns/${vpnNs}";
        BindReadOnlyPaths = [ "/etc/netns/${vpnNs}/resolv.conf:/etc/resolv.conf" ];
        User = "deluge";
        Group = "deluge";
        LimitNOFILE = mkForce 65536;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        CapabilityBoundingSet = [ "" ];
        ProtectHome = true;
        RemoveIPC = true;
        KeyringMode = "private";
        RestrictSUIDSGID = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
        LockPersonality = true;
        RestrictNamespaces = true;
        ProtectClock = true;
        PrivateMounts = true;
        PrivateDevices = true;
        ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd --connections-max=4096 --exit-idle-time=5min 127.0.0.1:8112";
      };
    };

    # Keep ProtonVPN's NAT-PMP forwarded port in sync with Deluge's listen port.
    # Proton assigns a random public port for both UDP and TCP; the mapping
    # expires after 60 s, so we refresh every 45 s.  When the port changes we
    # update Deluge via deluge-console (both run inside the VPN namespace, so
    # the console connects to 127.0.0.1:58846 directly).  The thin client still
    # reaches the daemon through proxy-deluge from the root namespace.
    systemd.services.deluge-natpmp = mkIf useVpn {
      description = "Refresh ProtonVPN NAT-PMP port mapping and sync Deluge listen port";
      wantedBy = [ "multi-user.target" ];
      after = [
        "deluged.service"
        "wireguard-wg-${vpnNs}.service"
        "create-netns-${vpnNs}.service"
      ];
      requires = [
        "deluged.service"
        "wireguard-wg-${vpnNs}.service"
        "create-netns-${vpnNs}.service"
      ];
      partOf = [ "deluged.service" ];
      path = with pkgs; [
        libnatpmp
        gawk
        deluge
      ];
      environment.HOME = config.services.deluge.dataDir;
      script = ''
        #!/usr/bin/env bash
        set -euo pipefail

        LAST_PORT=""

        while true; do
          # Refresh both UDP and TCP mappings — Proton assigns the same public
          # port for both.  Lifetime is 60 s; we refresh every 45 s.
          udp_out=$(natpmpc -a 1 0 udp 60 -g ${cfg.natpmpGateway}) \
            || { echo "natpmpc UDP request failed" >&2; exit 1; }
          tcp_out=$(natpmpc -a 1 0 tcp 60 -g ${cfg.natpmpGateway}) \
            || { echo "natpmpc TCP request failed" >&2; exit 1; }

          tcp_port=$(awk '/Mapped public port/ {print $4; exit}' <<<"$tcp_out")
          udp_port=$(awk '/Mapped public port/ {print $4; exit}' <<<"$udp_out")

          if [[ -z "$tcp_port" || -z "$udp_port" ]]; then
            echo "natpmpc did not return a mapped port (tcp=$tcp_port udp=$udp_port)" >&2
            exit 1
          fi

          if [[ "$tcp_port" != "$udp_port" ]]; then
            echo "natpmpc returned mismatched ports (tcp=$tcp_port udp=$udp_port)" >&2
            exit 1
          fi

          port="$tcp_port"

          if [[ "$port" != "$LAST_PORT" ]]; then
            echo "ProtonVPN forwarded port changed: $port"
            deluge-console \
              "connect 127.0.0.1:58846 localclient deluge; \
               config --set random_port False; \
               config --set listen_ports ($port,$port)"
            LAST_PORT="$port"
          fi

          sleep 45
        done
      '';
      serviceConfig = {
        NetworkNamespacePath = "/var/run/netns/${vpnNs}";
        BindReadOnlyPaths = [ "/etc/netns/${vpnNs}/resolv.conf:/etc/resolv.conf" ];
        User = "deluge";
        Group = "deluge";
        Restart = "on-failure";
        RestartSec = "10s";
        # Hardening — mirror the deluged service profile.
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = [ "" ];
        ProtectSystem = "strict";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
        PrivateDevices = true;
        LockPersonality = true;
        RestrictNamespaces = true;
        ProtectClock = true;
        PrivateMounts = true;
        RemoveIPC = true;
        KeyringMode = "private";
        RestrictSUIDSGID = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        MemoryDenyWriteExecute = true;
        ReadWritePaths = [
          "/var/lib/deluge"
        ];
      };
    };

    # Disk-space download guard: halt Deluge downloads before the disk fills.
    # The disk-full incident (100% btrfs allocation from a runaway download)
    # truncated /etc/passwd and bricked boot, so this is a hard safety valve:
    # when free space drops below the threshold, throttle the global download
    # speed to 1 KiB/s — stopping downloads while leaving seeding untouched.
    #
    # The speed is 1, NOT 0: Deluge maps max_download_speed to libtorrent's
    # download_rate_limit, where 0 means "unlimited" — a naive 0 would do
    # nothing. The configured resume speed may itself be -1 (unlimited), which
    # deluge-console accepts, so the guard restores exactly what core.conf has.
    # A state marker makes the unit idempotent so config --set only fires on
    # transitions. The console connects to 127.0.0.1:58846 from the root
    # namespace (same path the *arr apps use) — via proxy-deluge when
    # VPN-confined, directly otherwise — so no NetworkNamespacePath is needed.
    systemd.services.deluge-disk-guard = mkIf cfg.diskGuard.enable {
      description = "Halt Deluge downloads when disk space runs low";
      after = [ "deluged.service" ] ++ optionals useVpn [ "proxy-deluge.service" ];
      requires = [ "deluged.service" ] ++ optionals useVpn [ "proxy-deluge.service" ];
      environment.HOME = config.services.deluge.dataDir;
      path = with pkgs; [
        deluge
        gawk
        coreutils
      ];
      script = ''
        set -uo pipefail

        STATE_FILE="${config.services.deluge.dataDir}/.disk-guard-throttled"
        CHECK_PATH="${cfg.diskGuard.checkPath}"
        THRESHOLD_KIB=$(( ${toString cfg.diskGuard.thresholdGiB} * 1024 * 1024 ))
        RESUME_KIB=$(( ${toString cfg.diskGuard.resumeGiB} * 1024 * 1024 ))
        NOTIFY_ENABLED=${if cfg.diskGuard.notify then "1" else "0"}
        CONSOLE_CMD="connect 127.0.0.1:58846 localclient deluge;"

        notify() {
          [ "$NOTIFY_ENABLED" = "1" ] || return 0
          local title="$1" message="$2" token
          token=$(cat ${config.media-server.gotifyTokenFile} 2>/dev/null || echo "")
          [ -n "$token" ] || return 0
          ${pkgs.curl}/bin/curl -sf -X POST "http://127.0.0.1:6789/message?token=$token" \
            -F "title=Deluge Disk Guard: $title" \
            -F "message=$message" \
            -F "priority=5" >/dev/null 2>&1 || true
        }

        free_kib=$(df -Pk "$CHECK_PATH" 2>/dev/null | awk 'NR==2 {print $4}')
        if [ -z "$free_kib" ]; then
          echo "deluge-disk-guard: failed to read free space on $CHECK_PATH" >&2
          exit 1
        fi
        echo "deluge-disk-guard: free space on $CHECK_PATH is $(( free_kib / 1024 )) MiB"

        if [ "$free_kib" -lt "$THRESHOLD_KIB" ]; then
          if [ ! -e "$STATE_FILE" ]; then
            echo "deluge-disk-guard: free space below ${toString cfg.diskGuard.thresholdGiB} GiB, halting downloads"
            if deluge-console "$CONSOLE_CMD config --set max_download_speed 1"; then
              touch "$STATE_FILE"
              notify "Downloads halted" "Free space on $CHECK_PATH dropped below ${toString cfg.diskGuard.thresholdGiB} GiB (now $(( free_kib / 1048576 )) GiB). Downloads stopped."
            else
              echo "deluge-disk-guard: deluge-console failed, will retry" >&2
            fi
          fi
        elif [ "$free_kib" -gt "$RESUME_KIB" ] && [ -e "$STATE_FILE" ]; then
          echo "deluge-disk-guard: free space above ${toString cfg.diskGuard.resumeGiB} GiB, resuming downloads"
          if deluge-console "$CONSOLE_CMD config --set max_download_speed ${toString cfg.downloadSpeed}"; then
            rm -f "$STATE_FILE"
            notify "Downloads resumed" "Free space on $CHECK_PATH recovered above ${toString cfg.diskGuard.resumeGiB} GiB (now $(( free_kib / 1048576 )) GiB). Download speed restored to ${downloadSpeedLabel}."
          else
            echo "deluge-disk-guard: deluge-console failed, will retry" >&2
          fi
        fi
      '';
      serviceConfig = {
        User = "deluge";
        Group = "deluge";
        Type = "oneshot";
        # Hardening — mirror the deluge-natpmp service profile.
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = [ "" ];
        ProtectSystem = "strict";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
        PrivateDevices = true;
        LockPersonality = true;
        RestrictNamespaces = true;
        ProtectClock = true;
        PrivateMounts = true;
        RemoveIPC = true;
        KeyringMode = "private";
        RestrictSUIDSGID = true;
        ProtectHostname = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        MemoryDenyWriteExecute = true;
        ReadWritePaths = [
          config.services.deluge.dataDir
        ];
        # Read the Gotify app token (0600 root:gotify-readers) for notifications.
        SupplementaryGroups = mkIf cfg.diskGuard.notify [ "gotify-readers" ];
      };
    };

    systemd.timers.deluge-disk-guard = mkIf cfg.diskGuard.enable {
      description = "Check Deluge disk-space guard";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # Sub-minute checks are needed now that an unlimited download can
        # consume gigabytes in seconds. Persistent only applies to OnCalendar.
        OnUnitActiveSec = "${toString cfg.diskGuard.intervalSeconds}s";
        AccuracySec = "1s";
      };
    };

    networking.firewall = mkIf cfg.openFirewall {
      allowedTCPPorts = [ 58846 ];
      allowedUDPPorts = [ 58846 ];
    };
  };
}

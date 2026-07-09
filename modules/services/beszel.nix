{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.media-server.beszel;
in
{
  options.media-server.beszel = {
    enable = lib.mkEnableOption "Beszel monitoring hub and agent";
  };

  config = lib.mkIf cfg.enable {
    # Beszel hub — PocketBase-backed web dashboard
    services.beszel.hub = {
      enable = true;
      host = "127.0.0.1";
      port = 8090;
    };

    # Beszel agent — runs on the same host, hub connects via SSH
    services.beszel.agent = {
      enable = true;
      openFirewall = true;
      environment = {
        PORT = "45876";
      };
      environmentFile = "/var/lib/beszel-agent/env";
    };

    # Ensure podman docker socket is available so the agent can read container stats
    virtualisation.podman.dockerSocket.enable = lib.mkDefault true;

    # Create agent environment file directory
    systemd.tmpfiles.rules = [
      "d /var/lib/beszel-agent 0750 root beszel-agent -"
    ];

    # One-shot service to create the agent env file with a generated key and instructions
    systemd.services.beszel-agent-setup = {
      description = "Prepare Beszel agent environment file with SSH key";
      before = [ "beszel-agent.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.openssh ];
      script = ''
        if [ ! -s /var/lib/beszel-agent/env ]; then
          # Generate a temporary Ed25519 key pair for the agent
          TMP=$(mktemp -d)
          ssh-keygen -t ed25519 -f "$TMP/beszel" -N "" -C "beszel-local" >/dev/null 2>&1
          PUBKEY=$(cat "$TMP/beszel.pub")
          PRIVKEY=$(cat "$TMP/beszel")
          rm -rf "$TMP"

          cat > /var/lib/beszel-agent/env <<EOF
        # Beszel agent configuration
        #
        # The hub connects to this agent via SSH on port 45876.
        # The KEY below is the hub's public key (the key the hub uses to auth).
        #
        # To complete setup:
        # 1. Open the Beszel hub at https://media-server.tailbac0df.ts.net/metrics
        # 2. Create an admin account
        # 3. Click "Add System" and enter:
        #    - Name: media-server
        #    - Host: 127.0.0.1
        #    - Port: 45876
        # 4. Copy the public key shown in the hub UI and replace the KEY line below
        # 5. Restart beszel-agent.service
        #
        # Alternatively, you can use the following pre-generated key pair:
        # Agent public key (copy to hub): $PUBKEY
        # Agent private key (for reference): $PRIVKEY
        #
        # NOTE: If you use the hub-generated key, replace the KEY below with that key.
        KEY=$PUBKEY
        EOF

          chown root:beszel-agent /var/lib/beszel-agent/env
          chmod 640 /var/lib/beszel-agent/env
        fi
      '';
    };

    # Ensure the agent starts after the setup script has created the env file
    systemd.services.beszel-agent = {
      after = [ "beszel-agent-setup.service" ];
      requires = [ "beszel-agent-setup.service" ];
      unitConfig = {
        OnFailure = "notify-gotify@%n.service";
      };
    };
  };
}

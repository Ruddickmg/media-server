{ lib, ... }:
{
  services.unpackerr = {
    enable = true;
    settings = {
      debug = false;
      interval = "2m";
      start_delay = "5m";
      retry_delay = "5m";
      max_retries = 3;
      parallel = 1;
      folder = {
        "/media/downloads/completed" = {
          delete_original = true;
          delete_after = true;
        };
      };
    };
  };

  users.users.unpackerr.extraGroups = [ "media" ];
}

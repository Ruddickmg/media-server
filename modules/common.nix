{ lib, pkgs, ... }:
{
  users.groups.media = {};

  systemd.tmpfiles.rules = [
    "d /media 2775 root media"
    "d /media/downloads 2775 root media"
    "d /media/downloads/incomplete 2775 root media"
    "d /media/downloads/completed 2775 root media"
    "d /media/movies 2775 root media"
    "d /media/tv 2775 root media"
    "d /media/music 2775 root media"
  ];

  environment.systemPackages = with pkgs; [
    unzip
    unrar
    p7zip
    git
    ripgrep
    jq
    vim
  ];
}

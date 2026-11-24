{
  lib,
  buildFHSEnv,
  cacert,
  fetchzip,
  icu,
  openssl,
  stdenv,
  writeShellScript,
  zlib,
}:
let
  version = "2.11.1";

  # The upstream release is a .NET single-file bundle. It expects its bundled
  # wwwroot/ and libe_sqlite3.so to stay next to the executable, so keep the
  # unpacked tree intact and launch it in place rather than patchelf-ing it.
  # fetchzip strips the archive's single top-level directory, so the files are
  # already at the source root.
  unpacked = stdenv.mkDerivation {
    pname = "cleanuparr-unpacked";
    inherit version;

    src = fetchzip {
      url = "https://github.com/Cleanuparr/Cleanuparr/releases/download/v${version}/Cleanuparr-${version}-linux-amd64.zip";
      hash = "sha256-OPTtW+eNKgyJbAfcaWiLGw8oTV1tHwiKmWEMBb9CwMI=";
    };

    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -r "$src"/. "$out"/
      chmod +x "$out/Cleanuparr"
      runHook postInstall
    '';
  };

  runScript = writeShellScript "cleanuparr-run" ''
    cd "${unpacked}"
    exec "${unpacked}/Cleanuparr" "$@"
  '';
in
buildFHSEnv {
  name = "cleanuparr";

  targetPkgs =
    pkgs: with pkgs; [
      cacert
      icu
      openssl
      stdenv.cc.cc.lib
      zlib
    ];

  inherit runScript;

  meta = {
    description = "Automated torrent and media cleanup for *arr libraries";
    homepage = "https://github.com/Cleanuparr/Cleanuparr";
    changelog = "https://github.com/Cleanuparr/Cleanuparr/releases/tag/v${version}";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.linux;
    mainProgram = "cleanuparr";
  };
}

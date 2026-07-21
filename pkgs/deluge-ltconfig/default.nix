{
  lib,
  stdenv,
  fetchFromGitHub,
  python3,
}:

let
  version = "2.1.1";
in
stdenv.mkDerivation {
  pname = "deluge-ltconfig";
  inherit version;

  src = fetchFromGitHub {
    owner = "zakkarry";
    repo = "deluge-ltconfig";
    rev = "v${version}";
    hash = "sha256-VgFLDUKaDRiA5AKFa1jwuELSgeoKfbgu5P6yYQXj8KI=";
  };

  nativeBuildInputs = [
    python3
    python3.pkgs.setuptools
  ];

  buildPhase = ''
    runHook preBuild
    # Nix sandbox timestamps are epoch 0 (pre-1980); Python 3.13+ zipfile
    # rejects pre-1980 dates. Touch everything to 1980-01-01 before bdist_egg.
    find . -exec touch -t 198001010000.00 {} +
    python3 setup.py bdist_egg
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/deluge/plugins
    cp dist/*.egg $out/share/deluge/plugins/
    runHook postInstall
  '';

  meta = with lib; {
    description = "ltConfig plugin for Deluge 2.x — direct libtorrent settings modification";
    homepage = "https://github.com/zakkarry/deluge-ltconfig";
    license = licenses.gpl3Plus;
  };
}

{
  lib,
  buildNpmPackage,
  fetchFromGitHub,
  nix-update-script,
  nixosTests,
  nodejs_22,
}:

# Override can be removed once cross-seed v7 releases
buildNpmPackage.override { nodejs = nodejs_22; } rec {
  pname = "cross-seed";
  version = "6.13.9";

  src = fetchFromGitHub {
    owner = "cross-seed";
    repo = "cross-seed";
    tag = "v${version}";
    hash = "sha256-8WdSolN/AbW7C7HKrQpA3S+yndYJSq6eQ0/ahqHvHpc=";
  };

  npmDepsHash = "sha256-60YMls10w+PxgNLq2Bl3DXBUt3EWtQL5Zotn/ft+U5E=";

  passthru = {
    updateScript = nix-update-script { };
    tests.cross-seed = nixosTests.cross-seed;
  };

  meta = {
    description = "Fully-automatic torrent cross-seeding with Torznab";
    homepage = "https://cross-seed.org";
    license = lib.licenses.asl20;
    mainProgram = "cross-seed";
    maintainers = with lib.maintainers; [ mkez ];
  };
}

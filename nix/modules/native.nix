# Native builds module - platform-specific native builds
{
  perSystem =
    {
      lib,
      pkgs,
      system,
      crane,
      rustStable,
      rustMsrv,
      ...
    }:
    let
      nativeSuffix =
        if system == "x86_64-linux" then
          "x86_64-linux-gnu"
        else if system == "aarch64-linux" then
          "aarch64-linux-gnu"
        else if system == "x86_64-darwin" then
          "x86_64-darwin"
        else if system == "aarch64-darwin" then
          "aarch64-darwin"
        else
          throw "Unsupported system: ${system}";

      buildFeatures = lib.optionals pkgs.stdenv.isLinux [ "io-uring" ];

      # Common native build inputs (same for all native targets)
      nativeBuildInputs = [
        pkgs.autoconf
        pkgs.automake
        pkgs.libtool
        pkgs.rustPlatform.bindgenHook
      ];

      # Build client + server for a given toolchain, sharing one cargoArtifacts derivation
      mkPackagePair =
        toolchain: suffix:
        let
          craneLib = (crane.mkLib pkgs).overrideToolchain (_p: toolchain.minimal);
          src = craneLib.cleanCargoSource ../..;
          commonArgs = {
            inherit src buildFeatures nativeBuildInputs;
            strictDeps = true;
          };
          cargoArtifacts = craneLib.buildDepsOnly commonArgs;
          mkPkg =
            package:
            pkgs.callPackage ../. {
              inherit
                craneLib
                src
                cargoArtifacts
                buildFeatures
                nativeBuildInputs
                ;
              package = package;
              pname = package;
              cargoTomlPath = ../../${package}/Cargo.toml;
            };
        in
        {
          "lightway-client-${suffix}" = mkPkg "lightway-client";
          "lightway-server-${suffix}" = mkPkg "lightway-server";
        };
    in
    {
      packages =
        (mkPackagePair rustStable nativeSuffix) // (mkPackagePair rustMsrv "${nativeSuffix}-msrv");

      _module.args.nativeSuffix = nativeSuffix;
    };
}

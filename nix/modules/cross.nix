# Cross-compilation module - all cross-compilation targets
{
  perSystem =
    {
      lib,
      crane,
      pkgs,
      pkgsDarwinX64,
      system,
      rustStable,
      ...
    }:
    let
      # Map system to its native architecture (only for Linux)
      # On Darwin, everything is cross-compilation
      nativeArch =
        if lib.hasSuffix "linux" system then
          {
            "x86_64-linux" = "x86_64";
            "aarch64-linux" = "aarch64";
          }
          .${system} or null
        else
          null;

      # Cross-compilation target configurations
      # Includes both true cross-compilation and musl static builds
      allTargets = {
        x86_64-linux-gnu = {
          pkgsCross = pkgs.pkgsCross.gnu64;
          rustTarget = "x86_64-unknown-linux-gnu";
          isStatic = false;
          arch = "x86_64";
          libc = "gnu";
          os = "linux";
        };
        x86_64-linux-musl = {
          pkgsCross = pkgs.pkgsCross.musl64;
          rustTarget = "x86_64-unknown-linux-musl";
          isStatic = true;
          arch = "x86_64";
          libc = "musl";
          os = "linux";
        };
        aarch64-linux-musl = {
          pkgsCross = pkgs.pkgsCross.aarch64-multiplatform-musl;
          rustTarget = "aarch64-unknown-linux-musl";
          isStatic = true;
          arch = "aarch64";
          libc = "musl";
          os = "linux";
        };
        aarch64-linux-gnu = {
          pkgsCross = pkgs.pkgsCross.aarch64-multiplatform;
          rustTarget = "aarch64-unknown-linux-gnu";
          isStatic = false;
          arch = "aarch64";
          libc = "gnu";
          os = "linux";
        };
      }
      // lib.optionalAttrs (system == "aarch64-darwin") {
        # Cross-compile from Apple Silicon to Intel Mac.
        # nixpkgs 26.11 dropped x86_64-darwin (also from rustc targetPlatforms, which
        # buildRustPackage intersects into meta.platforms), so this target sources both
        # pkgsCross and the rust toolchain from the pinned 26.05 darwin nixpkgs
        # (pkgsDarwinX64) instead of the main pkgs.
        x86_64-darwin = {
          pkgsCross = pkgsDarwinX64.pkgsCross.x86_64-darwin;
          rustBin = pkgsDarwinX64.rust-bin.stable.latest;
          rustTarget = "x86_64-apple-darwin";
          isStatic = false;
          arch = "x86_64";
          libc = "darwin";
          os = "darwin";
        };
      };

      # Filter out gnu targets for native architecture (already built in native.nix)
      # Keep all musl targets (including native arch) since they're static builds
      # On Darwin, include all targets:
      #   - All Linux targets (true cross-compilation)
      #   - x86_64-darwin when on aarch64-darwin (Darwin-to-Darwin cross)
      crossTargets = lib.filterAttrs (
        name: config:
        nativeArch == null # Darwin: include everything (Linux + Darwin cross-targets)
        || config.libc == "musl" # Linux: include all musl
        || config.arch != nativeArch # Linux: include cross-arch gnu
      ) allTargets;

      mkPackagePair =
        targetName: config:
        let
          rust = (config.rustBin or rustStable).minimal.override { targets = [ config.rustTarget ]; };
          craneLib = (crane.mkLib config.pkgsCross).overrideToolchain (_p: rust);
          src = craneLib.cleanCargoSource ../..;

          buildFeatures = lib.optionals (config.os == "linux") [ "io-uring" ];

          rustflags =
            lib.optionalString config.isStatic "-C target-feature=+crt-static -C link-arg=-static"
            + lib.optionalString (
              !config.isStatic && config.os == "linux"
            ) " -C linker=${config.pkgsCross.stdenv.cc.targetPrefix}cc -C link-arg=-fuse-ld=bfd"
            + lib.optionalString (
              !config.isStatic && config.os == "darwin"
            ) " -C linker=${config.pkgsCross.stdenv.cc.targetPrefix}cc";

          crossEnv = {
            CARGO_BUILD_TARGET = config.rustTarget;
            RUSTFLAGS = rustflags;
            # Use build-platform libclang with target-platform headers for bindgen
            LIBCLANG_PATH = "${lib.getLib pkgs.buildPackages.llvmPackages.libclang}/lib";
            BINDGEN_EXTRA_CLANG_ARGS = lib.concatStringsSep " " (
              [
                "--target=${config.pkgsCross.stdenv.hostPlatform.config}"
                "-isystem ${lib.getDev config.pkgsCross.stdenv.cc.libc}/include"
                "-I${pkgs.buildPackages.llvmPackages.clang}/resource-root/include"
              ]
              ++ lib.optionals (config.pkgsCross.stdenv.cc ? nix-support) [
                "$(< ${config.pkgsCross.stdenv.cc}/nix-support/libc-cflags)"
                "$(< ${config.pkgsCross.stdenv.cc}/nix-support/cc-cflags)"
              ]
            );
            NIX_CFLAGS_COMPILE = lib.optionalString (
              config.pkgsCross.stdenv.hostPlatform.isAarch && config.pkgsCross.stdenv.hostPlatform.isLinux
            ) "-march=${config.pkgsCross.stdenv.hostPlatform.gcc.arch}+crypto";
          };

          commonArgs = {
            inherit src buildFeatures;
            strictDeps = true;
            nativeBuildInputs = [
              pkgs.autoconf
              pkgs.automake
              pkgs.libtool
            ];
          }
          // crossEnv;

          cargoArtifacts = craneLib.buildDepsOnly commonArgs;

          mkPkg =
            package:
            pkgs.callPackage ../. {
              inherit
                craneLib
                src
                cargoArtifacts
                buildFeatures
                ;
              nativeBuildInputs = commonArgs.nativeBuildInputs;
              package = package;
              pname = package;
              extraEnv = crossEnv;
              cargoTomlPath = ../../${package}/Cargo.toml;
            };
        in
        {
          "lightway-client-${targetName}" = mkPkg "lightway-client";
          "lightway-server-${targetName}" = mkPkg "lightway-server";
        };

      crossPackages = lib.foldl' lib.mergeAttrs { } (
        lib.mapAttrsToList (name: config: mkPackagePair name config) crossTargets
      );

      # Native musl toolchain config for the musl devShell (if on a Linux host)
      nativeMuslToolchain =
        if nativeArch == "x86_64" then
          crossTargets."x86_64-linux-musl" or null
        else if nativeArch == "aarch64" then
          crossTargets."aarch64-linux-musl" or null
        else
          null;
    in
    {
      packages = crossPackages;

      devShells = lib.optionalAttrs (nativeMuslToolchain != null) {
        musl = nativeMuslToolchain.pkgsCross.callPackage ../shell.nix {
          rustc = (nativeMuslToolchain.rustBin or rustStable).minimal.override {
            targets = [ nativeMuslToolchain.rustTarget ];
            extensions = [
              "rust-src"
              "rust-analyzer"
            ];
          };
          isStatic = true;
          defaultTarget = nativeMuslToolchain.rustTarget;
        };
      };
    };
}

{
  lib,
  craneLib,
  src,
  cargoArtifacts,
  package ? "lightway-client",
  pname,
  buildFeatures ? [ ],
  nativeBuildInputs ? [ ],
  strictDeps ? true,
  # Cross-compilation env vars (empty for native builds)
  extraEnv ? { },
  cargoTomlPath,
}:
let
  version = (builtins.fromTOML (builtins.readFile cargoTomlPath)).package.version;
in
craneLib.buildPackage (
  {
    inherit
      src
      cargoArtifacts
      pname
      version
      buildFeatures
      nativeBuildInputs
      strictDeps
      ;
    doCheck = false;
    cargoExtraArgs = "-p ${package}";
    meta = {
      mainProgram = package;
      platforms = lib.platforms.unix;
    };
  }
  // extraEnv
)

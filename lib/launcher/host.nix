{
  lib,
  writeShellApplication,
  writeText,
  python314,
}:
{
  configuration,
  runtimeInputs,
  meta,
  # Repaired game shortcuts run this command, so the launcher's name has to
  # match its executable. Each backend has its own name, so both can be
  # installed side by side
  launcherName,
}:
let
  python = python314.withPackages (packages: [
    packages.boltons
    packages.msgspec
  ]);
  configFile = writeText "steam-asahi-launcher.json" (
    builtins.toJSON (configuration // { LAUNCHER_COMMAND = launcherName; })
  );
in
writeShellApplication {
  inherit runtimeInputs meta;
  inheritPath = false;
  name = launcherName;
  text = ''
    exec ${lib.meta.getExe python} -I ${../../src/launcher}/main.py ${configFile} "$@"
  '';
}

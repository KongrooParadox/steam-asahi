{
  makeDesktopItem,
  runCommand,
  steam-unwrapped,
  symlinkJoin,
}:
{
  pname,
  version,
  launcher,
  desktopName,
  comment,
  passthru ? { },
}:
let
  # Copy icon contents so symlinks cannot retain the full Steam client
  steamIcons =
    runCommand "steam-asahi-icons-${steam-unwrapped.version}"
      {
        disallowedReferences = [ steam-unwrapped ];
      }
      ''
        mkdir -p "$out/share"
        cp --recursive --dereference -- ${steam-unwrapped}/share/icons "$out/share/"
      '';

  # The entry runs this backend's own command. The default entry that owns the
  # steam:// scheme comes from the NixOS module, so backends never compete for
  # those links
  command = launcher.meta.mainProgram;
  desktopItem = makeDesktopItem {
    inherit desktopName comment;
    name = command;
    exec = "${command} %U";
    icon = "steam";
    startupNotify = true;
    categories = [
      "Game"
      "Network"
    ];
  };
in
symlinkJoin {
  inherit pname version passthru;
  paths = [
    launcher
    desktopItem
    steamIcons
  ];
  inherit (launcher) meta;
}

# /// script
# requires-python = "==3.14.*"
# dependencies = ["boltons", "msgspec"]
# ///

"""Prepare FEX and Steam state, then launch Steam through muvm and FEX"""

from __future__ import annotations

import json
import os
import subprocess
from collections.abc import Mapping
from pathlib import Path

from common import (
    PRESSURE_VESSEL_FILESYSTEMS_RO,
    STEAM_CLIENT_ARGS,
    LauncherError,
    copy_bootstrap,
    desktop_entry_client_app_id,
    desktop_entry_is_managed,
    desktop_entry_needs_export,
    desktop_entry_runs_client,
    exec_guest,
    install_managed_desktop_entry,
    muvm_arguments,
    show_startup_splash,
    start_desktop_entry_watcher,
    warn_missing_audio_socket,
    write_managed_value,
    xdg_home,
)
from configuration import FexConfiguration

FEX_BASH_COMMAND = 'exec /bin/bash "$@"'


class FexLauncher:
    def __init__(self, configuration: FexConfiguration) -> None:
        self.config = configuration
        self.home = Path.home()
        self.data_home = xdg_home("XDG_DATA_HOME", ".local/share")
        self.config_home = xdg_home("XDG_CONFIG_HOME", ".config")
        self.data = self.data_home / "steam-asahi"

    def ensure_fex_rootfs(
        self, extra_environment: Mapping[str, str] | None = None
    ) -> None:
        environment = dict(os.environ)
        environment.update(extra_environment or {})
        if environment.get("FEX_ROOTFS"):
            return
        data_home = Path(
            environment.get("XDG_DATA_HOME") or str(self.data_home)
        )
        config_home = Path(
            environment.get("XDG_CONFIG_HOME") or str(self.config_home)
        )
        legacy = self.home / ".fex-emu"
        if legacy.is_dir():
            data = legacy
            config_path = legacy / "Config.json"
        else:
            data = Path(
                environment.get("FEX_APP_DATA_LOCATION")
                or str(data_home / "fex-emu")
            )
            config_path = config_home / "fex-emu/Config.json"

        if config_override := environment.get("FEX_APP_CONFIG_LOCATION"):
            config_directory = Path(config_override)
            if not config_directory.is_absolute():
                # FEX resolves relative config overrides beside its executable
                config_directory = (
                    Path(self.config["FEX_ROOTFS_FETCHER"]).parent
                    / config_directory
                )
            config_path = config_directory / "Config.json"

        rootfs = data / "RootFS"
        if rootfs.is_dir():
            for path in rootfs.iterdir():
                # Bash's original glob ignored hidden entries
                if (
                    not path.name.startswith(".")
                    and path.exists()
                    and (
                        path.is_dir()
                        or path.suffix in (".ero", ".img", ".sqsh")
                    )
                ):
                    return
        try:
            configuration = json.loads(config_path.read_text(encoding="utf-8"))
        except OSError, ValueError:
            configuration = {}
        # FEX stores options in Config; accept the legacy top-level form too
        if isinstance(configuration, dict):
            options = configuration.get("Config", configuration)
            if isinstance(options, dict):
                selected_rootfs = options.get("RootFS")
                if isinstance(selected_rootfs, str) and selected_rootfs:
                    return

        print(
            "FEX rootfs not found. Downloading Fedora 44 rootfs...\n"
            "This is a one-time setup (~1.3 GB download)."
        )
        try:
            subprocess.run(
                [
                    self.config["FEX_ROOTFS_FETCHER"],
                    "--assume-yes",
                    "--distro-name=Fedora",
                    "--distro-version=44",
                    "--distro-list-first",
                    "--as-is",
                ],
                env=environment,
                check=True,
            )
        except subprocess.CalledProcessError as error:
            raise LauncherError(
                "FEX rootfs download failed; run FEXRootFSFetcher manually."
            ) from error

    def muvm_arguments(
        self,
        extra_environment: Mapping[str, str] | None = None,
        *,
        interactive: bool = True,
    ) -> list[str]:
        config = self.config
        path = ":".join(
            [
                "/run/wrappers/bin",
                config["MUVM_PATH"],
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
            ]
        )
        environment = {
            "PATH": path,
            "XDG_DATA_HOME": str(self.data_home),
            "XDG_CONFIG_HOME": str(self.config_home),
            **{
                name: value
                for name, value in os.environ.items()
                if name.startswith("FEX_")
                or name in ("XDG_CACHE_HOME", "XDG_STATE_HOME")
            },
        }
        environment.update(extra_environment or {})
        return muvm_arguments(
            config, environment, emulator="fex", interactive=interactive
        )

    def fex_arguments(self, script: str, arguments: list[str]) -> list[str]:
        # FEXBash runs /bin/sh with these arguments, so -c selects the command
        return [
            "--",
            self.config["FEX_BASH"],
            "-c",
            FEX_BASH_COMMAND,
            "steam-asahi-fex",
            script,
            *arguments,
        ]

    def install_steam_bootstrap(self) -> None:
        marker = self.data / "bootstrap-installed"
        destination = self.data / "steam-launcher"
        if marker.is_file() and (destination / "bin_steam.sh").is_file():
            return
        print("Setting up Steam bootstrap...")
        copy_bootstrap(self.config["STEAM_BOOTSTRAP"], destination)
        write_managed_value(marker, "ok")
        print("Steam bootstrap ready.")

    def repair_desktop_entries(self) -> None:
        # This backend runs the client in the caller's own home, so its
        # shortcuts are already where the host's application launcher looks.
        # Their Exec line names a command that resolves only inside the
        # microVM, so repair it in place to keep the client's own names and
        # artwork. Mirror every game shortcut under this backend's prefix too,
        # so the menu finds it while another backend is running
        config = self.config
        prefix = config["ENTRY_PREFIX"]
        launcher_command = config["LAUNCHER_COMMAND"]
        target_directory = self.data_home / "applications"
        target_directory.mkdir(parents=True, exist_ok=True)
        directories = [
            xdg_home("XDG_DESKTOP_DIR", "Desktop"),
            target_directory,
        ]
        shortcut_names: set[str] = set()
        for directory in directories:
            for path in directory.glob("*.desktop"):
                if path.name.startswith(prefix):
                    continue
                if desktop_entry_runs_client(path):
                    install_managed_desktop_entry(path, path, launcher_command)
                app_id = desktop_entry_client_app_id(path, launcher_command)
                # The Desktop copy wins when both locations hold a shortcut
                if app_id is None or path.name in shortcut_names:
                    continue
                shortcut_names.add(path.name)
                target_path = target_directory / f"{prefix}{path.name}"
                icon = f"steam_icon_{app_id}"
                if not desktop_entry_needs_export(
                    path, target_path, launcher_command, icon
                ):
                    continue
                install_managed_desktop_entry(
                    path, target_path, launcher_command, icon
                )
        for target_path in target_directory.glob(f"{prefix}*.desktop"):
            if not desktop_entry_is_managed(target_path):
                continue
            if target_path.name.removeprefix(prefix) in shortcut_names:
                continue
            target_path.unlink(missing_ok=True)

    def main(self, arguments: list[str]) -> None:
        if Path(self.config["MUVM_HOST_MOUNT"]).is_dir():
            raise LauncherError(
                "Already inside a muvm guest. Exit FEXBash and run "
                "steam-asahi on the host."
            )
        steam_environment = {
            name: value
            for argument in self.config["EXTRA_ENVIRONMENT_ARGS"][1::2]
            for name, _, value in [argument.partition("=")]
        }
        self.ensure_fex_rootfs(
            None if arguments[:1] == ["--fex"] else steam_environment
        )
        if arguments[:1] == ["--fex"]:
            if len(arguments) != 2:
                raise LauncherError("usage: steam-asahi --fex '<command>'")
            exec_guest(
                self.muvm_arguments()
                + self.fex_arguments(
                    self.config["FEX_DIAGNOSTIC_SCRIPT"], arguments[1:]
                ),
                configuration=self.config,
            )

        warn_missing_audio_socket()
        show_startup_splash(
            self.config["YAD"],
            self.home / ".local/share/Steam/logs/cef_log.txt",
            10,
            "Starting Steam (microVM + FEX)...",
        )
        self.install_steam_bootstrap()
        start_desktop_entry_watcher(self.repair_desktop_entries)
        print("Launching Steam via muvm + FEX...")
        # muvm proxies a forwarded command's stdio only when asked, and that
        # proxy rejects the /dev/null an application launcher provides; only
        # the --fex diagnostic above asks for the proxy
        exec_guest(
            self.muvm_arguments(
                {
                    "PRESSURE_VESSEL_FILESYSTEMS_RO": PRESSURE_VESSEL_FILESYSTEMS_RO,
                    "STEAM_ASAHI_GUEST_UID": str(os.geteuid()),
                },
                interactive=False,
            )
            + self.config["EXTRA_ENVIRONMENT_ARGS"]
            + self.fex_arguments(
                self.config["FEX_STEAM_SCRIPT"],
                [
                    str(self.data / "steam-launcher/bin_steam.sh"),
                    *STEAM_CLIENT_ARGS,
                    *arguments,
                ],
            ),
            configuration=self.config,
        )

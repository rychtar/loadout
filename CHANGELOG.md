# Changelog

## Unreleased

### Fixed

- Removing or replacing a plugin folder no longer follows symlinks: a symlinked addon (or a symlink inside one) is only unlinked and what it points to stays. Symlinked sub folders are not copied or hashed.
- A Loadout self-update is refused when the new version's scripts do not compile, instead of leaving a broken Loadout after the restart.
- Two plugins from one GitHub repository (different folders) no longer share the cached release list and download each other's package.
- Releases flagged as pre-release (GitHub `prerelease`, Asset Store `stable: false`) are no longer offered as the newest version unless the range allows it. Tags that are a single big number (`nightly-20260105`, `build-2024`) are not versions.
- A backup of the same version is no longer replaced by the next one (`1.0.0`, `1.0.0-2`, …).
- A damaged registry, lock or cache file is backed up once, not on every read. An empty file counts as missing. A hand-edited cache with wrong types no longer crashes the update check.
- A failed first update check (nothing cached) is retried after 15 minutes instead of a day, and a check time in the future no longer blocks checks.
- An empty leftover `addons/<id>/` folder counts as not installed.
- `Thumbs.db` and `desktop.ini` no longer make a plugin look edited by hand.
- With two editors open, adding, editing, removing or importing a registry entry no longer undoes what the other editor saved: every change starts from the registry file on disk.
- "Overwrite anyway?" after choosing a version in "Install version…" installs that version (and keeps the pin choice) instead of the newest one.
- A local plugin whose plugin.cfg version is not valid (e.g. `1.2.3.4`) says so instead of "does not match range *". The version dialog no longer marks a release flagged as pre-release as the newest.
- The newest backups per plugin (10) are kept; older ones are deleted when a new backup is made.
- A release zip that also contains a copy of the plugin in a demo or test project (`Demo/addons/foo`) installs the plugin at the shallowest path, not the first one found.
- A package download may take up to 10 minutes (listing releases still 1 minute) instead of failing a large package on a slow connection after one minute.
- The dock says "Reading the registry…" until the first check is done instead of "The registry is empty".
- `tools/install_loadout` writes `project.godot` through a temporary file.
- Stricter validation: GitHub repos `owner/..` and `owner/name.git`, Windows device names and trailing dots in folder names, version numbers that overflow, numeric prerelease identifiers with leading zeros, zips that unpack to more than 512 MB or 20000 files, and a release without a download link now gives a clear message.

## 0.1.1

### Fixed

- The release notes in "Install version…" no longer stretch the dialog past the screen: they scroll, and the Asset Store BBCode and blank lines are cleaned up.
- After adding one addon to the registry, the other "Project addons not in the registry" rows stay clickable instead of greyed out.

### Changed

- Faster version checks, and the download, error and lock handling shared by the sources is no longer duplicated.
- Narrow docks keep room for plugin names, and the columns are resizable.

## 0.1.0

First release.

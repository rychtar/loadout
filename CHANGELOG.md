# Changelog

## 0.4.0

### Added

- **GDExtensions**: add-ons that ship a `.gdextension` file, with or without a `plugin.cfg` (for example Orchestrator), can be installed, updated, restored and removed. A new one is copied and Godot loads it right after (no restart). An update or a removal backs up and replaces or deletes the files and offers an editor restart, because the editor cannot swap a library it has loaded. The version is taken from the lock when there is no `plugin.cfg`. When the add-on also has a `plugin.cfg`, its editor plugin is enabled once Godot has loaded the library (with the next editor start when an older copy of the library is still loaded). Add-ons like this that are already in the project are listed for "Add to registry…" too.
- **Right-click** a plugin in the dock for all its actions, **double-click** (or Enter) to install or update it. A double-click also confirms a row in the version, backup and Asset Store search lists.
- **Copy to my plugin library**: "Add to registry…" for a plugin that is already in a project can copy its folder into a library folder (Editor Settings → Loadout → Library Path) and register that copy as a local source, so every other project gets the plugin from there.
- A **local folder with a GDExtension and no `plugin.cfg`** can be a source: the registry entry carries the version of its files (`"version"` in the local source), the Add dialog asks for it.
- **Show in FileSystem** for an installed plugin, and links to the plugin's page and the release notes of the version Loadout would install.
- Releases numbered the way Godot does it are understood: `v2.5.stable` is 2.5.0, `v2.5.1.rc2` is a release candidate of 2.5.1, `v2.6.dev2` a snapshot of 2.6.0. They are offered as pre-releases only with the opt-in, as before.

### Changed

- The dock is an `EditorDock` with its own title and icon (shown where the editor shows dock icons, for example in Editor → Editor Docks); it keeps its place in the layout.
- Symlinks inside a package, such as a macOS framework's `Versions/Current`, are unpacked and copied as symlinks instead of text files and missing folders. A link that points out of the package, or a file written through one, refuses the package.
- A release with both a `-demo-` zip and a plugin zip downloads the plugin zip.
- The dock header counts the plugins per state ("Up to date 3 · Update 1") and its tooltip, like the check button's, says when the sources last answered. The line saying what runs sits under the header and names the action ("Update · Gut…").
- **Remove from project…** and **Remove from registry…** are in a **Remove** menu at the end of the actions, apart from the ones that cannot lose anything.
- The plugin list and the detail share the dock with a border to drag; the detail is as tall as its content and scrolls past 60 % of the dock.
- A finished action that only reports (up to date, registry saved, imported) shows an editor toast instead of a dialog. Errors, warnings, skipped entries and **Show changes…** still open a dialog.
- A release zip that names the plugin folder as a whole word (`ui-1.0.zip` for `ui`, `debug-draw-3d.zip` for `debug_draw_3d`) wins over one that only contains it (`build-tools.zip`).
- Refreshing the dock no longer reads every file of every plugin again: a folder's hash is reused until one of its files changes, and installing several plugins refreshes the list once at the end instead of after each plugin.
- An install waits up to two minutes for the editor's filesystem scan, counted from the scan Loadout starts, so an update in a large project is no longer rolled back because the scan took longer than 30 seconds.

### Fixed

- Registry and lock entries this Loadout version cannot read (a source type or a version range from a newer Loadout, or a typo) are kept when it saves the file, instead of being dropped for every project. Their id and folder cannot be taken by a new entry meanwhile. Whole numbers in fields Loadout does not know are no longer written back as `5.0`.
- When **Remove from project** cannot delete the folder (a file locked by another program), the files are put back from the backup and the plugin is enabled again, instead of leaving a disabled, half-deleted plugin.
- The **Install** button of a plugin with no installable version stays disabled after another action.
- On Windows, an editor that reads the shared registry exactly while another editor saves it reads the new content instead of an empty registry.
- The startup offer and the update check no longer get lost when an extension in the project does not load at startup (no library for this system, for example): the editor's first scan then reloads every script, which cancelled them.
- A tag ending in `-stable` (Terrain3D's `v1.1.0-stable`) is the release 1.1.0, not a prerelease that a range like `^1.0.0` left out. Sources whose releases were cached the old way are checked again at the next refresh.
- An install that starts while the dock is still refreshing (right after the editor starts, for example) no longer fails with "Source type … is not supported" or "Release … is unknown".
- The dock hint ("Select a plugin in the list.") shows again after a plugin without a message was selected.
- A package whose zip declares more than 512 MB of content is refused before anything is unpacked, not after Loadout already unpacked a huge file into memory.
- `tools/install_loadout --force` moves the old Loadout aside while it copies the new one and puts it back when the copy fails, instead of leaving the project without Loadout.

## 0.3.0

### Added

- **Starter plugins…** (⋮ menu): a short list of plugins most projects can use (GDScript Templates, the Godot Git client Godit, Script-IDE). It opens the install dialog with the starter pack next to the plugins your registry says this project lacks. A chosen starter is added to your registry and installed in one step. The dialog opens by itself the first time, and again whenever a Loadout update adds a starter you were never offered (unless you hid the pack). The list is `addons/loadout/data/starter_pack.json`.
- The checkbox **Hide the starter pack from now on** at the bottom of the install dialog switches the starter pack off for good (Editor Settings → Loadout → Show Starter Pack, or ⋮ → Starter plugins… to bring it back). Starters you already moved to the install list stay and are installed.
- **Details…** on every card of the install dialog: what the plugin is for (from the Asset Store, GitHub, the Asset Library or its `plugin.cfg`) and the release notes of a version picked from a list. The lists themselves make no requests, the details are fetched when you click. A starter with no Asset Store release for your Godot version is skipped when you add it.

### Changed

- The install dialog ("Install plugins") has two lists: **Available** on the left (your global plugins that are missing here, then the tagged starters) and **To install in this project** on the right. Move a plugin with its button or a double-click, **Add all** and **Remove all** move everything. Each list scrolls when it is long.
- Release notes from the Asset Store, which it writes as BBCode, are shown as plain text instead of raw tags (a cached list is converted at the next update check).

## 0.2.0

### Added

- **Restore backup…**: put back files Loadout backed up before an update, an overwrite or "Remove from project" (the current files are backed up first, the restored version is pinned unless you untick it).
- **Show changes…** for a Modified plugin lists the files that were changed, added or deleted by hand compared with the version Loadout installed.
- When the newest release does not start (often a plugin written for another Godot version), Loadout offers the next older release and pins it, instead of leaving only an error.
- **Include pre-releases** per registry entry (Add/Edit dialog, `"prereleases": true`): betas and release candidates, and releases flagged as pre-releases, are then offered as updates.

### Fixed

- Removing or replacing a plugin folder no longer follows symlinks: a symlinked addon (or a symlink inside one) is only unlinked and what it points to stays. Symlinked sub folders are not copied or hashed.
- A Loadout self-update is refused when the new version's scripts do not compile, instead of leaving a broken Loadout after the restart. A script that uses a class the new version adds is not a false alarm: it cannot be checked before the restart and is skipped.
- "Update all" updates Loadout last. Its update restarts the editor, which used to cut off the plugins that came after it.
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
- The registry and the lock keep fields they do not know (written by a newer Loadout in another project), so an older Loadout saving the shared registry no longer drops them.
- Typing a project folder in the local source field no longer rewrites the text under the cursor, and a store entry being edited keeps its asset when you search again.
- `install_loadout.gd` asks for an absolute project path when the shell does not provide the start folder (Windows).
- GitHub: a full page of 50 releases is followed by the next page (up to 4), so an older version a range like `^1` needs is found even when the newest 50 releases are all 2.x.
- When a plugin does not load after installing (e.g. it needs the API of a newer Godot), the error names the running Godot version.
- A release or store answer with a value of the wrong type (e.g. `stable` as a list) no longer causes a script error.
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

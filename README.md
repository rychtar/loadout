# Loadout

The same editor plugins in every Godot project. Godot has no global editor plugins, so Loadout
lives in each project and brings the others along: it installs missing plugins from one registry
on your computer, keeps their versions in a lock file and tells you when updates are out.

![Loadout](media/thumbnail.webp)

## Features

- **One registry for all projects**: plugins from the Godot Asset Store, GitHub Releases or a local
  folder, shared by every project on your computer.
- **New project in one click**: when the editor starts, Loadout lists the missing plugins and you
  pick which ones the project gets.
- **Asset Store search**: find free add-ons for your Godot version by name, with all their releases.
- **Takes over what you already have**: plugins installed from the Asset Store or copied by hand can
  be added to the registry without reinstalling them.
- **Reproducible versions**: `loadout.lock.json` records the version, pin and folder hash of each
  plugin. Commit it and a fresh clone gets exactly the same versions.
- **Safe updates**: checked at most once a day, always confirmed, backed up and rolled back
  automatically when the new version does not start. No editor restart needed.
- **Pin or pick any version**: keep a plugin at one version in one project, or install an older
  release with its release notes.
- **Hands off your changes**: a plugin you edited by hand or pinned is never overwritten without
  asking.
- **Updates itself**, has no dependencies and runs only in the editor.

## Install

1. Copy `addons/loadout/` into your project's `addons/` folder (or install it from the Asset Store).
2. Enable **Loadout** in **Project → Project Settings → Plugins**.

You need Godot 4.7+.

For many projects, the install script from this repository does both steps in one command. It is
safe to run again; a different Loadout version is replaced only with `--force` (close the project's
editor first):

```bash
tools/install_loadout.sh ~/path/to/your/project
```

It finds Godot in `$GODOT`, in `PATH` or in `/Applications/Godot.app`. On Windows (or anywhere) run
it through Godot directly:

```bash
godot --headless --path <this repository> --script res://tools/install_loadout.gd -- <your project>
```

## Usage

- **Where**: the **Loadout** dock on the right side of the editor, next to History, Signals and
  Groups. **⟳** checks for updates now, **+** adds a plugin, **⋮** exports or imports the registry.
- **Add a plugin**: click **+** and search the Asset Store, enter a GitHub repository (`owner/name`
  or its URL) or pick a local folder with `plugin.cfg`. Choose the allowed versions: `*` (always the
  newest), `^1.2.0` (minor and patch updates) or `~1.2.0` (patch updates only).
- **New project**: open it with Loadout enabled. The missing plugins are listed with a checkbox
  each; unchecked ones can be ignored in this project. **Install missing…** in the dock opens the
  same list.
- **Update**: plugins with a newer version show **Update** with the release notes. **Update all…**
  updates every plugin in one confirmation (pinned ones are skipped).
- **Pin**: keeps a plugin at its installed version in this project; other projects still get
  updates. **Install version…** lists every release, and installing an older one pins it.
- **Edit…**: changes a plugin's source, allowed versions and whether it is installed automatically.
- **Remove from project…** deletes the folder (with a backup) and ignores the plugin here.
  **Remove from registry…** stops offering it everywhere; files in projects stay.
- **Plugins from elsewhere**: when a new plugin appears in `addons/` (for example from the Asset
  Store), Loadout offers to add it to the registry. Plugins you had before Loadout are listed under
  **Project addons not in the registry** with **Add to registry…**.
- **Modified** means the plugin's folder differs from the lock: **Accept changes** keeps your
  edits, **Overwrite** replaces them (with a backup).

Pins and ignores are per project, in `loadout.lock.json`. The registry is shared by all projects.

## How updates work

1. The plugin is disabled and its folder backed up to `user://loadout_backup/`.
2. The files are replaced, keeping existing `.uid` files so `uid://` references stay valid.
3. The editor rescans the project and checks that the new version compiles.
4. The plugin is enabled again and Loadout checks that it really runs.
5. If any step fails, the backup comes back.

Loadout can update itself too (registry entry with the folder `loadout`): it replaces its files and
restarts the editor. Offline or when a source fails, Loadout uses the data it saved last time and
shows a warning in the dock.

## Settings

**GitHub token** (optional): GitHub allows 60 API requests per hour without a token, and Loadout asks
each repository at most once a day, so that is plenty for most setups. With a token the limit is
5000 per hour. Create a fine-grained token with read access to public repositories and set it in
**Editor → Editor Settings → Loadout → Github Token**. It is sent only to `api.github.com` and
never ends up in the project or the log.

## Files

| File | Where | In git |
| --- | --- | --- |
| `loadout_registry.json` | Editor config folder: `~/Library/Application Support/Godot/` (macOS), `%APPDATA%\Godot\` (Windows), `~/.config/godot/` (Linux) | no |
| `loadout_cache.json` | Editor config folder (update checks, safe to delete) | no |
| `loadout.lock.json` | Project root | yes |

A damaged JSON file is never overwritten: Loadout copies it to `*.bak` and reports it in the dock.
Loadout installs only from sources in your registry, always over HTTPS. Paid Asset Store assets are
not supported.

## Development

Tests run headless and need no network or test framework:

```bash
godot --headless --path . --import
godot --headless --path . --script res://tests/run_tests.gd
```

Smoke tests that run in a real editor are described in `tests/editor/installer_smoke.gd`.

## License

MIT, see [LICENSE](LICENSE).

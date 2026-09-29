# Loadout

<img src="icon.png" width="128" align="right" alt="Loadout icon">

Keeps the same set of editor plugins in every Godot 4 project. Godot has no global editor
plugins, so Loadout lives in each project and brings the others along:
it installs missing plugins from one registry on your machine, keeps their versions in a
lock file and tells you when updates are out.

- **One registry for all projects**: plugins from GitHub Releases, the Godot Asset Library
  or a local folder.
- **New project in one click**: Loadout offers every missing plugin when the editor starts.
- **Reproducible versions**: `loadout.lock.json` records the version, pin and folder hash of each
  plugin. Commit it and a fresh clone gets exactly the same versions.
- **Safe updates**: checked at most once a day, always confirmed, backed up and rolled back
  automatically when the new version does not start.
- **Hands off your changes**: a plugin you edited by hand or pinned is never overwritten
  without asking.
- **Updates itself**, has no dependencies and runs only in the editor.

## Installation

Copy `addons/loadout` into your project's `addons` folder (or install it from
the Asset Library) and enable **Loadout** in **Project → Project Settings → Plugins**.

Requires Godot 4.5+ (tested with 4.7).

Optionally, the install script from this repository does both steps for you, which is handy
for many projects. Running it again is safe; a different Loadout version is replaced only with
`--force` (close the project's editor first):

```bash
tools/install_loadout.sh ~/path/to/your/project
```

The script finds Godot in `$GODOT`, in `PATH` or in `/Applications/Godot.app`. On Windows (or
anywhere) run it through Godot directly:

```bash
godot --headless --path <this repository> --script res://tools/install_loadout.gd -- <your project>
```

## Usage

Loadout adds the **Loadout** dock next to the Inspector.

**Add a plugin** with the **+** button:

| Source | What you enter |
| --- | --- |
| GitHub Releases | `owner/name` or the repository URL. Loadout installs the release's zip asset, or the tag's source zip. |
| Asset Library | Search by name; results are filtered to your Godot version. |
| Local folder | A folder with `plugin.cfg`, for your own plugins. |

The plugin folder must match its folder in the package (`addons/<folder>`). The version range
is `*` (always the newest), `^1.2.0` (minor and patch updates) or `~1.2.0` (patch updates only).
Plugins with **Install automatically in every project** are offered in every project.

**When the editor starts**, Loadout offers plugins missing in the project and shows a toast when
updates are available. The reload button checks for updates right away.

Each plugin in the dock has a state and matching actions:

| State | Meaning | Actions |
| --- | --- | --- |
| Up to date | Installed, matches the lock | Pin, remove from project |
| Missing | In the registry, not in this project | Install, ignore in this project |
| Update | Newer version within the range | Update (with release notes), pin |
| Pinned | Pinned in this project | Unpin, remove from project |
| Modified | Folder differs from the lock (edited by hand) | Accept changes, overwrite (with backup), remove |
| Not managed | Folder exists, Loadout did not install it | Take over, overwrite (with backup) |
| Unverified | Source unreachable, cached data used | Pin, remove from project |
| Not in registry | In the lock, no longer in the registry | Forget |

Removing a plugin from a project keeps a backup and marks it ignored there, so the next start
does not bring it back. Pins and ignores are per project, the registry is shared.

The **⋮** menu exports and imports the registry, for example to move it to another computer.

## Files

| File | Where | In git |
| --- | --- | --- |
| `loadout_registry.json` | Editor config folder: `~/Library/Application Support/Godot/` (macOS), `%APPDATA%\Godot\` (Windows), `~/.config/godot/` (Linux) | no |
| `loadout_cache.json` | Editor config folder (update checks, safe to delete) | no |
| `loadout.lock.json` | Project root | yes |

Backups of replaced and removed plugins go to `user://loadout_backup/<plugin>/<version>/`.
A damaged JSON file is never overwritten: Loadout copies it to `*.bak` and reports it in the dock.

## GitHub token

GitHub allows 60 API requests per hour without a token. Loadout asks each repository at most once
a day, so that is plenty for most setups. With a token the limit is 5000 per hour and unchanged
answers (`304 Not Modified`) do not count at all. To use one, set a token (fine-grained, public repositories only) in **Editor → Editor Settings → Global Addons
Manager → Github Token**. It stays in your editor settings, is sent only to `api.github.com` and
never ends up in the project or the log.

## How an update works

1. The plugin is disabled and its folder backed up.
2. The files are replaced, keeping existing `.uid` files so `uid://` references stay valid.
3. The editor rescans the project, reloads the plugin's scripts and checks that the new
   version compiles.
4. The plugin is enabled again and Loadout checks that it really runs.
5. If any step fails, the backup comes back.

When a new version removes a `class_name`, the editor keeps showing it until a restart, so Loadout
offers one. Loadout updates itself by replacing its files and restarting the editor right away.

Loadout only installs from sources listed in the registry, always over HTTPS.

## Development

Tests run headless and need no network or test framework:

```bash
godot --headless --path . --import
godot --headless --path . --script res://tests/run_tests.gd
```

Smoke tests that run in a real editor are described in `tests/editor/installer_smoke.gd`.

## License

MIT

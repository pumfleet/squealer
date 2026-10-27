# Squealer

Squealer is a per-app network firewall for macOS 15 and later. It shows every connection your apps make, asks before unknown ones go through, and lets you answer with rules. A rule can be scoped by host, domain, port, lifetime, profile and rule group.

## Layout

| Path | Contents |
| --- | --- |
| `Packages/SquealerKit` | Shared, unit-tested core used by all three targets: rule engine and precedence, rule analysis, the Little Snitch `.lsrules` format, the DNS parser, the MaxMind DB reader, the blocklist parser, the offline knowledge base, and XPC messages |
| `SquealerExtension` | The Network Extension system extension (`NEFilterDataProvider`, running as root). It owns rules, rule groups, settings, traffic history, the connection log and backups (SQLite via GRDB), and decides every flow |
| `Squealer` | The menu bar app: alerts, monitor, log, map, rules, rule groups, blocklists, profiles, encrypted DNS, settings and onboarding |
| `SquealerCLI` | The `squealer` command-line tool, bundled at `Contents/Helpers/squealer` |
| `SquealerTests` | App-level tests, including layout tests that catch overflowing alerts |
| `scripts/` | `dev-install.sh`, `release.sh`, `fetch-geoip.sh`, `sync-strings.sh` |

The extension is the source of truth and keeps filtering while the app isn't running. The app and the CLI talk to it over a privileged mach service, and both ends check code-signing requirements:

- **Answering alerts:** only the app can answer them.
- **CLI changes:** the CLI can change settings only when run as root.
- **Endpoint names:** each extension build registers its own endpoint, `…squealer.engine.<build>`. If two versions used the same name, launchd would race on it when an update replaces the running extension, and the new one would stay unreachable until a reboot.

## Developing

```sh
brew install xcodegen
scripts/fetch-geoip.sh                         # DB-IP Lite country + ASN databases (CC BY 4.0)
(cd Packages/SquealerKit && swift test)        # core tests
xcodegen && xcodebuild -scheme Squealer test   # app tests
scripts/dev-install.sh                         # build, install to /Applications, relaunch
```

- **System extensions only activate from `/Applications`.** The app replaces the running extension whenever the bundled extension has a different build number. `dev-install.sh` only bumps that number when extension code changes.
- **Demo mode:** `open Squealer.app --args -demo` runs the full UI on synthetic traffic, with no extension needed.
- **Debug launch arguments**:
  - `-snapshot <dir>` saves every window as a PNG.
  - `-tour <dir>` saves every main-window section.
  - `-dump <dir>` writes the live model state to `state.json`.
  - `-activate` resubmits the extension activation request.
  - `-restart-filter` turns the filter off and on.
  - `-open <window id>` opens a window at launch.
  - `-AppleLanguages "(de)"` runs the app in another language.
- **Logs:** `/usr/bin/log stream --info --predicate 'subsystem == "com.fusial.squealer"'`. Use the full path, because `log` is a zsh builtin.
- **Localization:**
  1. Strings live in `Squealer/Resources/Localizable.xcstrings`, translated into German, French, Spanish, Japanese and Simplified Chinese.
  2. After adding UI text, build, then run `scripts/sync-strings.sh`. It adds the new strings and reports how many are untranslated in each language.
  3. Have native speakers review the translations before release.

## Command-line tool

Install it from Settings › Advanced. That links `/usr/local/bin/squealer` to the copy bundled in the app.

```
squealer status | mode [ask|allow|deny|off] | profile [name] | rules | connections | log [--since 1h] [--app NAME] [--denied]
squealer blocklists [update] | backup | export | import FILE
```

Anyone can read state with the CLI. Changing anything requires `sudo`.

## Releasing

`scripts/release.sh <version> [build] [--skip-notarize]` produces a signed DMG:

1. Archives the app.
2. Re-signs it inside-out for Developer ID. Xcode can't export it directly: Developer ID profiles only grant the `-systemextension` form of the Network Extension entitlement, and export doesn't convert to it.
3. Notarizes and staples it.
4. Builds the DMG, plus a Sparkle appcast when Sparkle is configured.

Before the first release:

1. **Provisioning profiles.** The Developer ID profiles ("Mac Team Direct Provisioning Profile: com.fusial.squealer" and `….extension`) must exist locally. `xcodebuild -exportArchive -allowProvisioningUpdates` creates them.
2. **Notarization credentials:**

   ```sh
   xcrun notarytool store-credentials squealer --apple-id <id> --team-id U6P67B4375
   ```

3. **Sparkle updates (optional).** Run Sparkle's `generate_keys`, then set `SQUEALER_APPCAST_URL` and `SQUEALER_SPARKLE_PUBLIC_KEY` in `project.yml`. If either is empty, the app ships without an updater.
4. **Licensing.** Not decided yet. `Squealer/App/Licensing.swift` is the hook where a provider plugs in.

## Credits

IP geolocation is by [DB-IP](https://db-ip.com), licensed CC BY 4.0. The architecture was informed by Objective-See's LuLu; no LuLu code is used.

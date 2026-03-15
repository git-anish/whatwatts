# whatwatts

![whatwatts icon](assets/repo-preview.png)

whatwatts is a lightweight macOS menu bar app for answering one simple question: what is your Mac actually doing right now when you plug in a charger?

It keeps the original WhatWatt idea of showing negotiated adapter wattage, and adds the missing half of the picture: live battery charge and discharge rate.

It also includes an optional system-power estimate sourced from the Mac's SMC, inspired by SAP's Power Monitor app.

## Screenshots

Menu bar app:

![Menu bar app](assets/screenshots/menu-bar.png)

Preferences:

![Preferences](assets/screenshots/preferences.png)

Built on top of [SomeInterestingUserName/WhatWatt](https://github.com/SomeInterestingUserName/WhatWatt) by Jiawei Chen. The original MIT license is preserved. The upstream PR intentionally keeps the original app name; this public repo uses the `whatwatts` branding.

## Highlights

- Shows adapter wattage and battery power flow in one compact menu bar item
- Can also show an optional SMC system-power estimate in the menu bar
- Uses a clean title format like `67W | ↑18.4W | 23.1W`
- Defaults to a low-power refresh mode with fast updates only when charger state changes

## Why this fork exists

The original app is great at showing what the charger negotiated with macOS. This fork adds the part that is often more useful in practice: whether the battery is actually charging or discharging, and by how much.

That makes it easier to compare chargers, cables, docks, and multi-port power bricks without opening a larger system utility.

The optional system-power estimate came from looking at how [SAP Power Monitor](https://github.com/SAP/power-monitoring-tool-for-macos) approaches the same problem. `whatwatts` now reads the same class of private SMC value to expose a lightweight "how hard is the machine pulling right now?" estimate alongside charger and battery data.

In low-power mode, the app checks infrequently to stay lightweight. After plugging or unplugging a charger, it updates once a second for 20 seconds. The SMC system-power value is shown as a 60-second average unless `Always Live Updates` is enabled.

## SMC system power note

The SMC system-power readout is an estimate exposed through private Apple interfaces, not a public supported API.

- It is useful today and was tested working on an Intel Mac.
- It may stop working in a future macOS release or on different hardware generations.
- If it does, adapter and battery readings should continue to work normally.

## Trust and first launch

The full app source is public in this repo, so you can inspect exactly what it does before running it.

`whatwatts` is not notarized because this project is not being shipped under a paid Apple Developer account. That means macOS may block it on first launch until you explicitly allow it.

To open it on macOS:

1. Try to open the app once.
2. When macOS says it cannot be opened, dismiss the warning.
3. Open `System Settings > Privacy & Security`.
4. Scroll down to the `Security` section.
5. Find the message saying the app was blocked from opening.
6. Click `Open Anyway`.
7. Confirm by clicking `Open` in the follow-up dialog.

Apple's guidance for this flow:
- [Safely open apps on your Mac](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unidentified-developer-mh40616/mac)

If you want to test the app first without an admin password, use these one-line commands to unzip it in `~/Downloads`, remove the quarantine flag, and open it there.

Intel test run:

```bash
ditto -x -k ~/Downloads/whatwatts-intel.zip ~/Downloads && xattr -dr com.apple.quarantine ~/Downloads/whatwatts-intel.app && open ~/Downloads/whatwatts-intel.app
```

Apple Silicon test run:

```bash
ditto -x -k ~/Downloads/whatwatts-apple-silicon.zip ~/Downloads && xattr -dr com.apple.quarantine ~/Downloads/whatwatts-apple-silicon.app && open ~/Downloads/whatwatts-apple-silicon.app
```

If you want to install it in `/Applications`, use these one-line commands instead.

Intel install:

```bash
ditto -x -k ~/Downloads/whatwatts-intel.zip ~/Downloads && sudo rm -rf /Applications/whatwatts.app && sudo mv ~/Downloads/whatwatts-intel.app /Applications/whatwatts.app && sudo xattr -dr com.apple.quarantine /Applications/whatwatts.app && open /Applications/whatwatts.app
```

Apple Silicon install:

```bash
ditto -x -k ~/Downloads/whatwatts-apple-silicon.zip ~/Downloads && sudo rm -rf /Applications/whatwatts.app && sudo mv ~/Downloads/whatwatts-apple-silicon.app /Applications/whatwatts.app && sudo xattr -dr com.apple.quarantine /Applications/whatwatts.app && open /Applications/whatwatts.app
```

These commands use `sudo` because writing to `/Applications` usually requires an administrator password.

## Build

### Xcode

1. Open `WhatWatt.xcodeproj` in Xcode.
2. Select the `WhatWatt` target.
3. Build on the machine architecture you want to ship.

For release builds:

- Intel: build on an Intel Mac to produce an `x86_64` app
- Apple Silicon: build on an Apple Silicon Mac to produce an `arm64` app

This is the supported path for `whatwatts`, and it is the path used for the published release builds.

## Dependencies

`whatwatts` does not use third-party packages.

It depends on:

- macOS 10.13 or newer
- Xcode for release-quality Intel and Apple Silicon app bundles
- AppKit/Cocoa and IOKit, both provided by macOS

## Releases

The clean distribution strategy is to publish separate binaries by architecture.

- Intel release: build and ship an `x86_64` app bundle on Intel
- Apple Silicon release: build and ship an `arm64` app bundle on Apple Silicon
- Universal release: optional later, only if both sides are built and verified first

That keeps releases explicit and avoids shipping cross-compiled binaries that were never tested on their native platform.

## License and credit

Original project:
- Author: Jiawei Chen
- Repo: [SomeInterestingUserName/WhatWatt](https://github.com/SomeInterestingUserName/WhatWatt)
- License: MIT

This fork remains under the MIT license. See `LICENSE`.

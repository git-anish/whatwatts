# whatwatts

whatwatts is a lightweight macOS menu bar app for answering one simple question: what is your Mac actually doing right now when you plug in a charger?

It keeps the original WhatWatt idea of showing negotiated adapter wattage, and adds the missing half of the picture: live battery charge and discharge rate.

Built on top of [SomeInterestingUserName/WhatWatt](https://github.com/SomeInterestingUserName/WhatWatt) by Jiawei Chen. The original MIT license is preserved. The upstream PR intentionally keeps the original app name; this public repo uses the `whatwatts` branding.

## Highlights

- Shows adapter wattage and battery power flow in one compact menu bar item
- Uses a clean title format like `67W | ↑18.4W` while charging and `↓18.4W` when unplugged
- Defaults to a low-power refresh mode with fast updates only when charger state changes
- Includes `Always Live Updates` for people who want continuous refreshes
- Includes `Show 0W adapter when unplugged` if you prefer explicit adapter state in the menu bar
- Adds a lightweight `Preferences...` window for tuning update behavior
- Handles wrapped signed battery current values correctly on Intel Macs

## Why this fork exists

The original app is great at showing what the charger negotiated with macOS. This fork adds the part that is often more useful in practice: whether the battery is actually charging or discharging, and by how much.

That makes it easier to compare chargers, cables, docks, and multi-port power bricks without opening a larger system utility.

## Build

### Xcode

1. Open `WhatWatt.xcodeproj` in Xcode.
2. Select the `WhatWatt` target.
3. Build on the machine architecture you want to ship.

### Command Line Tools

On Intel Macs, you can build with `swiftc` and the macOS SDK from Command Line Tools:

```bash
mkdir -p build/whatwatts.app/Contents/MacOS build/whatwatts.app/Contents/Resources
swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk \
  -framework Cocoa \
  -framework IOKit \
  WhatWatt/main.swift \
  WhatWatt/AppDelegate.swift \
  WhatWatt/ViewController.swift \
  -o build/whatwatts.app/Contents/MacOS/whatwatts
cp WhatWatt/Info.plist build/whatwatts.app/Contents/Info.plist
codesign --force --deep --sign - build/whatwatts.app
```

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

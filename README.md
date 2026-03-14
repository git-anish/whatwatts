# WhatWatt Power Rate

A lightweight macOS menu bar app that shows both:
- adapter wattage requested from the charger
- live battery charge or discharge rate

This repo started from [SomeInterestingUserName/WhatWatt](https://github.com/SomeInterestingUserName/WhatWatt) by Jiawei Chen and keeps the original MIT license.

## What changed

This fork adds the behavior requested for day-to-day charger debugging:
- battery charge and discharge rate in watts, derived from `AppleSmartBattery` current and voltage
- event-driven low-power refresh behavior
- default low-power mode: `60s` idle refresh
- burst mode: `1s` refresh for `20s` after a real charger-state change
- menu toggle for `Always Live Updates`
- lightweight `Preferences...` window for tuning live interval, burst duration, and idle interval
- cleaner menu bar title format such as `67W | ↑18.4W` while charging and `↓18.4W` when unplugged
- optional `Show 0W adapter when unplugged` preference if you prefer the explicit adapter state in the menu bar
- Intel-safe signed current handling for wrapped battery amperage values

## Why this exists

The original app is excellent for showing negotiated adapter wattage, but it does not expose the current battery power flow. This fork is aimed at people who want to answer questions like:
- Is the battery actually charging right now?
- At what rate is it charging or discharging?
- Did plugging in this cable or charger change only the negotiated adapter wattage, or the real battery power flow too?

## Telemetry caveat

Battery power values come from macOS battery telemetry. Even when the app refreshes every second, the underlying battery readings may update more slowly or appear smoothed by the system, so visible changes often land on a cadence closer to a few seconds rather than every exact second.

## Build

### With Xcode

1. Open `WhatWatt.xcodeproj` in Xcode.
2. Select the `WhatWatt` target.
3. Build for the architecture you want on that machine.

### With Command Line Tools

On Intel Macs, you can build with `swiftc` and the macOS SDK from Command Line Tools:

```bash
mkdir -p build/WhatWatt.app/Contents/MacOS build/WhatWatt.app/Contents/Resources
swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk   -framework Cocoa   -framework IOKit   WhatWatt/main.swift   WhatWatt/AppDelegate.swift   WhatWatt/ViewController.swift   -o build/WhatWatt.app/Contents/MacOS/WhatWatt
cp WhatWatt/Info.plist build/WhatWatt.app/Contents/Info.plist
codesign --force --deep --sign - build/WhatWatt.app
```

## Release strategy

This project should publish separate binaries instead of pretending one local machine can always produce both cleanly.

- Intel release: build on Intel and publish an `x86_64` app bundle.
- Apple Silicon release: build on Apple Silicon and publish an `arm64` app bundle.
- Optional universal release: if needed later, combine vetted `x86_64` and `arm64` binaries with `lipo` and package that separately.

That keeps distribution explicit and avoids shipping untested cross-compiled binaries.

## License and credit

Original project:
- Author: Jiawei Chen
- Repo: [SomeInterestingUserName/WhatWatt](https://github.com/SomeInterestingUserName/WhatWatt)
- License: MIT

This fork remains under the MIT license. See `LICENSE`.

//
//  AppDelegate.swift
//  WhatWatt
//
//  Created by Jiawei Chen on 8/15/22.
//

import Cocoa
import IOKit
import IOKit.ps

private enum DefaultsKey {
    static let alwaysLiveUpdates = "AlwaysLiveUpdates"
    static let liveUpdateInterval = "LiveUpdateInterval"
    static let liveBurstDuration = "LiveBurstDuration"
    static let idleUpdateInterval = "IdleUpdateInterval"
    static let showAdapterWhenUnplugged = "ShowAdapterWhenUnplugged"
}

private struct AppConfiguration {
    let alwaysLiveUpdates: Bool
    let liveUpdateInterval: TimeInterval
    let liveBurstDuration: TimeInterval
    let idleUpdateInterval: TimeInterval
    let showAdapterWhenUnplugged: Bool

    static func current() -> AppConfiguration {
        let defaults = UserDefaults.standard
        return AppConfiguration(
            alwaysLiveUpdates: defaults.bool(forKey: DefaultsKey.alwaysLiveUpdates),
            liveUpdateInterval: clamp(defaults.double(forKey: DefaultsKey.liveUpdateInterval), min: 1.0, max: 10.0, fallback: 1.0),
            liveBurstDuration: clamp(defaults.double(forKey: DefaultsKey.liveBurstDuration), min: 5.0, max: 300.0, fallback: 20.0),
            idleUpdateInterval: clamp(defaults.double(forKey: DefaultsKey.idleUpdateInterval), min: 10.0, max: 300.0, fallback: 60.0),
            showAdapterWhenUnplugged: defaults.bool(forKey: DefaultsKey.showAdapterWhenUnplugged)
        )
    }

    private static func clamp(_ value: Double, min minValue: Double, max maxValue: Double, fallback: Double) -> Double {
        guard value.isFinite, value > 0 else { return fallback }
        return Swift.min(maxValue, Swift.max(minValue, value))
    }
}

private struct AdapterInfo {
    let watts: Int
    let amps: Double
    let volts: Double
    let hasValidVoltsAndAmps: Bool
}

private struct BatteryInfo {
    let watts: Double?
    let amps: Double?
    let volts: Double?
    let externalConnected: Bool
    let isCharging: Bool

    var flowSymbol: String {
        guard let watts else { return "?" }
        if watts > 0.05 { return "↑" }
        if watts < -0.05 { return "↓" }
        return "~"
    }
}

private struct PowerSnapshot {
    let adapter: AdapterInfo
    let battery: BatteryInfo

    var eventSignature: PowerEventSignature {
        PowerEventSignature(externalConnected: battery.externalConnected,
                            adapterWatts: adapter.watts,
                            isCharging: battery.isCharging)
    }
}

private struct PowerEventSignature: Equatable {
    let externalConnected: Bool
    let adapterWatts: Int
    let isCharging: Bool
}

private struct TimerConfiguration: Equatable {
    let interval: TimeInterval
    let leeway: TimeInterval
}

private enum RefreshReason {
    case launch
    case timer
    case powerNotification
    case preferencesChanged
}

class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var chargerDetail: NSMenuItem!
    private var batteryDetail: NSMenuItem!
    private var modeDetail: NSMenuItem!
    private var alwaysLiveMenuItem: NSMenuItem!
    private var showAdapterWhenUnpluggedMenuItem: NSMenuItem!
    private var preferencesWindowController: PreferencesWindowController?
    private var powerSourceLoopSource: CFRunLoopSource?
    private var refreshTimer: DispatchSourceTimer?
    private var timerConfiguration: TimerConfiguration?
    private var burstEndDate: Date?
    private var lastEventSignature: PowerEventSignature?

    private let notChargingText = "Not Charging"
    private let chargingText = "Charging"
    private let batteryUnknownText = "Battery Rate Unavailable"

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        registerDefaults()
        configureMenu()
        configurePowerNotifications()
        refreshReadings(reason: .launch)
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.setEventHandler {}
        refreshTimer?.cancel()
        refreshTimer = nil

        if let powerSourceLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), powerSourceLoopSource, .defaultMode)
        }
    }

    private func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            DefaultsKey.alwaysLiveUpdates: false,
            DefaultsKey.liveUpdateInterval: 1.0,
            DefaultsKey.liveBurstDuration: 20.0,
            DefaultsKey.idleUpdateInterval: 60.0,
            DefaultsKey.showAdapterWhenUnplugged: false,
        ])
    }

    private func configureMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        chargerDetail = NSMenuItem(title: notChargingText, action: nil, keyEquivalent: "")
        chargerDetail.isEnabled = false

        batteryDetail = NSMenuItem(title: batteryUnknownText, action: nil, keyEquivalent: "")
        batteryDetail.isEnabled = false

        modeDetail = NSMenuItem(title: "Mode: Starting...", action: nil, keyEquivalent: "")
        modeDetail.isEnabled = false

        alwaysLiveMenuItem = NSMenuItem(title: "Always Live Updates", action: #selector(toggleAlwaysLiveUpdates(_:)), keyEquivalent: "")
        alwaysLiveMenuItem.target = self

        showAdapterWhenUnpluggedMenuItem = NSMenuItem(title: "Show 0W Adapter When Unplugged", action: #selector(toggleShowAdapterWhenUnplugged(_:)), keyEquivalent: "")
        showAdapterWhenUnpluggedMenuItem.target = self

        let preferencesItem = NSMenuItem(title: "Preferences...", action: #selector(openPreferences(_:)), keyEquivalent: ",")
        preferencesItem.target = self

        let menu = NSMenu()
        menu.addItem(chargerDetail)
        menu.addItem(batteryDetail)
        menu.addItem(modeDetail)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(alwaysLiveMenuItem)
        menu.addItem(showAdapterWhenUnpluggedMenuItem)
        menu.addItem(preferencesItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        syncMenuState()
    }

    private func configurePowerNotifications() {
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        powerSourceLoopSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            delegate.refreshReadings(reason: .powerNotification)
        }, context).takeRetainedValue()

        if let powerSourceLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), powerSourceLoopSource, .defaultMode)
        }
    }

    @objc private func toggleAlwaysLiveUpdates(_ sender: NSMenuItem) {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: DefaultsKey.alwaysLiveUpdates), forKey: DefaultsKey.alwaysLiveUpdates)
        applyPreferences()
    }

    @objc private func toggleShowAdapterWhenUnplugged(_ sender: NSMenuItem) {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: DefaultsKey.showAdapterWhenUnplugged), forKey: DefaultsKey.showAdapterWhenUnplugged)
        applyPreferences()
    }

    @objc private func openPreferences(_ sender: Any?) {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController { [weak self] in
                self?.applyPreferences()
            }
        }

        preferencesWindowController?.reloadFromDefaults()
        preferencesWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyPreferences() {
        let configuration = AppConfiguration.current()
        if configuration.alwaysLiveUpdates {
            burstEndDate = nil
        }
        syncMenuState()
        refreshReadings(reason: .preferencesChanged)
    }

    private func refreshReadings(reason: RefreshReason) {
        let configuration = AppConfiguration.current()
        let snapshot = readPowerSnapshot()

        if reason == .powerNotification,
           lastEventSignature != snapshot.eventSignature,
           !configuration.alwaysLiveUpdates {
            burstEndDate = Date().addingTimeInterval(configuration.liveBurstDuration)
        }

        if !configuration.alwaysLiveUpdates,
           let burstEndDate,
           Date() >= burstEndDate {
            self.burstEndDate = nil
        }

        lastEventSignature = snapshot.eventSignature
        updateUI(with: snapshot, configuration: configuration)
        rescheduleTimer(using: configuration)
    }

    private func updateUI(with snapshot: PowerSnapshot, configuration: AppConfiguration) {
        statusItem.button?.title = menuBarTitle(snapshot: snapshot)
        chargerDetail.title = adapterTitle(snapshot.adapter)
        batteryDetail.title = batteryTitle(snapshot.battery)
        modeDetail.title = currentModeLabel(configuration: configuration)
        syncMenuState()
    }

    private func syncMenuState() {
        let configuration = AppConfiguration.current()
        alwaysLiveMenuItem.state = configuration.alwaysLiveUpdates ? .on : .off
        showAdapterWhenUnpluggedMenuItem.state = configuration.showAdapterWhenUnplugged ? .on : .off
    }

    private func currentModeLabel(configuration: AppConfiguration) -> String {
        if configuration.alwaysLiveUpdates {
            return String(format: "Mode: Always live (%.0fs)", configuration.liveUpdateInterval)
        }

        if let burstEndDate, burstEndDate > Date() {
            let remaining = max(1, Int(ceil(burstEndDate.timeIntervalSinceNow)))
            return String(format: "Mode: Event burst live (%.0fs, %ds left)", configuration.liveUpdateInterval, remaining)
        }

        return String(format: "Mode: Low power idle (%.0fs)", configuration.idleUpdateInterval)
    }

    private func rescheduleTimer(using configuration: AppConfiguration) {
        let newConfiguration = makeTimerConfiguration(configuration: configuration)
        guard newConfiguration != timerConfiguration else { return }

        refreshTimer?.setEventHandler {}
        refreshTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + newConfiguration.interval,
                       repeating: newConfiguration.interval,
                       leeway: .milliseconds(max(100, Int(newConfiguration.leeway * 1000.0))))
        timer.setEventHandler { [weak self] in
            self?.refreshReadings(reason: .timer)
        }
        timer.resume()

        refreshTimer = timer
        timerConfiguration = newConfiguration
    }

    private func makeTimerConfiguration(configuration: AppConfiguration) -> TimerConfiguration {
        let interval: TimeInterval
        if configuration.alwaysLiveUpdates {
            interval = configuration.liveUpdateInterval
        } else if let burstEndDate, burstEndDate > Date() {
            interval = configuration.liveUpdateInterval
        } else {
            interval = configuration.idleUpdateInterval
        }

        return TimerConfiguration(interval: interval,
                                  leeway: max(0.2, interval * 0.2))
    }

    private func menuBarTitle(snapshot: PowerSnapshot) -> String {
        let configuration = AppConfiguration.current()
        guard let batteryWatts = snapshot.battery.watts else {
            if snapshot.adapter.watts == 0 && !configuration.showAdapterWhenUnplugged {
                return snapshot.battery.flowSymbol
            }
            return String(format: "%dW", snapshot.adapter.watts)
        }

        if snapshot.adapter.watts == 0 && !configuration.showAdapterWhenUnplugged {
            return String(format: "%@%.1fW", snapshot.battery.flowSymbol, abs(batteryWatts))
        }

        return String(format: "%dW | %@%.1fW",
                      snapshot.adapter.watts,
                      snapshot.battery.flowSymbol,
                      abs(batteryWatts))
    }

    private func adapterTitle(_ adapter: AdapterInfo) -> String {
        if adapter.hasValidVoltsAndAmps {
            return String(format: "Adapter: %d W, %.02f V, %.02f A", adapter.watts, adapter.volts, adapter.amps)
        }

        if adapter.watts != 0 {
            return String(format: "Adapter: %d W (%@)", adapter.watts, chargingText)
        }

        return notChargingText
    }

    private func batteryTitle(_ battery: BatteryInfo) -> String {
        guard let watts = battery.watts,
              let amps = battery.amps,
              let volts = battery.volts else {
            return batteryUnknownText
        }

        let direction: String
        if watts > 0.05 {
            direction = "Charging"
        } else if watts < -0.05 {
            direction = "Discharging"
        } else {
            direction = "Near idle"
        }

        return String(format: "Battery: %@ %@%.1f W (%@%.02f A, %.02f V)",
                      battery.flowSymbol,
                      direction,
                      abs(watts),
                      amps >= 0 ? "+" : "-",
                      abs(amps),
                      volts)
    }

    private func readPowerSnapshot() -> PowerSnapshot {
        PowerSnapshot(adapter: readAdapterInfo(), battery: readBatteryInfo())
    }

    private func readAdapterInfo() -> AdapterInfo {
        let unmanagedDict = IOPSCopyExternalPowerAdapterDetails()
        var watts = 0
        var amps = 0.0
        var volts = 0.0
        var hasValidVoltsAndAmps = false

        if let dict = unmanagedDict?.takeRetainedValue() as? [String: Any] {
            if let maybeWatts = dict[kIOPSPowerAdapterWattsKey] as? Int {
                watts = maybeWatts
                if let maybeAmps = dict[kIOPSPowerAdapterCurrentKey] as? Double {
                    amps = maybeAmps / 1000.0
                    if abs(amps) >= 1E-9 {
                        volts = Double(watts) / amps
                        hasValidVoltsAndAmps = true
                    }
                }
            }
        }

        return AdapterInfo(watts: watts,
                           amps: amps,
                           volts: volts,
                           hasValidVoltsAndAmps: hasValidVoltsAndAmps)
    }

    private func readBatteryInfo() -> BatteryInfo {
        let batteryEntry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard batteryEntry != IO_OBJECT_NULL else {
            return BatteryInfo(watts: nil,
                               amps: nil,
                               volts: nil,
                               externalConnected: false,
                               isCharging: false)
        }

        defer { IOObjectRelease(batteryEntry) }

        var properties: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(batteryEntry, &properties, kCFAllocatorDefault, 0)
        guard result == KERN_SUCCESS,
              let dict = properties?.takeRetainedValue() as? [String: Any] else {
            return BatteryInfo(watts: nil,
                               amps: nil,
                               volts: nil,
                               externalConnected: false,
                               isCharging: false)
        }

        let amperageMilliAmps = signedIntegerValue(dict["Amperage"]) ?? signedIntegerValue(dict["InstantAmperage"])
        let voltageMilliVolts = signedIntegerValue(dict["Voltage"])
        let externalConnected = (dict["ExternalConnected"] as? Bool) ?? false
        let isCharging = (dict["IsCharging"] as? Bool) ?? false

        guard let amperageMilliAmps, let voltageMilliVolts else {
            return BatteryInfo(watts: nil,
                               amps: nil,
                               volts: nil,
                               externalConnected: externalConnected,
                               isCharging: isCharging)
        }

        let amps = Double(amperageMilliAmps) / 1000.0
        let volts = Double(voltageMilliVolts) / 1000.0
        let watts = amps * volts

        return BatteryInfo(watts: watts,
                           amps: amps,
                           volts: volts,
                           externalConnected: externalConnected,
                           isCharging: isCharging)
    }

    private func signedIntegerValue(_ rawValue: Any?) -> Int? {
        if let number = rawValue as? NSNumber {
            return Int(Int64(bitPattern: number.uint64Value))
        }
        if let value = rawValue as? Int {
            return value
        }
        if let value = rawValue as? Int64 {
            return Int(value)
        }
        if let value = rawValue as? UInt64 {
            return Int(Int64(bitPattern: value))
        }
        return nil
    }
}

private final class PreferencesWindowController: NSWindowController {
    private let defaults = UserDefaults.standard
    private let onApply: () -> Void

    private let alwaysLiveCheckbox = NSButton(checkboxWithTitle: "Always live updates", target: nil, action: nil)
    private let showAdapterWhenUnpluggedCheckbox = NSButton(checkboxWithTitle: "Show 0W adapter when unplugged", target: nil, action: nil)
    private let liveIntervalField = NSTextField(string: "")
    private let burstDurationField = NSTextField(string: "")
    private let idleIntervalField = NSTextField(string: "")

    init(onApply: @escaping () -> Void) {
        self.onApply = onApply

        let contentRect = NSRect(x: 0, y: 0, width: 420, height: 250)
        let window = NSWindow(contentRect: contentRect,
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "WhatWatt Preferences"
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.contentView = makeContentView()
        reloadFromDefaults()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reloadFromDefaults() {
        let configuration = AppConfiguration.current()
        alwaysLiveCheckbox.state = configuration.alwaysLiveUpdates ? .on : .off
        showAdapterWhenUnpluggedCheckbox.state = configuration.showAdapterWhenUnplugged ? .on : .off
        liveIntervalField.stringValue = formatNumber(configuration.liveUpdateInterval)
        burstDurationField.stringValue = formatNumber(configuration.liveBurstDuration)
        idleIntervalField.stringValue = formatNumber(configuration.idleUpdateInterval)
    }

    private func makeContentView() -> NSView {
        let numberFormatter = NumberFormatter()
        numberFormatter.minimum = 1
        numberFormatter.maximumFractionDigits = 0
        numberFormatter.allowsFloats = false

        [liveIntervalField, burstDurationField, idleIntervalField].forEach {
            $0.formatter = numberFormatter
            $0.alignment = .right
        }

        let helpLabel = NSTextField(labelWithString: "Default behavior is low power mode: refresh every 60 seconds, switch to 1-second updates for 20 seconds after a charger-state change.")
        helpLabel.lineBreakMode = .byWordWrapping
        helpLabel.maximumNumberOfLines = 3
        helpLabel.textColor = .secondaryLabelColor

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Live interval (sec)"), liveIntervalField],
            [NSTextField(labelWithString: "Burst duration (sec)"), burstDurationField],
            [NSTextField(labelWithString: "Idle interval (sec)"), idleIntervalField],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 16
        grid.xPlacement = .fill

        let saveButton = NSButton(title: "Save", target: self, action: #selector(savePreferences(_:)))
        let resetButton = NSButton(title: "Reset Defaults", target: self, action: #selector(resetDefaults(_:)))
        let buttonRow = NSStackView(views: [resetButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.alignment = .centerY

        let stack = NSStackView(views: [helpLabel, alwaysLiveCheckbox, showAdapterWhenUnpluggedCheckbox, grid, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 250))
        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
            liveIntervalField.widthAnchor.constraint(equalToConstant: 80),
            burstDurationField.widthAnchor.constraint(equalToConstant: 80),
            idleIntervalField.widthAnchor.constraint(equalToConstant: 80),
        ])

        return container
    }

    @objc private func savePreferences(_ sender: Any?) {
        defaults.set(alwaysLiveCheckbox.state == .on, forKey: DefaultsKey.alwaysLiveUpdates)
        defaults.set(showAdapterWhenUnpluggedCheckbox.state == .on, forKey: DefaultsKey.showAdapterWhenUnplugged)
        defaults.set(sanitizedValue(from: liveIntervalField, min: 1, max: 10, fallback: 1), forKey: DefaultsKey.liveUpdateInterval)
        defaults.set(sanitizedValue(from: burstDurationField, min: 5, max: 300, fallback: 20), forKey: DefaultsKey.liveBurstDuration)
        defaults.set(sanitizedValue(from: idleIntervalField, min: 10, max: 300, fallback: 60), forKey: DefaultsKey.idleUpdateInterval)
        reloadFromDefaults()
        onApply()
    }

    @objc private func resetDefaults(_ sender: Any?) {
        defaults.set(false, forKey: DefaultsKey.alwaysLiveUpdates)
        defaults.set(false, forKey: DefaultsKey.showAdapterWhenUnplugged)
        defaults.set(1.0, forKey: DefaultsKey.liveUpdateInterval)
        defaults.set(20.0, forKey: DefaultsKey.liveBurstDuration)
        defaults.set(60.0, forKey: DefaultsKey.idleUpdateInterval)
        reloadFromDefaults()
        onApply()
    }

    private func sanitizedValue(from field: NSTextField, min minValue: Double, max maxValue: Double, fallback: Double) -> Double {
        guard let value = Double(field.stringValue), value.isFinite else { return fallback }
        return Swift.min(maxValue, Swift.max(minValue, value))
    }

    private func formatNumber(_ value: Double) -> String {
        String(Int(round(value)))
    }
}

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
    static let showAdapterInMenuBar = "ShowAdapterInMenuBar"
    static let showBatteryInMenuBar = "ShowBatteryInMenuBar"
    static let showSystemPowerInMenuBar = "ShowSystemPowerInMenuBar"
    static let hideBatteryWhenIdleOnCharger = "HideBatteryWhenIdleOnCharger"
}

private struct AppConfiguration {
    let alwaysLiveUpdates: Bool
    let liveUpdateInterval: TimeInterval
    let liveBurstDuration: TimeInterval
    let idleUpdateInterval: TimeInterval
    let showAdapterWhenUnplugged: Bool
    let showAdapterInMenuBar: Bool
    let showBatteryInMenuBar: Bool
    let showSystemPowerInMenuBar: Bool
    let hideBatteryWhenIdleOnCharger: Bool

    static func current() -> AppConfiguration {
        let defaults = UserDefaults.standard
        return AppConfiguration(
            alwaysLiveUpdates: defaults.bool(forKey: DefaultsKey.alwaysLiveUpdates),
            liveUpdateInterval: clamp(defaults.double(forKey: DefaultsKey.liveUpdateInterval), min: 1.0, max: 10.0, fallback: 1.0),
            liveBurstDuration: clamp(defaults.double(forKey: DefaultsKey.liveBurstDuration), min: 5.0, max: 300.0, fallback: 20.0),
            idleUpdateInterval: clamp(defaults.double(forKey: DefaultsKey.idleUpdateInterval), min: 10.0, max: 300.0, fallback: 60.0),
            showAdapterWhenUnplugged: defaults.bool(forKey: DefaultsKey.showAdapterWhenUnplugged),
            showAdapterInMenuBar: defaults.bool(forKey: DefaultsKey.showAdapterInMenuBar),
            showBatteryInMenuBar: defaults.bool(forKey: DefaultsKey.showBatteryInMenuBar),
            showSystemPowerInMenuBar: defaults.bool(forKey: DefaultsKey.showSystemPowerInMenuBar),
            hideBatteryWhenIdleOnCharger: defaults.bool(forKey: DefaultsKey.hideBatteryWhenIdleOnCharger)
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
    let systemPowerWatts: Double?

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
    private var systemDetail: NSMenuItem!
    private var modeDetail: NSMenuItem!
    private var alwaysLiveMenuItem: NSMenuItem!
    private var showAdapterWhenUnpluggedMenuItem: NSMenuItem!
    private var showAdapterInMenuBarMenuItem: NSMenuItem!
    private var showBatteryInMenuBarMenuItem: NSMenuItem!
    private var showSystemPowerInMenuBarMenuItem: NSMenuItem!
    private var hideBatteryWhenIdleMenuItem: NSMenuItem!
    private var preferencesWindowController: PreferencesWindowController?
    private var powerSourceLoopSource: CFRunLoopSource?
    private var refreshTimer: DispatchSourceTimer?
    private var timerConfiguration: TimerConfiguration?
    private var burstEndDate: Date?
    private var lastEventSignature: PowerEventSignature?

    private let notChargingText = "Not Charging"
    private let chargingText = "Charging"
    private let batteryUnknownText = "Battery Rate Unavailable"
    private var recentSystemPowerSamples: [(date: Date, watts: Double)] = []

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
            DefaultsKey.showAdapterInMenuBar: true,
            DefaultsKey.showBatteryInMenuBar: true,
            DefaultsKey.showSystemPowerInMenuBar: true,
            DefaultsKey.hideBatteryWhenIdleOnCharger: false,
        ])
    }

    private func configureMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        chargerDetail = NSMenuItem(title: notChargingText, action: nil, keyEquivalent: "")
        chargerDetail.isEnabled = false

        batteryDetail = NSMenuItem(title: batteryUnknownText, action: nil, keyEquivalent: "")
        batteryDetail.isEnabled = false

        systemDetail = NSMenuItem(title: "System Power Unavailable", action: nil, keyEquivalent: "")
        systemDetail.isEnabled = false

        modeDetail = NSMenuItem(title: "Mode: Starting...", action: nil, keyEquivalent: "")
        modeDetail.isEnabled = false

        alwaysLiveMenuItem = NSMenuItem(title: "Always Live Updates", action: #selector(toggleAlwaysLiveUpdates(_:)), keyEquivalent: "")
        alwaysLiveMenuItem.target = self

        showAdapterWhenUnpluggedMenuItem = NSMenuItem(title: "Keep showing adapter as 0W when unplugged", action: #selector(toggleShowAdapterWhenUnplugged(_:)), keyEquivalent: "")
        showAdapterWhenUnpluggedMenuItem.target = self

        showAdapterInMenuBarMenuItem = NSMenuItem(title: "Show Adapter Wattage", action: #selector(toggleShowAdapterInMenuBar(_:)), keyEquivalent: "")
        showAdapterInMenuBarMenuItem.target = self

        showBatteryInMenuBarMenuItem = NSMenuItem(title: "Show Battery Flow", action: #selector(toggleShowBatteryInMenuBar(_:)), keyEquivalent: "")
        showBatteryInMenuBarMenuItem.target = self

        showSystemPowerInMenuBarMenuItem = NSMenuItem(title: "Show System Power", action: #selector(toggleShowSystemPowerInMenuBar(_:)), keyEquivalent: "")
        showSystemPowerInMenuBarMenuItem.target = self

        hideBatteryWhenIdleMenuItem = NSMenuItem(title: "Hide Battery Flow When Idle On Charger", action: #selector(toggleHideBatteryWhenIdleOnCharger(_:)), keyEquivalent: "")
        hideBatteryWhenIdleMenuItem.target = self

        let preferencesItem = NSMenuItem(title: "Preferences...", action: #selector(openPreferences(_:)), keyEquivalent: ",")
        preferencesItem.target = self

        let menu = NSMenu()
        menu.addItem(chargerDetail)
        menu.addItem(batteryDetail)
        menu.addItem(systemDetail)
        menu.addItem(modeDetail)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(showAdapterInMenuBarMenuItem)
        menu.addItem(showBatteryInMenuBarMenuItem)
        menu.addItem(showSystemPowerInMenuBarMenuItem)
        menu.addItem(showAdapterWhenUnpluggedMenuItem)
        menu.addItem(hideBatteryWhenIdleMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(alwaysLiveMenuItem)
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

    @objc private func toggleShowAdapterInMenuBar(_ sender: NSMenuItem) {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: DefaultsKey.showAdapterInMenuBar), forKey: DefaultsKey.showAdapterInMenuBar)
        applyPreferences()
    }

    @objc private func toggleShowBatteryInMenuBar(_ sender: NSMenuItem) {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: DefaultsKey.showBatteryInMenuBar), forKey: DefaultsKey.showBatteryInMenuBar)
        applyPreferences()
    }

    @objc private func toggleShowSystemPowerInMenuBar(_ sender: NSMenuItem) {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: DefaultsKey.showSystemPowerInMenuBar), forKey: DefaultsKey.showSystemPowerInMenuBar)
        applyPreferences()
    }

    @objc private func toggleHideBatteryWhenIdleOnCharger(_ sender: NSMenuItem) {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: DefaultsKey.hideBatteryWhenIdleOnCharger), forKey: DefaultsKey.hideBatteryWhenIdleOnCharger)
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
        recordSystemPowerSample(snapshot.systemPowerWatts)
        updateUI(with: snapshot, configuration: configuration)
        rescheduleTimer(using: configuration)
    }

    private func updateUI(with snapshot: PowerSnapshot, configuration: AppConfiguration) {
        statusItem.button?.title = menuBarTitle(snapshot: snapshot)
        chargerDetail.title = adapterTitle(snapshot.adapter)
        batteryDetail.title = batteryTitle(snapshot.battery)
        systemDetail.title = systemPowerTitle(snapshot.systemPowerWatts)
        modeDetail.title = currentModeLabel(configuration: configuration)
        syncMenuState()
    }

    private func syncMenuState() {
        let configuration = AppConfiguration.current()
        alwaysLiveMenuItem.state = configuration.alwaysLiveUpdates ? .on : .off
        showAdapterWhenUnpluggedMenuItem.state = configuration.showAdapterWhenUnplugged ? .on : .off
        showAdapterInMenuBarMenuItem.state = configuration.showAdapterInMenuBar ? .on : .off
        showBatteryInMenuBarMenuItem.state = configuration.showBatteryInMenuBar ? .on : .off
        showSystemPowerInMenuBarMenuItem.state = configuration.showSystemPowerInMenuBar ? .on : .off
        hideBatteryWhenIdleMenuItem.state = configuration.hideBatteryWhenIdleOnCharger ? .on : .off
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
        var parts: [String] = []

        if configuration.showAdapterInMenuBar {
            if snapshot.adapter.watts != 0 || configuration.showAdapterWhenUnplugged {
                parts.append(String(format: "%dW", snapshot.adapter.watts))
            }
        }

        if configuration.showBatteryInMenuBar,
           !shouldHideBatteryInMenuBar(snapshot: snapshot, configuration: configuration),
           let batteryWatts = snapshot.battery.watts {
            parts.append(String(format: "%@%.1fW", snapshot.battery.flowSymbol, abs(batteryWatts)))
        }

        if configuration.showSystemPowerInMenuBar,
           let systemPowerWatts = displayedSystemPowerWatts(configuration: configuration),
           systemPowerWatts > 0.05 {
            parts.append(String(format: "%.1fW", systemPowerWatts))
        }

        if !parts.isEmpty {
            return parts.joined(separator: " | ")
        }

        if let batteryWatts = snapshot.battery.watts {
            return String(format: "%@%.1fW", snapshot.battery.flowSymbol, abs(batteryWatts))
        }

        return "whatwatts"
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

        return String(format: "Battery: %@ %@ %.1f W (%@%.02f A, %.02f V)",
                      battery.flowSymbol,
                      direction,
                      abs(watts),
                      amps >= 0 ? "+" : "-",
                      abs(amps),
                      volts)
    }

    private func systemPowerTitle(_ watts: Double?) -> String {
        let configuration = AppConfiguration.current()
        guard let watts = displayedSystemPowerWatts(configuration: configuration), watts > 0.05 else {
            return "System: Power Unavailable"
        }
        if configuration.alwaysLiveUpdates {
            return String(format: "System: %.1f W live (SMC estimate)", watts)
        }
        return String(format: "System: %.1f W avg (60s, SMC estimate)", watts)
    }

    private func readPowerSnapshot() -> PowerSnapshot {
        PowerSnapshot(adapter: readAdapterInfo(),
                      battery: readBatteryInfo(),
                      systemPowerWatts: readSystemPowerWatts())
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
        let batteryEntry = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSmartBattery"))
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

    private func readSystemPowerWatts() -> Double? {
        let smc = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSMC"))
        guard smc != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(smc) }

        var connection: io_connect_t = IO_OBJECT_NULL
        let openResult = IOServiceOpen(smc, mach_task_self_, 1, &connection)
        guard openResult == KERN_SUCCESS, connection != IO_OBJECT_NULL else {
            return nil
        }
        defer { IOServiceClose(connection) }

        let key = fourCharCode("PSTR")
        let valueOffset = 48
        var input = [UInt8](repeating: 0, count: 80)
        var output = [UInt8](repeating: 0, count: 80)
        var outputSize = output.count

        withUnsafeBytes(of: key) { keyBytes in
            for (index, byte) in keyBytes.enumerated() {
                input[index] = byte
            }
        }
        withUnsafeBytes(of: UInt32(4)) { sizeBytes in
            for (index, byte) in sizeBytes.enumerated() {
                input[28 + index] = byte
            }
        }
        input[42] = 5

        let result = input.withUnsafeBytes { inputBytes in
            output.withUnsafeMutableBytes { outputBytes in
                IOConnectCallStructMethod(connection,
                                          2,
                                          inputBytes.baseAddress!,
                                          input.count,
                                          outputBytes.baseAddress!,
                                          &outputSize)
            }
        }

        guard result == kIOReturnSuccess, outputSize >= valueOffset + 4 else {
            return nil
        }

        let watts = output.withUnsafeBytes { rawBuffer -> Float in
            rawBuffer.load(fromByteOffset: valueOffset, as: Float.self)
        }
        return watts.isFinite && watts > 0 ? Double(watts) : nil
    }

    private func fourCharCode(_ string: String) -> UInt32 {
        string.utf8.reduce(0) { ($0 << 8) + UInt32($1) }
    }

    private func recordSystemPowerSample(_ watts: Double?) {
        guard let watts, watts > 0.05 else { return }
        let now = Date()
        recentSystemPowerSamples.append((date: now, watts: watts))
        recentSystemPowerSamples.removeAll { now.timeIntervalSince($0.date) > 60.0 }
    }

    private func displayedSystemPowerWatts(configuration: AppConfiguration) -> Double? {
        if configuration.alwaysLiveUpdates {
            return recentSystemPowerSamples.last?.watts
        }

        let now = Date()
        let samples = recentSystemPowerSamples.filter { now.timeIntervalSince($0.date) <= 60.0 }
        guard !samples.isEmpty else { return nil }
        let total = samples.reduce(0.0) { $0 + $1.watts }
        return total / Double(samples.count)
    }

    private func shouldHideBatteryInMenuBar(snapshot: PowerSnapshot, configuration: AppConfiguration) -> Bool {
        guard configuration.hideBatteryWhenIdleOnCharger,
              snapshot.battery.externalConnected,
              !snapshot.battery.isCharging,
              let watts = snapshot.battery.watts else {
            return false
        }
        return abs(watts) <= 0.35
    }
}

private final class PreferencesWindowController: NSWindowController {
    private let defaults = UserDefaults.standard
    private let onApply: () -> Void

    private let showAdapterCheckbox = NSButton(checkboxWithTitle: "Show adapter wattage", target: nil, action: nil)
    private let showBatteryCheckbox = NSButton(checkboxWithTitle: "Show battery flow", target: nil, action: nil)
    private let showSystemPowerCheckbox = NSButton(checkboxWithTitle: "Show system power", target: nil, action: nil)
    private let hideBatteryWhenIdleCheckbox = NSButton(checkboxWithTitle: "Hide battery flow when idle on charger", target: nil, action: nil)
    private let alwaysLiveCheckbox = NSButton(checkboxWithTitle: "Always live updates", target: nil, action: nil)
    private let showAdapterWhenUnpluggedCheckbox = NSButton(checkboxWithTitle: "Keep showing adapter as 0W when unplugged", target: nil, action: nil)

    private let liveIntervalValueLabel = NSTextField(labelWithString: "")
    private let burstDurationValueLabel = NSTextField(labelWithString: "")
    private let idleIntervalValueLabel = NSTextField(labelWithString: "")

    private let liveIntervalStepper = NSStepper()
    private let burstDurationStepper = NSStepper()
    private let idleIntervalStepper = NSStepper()

    init(onApply: @escaping () -> Void) {
        self.onApply = onApply

        let contentRect = NSRect(x: 0, y: 0, width: 352, height: 252)
        let window = NSWindow(contentRect: contentRect,
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "whatwatts Settings"
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.isMovableByWindowBackground = false
        window.isOpaque = false
        window.backgroundColor = NSColor(calibratedWhite: 0.97, alpha: 0.94)
        window.center()

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
        showAdapterCheckbox.state = configuration.showAdapterInMenuBar ? .on : .off
        showBatteryCheckbox.state = configuration.showBatteryInMenuBar ? .on : .off
        showSystemPowerCheckbox.state = configuration.showSystemPowerInMenuBar ? .on : .off
        hideBatteryWhenIdleCheckbox.state = configuration.hideBatteryWhenIdleOnCharger ? .on : .off
        alwaysLiveCheckbox.state = configuration.alwaysLiveUpdates ? .on : .off
        showAdapterWhenUnpluggedCheckbox.state = configuration.showAdapterWhenUnplugged ? .on : .off

        liveIntervalStepper.doubleValue = configuration.liveUpdateInterval
        burstDurationStepper.doubleValue = configuration.liveBurstDuration
        idleIntervalStepper.doubleValue = configuration.idleUpdateInterval

        syncValueLabels()
    }

    private func makeContentView() -> NSView {
        configureStepper(liveIntervalStepper, action: #selector(stepperChanged(_:)), min: 1, max: 10, increment: 1)
        configureStepper(burstDurationStepper, action: #selector(stepperChanged(_:)), min: 5, max: 300, increment: 5)
        configureStepper(idleIntervalStepper, action: #selector(stepperChanged(_:)), min: 10, max: 300, increment: 5)

        showAdapterCheckbox.font = .systemFont(ofSize: 13, weight: .medium)
        showBatteryCheckbox.font = .systemFont(ofSize: 13, weight: .medium)
        showSystemPowerCheckbox.font = .systemFont(ofSize: 13, weight: .medium)
        hideBatteryWhenIdleCheckbox.font = .systemFont(ofSize: 13, weight: .medium)
        alwaysLiveCheckbox.font = .systemFont(ofSize: 13, weight: .medium)
        showAdapterWhenUnpluggedCheckbox.font = .systemFont(ofSize: 13, weight: .medium)

        let iconView = NSImageView(image: NSApp.applicationIconImage)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),
        ])

        let displayLabel = sectionLabel("Display")
        let refreshLabel = sectionLabel("Refresh cadence")

        let explanationLabel = NSTextField(labelWithString: "Idle: 60 sec. Charger events: 1 sec for 20 sec. System power uses a rolling 60 sec average unless Always live is enabled.")
        explanationLabel.textColor = .secondaryLabelColor
        explanationLabel.lineBreakMode = .byWordWrapping
        explanationLabel.maximumNumberOfLines = 2

        let displayGroup = NSStackView(views: [
            showAdapterCheckbox,
            showBatteryCheckbox,
            showSystemPowerCheckbox,
            hideBatteryWhenIdleCheckbox,
            showAdapterWhenUnpluggedCheckbox,
            alwaysLiveCheckbox,
        ])
        displayGroup.orientation = .vertical
        displayGroup.alignment = .leading
        displayGroup.spacing = 10

        let intervalGrid = NSGridView(views: [
            [metricLabel("Live interval"), valueControlRow(label: liveIntervalValueLabel, stepper: liveIntervalStepper)],
            [metricLabel("Burst duration"), valueControlRow(label: burstDurationValueLabel, stepper: burstDurationStepper)],
            [metricLabel("Idle interval"), valueControlRow(label: idleIntervalValueLabel, stepper: idleIntervalStepper)],
        ])
        intervalGrid.rowSpacing = 12
        intervalGrid.columnSpacing = 18
        intervalGrid.yPlacement = .center

        let saveButton = NSButton(title: "Save", target: self, action: #selector(savePreferences(_:)))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let resetButton = NSButton(title: "Reset Defaults", target: self, action: #selector(resetDefaults(_:)))
        resetButton.bezelStyle = .rounded

        let spacer = NSView()
        let buttonRow = NSStackView(views: [spacer, resetButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        buttonRow.alignment = .centerY

        let content = NSStackView(views: [
            iconView,
            displayLabel,
            displayGroup,
            divider(),
            refreshLabel,
            explanationLabel,
            intervalGrid,
            buttonRow,
        ])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)

        let container = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 352, height: 252))
        if #available(macOS 10.14, *) {
            container.material = .underWindowBackground
        } else {
            container.material = .popover
        }
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.97, alpha: 0.86).cgColor
        container.addSubview(content)

        content.translatesAutoresizingMaskIntoConstraints = false
        spacer.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 24),
            explanationLabel.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -content.edgeInsets.left - content.edgeInsets.right),
        ])

        return container
    }

    @objc private func stepperChanged(_ sender: NSStepper) {
        syncValueLabels()
    }

    @objc private func savePreferences(_ sender: Any?) {
        defaults.set(alwaysLiveCheckbox.state == .on, forKey: DefaultsKey.alwaysLiveUpdates)
        defaults.set(showAdapterWhenUnpluggedCheckbox.state == .on, forKey: DefaultsKey.showAdapterWhenUnplugged)
        defaults.set(showAdapterCheckbox.state == .on, forKey: DefaultsKey.showAdapterInMenuBar)
        defaults.set(showBatteryCheckbox.state == .on, forKey: DefaultsKey.showBatteryInMenuBar)
        defaults.set(showSystemPowerCheckbox.state == .on, forKey: DefaultsKey.showSystemPowerInMenuBar)
        defaults.set(hideBatteryWhenIdleCheckbox.state == .on, forKey: DefaultsKey.hideBatteryWhenIdleOnCharger)
        defaults.set(liveIntervalStepper.doubleValue, forKey: DefaultsKey.liveUpdateInterval)
        defaults.set(burstDurationStepper.doubleValue, forKey: DefaultsKey.liveBurstDuration)
        defaults.set(idleIntervalStepper.doubleValue, forKey: DefaultsKey.idleUpdateInterval)
        reloadFromDefaults()
        onApply()
    }

    @objc private func resetDefaults(_ sender: Any?) {
        defaults.set(false, forKey: DefaultsKey.alwaysLiveUpdates)
        defaults.set(false, forKey: DefaultsKey.showAdapterWhenUnplugged)
        defaults.set(true, forKey: DefaultsKey.showAdapterInMenuBar)
        defaults.set(true, forKey: DefaultsKey.showBatteryInMenuBar)
        defaults.set(true, forKey: DefaultsKey.showSystemPowerInMenuBar)
        defaults.set(false, forKey: DefaultsKey.hideBatteryWhenIdleOnCharger)
        defaults.set(1.0, forKey: DefaultsKey.liveUpdateInterval)
        defaults.set(20.0, forKey: DefaultsKey.liveBurstDuration)
        defaults.set(60.0, forKey: DefaultsKey.idleUpdateInterval)
        reloadFromDefaults()
        onApply()
    }

    private func configureStepper(_ stepper: NSStepper, action: Selector, min: Double, max: Double, increment: Double) {
        stepper.target = self
        stepper.action = action
        stepper.minValue = min
        stepper.maxValue = max
        stepper.increment = increment
        stepper.valueWraps = false
        stepper.autorepeat = true
    }

    private func syncValueLabels() {
        liveIntervalValueLabel.stringValue = valueString(liveIntervalStepper.doubleValue)
        burstDurationValueLabel.stringValue = valueString(burstDurationStepper.doubleValue)
        idleIntervalValueLabel.stringValue = valueString(idleIntervalStepper.doubleValue)
    }

    private func valueString(_ value: Double) -> String {
        "\(Int(value)) sec"
    }

    private func sectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func metricLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        return label
    }

    private func valueControlRow(label: NSTextField, stepper: NSStepper) -> NSView {
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        label.alignment = .right
        label.textColor = .labelColor

        let row = NSStackView(views: [label, stepper])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY

        label.widthAnchor.constraint(equalToConstant: 74).isActive = true

        let capsule = NSView()
        capsule.wantsLayer = true
        capsule.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.95).cgColor
        capsule.layer?.cornerRadius = 8
        let borderColor: NSColor
        if #available(macOS 10.14, *) {
            borderColor = NSColor.separatorColor.withAlphaComponent(0.3)
        } else {
            borderColor = NSColor.gridColor.withAlphaComponent(0.35)
        }
        capsule.layer?.borderColor = borderColor.cgColor
        capsule.layer?.borderWidth = 1
        capsule.layer?.shadowColor = NSColor.black.withAlphaComponent(0.08).cgColor
        capsule.layer?.shadowOpacity = 1
        capsule.layer?.shadowRadius = 4
        capsule.layer?.shadowOffset = CGSize(width: 0, height: -1)
        capsule.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: capsule.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: capsule.trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: capsule.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: capsule.bottomAnchor, constant: -6),
        ])

        return capsule
    }

    private func divider() -> NSView {
        let divider = NSBox()
        divider.boxType = .separator
        return divider
    }
}

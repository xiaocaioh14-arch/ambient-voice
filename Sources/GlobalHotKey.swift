import Foundation
import AppKit
import Carbon

final class GlobalHotKey: @unchecked Sendable {
    enum Event {
        case pressed
        case released
        case doubleTap
    }

    var onEvent: ((Event) -> Void)?

    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false
    private var pressTimestamp: Date?
    private let debounceInterval: TimeInterval = 0.2  // 200ms
    private var debounceTimer: DispatchSourceTimer?
    private var pendingStop = false

    // Double-tap detection
    private var lastTapReleaseTime: Date?
    private let doubleTapInterval: TimeInterval = 0.4  // 400ms window
    private var lastTapWasShort = false

    /// Device-dependent Right Command mask (NX_DEVICERCMDKEYMASK).
    private static let rightCommandDeviceMask: UInt64 = 0x10

    func start() {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: globalHotKeyCallback,
            userInfo: userInfo
        ) else {
            NSLog("[GlobalHotKey] Failed to create event tap. Check Accessibility permissions.")
            return
        }

        eventTap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        debounceTimer?.cancel()
        debounceTimer = nil

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        runLoopSource = nil
        isPressed = false
        pressTimestamp = nil
        pendingStop = false
        lastTapReleaseTime = nil
        lastTapWasShort = false
    }

    // MARK: - Internal handling

    fileprivate func handleFlagsChanged(_ event: CGEvent) {
        let flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // kVK_RightCommand = 0x36
        guard keyCode == 0x36 else { return }

        // Check device-dependent right command flag
        let rawFlags = flags.rawValue
        let rightCmdDown = (rawFlags & GlobalHotKey.rightCommandDeviceMask) != 0

        if rightCmdDown && !isPressed {
            // Key just pressed — start debounce
            isPressed = true
            pressTimestamp = Date()
            pendingStop = false

            debounceTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + debounceInterval)
            timer.setEventHandler { [weak self] in
                guard let self = self, self.isPressed else { return }
                self.onEvent?(.pressed)
            }
            timer.resume()
            debounceTimer = timer

        } else if !rightCmdDown && isPressed {
            // Key released
            isPressed = false
            let held = -(pressTimestamp?.timeIntervalSinceNow ?? -debounceInterval)

            debounceTimer?.cancel()
            debounceTimer = nil

            if held >= debounceInterval {
                // Was past debounce — fire release (normal push-to-talk)
                DispatchQueue.main.async { [weak self] in
                    self?.onEvent?(.released)
                }
                lastTapWasShort = false
            } else {
                // Short tap (released before debounce) — check for double-tap
                let now = Date()
                if lastTapWasShort,
                   let lastRelease = lastTapReleaseTime,
                   now.timeIntervalSince(lastRelease) <= doubleTapInterval {
                    // Double-tap detected!
                    lastTapWasShort = false
                    lastTapReleaseTime = nil
                    DispatchQueue.main.async { [weak self] in
                        self?.onEvent?(.doubleTap)
                    }
                } else {
                    lastTapWasShort = true
                    lastTapReleaseTime = now
                }
            }
            pressTimestamp = nil
        }
    }
}

// MARK: - C callback

private func globalHotKeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // Re-enable the tap
        let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userInfo).takeUnretainedValue()
        if let tap = hotKey.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userInfo).takeUnretainedValue()
    hotKey.handleFlagsChanged(event)

    return Unmanaged.passUnretained(event)
}

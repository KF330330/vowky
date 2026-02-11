import Foundation
import CoreGraphics

// MARK: - Pure data types for hotkey evaluation

enum HotkeyAction: Equatable {
    case hotkeyDown
    case hotkeyUp
    case cancelRecording
    case passThrough
}

struct HotkeyModifiers {
    let option: Bool
    let command: Bool
    let control: Bool
    let shift: Bool
}

// MARK: - Pure function evaluator (no CGEvent dependency)

struct HotkeyEvaluator {
    static let escapeKeyCode: Int64 = 53

    static func evaluateEvent(
        keyCode: Int64,
        modifiers: HotkeyModifiers,
        isRepeat: Bool,
        isKeyUp: Bool
    ) -> HotkeyAction {
        let config = HotkeyConfig.current
        let isTargetKey = keyCode == config.keyCode
        let modifiersMatch = modifiers.option == config.needsOption
            && modifiers.command == config.needsCommand
            && modifiers.control == config.needsControl
            && modifiers.shift == config.needsShift

        guard isTargetKey && modifiersMatch && !isRepeat else {
            return .passThrough
        }

        return isKeyUp ? .hotkeyUp : .hotkeyDown
    }

    static func evaluateCancelEvent(
        keyCode: Int64,
        modifiers: HotkeyModifiers,
        isKeyUp: Bool
    ) -> HotkeyAction {
        guard keyCode == escapeKeyCode,
              !modifiers.option, !modifiers.command,
              !modifiers.control, !modifiers.shift,
              !isKeyUp else {
            return .passThrough
        }
        return .cancelRecording
    }
}

// MARK: - HotkeyManager (CGEvent tap + evaluateEvent)

final class HotkeyManager {

    private var eventTapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapHolder: UnsafeMutablePointer<CFMachPort?>?

    /// Called on main thread when hotkey is pressed (toggle mode: keyDown only)
    var onHotkeyPressed: (() -> Void)?

    /// Called on main thread when Escape is pressed during recording
    var onCancelPressed: (() -> Void)?

    /// Returns true if cancel (Escape) should be intercepted (i.e. currently recording)
    var shouldInterceptCancel: (() -> Bool)?

    var isRunning: Bool { eventTapPort != nil }

    /// Start listening for the global hotkey (Option+Space).
    /// Returns true if tap was created successfully.
    @discardableResult
    func start() -> Bool {
        guard eventTapPort == nil else { return true }

        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let holder = UnsafeMutablePointer<CFMachPort?>.allocate(capacity: 1)
        holder.initialize(to: nil)

        // Store a reference to self in a pointer for the C callback
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        // We pass refcon = (tapHolder, selfPointer) via a wrapper struct
        let context = UnsafeMutablePointer<HotkeyTapContext>.allocate(capacity: 1)
        context.initialize(to: HotkeyTapContext(tapHolder: holder, manager: refcon))

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: hotkeyTapCallback,
            userInfo: context
        ) else {
            holder.deallocate()
            context.deallocate()
            return false
        }

        holder.pointee = tap
        self.tapHolder = holder
        self.eventTapPort = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.runLoopSource = source

        print("[VoKey][Hotkey] Event tap created and running")
        return true
    }

    /// Stop listening for the global hotkey.
    func stop() {
        if let tap = eventTapPort {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            // CFMachPort is managed by the RunLoop; invalidating it cleans up
        }

        tapHolder?.deinitialize(count: 1)
        tapHolder?.deallocate()
        tapHolder = nil
        eventTapPort = nil
        runLoopSource = nil
    }

    deinit {
        stop()
    }
}

// MARK: - C callback support

private struct HotkeyTapContext {
    let tapHolder: UnsafeMutablePointer<CFMachPort?>
    let manager: UnsafeMutableRawPointer
}

private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else {
        return Unmanaged.passRetained(event)
    }

    let context = refcon.assumingMemoryBound(to: HotkeyTapContext.self).pointee

    // tapDisabledByTimeout auto-recovery
    if type == .tapDisabledByTimeout {
        print("[VoKey][Hotkey] tapDisabledByTimeout — auto-recovering")
        if let port = context.tapHolder.pointee {
            CGEvent.tapEnable(tap: port, enable: true)
        }
        return Unmanaged.passRetained(event)
    }

    guard type == .keyDown || type == .keyUp else {
        return Unmanaged.passRetained(event)
    }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    let isKeyUp = (type == .keyUp)

    let modifiers = HotkeyModifiers(
        option: flags.contains(.maskAlternate),
        command: flags.contains(.maskCommand),
        control: flags.contains(.maskControl),
        shift: flags.contains(.maskShift)
    )

    let action = HotkeyEvaluator.evaluateEvent(
        keyCode: keyCode,
        modifiers: modifiers,
        isRepeat: isRepeat,
        isKeyUp: isKeyUp
    )

    switch action {
    case .hotkeyDown:
        print("[VoKey][Hotkey] Option+Space keyDown — dispatching onHotkeyPressed")
        let manager = Unmanaged<HotkeyManager>.fromOpaque(context.manager).takeUnretainedValue()
        DispatchQueue.main.async {
            manager.onHotkeyPressed?()
        }
        return nil // Swallow the event

    case .hotkeyUp:
        // Toggle mode: swallow keyUp but don't dispatch callback
        return nil

    case .cancelRecording:
        // Should not happen from evaluateEvent, but handle gracefully
        return Unmanaged.passRetained(event)

    case .passThrough:
        // Check for Escape cancel
        let cancelAction = HotkeyEvaluator.evaluateCancelEvent(
            keyCode: keyCode,
            modifiers: modifiers,
            isKeyUp: isKeyUp
        )
        if cancelAction == .cancelRecording {
            let manager = Unmanaged<HotkeyManager>.fromOpaque(context.manager).takeUnretainedValue()
            let shouldIntercept = manager.shouldInterceptCancel?() ?? false
            if shouldIntercept {
                print("[VoKey][Hotkey] Escape keyDown — dispatching onCancelPressed")
                DispatchQueue.main.async {
                    manager.onCancelPressed?()
                }
                return nil // Swallow
            }
        }
        return Unmanaged.passRetained(event)
    }
}

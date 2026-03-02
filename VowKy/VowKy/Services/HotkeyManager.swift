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

    // MARK: - Modifier-only mode state
    /// 单修饰键模式：目标修饰键是否正在按下
    var modifierIsDown: Bool = false
    /// 单修饰键模式：按下期间是否有其他 keyDown（组合键）
    var hadKeyDownWhileModifierHeld: Bool = false

    var isRunning: Bool { eventTapPort != nil }

    /// Start listening for the global hotkey (Option+Space).
    /// Returns true if tap was created successfully.
    @discardableResult
    func start() -> Bool {
        let config = HotkeyConfig.current
        CrashLogger.log("[HotkeyManager] start() called, config: \(config.displayName) (keyCode=\(config.keyCode))")

        guard eventTapPort == nil else {
            CrashLogger.log("[HotkeyManager] Already running, skipped")
            return true
        }

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
            CrashLogger.log("[HotkeyManager] CGEvent.tapCreate failed (no accessibility permission?)")
            return false
        }

        holder.pointee = tap
        self.tapHolder = holder
        self.eventTapPort = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.runLoopSource = source

        CrashLogger.log("[HotkeyManager] Event tap created successfully")
        print("[VowKy][Hotkey] Event tap created and running")
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
        CrashLogger.log("[HotkeyCallback] tapDisabledByTimeout — auto-recovering")
        print("[VowKy][Hotkey] tapDisabledByTimeout — auto-recovering")
        if let port = context.tapHolder.pointee {
            CGEvent.tapEnable(tap: port, enable: true)
        }
        return Unmanaged.passRetained(event)
    }

    let config = HotkeyConfig.current
    let manager = Unmanaged<HotkeyManager>.fromOpaque(context.manager).takeUnretainedValue()

    if config.isModifierOnly {
        // ===== 单修饰键模式（短按触发） =====
        return handleModifierOnlyMode(type: type, event: event, config: config, manager: manager)
    } else {
        // ===== 原有组合键模式 =====
        return handleComboKeyMode(type: type, event: event, manager: manager)
    }
}

/// 单修饰键模式：通过 flagsChanged 检测短按
private func handleModifierOnlyMode(
    type: CGEventType,
    event: CGEvent,
    config: HotkeyConfig,
    manager: HotkeyManager
) -> Unmanaged<CGEvent>? {

    if type == .flagsChanged {
        let flags = event.flags
        guard let targetFlag = config.modifierFlag else {
            return Unmanaged.passRetained(event)
        }
        let hasTarget = flags.contains(targetFlag)

        // 检查是否有其他修饰键同时按下
        let allModifiers: CGEventFlags = [.maskAlternate, .maskCommand, .maskControl, .maskShift, .maskSecondaryFn]
        let otherFlags = allModifiers.subtracting(targetFlag)
        let hasOtherModifiers = !flags.intersection(otherFlags).isEmpty

        if hasTarget && !hasOtherModifiers && !manager.modifierIsDown {
            // 目标修饰键刚按下，无其他修饰键
            manager.modifierIsDown = true
            manager.hadKeyDownWhileModifierHeld = false
        } else if !hasTarget && manager.modifierIsDown {
            // 目标修饰键释放
            if !manager.hadKeyDownWhileModifierHeld {
                // 短按单独触发
                CrashLogger.log("[HotkeyCallback] Modifier-only release — dispatching")
                print("[VowKy][Hotkey] Modifier-only \(config.displayName) release — dispatching onHotkeyPressed")
                DispatchQueue.main.async {
                    manager.onHotkeyPressed?()
                }
            }
            manager.modifierIsDown = false
            manager.hadKeyDownWhileModifierHeld = false
        } else if hasOtherModifiers && manager.modifierIsDown {
            // 其他修饰键介入，取消
            manager.modifierIsDown = false
            manager.hadKeyDownWhileModifierHeld = false
        }
        return Unmanaged.passRetained(event) // 不吞掉 flagsChanged

    } else if type == .keyDown {
        // 修饰键按住期间有 keyDown → 标记为组合键
        if manager.modifierIsDown {
            manager.hadKeyDownWhileModifierHeld = true
        }

        // 检查 Escape 取消键
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let modifiers = HotkeyModifiers(
            option: flags.contains(.maskAlternate),
            command: flags.contains(.maskCommand),
            control: flags.contains(.maskControl),
            shift: flags.contains(.maskShift)
        )
        let cancelAction = HotkeyEvaluator.evaluateCancelEvent(
            keyCode: keyCode,
            modifiers: modifiers,
            isKeyUp: false
        )
        if cancelAction == .cancelRecording {
            let shouldIntercept = manager.shouldInterceptCancel?() ?? false
            if shouldIntercept {
                print("[VowKy][Hotkey] Escape keyDown — dispatching onCancelPressed")
                DispatchQueue.main.async {
                    manager.onCancelPressed?()
                }
                return nil
            }
        }
        return Unmanaged.passRetained(event)

    } else {
        return Unmanaged.passRetained(event)
    }
}

/// 原有组合键模式
private func handleComboKeyMode(
    type: CGEventType,
    event: CGEvent,
    manager: HotkeyManager
) -> Unmanaged<CGEvent>? {

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
        CrashLogger.log("[HotkeyCallback] Hotkey keyDown — dispatching")
        print("[VowKy][Hotkey] Hotkey keyDown — dispatching onHotkeyPressed")
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
            let shouldIntercept = manager.shouldInterceptCancel?() ?? false
            if shouldIntercept {
                print("[VowKy][Hotkey] Escape keyDown — dispatching onCancelPressed")
                DispatchQueue.main.async {
                    manager.onCancelPressed?()
                }
                return nil // Swallow
            }
        }
        return Unmanaged.passRetained(event)
    }
}

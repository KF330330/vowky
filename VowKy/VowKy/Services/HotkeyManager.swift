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

    /// Called on main thread when hotkey is released (hold mode only)
    var onHotkeyReleased: (() -> Void)?

    /// Called on main thread when Escape is pressed during recording
    var onCancelPressed: (() -> Void)?

    /// Returns true if cancel (Escape) should be intercepted (i.e. currently recording)
    var shouldInterceptCancel: (() -> Bool)?

    // MARK: - Modifier-only mode state
    /// 单修饰键模式：目标修饰键是否正在按下
    var modifierIsDown: Bool = false
    /// 单修饰键模式：按下期间是否有其他 keyDown（组合键）
    var hadKeyDownWhileModifierHeld: Bool = false

    // MARK: - Hold mode state
    /// 长按模式：是否正在长按录音中
    var isHoldRecording: Bool = false

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

        if config.isHoldMode {
            // ===== 长按模式：按下立即开始，松开立即停止 =====
            if hasTarget && !hasOtherModifiers && !manager.modifierIsDown {
                // 修饰键按下 → 开始录音
                manager.modifierIsDown = true
                CrashLogger.log("[HotkeyCallback] Hold mode modifier down — dispatching onHotkeyPressed")
                print("[VowKy][Hotkey] Hold mode modifier \(config.displayName) down — dispatching onHotkeyPressed")
                DispatchQueue.main.async {
                    manager.onHotkeyPressed?()
                }
            } else if !hasTarget && manager.modifierIsDown {
                // 修饰键松开 → 停止识别
                manager.modifierIsDown = false
                CrashLogger.log("[HotkeyCallback] Hold mode modifier up — dispatching onHotkeyReleased")
                print("[VowKy][Hotkey] Hold mode modifier \(config.displayName) up — dispatching onHotkeyReleased")
                DispatchQueue.main.async {
                    manager.onHotkeyReleased?()
                }
            } else if hasOtherModifiers && manager.modifierIsDown {
                // 其他修饰键介入，取消
                manager.modifierIsDown = false
                DispatchQueue.main.async {
                    manager.onCancelPressed?()
                }
            }
        } else {
            // ===== 切换模式：短按检测（现有逻辑） =====
            if hasTarget && !hasOtherModifiers && !manager.modifierIsDown {
                manager.modifierIsDown = true
                manager.hadKeyDownWhileModifierHeld = false
            } else if !hasTarget && manager.modifierIsDown {
                if !manager.hadKeyDownWhileModifierHeld {
                    CrashLogger.log("[HotkeyCallback] Modifier-only release — dispatching")
                    print("[VowKy][Hotkey] Modifier-only \(config.displayName) release — dispatching onHotkeyPressed")
                    DispatchQueue.main.async {
                        manager.onHotkeyPressed?()
                    }
                }
                manager.modifierIsDown = false
                manager.hadKeyDownWhileModifierHeld = false
            } else if hasOtherModifiers && manager.modifierIsDown {
                manager.modifierIsDown = false
                manager.hadKeyDownWhileModifierHeld = false
            }
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
    let config = HotkeyConfig.current

    // 长按模式：松手时只匹配 keyCode，不匹配修饰键
    // （解决 ⌘\ 先松 ⌘ 再松 \ 时修饰符不匹配的问题）
    if config.isHoldMode && manager.isHoldRecording && isKeyUp && keyCode == config.keyCode && !isRepeat {
        manager.isHoldRecording = false
        CrashLogger.log("[HotkeyCallback] Hold mode keyUp — dispatching onHotkeyReleased")
        print("[VowKy][Hotkey] Hold mode keyUp — dispatching onHotkeyReleased")
        DispatchQueue.main.async {
            manager.onHotkeyReleased?()
        }
        return nil
    }

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
        if config.isHoldMode {
            manager.isHoldRecording = true
        }
        CrashLogger.log("[HotkeyCallback] Hotkey keyDown — dispatching")
        print("[VowKy][Hotkey] Hotkey keyDown — dispatching onHotkeyPressed")
        DispatchQueue.main.async {
            manager.onHotkeyPressed?()
        }
        return nil // Swallow the event

    case .hotkeyUp:
        // 切换模式：吞掉 keyUp 不做任何事
        // 长按模式：正常情况已在上方处理，这里是修饰符完全匹配的 keyUp 兜底
        if config.isHoldMode && manager.isHoldRecording {
            manager.isHoldRecording = false
            CrashLogger.log("[HotkeyCallback] Hold mode hotkeyUp — dispatching onHotkeyReleased")
            print("[VowKy][Hotkey] Hold mode hotkeyUp — dispatching onHotkeyReleased")
            DispatchQueue.main.async {
                manager.onHotkeyReleased?()
            }
        }
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
                // 长按模式下取消时也要重置 hold 状态
                if config.isHoldMode {
                    manager.isHoldRecording = false
                }
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

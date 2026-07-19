import AppKit
import CoreGraphics
import Foundation

/// Маркер для симулированных событий — KeyboardMonitor их игнорирует
let kRuSwitcherEventMarker: Int64 = 0x52555300

/// Одно локальное нажатие в краткоживущем буфере конверсии.
struct TypedKey: Sendable {
    let keyCode: UInt16
    let shift: Bool
    let caps: Bool
}

/// Диагностические сообщения намеренно не сохраняются: приложение обрабатывает ввод.
@inline(__always)
func rslog(_ message: @autoclosure () -> String) {}

/// Конфигурация клавиши-триггера (читается из настроек, кэшируется в KeyboardMonitor).
struct TriggerConfig {
    enum Kind {
        case modifier(mask: CGEventFlags, left: UInt16, right: UInt16)
        /// Комбо из двух модификаторов (например ⌘+⇧). Детект по флагам: оба зажаты без
        /// посторонних → отпущены все без клавиш между. Сторона (left/right) не важна.
        case combo(CGEventFlags, CGEventFlags)
        case capsLock
    }
    let kind: Kind
    let rightOnly: Bool
    let doubleTap: Bool

    var isCapsLock: Bool { if case .capsLock = kind { return true } else { return false } }

    static func current() -> TriggerConfig {
        let s = SettingsManager.shared
        let kind: Kind
        switch s.triggerKey {
        case "command": kind = .modifier(mask: .maskCommand, left: KC.leftCommand, right: KC.rightCommand)
        case "control": kind = .modifier(mask: .maskControl, left: KC.leftControl, right: KC.rightControl)
        case "shift":   kind = .modifier(mask: .maskShift,   left: KC.leftShift,   right: KC.rightShift)
        // Комбо двух модификаторов (issue #12: привычный по Windows стиль Alt+Shift и т.п.).
        case "command+shift":  kind = .combo(.maskCommand, .maskShift)
        case "control+shift":  kind = .combo(.maskControl, .maskShift)
        case "command+option": kind = .combo(.maskCommand, .maskAlternate)
        case "control+option": kind = .combo(.maskControl, .maskAlternate)
        case "capsLock": kind = .capsLock
        default:        kind = .modifier(mask: .maskAlternate, left: KC.leftOption, right: KC.rightOption)
        }
        return TriggerConfig(kind: kind, rightOnly: s.triggerRightOnly, doubleTap: s.triggerDoubleTap)
    }
}

final class KeyboardMonitor: @unchecked Sendable {
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Длина текущего набираемого слова
    private(set) var currentWordLength = 0
    /// Сколько пробелов после слова (только пробелы, не enter/стрелки)
    private(set) var boundaryCount = 0
    /// Были ли реальные нажатия после последней конвертации?
    private(set) var keysTypedSinceConversion = true

    /// Нажатия набираемого слова — для движка перепечатки (без буфера обмена)
    private(set) var currentWordKeys: [TypedKey] = []
    /// Нажатия слова перед последней границей-пробелом
    private(set) var prevWordKeys: [TypedKey] = []
    private var currentWordTarget: AutoSwitchPolicy.FocusedInput?
    private var prevWordTarget: AutoSwitchPolicy.FocusedInput?
    var conversionTarget: AutoSwitchPolicy.FocusedInput? {
        if !currentWordKeys.isEmpty { return currentWordTarget }
        if !prevWordKeys.isEmpty, boundaryCount > 0 { return prevWordTarget }
        return nil
    }
    /// Для clipboard-fallback помним только факт явного жеста выделения, но не текст.
    private(set) var mayHaveSelectedText = false
    private var leftMouseDownLocation: CGPoint?
    /// issue #7: взводится при смене раскладки → на первой букве играем звук раскладки.
    var soundArmed = false

    private var onAltTap: (() -> Void)?
    private var onAltReconvert: (() -> Void)?
    private var onWordBoundary: (([TypedKey], AutoSwitchPolicy.FocusedInput, UInt) -> Void)?
    /// Кэш настройки: при выключенной функции на границе слова ничего не диспатчим.
    var adaptiveAutoSwitchEnabled = false
    private var inputGeneration: UInt = 0
    /// issue #10: любой ввод/клик пользователя — чтобы спрятать флаг у каретки во время печати.
    var onUserInput: (() -> Void)?
    /// issue #10: включена ли фича флага-у-каретки. Гейтит диспатч onUserInput на горячем пути,
    /// чтобы при выключенной фиче (по умолчанию) не будить main-очередь на каждом нажатии.
    var caretFlagEnabled = false

    // Конфиг триггера (кэш; обновляется в start/reconfigure)
    private var triggerConfig = TriggerConfig.current()

    // Детект соло-тапа модификатора
    private var triggerArmed = false
    private var triggerPressTime: Date?
    // Для двойного тапа
    private var lastTapTime: Date?
    private var idleClearWork: DispatchWorkItem?
    private let tapWindow: TimeInterval = 0.4

    func start(
        onAltTap: @escaping () -> Void,
        onAltReconvert: @escaping () -> Void,
        onWordBoundary: @escaping ([TypedKey], AutoSwitchPolicy.FocusedInput, UInt) -> Void
    ) -> Bool {
        self.onAltTap = onAltTap
        self.onAltReconvert = onAltReconvert
        self.onWordBoundary = onWordBoundary

        let precheck = CGPreflightListenEventAccess()
        rslog("Preflight check = \(precheck)")
        if !precheck {
            rslog("Requesting access...")
            CGRequestListenEventAccess()
        }

        triggerConfig = TriggerConfig.current()
        rslog("Attempting to create event tap... (trigger=\(SettingsManager.shared.triggerKey) capsLock=\(triggerConfig.isCapsLock))")
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)

        // Caps Lock требует активного tap (consume), чтобы подавить переключение
        // регистра. Для модификаторов оставляем listenOnly — не вмешиваемся в ввод.
        let options: CGEventTapOptions = triggerConfig.isCapsLock ? .defaultTap : .listenOnly

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .tailAppendEventTap,
            options: options,
            eventsOfInterest: mask,
            callback: keyboardCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            rslog("FAILED to create event tap - no permission")
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        rslog("Event tap created and enabled successfully")
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        clearSensitiveState()
    }

    /// Перезапускает tap с актуальным конфигом триггера. Нужен при смене настройки —
    /// особенно при переключении на/с Caps Lock, т.к. меняется режим tap (consume).
    @discardableResult
    func reconfigure() -> Bool {
        guard let t = onAltTap, let r = onAltReconvert, let b = onWordBoundary else { return false }
        rslog("Reconfiguring trigger…")
        stop()
        return start(onAltTap: t, onAltReconvert: r, onWordBoundary: b)
    }

    func markConverted() {
        idleClearWork?.cancel()
        idleClearWork = nil
        currentWordLength = 0
        boundaryCount = 0
        eraseKeys(&currentWordKeys)
        eraseKeys(&prevWordKeys)
        currentWordTarget = nil
        prevWordTarget = nil
        keysTypedSinceConversion = false
        mayHaveSelectedText = false
        leftMouseDownLocation = nil
    }

    private func fullReset() {
        currentWordLength = 0
        boundaryCount = 0
        eraseKeys(&currentWordKeys)
        eraseKeys(&prevWordKeys)
        currentWordTarget = nil
        prevWordTarget = nil
    }

    private func eraseKeys(_ keys: inout [TypedKey]) {
        for index in keys.indices {
            keys[index] = TypedKey(keyCode: 0, shift: false, caps: false)
        }
        keys.removeAll(keepingCapacity: false)
    }

    /// Стирает весь реконструируемый ввод и состояние триггера.
    func clearSensitiveState() {
        idleClearWork?.cancel()
        idleClearWork = nil
        triggerArmed = false
        triggerPressTime = nil
        lastTapTime = nil
        keysTypedSinceConversion = true
        mayHaveSelectedText = false
        leftMouseDownLocation = nil
        fullReset()
    }

    private func scheduleIdleClear() {
        idleClearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.clearSensitiveState()
        }
        idleClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }

    /// Secure Event Input может временно отключить tap. Возвращаем его только после
    /// выхода из защищённого поля или защищённого приложения.
    fileprivate func resumeEventTapWhenSafe() {
        clearSensitiveState()
        guard eventTap != nil, SettingsManager.shared.autoSwitchEnabled else { return }
        if AutoSwitchPolicy.protectedInputActive
            || AutoSwitchPolicy.isProtectedApp(NSWorkspace.shared.frontmostApplication?.bundleIdentifier) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.resumeEventTapWhenSafe()
            }
            return
        }
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
    }

    /// Клик сбрасывает буфер слова; drag, мультиклик и Shift-клик помечают явное
    /// выделение для редакторов, которые не публикуют его через Accessibility.
    fileprivate func handleMouseEvent(type: CGEventType, event: CGEvent) {
        switch type {
        case .leftMouseDown:
            clearSensitiveState()
            leftMouseDownLocation = event.location
            let clickCount = event.getIntegerValueField(.mouseEventClickState)
            mayHaveSelectedText = clickCount >= 2 || event.flags.contains(.maskShift)
            if caretFlagEnabled {
                DispatchQueue.main.async { [weak self] in self?.onUserInput?() }
            }

        case .leftMouseDragged:
            guard let start = leftMouseDownLocation else { return }
            let dx = event.location.x - start.x
            let dy = event.location.y - start.y
            if dx * dx + dy * dy >= 4 { mayHaveSelectedText = true }

        case .leftMouseUp:
            leftMouseDownLocation = nil

        case .rightMouseDown, .otherMouseDown:
            clearSensitiveState()
            if caretFlagEnabled {
                DispatchQueue.main.async { [weak self] in self?.onUserInput?() }
            }

        default:
            break
        }
    }

    // MARK: - Event Handling

    fileprivate func handleKeyDown(
        keyCode: UInt16,
        flags: CGEventFlags,
        focusedInput: AutoSwitchPolicy.FocusedInput
    ) {
        guard SettingsManager.shared.autoSwitchEnabled else {
            clearSensitiveState()
            return
        }
        inputGeneration &+= 1
        if let bufferedTarget = currentWordTarget ?? prevWordTarget,
           !AutoSwitchPolicy.sameIdentity(bufferedTarget, focusedInput) {
            fullReset()
        }
        triggerArmed = false
        lastTapTime = nil
        keysTypedSinceConversion = true
        scheduleIdleClear()
        if caretFlagEnabled { DispatchQueue.main.async { [weak self] in self?.onUserInput?() } }   // issue #10: спрятать флаг при печати

        // Явные клавиатурные жесты выделения нужны только для clipboard-fallback.
        // Cmd+C сохраняет выделение; другие команды считаем потенциально меняющими его.
        if flags.contains(.maskCommand), keyCode == KC.letterA {
            mayHaveSelectedText = true
            fullReset()
            return
        }
        if flags.contains(.maskCommand), keyCode == KC.letterC {
            fullReset()
            return
        }
        mayHaveSelectedText = false

        // Структурные клавиши обрабатываем ВСЕГДА, даже если в flags остался
        // «грязный» модификатор (stale .maskAlternate и т.п.) — иначе счётчик
        // слова не сбрасывается и конвертация захватывает лишние символы.

        // Пробел — единственная граница через которую можно вернуться
        if keyCode == KC.space {
            if currentWordLength > 0 {
                let completedKeys = currentWordKeys
                let completedTarget = currentWordTarget ?? focusedInput
                let generation = inputGeneration
                boundaryCount = 1
                prevWordKeys = currentWordKeys
                prevWordTarget = completedTarget
                if adaptiveAutoSwitchEnabled, let onWordBoundary {
                    DispatchQueue.main.async {
                        onWordBoundary(completedKeys, completedTarget, generation)
                    }
                }
            } else {
                boundaryCount += 1
            }
            currentWordLength = 0
            eraseKeys(&currentWordKeys)
            currentWordTarget = nil
            return
        }

        // Enter, Tab — полный сброс
        if keyCode == KC.enter || keyCode == KC.tab {
            fullReset()
            return
        }

        // Стрелки (Left…Up) — полный сброс
        if keyCode >= KC.left && keyCode <= KC.up {
            mayHaveSelectedText = flags.contains(.maskShift)
            fullReset()
            return
        }

        // Backspace
        if keyCode == KC.backspace {
            if currentWordLength > 0 {
                currentWordLength -= 1
                if !currentWordKeys.isEmpty { currentWordKeys.removeLast() }
                if currentWordKeys.isEmpty { currentWordTarget = nil }
            } else {
                fullReset()
            }
            return
        }

        // (Cmd+A, Cmd+C, Cmd+X и т.п.) могло изменить выделение — сбрасываем наш буфер.
        let modifiers = flags.intersection([.maskCommand, .maskControl, .maskAlternate])
        if !modifiers.isEmpty {
            fullReset()
            return
        }

        if KeyMapping.keycodeToEN[keyCode] != nil {
            if currentWordKeys.isEmpty { currentWordTarget = focusedInput }
            currentWordKeys.append(TypedKey(keyCode: keyCode, shift: flags.contains(.maskShift), caps: flags.contains(.maskAlphaShift)))
            currentWordLength += 1
            boundaryCount = 0
            eraseKeys(&prevWordKeys)
            prevWordTarget = nil
            playLayoutSoundIfArmed()
        } else {
            // Esc, F-клавиши, и т.д. — полный сброс
            fullReset()
        }
    }

    /// Слово ещё находится непосредственно перед единственным пробелом и с момента
    /// границы не было нового реального нажатия.
    func isCurrentWordBoundary(_ generation: UInt) -> Bool {
        inputGeneration == generation
            && currentWordKeys.isEmpty
            && !prevWordKeys.isEmpty
            && boundaryCount == 1
    }

    /// issue #7: на первой букве после смены раскладки даём короткий звук, зависящий от
    /// раскладки — слышно, в какой раскладке начал печатать. Опц., по умолчанию выключено.
    private func playLayoutSoundIfArmed() {
        guard soundArmed, SettingsManager.shared.keySound else { return }
        soundArmed = false
        let sources = LayoutSwitcher.installedLayouts()
        let id1 = SettingsManager.shared.layout1ID.isEmpty
            ? LayoutSwitcher.autoDetectID1(from: sources) : SettingsManager.shared.layout1ID
        let name = LayoutSwitcher.currentLayoutID() == id1 ? "Tink" : "Pop"
        NSSound(named: name)?.play()
    }

    /// Возвращает true, если событие надо «съесть» (только Caps Lock в consume-режиме).
    fileprivate func handleFlagsChanged(flags: CGEventFlags, keyCode: UInt16) -> Bool {
        switch triggerConfig.kind {
        case .capsLock:
            guard keyCode == KC.capsLock else { return false }
            // Caps Lock шлёт одно событие на нажатие. Используем как тап и съедаем,
            // чтобы не переключался регистр.
            registerTap()
            return true

        case let .modifier(mask, left, right):
            let accepted: Set<UInt16> = triggerConfig.rightOnly ? [right] : [left, right]
            let allMods: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
            let otherMods = allMods.subtracting(mask)

            if flags.contains(mask) {
                // нажатие: армим только если это нужная клавиша и нет других модификаторов
                if accepted.contains(keyCode) && flags.intersection(otherMods).isEmpty {
                    triggerArmed = true
                    triggerPressTime = Date()
                } else {
                    triggerArmed = false  // не та сторона / комбо
                }
            } else {
                // отпускание: соло-тап нужной клавиши, быстро и без клавиш между
                if triggerArmed, accepted.contains(keyCode), let t = triggerPressTime,
                   Date().timeIntervalSince(t) < tapWindow {
                    registerTap()
                }
                triggerArmed = false
                triggerPressTime = nil
            }
            return false

        case let .combo(maskA, maskB):
            let both: CGEventFlags = [maskA, maskB]
            let allMods: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
            let others = allMods.subtracting(both)
            if !flags.intersection(others).isEmpty {
                triggerArmed = false                 // зажат посторонний модификатор — не наш триггер
            } else if flags.contains(both) {
                triggerArmed = true                  // ровно оба нужных, без посторонних → армим
                triggerPressTime = Date()
            } else if flags.intersection(allMods).isEmpty {
                // всё отпущено: тап-комбо, если был армлен, быстро и без клавиш между
                if triggerArmed, let t = triggerPressTime, Date().timeIntervalSince(t) < tapWindow {
                    registerTap()
                }
                triggerArmed = false
                triggerPressTime = nil
            }
            // частичное состояние (зажат один из двух) — ждём, ничего не трогаем
            return false
        }
    }

    /// Учитывает одиночный/двойной тап и запускает конвертацию.
    private func registerTap() {
        if triggerConfig.doubleTap {
            if let last = lastTapTime, Date().timeIntervalSince(last) < tapWindow {
                lastTapTime = nil
                fireConversion()
            } else {
                lastTapTime = Date()  // ждём второй тап
            }
        } else {
            fireConversion()
        }
    }

    private func fireConversion() {
        if !keysTypedSinceConversion {
            rslog("trigger: RECONVERT")
            DispatchQueue.main.async { [weak self] in self?.onAltReconvert?() }
        } else {
            rslog("trigger: CONVERT")
            DispatchQueue.main.async { [weak self] in self?.onAltTap?() }
        }
    }
}

// MARK: - C Callback

private func keyboardCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo {
            let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(userInfo).takeUnretainedValue()
            monitor.resumeEventTapWhenSafe()
        }
        return Unmanaged.passUnretained(event)
    }

    // Игнорируем собственные симулированные события по маркеру
    if event.getIntegerValueField(.eventSourceUserData) == kRuSwitcherEventMarker {
        return Unmanaged.passUnretained(event)
    }

    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    guard SettingsManager.shared.autoSwitchEnabled else {
        monitor.clearSensitiveState()
        return Unmanaged.passUnretained(event)
    }

    // flagsChanged не содержит вводимого текста. Обрабатываем триггер до AX-проверки:
    // кратковременный timeout Accessibility на press/release не должен сбрасывать
    // triggerArmed и полностью глушить конвертацию.
    if type == .flagsChanged {
        guard !AutoSwitchPolicy.secureInputActive,
              !AutoSwitchPolicy.isProtectedApp(
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier
              ) else {
            monitor.clearSensitiveState()
            return Unmanaged.passUnretained(event)
        }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if monitor.handleFlagsChanged(flags: event.flags, keyCode: keyCode) {
            return nil  // съедаем Caps Lock, чтобы не переключался регистр
        }
        return Unmanaged.passUnretained(event)
    }

    if type == .leftMouseDown || type == .leftMouseDragged || type == .leftMouseUp
        || type == .rightMouseDown || type == .otherMouseDown {
        monitor.handleMouseEvent(type: type, event: event)
        return Unmanaged.passUnretained(event)
    }

    // Не извлекаем keycode набранного символа, пока не получили проверенную identity
    // незащищённого поля. Финальная проверка повторяется перед инжектом в TextConverter.
    guard type == .keyDown,
          let focusedInput = AutoSwitchPolicy.currentSafeFocusedInput(),
          !AutoSwitchPolicy.isProtectedApp(focusedInput.bundleIdentifier) else {
        monitor.clearSensitiveState()
        return Unmanaged.passUnretained(event)
    }
    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    monitor.handleKeyDown(keyCode: keyCode, flags: event.flags, focusedInput: focusedInput)

    return Unmanaged.passUnretained(event)
}

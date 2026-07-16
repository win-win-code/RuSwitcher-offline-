import CoreGraphics
import Foundation

/// Локальная конвертация текста между раскладками без буфера обмена.
@MainActor
final class TextConverter {
    private var isConverting = false
    private var lastOriginal = ""
    private var lastConverted = ""
    private var lastTarget: AutoSwitchPolicy.FocusedInput?
    private var sensitiveStateClearWork: DispatchWorkItem?
    private var injectionTask: Task<Void, Never>?
    private var injectionGeneration: UInt = 0

    /// Создаёт CGEventSource с маркером, чтобы KeyboardMonitor игнорировал наши события.
    nonisolated private func makeSource() -> CGEventSource? {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.userData = kRuSwitcherEventMarker
        return source
    }

    /// Стирает набранное слово и впечатывает конвертированное напрямую через Unicode.
    /// Глобальный буфер обмена не используется ни при каких условиях.
    func convert(wordKeys: [TypedKey], prevWordKeys: [TypedKey], boundaryCount: Int,
                 expectedTarget: AutoSwitchPolicy.FocusedInput,
                 completion: @escaping (Bool) -> Void) -> Bool {
        guard !isConverting else { return false }
        guard let target = captureSafeTarget(matching: expectedTarget) else {
            clearState()
            return false
        }

        let keys: [TypedKey]
        let trailingSpaces: Int
        if !wordKeys.isEmpty {
            keys = wordKeys
            trailingSpaces = 0
        } else if !prevWordKeys.isEmpty && boundaryCount > 0 {
            keys = prevWordKeys
            trailingSpaces = boundaryCount
        } else {
            return false
        }

        guard let pair = DynamicKeyMapping.convertKeys(keys) else { return false }

        let spaces = String(repeating: " ", count: trailingSpaces)
        let backspaceCount = keys.count + trailingSpaces
        let insert = pair.converted + spaces
        let erasedText = pair.original + spaces
        lastOriginal = erasedText
        lastConverted = insert
        lastTarget = target
        scheduleSensitiveStateClear()
        beginInjection(
            backspaceCount: backspaceCount,
            insert: insert,
            erasedText: erasedText,
            target: target,
            completion: completion
        )
        return true
    }

    /// Конвертирует выделенный пользователем текст. Стандартный AX setter заменяет
    /// выделение одной операцией, поэтому размер выделения не ограничен буфером
    /// нажатий и системный буфер обмена не задействуется.
    func convertSelectedText(
        expectedTarget: AutoSwitchPolicy.FocusedInput,
        completion: @escaping (Bool) -> Void
    ) -> Bool {
        guard !isConverting,
              let target = captureSafeTarget(matching: expectedTarget),
              let selection = AutoSwitchPolicy.selectedText(in: target) else { return false }

        let converted = DynamicKeyMapping.convert(selection.text)
        isConverting = true
        defer { isConverting = false }

        guard targetIsSafe(target) else { return false }

        // Не все приложения дают записывать AXSelectedText (особенно браузеры и
        // Electron). Если выделение не менялось, заменяем его обычным Unicode-вводом:
        // активное выделение поглощает первое введённое событие без Backspace.
        if !AutoSwitchPolicy.replaceSelectedText(selection, in: target, with: converted) {
            guard targetIsSafe(target),
                  AutoSwitchPolicy.selectedTextMatches(selection, in: target),
                  insertText(converted) else { return false }
        }

        lastOriginal = selection.text
        lastConverted = converted
        lastTarget = target
        scheduleSensitiveStateClear()
        completion(true)
        return true
    }

    /// Повторная конвертация сразу после предыдущей операции.
    func reconvert(completion: @escaping (Bool) -> Void) -> Bool {
        guard !isConverting, !lastConverted.isEmpty, let lastTarget else { return false }
        guard let target = captureSafeTarget(matching: lastTarget) else {
            clearState()
            return false
        }

        let backspaceCount = lastConverted.count
        let insert = lastOriginal
        let erasedText = lastConverted
        swap(&lastOriginal, &lastConverted)
        scheduleSensitiveStateClear()
        beginInjection(
            backspaceCount: backspaceCount,
            insert: insert,
            erasedText: erasedText,
            target: target,
            completion: completion
        )
        return true
    }

    /// Немедленно отменяет инжект и стирает сохранённые в памяти строки.
    func clearState() {
        injectionGeneration &+= 1
        injectionTask?.cancel()
        injectionTask = nil
        isConverting = false
        eraseRetainedText()
    }

    private func captureSafeTarget(
        matching expectedTarget: AutoSwitchPolicy.FocusedInput
    ) -> AutoSwitchPolicy.FocusedInput? {
        guard SettingsManager.shared.autoSwitchEnabled,
              let focused = AutoSwitchPolicy.currentSafeFocusedInput(),
              !AutoSwitchPolicy.isProtectedApp(focused.bundleIdentifier),
              AutoSwitchPolicy.sameIdentity(focused, expectedTarget) else { return nil }
        return focused
    }

    private func targetIsSafe(_ target: AutoSwitchPolicy.FocusedInput) -> Bool {
        guard SettingsManager.shared.autoSwitchEnabled,
              let focused = AutoSwitchPolicy.currentSafeFocusedInput(),
              AutoSwitchPolicy.sameIdentity(focused, target),
              !AutoSwitchPolicy.isProtectedApp(focused.bundleIdentifier) else { return false }
        return true
    }

    private func targetIsStillSafe(
        _ target: AutoSwitchPolicy.FocusedInput,
        generation: UInt
    ) -> Bool {
        generation == injectionGeneration && !Task.isCancelled && targetIsSafe(target)
    }

    /// Инжект выполняется как отменяемая MainActor-задача. Между событиями actor
    /// освобождается, а прямо перед каждым событием заново проверяются master toggle,
    /// Secure Input, AX-защита и identity поля/приложения.
    private func beginInjection(
        backspaceCount: Int,
        insert: String,
        erasedText: String,
        target: AutoSwitchPolicy.FocusedInput,
        completion: @escaping (Bool) -> Void
    ) {
        injectionGeneration &+= 1
        let generation = injectionGeneration
        injectionTask?.cancel()
        isConverting = true

        injectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var backspacesSent = 0

            for _ in 0..<backspaceCount {
                guard self.targetIsStillSafe(target, generation: generation) else {
                    self.finishInjection(
                        generation: generation,
                        succeeded: false,
                        backspacesSent: backspacesSent,
                        erasedText: erasedText,
                        target: target,
                        completion: completion
                    )
                    return
                }
                guard self.simKey(keyCode: KC.backspace, flags: []) else {
                    self.finishInjection(
                        generation: generation,
                        succeeded: false,
                        backspacesSent: backspacesSent,
                        erasedText: erasedText,
                        target: target,
                        completion: completion
                    )
                    return
                }
                backspacesSent += 1
                guard await self.pause(nanoseconds: 3_000_000) else {
                    self.finishInjection(
                        generation: generation,
                        succeeded: false,
                        backspacesSent: backspacesSent,
                        erasedText: erasedText,
                        target: target,
                        completion: completion
                    )
                    return
                }
            }

            guard await self.pause(nanoseconds: 20_000_000),
                  self.targetIsStillSafe(target, generation: generation) else {
                self.finishInjection(
                    generation: generation,
                    succeeded: false,
                    backspacesSent: backspacesSent,
                    erasedText: erasedText,
                    target: target,
                    completion: completion
                )
                return
            }

            guard self.insertText(insert) else {
                self.finishInjection(
                    generation: generation,
                    succeeded: false,
                    backspacesSent: backspacesSent,
                    erasedText: erasedText,
                    target: target,
                    completion: completion
                )
                return
            }
            self.finishInjection(
                generation: generation,
                succeeded: true,
                backspacesSent: backspacesSent,
                erasedText: erasedText,
                target: target,
                completion: completion
            )
        }
    }

    private func pause(nanoseconds: UInt64) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private func finishInjection(
        generation: UInt,
        succeeded: Bool,
        backspacesSent: Int,
        erasedText: String,
        target: AutoSwitchPolicy.FocusedInput,
        completion: (Bool) -> Void
    ) {
        guard generation == injectionGeneration else { return }
        injectionTask = nil
        isConverting = false
        if !succeeded {
            if backspacesSent > 0, targetIsSafe(target) {
                _ = insertText(String(erasedText.suffix(backspacesSent)))
            }
            eraseRetainedText()
        }
        completion(succeeded)
    }

    private func eraseRetainedText() {
        sensitiveStateClearWork?.cancel()
        sensitiveStateClearWork = nil
        lastOriginal = ""
        lastConverted = ""
        lastTarget = nil
    }

    private func scheduleSensitiveStateClear() {
        sensitiveStateClearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.lastOriginal = ""
            self?.lastConverted = ""
            self?.lastTarget = nil
            self?.sensitiveStateClearWork = nil
        }
        sensitiveStateClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    /// Впечатывает строку напрямую, без буфера обмена.
    nonisolated private func insertText(_ text: String) -> Bool {
        guard !text.isEmpty, let source = makeSource() else { return false }
        let utf16 = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
        utf16.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: buffer.baseAddress
            )
            up.keyboardSetUnicodeString(
                stringLength: buffer.count,
                unicodeString: buffer.baseAddress
            )
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Симулирует нажатие клавиши с локальным маркером приложения.
    nonisolated private func simKey(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        guard let source = makeSource(),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else { return false }

        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}

import AppKit
import CoreGraphics
import Foundation

/// Локальная конвертация текста между раскладками. Для выделений сначала используется
/// Accessibility; clipboard задействуется только как fallback для несовместимых полей.
@MainActor
final class TextConverter {
    struct ManualWordConversion {
        let sourceLayoutID: String
        let targetLayoutID: String
        let originalWord: String
        let convertedWord: String
    }

    private struct PasteboardSnapshot {
        struct Item {
            let values: [(type: NSPasteboard.PasteboardType, data: Data)]
        }

        let items: [Item]

        init?(pasteboard: NSPasteboard) {
            var capturedItems: [Item] = []
            for item in pasteboard.pasteboardItems ?? [] {
                var values: [(type: NSPasteboard.PasteboardType, data: Data)] = []
                for type in item.types {
                    guard let data = item.data(forType: type) else { return nil }
                    values.append((type, data))
                }
                if !values.isEmpty { capturedItems.append(Item(values: values)) }
            }
            items = capturedItems
        }

        func restore(to pasteboard: NSPasteboard) {
            let restoredItems: [NSPasteboardItem] = items.map { item in
                let restored = NSPasteboardItem()
                for value in item.values {
                    restored.setData(value.data, forType: value.type)
                }
                return restored
            }
            pasteboard.clearContents()
            if !restoredItems.isEmpty {
                pasteboard.writeObjects(restoredItems)
            }
        }
    }

    private static let selectionProbeType = NSPasteboard.PasteboardType(
        "com.ruswitcher.selection-probe"
    )

    private var isConverting = false
    private var lastOriginal = ""
    private var lastConverted = ""
    private var lastTarget: AutoSwitchPolicy.FocusedInput?
    private var lastAutomaticRule: LearnedWordStore.RuleID?
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
                 completion: @escaping (Bool, ManualWordConversion?) -> Void) -> Bool {
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
        let manualConversion = ManualWordConversion(
            sourceLayoutID: pair.sourceLayoutID,
            targetLayoutID: pair.targetLayoutID,
            originalWord: pair.original,
            convertedWord: pair.converted
        )
        lastOriginal = erasedText
        lastConverted = insert
        lastTarget = target
        lastAutomaticRule = nil
        scheduleSensitiveStateClear()
        beginInjection(
            backspaceCount: backspaceCount,
            insert: insert,
            erasedText: erasedText,
            target: target,
            completion: { succeeded in
                completion(succeeded, succeeded ? manualConversion : nil)
            }
        )
        return true
    }

    /// Исправляет слово только если его подпись уже была явно подтверждена пользователем.
    /// В отличие от ручного пути, не использует ни выделение, ни pasteboard.
    func convertLearnedWord(
        wordKeys: [TypedKey],
        trailingSpaces: Int,
        expectedTarget: AutoSwitchPolicy.FocusedInput,
        completion: @escaping (Bool, String?) -> Void
    ) -> Bool {
        guard SettingsManager.shared.adaptiveAutoSwitchEnabled,
              !isConverting,
              trailingSpaces > 0,
              let target = captureSafeTarget(matching: expectedTarget),
              let pair = DynamicKeyMapping.convertKeys(wordKeys),
              let rule = LearnedWordStore.shared.matchingRule(
                sourceLayoutID: pair.sourceLayoutID,
                targetLayoutID: pair.targetLayoutID,
                targetWord: pair.converted
              ) else { return false }

        let spaces = String(repeating: " ", count: trailingSpaces)
        let insert = pair.converted + spaces
        let erasedText = pair.original + spaces
        lastOriginal = erasedText
        lastConverted = insert
        lastTarget = target
        lastAutomaticRule = rule
        scheduleSensitiveStateClear()
        beginInjection(
            backspaceCount: wordKeys.count + trailingSpaces,
            insert: insert,
            erasedText: erasedText,
            target: target,
            completion: { [weak self] succeeded in
                if !succeeded { self?.lastAutomaticRule = nil }
                completion(succeeded, succeeded ? pair.targetLayoutID : nil)
            }
        )
        return true
    }

    /// Конвертирует выделенный пользователем текст. Если приложение не публикует
    /// выделение через Accessibility, кратковременно использует Cmd+C/Cmd+V и
    /// восстанавливает прежний clipboard сразу после замены выделения.
    func convertSelectedText(
        expectedTarget: AutoSwitchPolicy.FocusedInput,
        allowClipboardFallback: Bool,
        completion: @escaping (Bool) -> Void
    ) -> Bool {
        guard !isConverting,
              let target = captureSafeTarget(matching: expectedTarget) else { return false }
        lastAutomaticRule = nil

        guard let selection = AutoSwitchPolicy.selectedText(in: target) else {
            guard allowClipboardFallback else { return false }
            beginClipboardSelectionConversion(target: target, completion: completion)
            return true
        }

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
        lastAutomaticRule = nil
        scheduleSensitiveStateClear()
        completion(true)
        return true
    }

    private func beginClipboardSelectionConversion(
        target: AutoSwitchPolicy.FocusedInput,
        completion: @escaping (Bool) -> Void
    ) {
        injectionGeneration &+= 1
        let generation = injectionGeneration
        injectionTask?.cancel()
        isConverting = true

        injectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let pasteboard = NSPasteboard.general
            guard let snapshot = PasteboardSnapshot(pasteboard: pasteboard) else {
                self.finishClipboardSelectionConversion(
                    generation: generation,
                    succeeded: false,
                    completion: completion
                )
                return
            }
            var ownedChangeCount: Int?

            defer {
                if let ownedChangeCount,
                   pasteboard.changeCount == ownedChangeCount {
                    snapshot.restore(to: pasteboard)
                }
            }

            guard self.targetIsStillSafe(target, generation: generation) else {
                self.finishClipboardSelectionConversion(
                    generation: generation,
                    succeeded: false,
                    completion: completion
                )
                return
            }

            pasteboard.clearContents()
            guard pasteboard.setData(
                Data([0x52, 0x55, 0x53]),
                forType: Self.selectionProbeType
            ) else {
                snapshot.restore(to: pasteboard)
                self.finishClipboardSelectionConversion(
                    generation: generation,
                    succeeded: false,
                    completion: completion
                )
                return
            }
            ownedChangeCount = pasteboard.changeCount

            guard self.targetIsStillSafe(target, generation: generation),
                  self.simKey(keyCode: KC.letterC, flags: .maskCommand) else {
                self.finishClipboardSelectionConversion(
                    generation: generation,
                    succeeded: false,
                    completion: completion
                )
                return
            }

            var selectedText: String?
            for _ in 0..<25 {
                guard await self.pause(nanoseconds: 10_000_000) else { break }
                let currentChangeCount = pasteboard.changeCount
                if currentChangeCount != ownedChangeCount {
                    ownedChangeCount = currentChangeCount
                    selectedText = pasteboard.string(forType: .string)
                    break
                }
            }

            guard let original = selectedText, !original.isEmpty,
                  let expectedChangeCount = ownedChangeCount,
                  pasteboard.changeCount == expectedChangeCount else {
                self.finishClipboardSelectionConversion(
                    generation: generation,
                    succeeded: false,
                    completion: completion
                )
                return
            }

            let converted = DynamicKeyMapping.convert(original)
            guard self.targetIsStillSafe(target, generation: generation) else {
                self.finishClipboardSelectionConversion(
                    generation: generation,
                    succeeded: false,
                    completion: completion
                )
                return
            }

            pasteboard.clearContents()
            guard pasteboard.setString(converted, forType: .string) else {
                self.finishClipboardSelectionConversion(
                    generation: generation,
                    succeeded: false,
                    completion: completion
                )
                return
            }
            ownedChangeCount = pasteboard.changeCount

            guard self.targetIsStillSafe(target, generation: generation),
                  self.simKey(keyCode: KC.letterV, flags: .maskCommand) else {
                self.finishClipboardSelectionConversion(
                    generation: generation,
                    succeeded: false,
                    completion: completion
                )
                return
            }

            // CGEventPost ставит событие в очередь. Даже при отмене задачи держим
            // сконвертированный clipboard до доставки Cmd+V, затем восстанавливаем.
            await self.waitForPasteDelivery()
            if let expectedChangeCount = ownedChangeCount,
               pasteboard.changeCount == expectedChangeCount {
                snapshot.restore(to: pasteboard)
            }
            ownedChangeCount = nil

            guard self.targetIsStillSafe(target, generation: generation) else {
                self.finishClipboardSelectionConversion(
                    generation: generation,
                    succeeded: false,
                    completion: completion
                )
                return
            }

            self.lastOriginal = original
            self.lastConverted = converted
            self.lastTarget = target
            self.scheduleSensitiveStateClear()
            self.finishClipboardSelectionConversion(
                generation: generation,
                succeeded: true,
                completion: completion
            )
        }
    }

    private func finishClipboardSelectionConversion(
        generation: UInt,
        succeeded: Bool,
        completion: (Bool) -> Void
    ) {
        guard generation == injectionGeneration else { return }
        injectionTask = nil
        isConverting = false
        if !succeeded { eraseRetainedText() }
        completion(succeeded)
    }

    private func waitForPasteDelivery() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                continuation.resume()
            }
        }
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

    /// Вызывается только после успешной обратной конвертации: правило могло быть
    /// применено автоматически и теперь должно быть заблокировано до нового обучения.
    func consumeLastAutomaticRuleForReconversion() -> LearnedWordStore.RuleID? {
        defer { lastAutomaticRule = nil }
        return lastAutomaticRule
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
        lastAutomaticRule = nil
    }

    private func scheduleSensitiveStateClear() {
        sensitiveStateClearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.lastOriginal = ""
            self?.lastConverted = ""
            self?.lastTarget = nil
            self?.lastAutomaticRule = nil
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

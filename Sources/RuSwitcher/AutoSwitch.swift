import AppKit
import ApplicationServices
import Carbon

/// Политика безопасности мониторинга ввода и ручной конвертации.
enum AutoSwitchPolicy {
    struct FocusedInput {
        let processIdentifier: pid_t
        let bundleIdentifier: String?
        /// nil, если приложение не публикует AX-фокус (часто веб-поля Chromium/Electron).
        let element: AXUIElement?
    }

    /// Текущее выделение в проверенном текстовом поле. Текст живёт только в памяти
    /// вызывающего кода и нужен для явной ручной конвертации.
    struct SelectedText {
        let text: String
        private let range: CFRange

        fileprivate init(text: String, range: CFRange) {
            self.text = text
            self.range = range
        }

        fileprivate func matches(_ other: SelectedText) -> Bool {
            text == other.text
                && range.location == other.range.location
                && range.length == other.range.length
        }
    }

    /// Активен ли защищённый ввод (поле пароля, Secure Keyboard Entry в терминале) —
    /// тогда мониторинг и конвертацию НЕ делаем (приватность; пароль не трогаем).
    static var secureInputActive: Bool { IsSecureEventInputEnabled() }

    /// Текущий фокус ввода. Если приложение не публикует AX-элемент, сохраняем
    /// identity активного процесса: это позволяет работать в веб-полях, не ослабляя
    /// проверку Secure Event Input и блокировку известных защищённых приложений.
    static func currentFocusedInput() -> FocusedInput? {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication else { return nil }

        let fallback = FocusedInput(
            processIdentifier: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier,
            element: nil
        )

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Chromium и Electron (включая Gemini в браузере и приложение ChatGPT)
        // создают дерево Accessibility лениво. Без этого focused element часто
        // недоступен, хотя пользователь печатает в обычном, незащищённом поле.
        // Атрибут идемпотентен и игнорируется приложениями, которые его не знают.
        AXUIElementSetMessagingTimeout(axApp, 0.15)
        AXUIElementSetAttributeValue(
            axApp,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
        var focusedRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            axApp,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRaw
        ) == .success, let focusedRaw else { return fallback }

        let focused = focusedRaw as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, 0.15)
        return FocusedInput(
            processIdentifier: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier,
            element: focused
        )
    }

    /// Проверяет стандартный secure-subrole и protected-content attribute.
    /// Неожиданные AX-ошибки считаем защищённым вводом (fail-closed).
    static func isProtectedElement(_ element: AXUIElement) -> Bool {
        var subroleRaw: AnyObject?
        let subroleResult = AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &subroleRaw
        )
        if subroleResult == .success {
            guard let subrole = subroleRaw as? String else { return true }
            if subrole == (kAXSecureTextFieldSubrole as String) { return true }
        }
        if subroleResult != .success,
           subroleResult != .noValue,
           subroleResult != .attributeUnsupported {
            return true
        }

        var protectedRaw: AnyObject?
        let protectedResult = AXUIElementCopyAttributeValue(
            element,
            NSAccessibility.Attribute.containsProtectedContent.rawValue as CFString,
            &protectedRaw
        )
        if protectedResult == .success {
            guard let isProtected = protectedRaw as? Bool else { return true }
            return isProtected
        }
        return protectedResult != .noValue && protectedResult != .attributeUnsupported
    }

    static func sameIdentity(_ lhs: FocusedInput, _ rhs: FocusedInput) -> Bool {
        guard lhs.processIdentifier == rhs.processIdentifier else { return false }
        guard let lhsElement = lhs.element, let rhsElement = rhs.element else { return true }
        return CFEqual(lhsElement, rhsElement)
    }

    /// Возвращает фокус только если его удалось проверить и он не защищён.
    static func currentSafeFocusedInput() -> FocusedInput? {
        guard !secureInputActive,
              let focused = currentFocusedInput() else { return nil }
        if let element = focused.element, isProtectedElement(element) { return nil }
        return focused
    }

    /// Читает выделенный текст через стандартный Accessibility API. Неиспользуемые
    /// или пустые выделения не считаются текстом для конвертации.
    static func selectedText(in focusedInput: FocusedInput) -> SelectedText? {
        guard let element = focusedInput.element else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.15)

        var rangeRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRaw
        ) == .success,
              let rangeValue = rangeRaw,
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }

        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range),
              range.location != kCFNotFound,
              range.length > 0 else { return nil }

        var textRaw: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &textRaw
        ) == .success,
              let text = textRaw as? String,
              !text.isEmpty else { return nil }

        return SelectedText(text: text, range: range)
    }

    /// Проверяет, что пользователь не изменил выделение между чтением и заменой.
    static func selectedTextMatches(_ selection: SelectedText, in focusedInput: FocusedInput) -> Bool {
        guard let current = selectedText(in: focusedInput) else { return false }
        return selection.matches(current)
    }

    /// Заменяет выделение атомарно через Accessibility, без буфера обмена и серии
    /// Backspace. Это позволяет поддерживать длинные многострочные выделения.
    static func replaceSelectedText(
        _ selection: SelectedText,
        in focusedInput: FocusedInput,
        with replacement: String
    ) -> Bool {
        guard let element = focusedInput.element,
              selectedTextMatches(selection, in: focusedInput) else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            replacement as CFString
        ) == .success
    }

    /// Дополнительная проверка Accessibility для приложений, которые помечают поле
    /// пароля, но не включают системный Secure Event Input.
    static var protectedInputActive: Bool {
        currentSafeFocusedInput() == nil
    }

    /// Менеджеры паролей и клиенты удалённых сессий блокируются безусловно.
    static let protectedApps: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "org.keepassxc.keepassxc",
        "com.apple.ScreenSharing", "com.apple.RemoteDesktop",
    ]

    static func isProtectedApp(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return protectedApps.contains(bundleID)
    }
}

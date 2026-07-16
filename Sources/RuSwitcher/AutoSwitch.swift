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

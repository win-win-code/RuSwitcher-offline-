import Foundation
import ServiceManagement

/// Централизованное хранение настроек через UserDefaults
/// Настройки приложения. Свойства thread-safe через UserDefaults.
final class SettingsManager: @unchecked Sendable {
    static let shared = SettingsManager()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let autoSwitch = "com.ruswitcher.autoSwitch"
        static let layout1ID = "com.ruswitcher.layout1ID"
        static let layout2ID = "com.ruswitcher.layout2ID"
        static let launchAtLogin = "com.ruswitcher.launchAtLogin"
        static let interfaceLanguage = "com.ruswitcher.interfaceLanguage"
        static let permissionsWereGranted = "com.ruswitcher.permissionsWereGranted"
        static let launchAtLoginAsked = "com.ruswitcher.launchAtLoginAsked"
        static let perAppLayout = "com.ruswitcher.perAppLayout"
        static let triggerKey = "com.ruswitcher.triggerKey"
        static let triggerRightOnly = "com.ruswitcher.triggerRightOnly"
        static let triggerDoubleTap = "com.ruswitcher.triggerDoubleTap"
        static let keySound = "com.ruswitcher.keySound"
        static let caretFlag = "com.ruswitcher.caretFlag"
        static let monochromeIcon = "com.ruswitcher.monochromeIcon"
        static let adaptiveAutoSwitch = "com.ruswitcher.adaptiveAutoSwitch"
    }

    private init() {
        // Старые версии могли сохранять диагностический лог ввода. Офлайн-сборка
        // не ведёт логи и удаляет этот legacy-артефакт при первом запуске.
        defaults.removeObject(forKey: "com.ruswitcher.debugLog")
        // Автоконверсия старых версий передавала слова spell-service. Удаляем саму
        // функцию и сохранённые ею настройки/словари при миграции.
        for key in [
            "com.ruswitcher.autoConvert",
            "com.ruswitcher.autoConvertOffered",
            "com.ruswitcher.deniedAppsAdded",
            "com.ruswitcher.deniedAppsRemoved",
            "com.ruswitcher.deniedWords",
            "com.ruswitcher.alwaysConvertWords",
        ] {
            defaults.removeObject(forKey: key)
        }
        let legacyLogDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/RuSwitcher", isDirectory: true)
        try? FileManager.default.removeItem(at: legacyLogDirectory)
    }

    // MARK: - Properties

    var autoSwitchEnabled: Bool {
        get { defaults.object(forKey: Keys.autoSwitch) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.autoSwitch) }
    }

    /// ID первой раскладки (пустая строка = авто-определение)
    var layout1ID: String {
        get { defaults.string(forKey: Keys.layout1ID) ?? "" }
        set { defaults.set(newValue, forKey: Keys.layout1ID) }
    }

    /// ID второй раскладки (пустая строка = авто-определение)
    var layout2ID: String {
        get { defaults.string(forKey: Keys.layout2ID) ?? "" }
        set { defaults.set(newValue, forKey: Keys.layout2ID) }
    }

    var launchAtLogin: Bool {
        get { defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false }
        set {
            defaults.set(newValue, forKey: Keys.launchAtLogin)
            let enabled = newValue
            DispatchQueue.main.async {
                self.doUpdateLoginItem(enabled: enabled)
            }
        }
    }

    /// Язык интерфейса (пустая строка = авто-определение по системе)
    var interfaceLanguage: String {
        get { defaults.string(forKey: Keys.interfaceLanguage) ?? "" }
        set {
            defaults.set(newValue, forKey: Keys.interfaceLanguage)
            L10n.reloadLanguage()
        }
    }

    /// Флаг: разрешения были ранее выданы (для определения сброса после обновления)
    var permissionsWereGranted: Bool {
        get { defaults.bool(forKey: Keys.permissionsWereGranted) }
        set { defaults.set(newValue, forKey: Keys.permissionsWereGranted) }
    }

    var launchAtLoginAsked: Bool {
        get { defaults.bool(forKey: Keys.launchAtLoginAsked) }
        set { defaults.set(newValue, forKey: Keys.launchAtLoginAsked) }
    }

    var perAppLayout: Bool {
        get { defaults.bool(forKey: Keys.perAppLayout) }
        set { defaults.set(newValue, forKey: Keys.perAppLayout) }
    }

    // MARK: - Триггер конвертации

    /// Клавиша-триггер: "option" | "command" | "control" | "shift" | "capsLock".
    /// Дефолт — option (как было до 2.3, поведение не меняется).
    var triggerKey: String {
        get { defaults.string(forKey: Keys.triggerKey) ?? "option" }
        set { defaults.set(newValue, forKey: Keys.triggerKey) }
    }

    /// Реагировать только на правую клавишу модификатора (для option/command/control/shift).
    var triggerRightOnly: Bool {
        get { defaults.bool(forKey: Keys.triggerRightOnly) }
        set { defaults.set(newValue, forKey: Keys.triggerRightOnly) }
    }

    /// Двойной тап вместо одиночного.
    var triggerDoubleTap: Bool {
        get { defaults.bool(forKey: Keys.triggerDoubleTap) }
        set { defaults.set(newValue, forKey: Keys.triggerDoubleTap) }
    }

    /// Caps Lock как триггер требует consume-tap (чтобы подавить переключение регистра).
    var triggerIsCapsLock: Bool { triggerKey == "capsLock" }

    /// issue #10: показывать флаг раскладки у текстовой каретки (бета). По умолчанию ВЫКЛ.
    var caretFlag: Bool {
        get { defaults.bool(forKey: Keys.caretFlag) }
        set { defaults.set(newValue, forKey: Keys.caretFlag) }
    }

    /// issue #7: звук раскладки на первой букве после смены раскладки. По умолчанию OFF.
    var keySound: Bool {
        get { defaults.bool(forKey: Keys.keySound) }
        set { defaults.set(newValue, forKey: Keys.keySound) }
    }

    /// Иконка меню-бара в системном стиле: монохромная плашка «РУ/EN» (template)
    /// вместо цветного флага-эмодзи. По умолчанию OFF — флаг привычнее.
    var monochromeIcon: Bool {
        get { defaults.bool(forKey: Keys.monochromeIcon) }
        set { defaults.set(newValue, forKey: Keys.monochromeIcon) }
    }

    /// Локальное обучение на явных конвертациях. По умолчанию выключено.
    var adaptiveAutoSwitchEnabled: Bool {
        get { defaults.bool(forKey: Keys.adaptiveAutoSwitch) }
        set { defaults.set(newValue, forKey: Keys.adaptiveAutoSwitch) }
    }

    // MARK: - Login Item

    private func doUpdateLoginItem(enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
                rslog("Login item registered")
            } else {
                try service.unregister()
                rslog("Login item unregistered")
            }
        } catch {
            rslog("Login item error: \(error)")
        }
    }

    /// Текущий статус автозапуска (может отличаться от настройки)
    var loginItemStatus: SMAppService.Status {
        SMAppService.mainApp.status
    }
}

import CryptoKit
import Foundation
import Security

/// Локальные HMAC-подписи слов, которые пользователь уже явно исправлял.
/// Исходные и преобразованные слова не попадают в постоянное хранилище.
@MainActor
final class LearnedWordStore {
    static let shared = LearnedWordStore()

    struct RuleID: Hashable, Sendable {
        let sourceLayoutID: String
        let targetLayoutID: String
        let wordHMAC: Data
    }

    private struct Record: Codable, Sendable {
        let sourceLayoutID: String
        let targetLayoutID: String
        let wordHMAC: Data
        var manualConfirmationCount: Int
        var isBlocked: Bool

        var id: RuleID {
            RuleID(
                sourceLayoutID: sourceLayoutID,
                targetLayoutID: targetLayoutID,
                wordHMAC: wordHMAC
            )
        }
    }

    private enum Storage {
        static let defaultsKey = "com.ruswitcher.learnedWordRules.v1"
        static let keychainService = "com.ruswitcher.learned-word-hmac"
        static let keychainAccount = "device-key-v1"
        static let keyLength = 32
        static let confirmationThreshold = 2
    }

    private var didPrepare = false
    private var isAvailable = false
    private var hmacKey: SymmetricKey?
    private var records: [RuleID: Record] = [:]
    /// Только подтверждённые и не заблокированные подписи для O(1)-поиска.
    private var activeRuleIDs: Set<RuleID> = []
    private let persistenceQueue = DispatchQueue(
        label: "com.ruswitcher.learned-word-storage",
        qos: .utility
    )

    private init() {}

    /// Читает ключ и базу до начала автоконвертации. Любая ошибка оставляет ручной
    /// триггер независимым и безопасно выключает только обученную автоматику.
    func prepareIfNeeded() {
        guard !didPrepare else { return }
        didPrepare = true

        guard let keyData = loadOrCreateKey(), keyData.count == Storage.keyLength else { return }
        hmacKey = SymmetricKey(data: keyData)

        let defaults = UserDefaults.standard
        guard let storedObject = defaults.object(forKey: Storage.defaultsKey) else {
            isAvailable = true
            return
        }
        guard let data = storedObject as? Data,
              let decoded = try? JSONDecoder().decode([Record].self, from: data),
              decoded.allSatisfy(isValid),
              Set(decoded.map(\.id)).count == decoded.count else {
            return
        }

        records = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
        activeRuleIDs = Set(decoded.compactMap { record in
            !record.isBlocked && record.manualConfirmationCount >= Storage.confirmationThreshold
                ? record.id : nil
        })
        isAvailable = true
    }

    /// Запоминает только успешную ручную конвертацию одного безопасного слова.
    func recordManualCorrection(
        sourceLayoutID: String,
        targetLayoutID: String,
        originalWord: String,
        convertedWord: String
    ) {
        prepareIfNeeded()
        guard isAvailable,
              isEligibleWord(originalWord),
              isEligibleWord(convertedWord),
              let id = ruleID(
                sourceLayoutID: sourceLayoutID,
                targetLayoutID: targetLayoutID,
                targetWord: convertedWord
              ) else { return }

        if var record = records[id] {
            if record.isBlocked {
                record.isBlocked = false
                record.manualConfirmationCount = 1
            } else if record.manualConfirmationCount < Int.max {
                record.manualConfirmationCount += 1
            }
            records[id] = record
        } else {
            records[id] = Record(
                sourceLayoutID: sourceLayoutID,
                targetLayoutID: targetLayoutID,
                wordHMAC: id.wordHMAC,
                manualConfirmationCount: 1,
                isBlocked: false
            )
        }
        refreshActiveRule(id)
        persist()
    }

    /// Возвращает идентификатор правила для обратимой автоконвертации на границе слова.
    func matchingRule(
        sourceLayoutID: String,
        targetLayoutID: String,
        targetWord: String
    ) -> RuleID? {
        prepareIfNeeded()
        guard isAvailable,
              isEligibleWord(targetWord),
              let id = ruleID(
                sourceLayoutID: sourceLayoutID,
                targetLayoutID: targetLayoutID,
                targetWord: targetWord
              ),
              activeRuleIDs.contains(id) else {
            return nil
        }
        return id
    }

    /// Отмена автоматической конвертации блокирует её до нового явного обучения.
    func block(_ id: RuleID) {
        prepareIfNeeded()
        guard isAvailable, var record = records[id] else { return }
        record.isBlocked = true
        record.manualConfirmationCount = 0
        records[id] = record
        activeRuleIDs.remove(id)
        persist()
    }

    /// Очищает все подписи, счётчики и блокировки. Ключ остаётся в Keychain.
    func clear() {
        prepareIfNeeded()
        guard hmacKey != nil else { return }
        records.removeAll()
        activeRuleIDs.removeAll()
        isAvailable = true
        persistenceQueue.async {
            UserDefaults.standard.removeObject(forKey: Storage.defaultsKey)
        }
    }

    /// Перед завершением приложения ждём только запись уже подготовленного снимка.
    /// В горячем пути event tap запись по-прежнему выполняется асинхронно.
    func flush() {
        guard isAvailable else { return }
        let snapshot = Array(records.values)
        persistenceQueue.sync {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            UserDefaults.standard.set(data, forKey: Storage.defaultsKey)
        }
    }

    private func ruleID(
        sourceLayoutID: String,
        targetLayoutID: String,
        targetWord: String
    ) -> RuleID? {
        guard !sourceLayoutID.isEmpty,
              !targetLayoutID.isEmpty,
              sourceLayoutID != targetLayoutID,
              let hmacKey else { return nil }
        let normalized = normalizedWord(targetWord)
        guard !normalized.isEmpty else { return nil }
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(normalized.utf8),
            using: hmacKey
        )
        return RuleID(
            sourceLayoutID: sourceLayoutID,
            targetLayoutID: targetLayoutID,
            wordHMAC: Data(code)
        )
    }

    private func isValid(_ record: Record) -> Bool {
        !record.sourceLayoutID.isEmpty
            && !record.targetLayoutID.isEmpty
            && record.sourceLayoutID != record.targetLayoutID
            && record.wordHMAC.count == SHA256.Digest.byteCount
            && record.manualConfirmationCount >= 0
    }

    /// В правила попадают только слова из букв: это исключает URL, email, код,
    /// цифры, управляющие символы и пунктуацию.
    private func isEligibleWord(_ word: String) -> Bool {
        let normalized = normalizedWord(word)
        guard normalized.count >= 3 else { return false }
        return word.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
    }

    /// NFC + lowercase + удаление завершающей пунктуации перед HMAC.
    private func normalizedWord(_ word: String) -> String {
        var normalized = word.precomposedStringWithCanonicalMapping.lowercased()
        while let last = normalized.last,
              last.unicodeScalars.allSatisfy({ CharacterSet.punctuationCharacters.contains($0) }) {
            normalized.removeLast()
        }
        return normalized
    }

    private func persist() {
        let snapshot = records
        persistenceQueue.async {
            guard let data = try? JSONEncoder().encode(Array(snapshot.values)) else { return }
            UserDefaults.standard.set(data, forKey: Storage.defaultsKey)
        }
    }

    private func refreshActiveRule(_ id: RuleID) {
        guard let record = records[id],
              !record.isBlocked,
              record.manualConfirmationCount >= Storage.confirmationThreshold else {
            activeRuleIDs.remove(id)
            return
        }
        activeRuleIDs.insert(id)
    }

    private func loadOrCreateKey() -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Storage.keychainService,
            kSecAttrAccount: Storage.keychainAccount,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            return result as? Data
        }
        guard status == errSecItemNotFound else { return nil }

        var bytes = [UInt8](repeating: 0, count: Storage.keyLength)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        let keyData = Data(bytes)
        var addQuery = query
        addQuery.removeValue(forKey: kSecReturnData)
        addQuery.removeValue(forKey: kSecMatchLimit)
        addQuery[kSecValueData] = keyData
        addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess { return keyData }
        if addStatus == errSecDuplicateItem {
            return loadOrCreateKey()
        }
        return nil
    }
}

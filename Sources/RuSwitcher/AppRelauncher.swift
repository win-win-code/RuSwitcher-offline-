import AppKit
import Foundation

/// Единая локальная последовательность перезапуска приложения.
@MainActor
enum AppRelauncher {
    /// Перезапускает приложение: открывает бандл заново и завершает текущий процесс.
    static func relaunch(bundlePath: String = Bundle.main.bundlePath) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundlePath]
        try? task.run()
        NSApplication.shared.terminate(nil)
    }
}

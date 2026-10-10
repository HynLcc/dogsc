import AppKit
import Foundation
import Observation
import SwiftUI
import os

/// Shares a language across SwiftUI and AppKit without replacing view identities.
/// String lookup may also run off the main thread when presenting core errors.
final class AppLocalization: Observable, Sendable {
    static let shared = AppLocalization()

    private struct Selection: Sendable {
        let code: String
        let bundle: Bundle
    }

    private let selection: OSAllocatedUnfairLock<Selection>
    private let observation = ObservationRegistrar()

    private init() {
        selection = OSAllocatedUnfairLock(initialState: Self.resolvePreference())
    }

    var languageCode: String {
        observation.access(self, keyPath: \.languageCode)
        return selection.withLock { $0.code }
    }

    func localizedString(_ key: String) -> String {
        // Reading a translation in a SwiftUI body also observes language changes.
        observation.access(self, keyPath: \.languageCode)
        let bundle = selection.withLock { $0.bundle }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    @MainActor
    func refresh() {
        let next = Self.resolvePreference()
        guard next.code != languageCode else { return }
        observation.withMutation(of: self, keyPath: \.languageCode) {
            selection.withLock { $0 = next }
        }
        refreshWindowTitles()
        // SwiftUI can rebuild scene commands after their labels change. Restore
        // the existing AppKit menu contract after that update has settled.
        (NSApplication.shared.delegate as? DogSCApplicationDelegate)?
            .scheduleMainMenuRefresh()
    }

    private static func resolvePreference() -> Selection {
        let preference = AppLanguagePreference(rawValue:
            UserDefaults.standard.string(forKey: AppPreferences.languagePreferenceKey) ?? ""
        ) ?? .system
        let code: String
        if preference == .system {
            // Preserve macOS's system / per-app language choice, including fallback.
            code = Bundle.main.preferredLocalizations.first ?? "zh-Hans"
        } else {
            code = preference.rawValue
        }
        let bundle = Bundle.main.path(forResource: code, ofType: "lproj")
            .flatMap(Bundle.init(path:)) ?? Bundle.main
        return Selection(code: code, bundle: bundle)
    }

    @MainActor
    private func refreshWindowTitles() {
        for window in NSApplication.shared.windows {
            switch window.identifier?.rawValue {
            case "cn.laogou.dogsc.settings-window":
                window.title = "\(AppIdentity.displayName) \(appLocalized("设置"))"
            case "cn.laogou.dogsc.permission-onboarding":
                window.title = String(format: appLocalized("开始使用 %@"), AppIdentity.displayName)
            case "recorder.memo.window":
                window.title = appLocalized("备忘录")
            case "dogsc.recording-completion":
                window.title = appLocalized("录制完成")
            default: break
            }
        }
    }
}

private struct AppLanguageModifier: ViewModifier {
    @AppStorage(AppPreferences.languagePreferenceKey)
    private var preference = AppLanguagePreference.system

    func body(content: Content) -> some View {
        content
            .environment(\.locale, Locale(identifier: AppLocalization.shared.languageCode))
            .onChange(of: preference) { _, _ in AppLocalization.shared.refresh() }
    }
}

extension View {
    /// Apply to each presentation root, including independently hosted panels.
    func appLanguage() -> some View {
        modifier(AppLanguageModifier())
    }
}

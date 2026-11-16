// Resolves app-owned strings from bundled Japanese/English resources. InterfaceLanguage
// follows the system or an explicit preference, independently of recognition language.
import Foundation

enum InterfaceLanguage: String, CaseIterable {
    case system, japanese = "ja", english = "en"

    static var current: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: "interfaceLanguage") ?? "system") ?? .system
    }

    var identifier: String {
        if self != .system { return rawValue }
        return Bundle.preferredLocalizations(from: ["ja", "en"]).first ?? "en"
    }

    var locale: Locale { Locale(identifier: identifier) }

    var title: String {
        switch self {
        case .system: localized("システム設定に従う")
        case .japanese: "日本語"
        case .english: "English"
        }
    }
}

func localized(_ key: String, _ arguments: CVarArg...) -> String {
    let language = InterfaceLanguage.current
    let bundle = Bundle.main.path(forResource: language.identifier, ofType: "lproj")
        .flatMap(Bundle.init(path:)) ?? .main
    let format = bundle.localizedString(forKey: key, value: key, table: nil)
    return arguments.isEmpty ? format : String(format: format, locale: language.locale, arguments: arguments)
}

func languageName(_ identifier: String) -> String {
    InterfaceLanguage.current.locale.localizedString(forIdentifier: identifier) ?? identifier
}

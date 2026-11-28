// PSST (D99): localization of the LoRa texts (Resources/{en,sk}.lproj/Localizable.strings in this package).
import Foundation

/// App name shown in texts: "psst" in psst, "psst lab" in the test app.
public var psstAppName: String {
    (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? "psst"
}

/// Localized LoRa text; `{app}` is replaced by the app name, `%1$@`… by the arguments (any value, via String(describing:)).
public func psstTr(_ key: String, _ args: Any...) -> String {
    let format = Bundle.module.localizedString(forKey: key, value: nil, table: nil).replacingOccurrences(of: "{app}", with: psstAppName)
    guard !args.isEmpty else { return format }
    return String(format: format, arguments: args.map { String(describing: $0) as NSString as CVarArg })
}

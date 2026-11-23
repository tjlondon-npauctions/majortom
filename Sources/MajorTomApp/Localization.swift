import Foundation

/// Look up existing model copy at the presentation boundary, leaving CLI and saved data unchanged.
func localized(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

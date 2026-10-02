import Foundation

/// Picks the language the app should render in.
///
/// - Parameters:
///   - selection: The user's explicit choice, or `nil` to follow the system.
///   - available: Language codes the app ships, e.g. `["en", "tr", "zh-Hans"]`.
///   - systemPreferred: The system language list, newest first. Region tags
///     (`"tr-TR"`, `"zh-CN"`) match the language the app ships. A script tag
///     stays distinct, so `"zh-Hant"` does not select `"zh-Hans"`.
/// - Returns: A member of `available`, or `"en"` when nothing matches.
public func resolveLanguage(
    selection: String?,
    available: [String],
    systemPreferred: [String]
) -> String {
    if let selection, let match = matchingEntry(for: selection, in: available) {
        return match
    }
    for candidate in systemPreferred {
        if let match = matchingEntry(for: candidate, in: available) {
            return match
        }
    }
    return "en"
}

/// A localization code no real preference should select. Pairing it with a
/// candidate lets us tell a real match from `Bundle`'s fallback, which otherwise
/// returns some available language even when the preference does not fit.
private let unmatchedSentinel = "zxx"

private func matchingEntry(for candidate: String, in available: [String]) -> String? {
    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !available.isEmpty else { return nil }
    let ranked = Bundle.preferredLocalizations(from: available, forPreferences: [trimmed])
    guard let best = ranked.first, available.contains(best) else { return nil }
    let confirmed = Bundle.preferredLocalizations(from: [best, unmatchedSentinel], forPreferences: [trimmed])
    return confirmed.first == best ? best : nil
}

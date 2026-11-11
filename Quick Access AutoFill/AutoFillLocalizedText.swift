import Foundation

/// Presentation-only formatting. Candidate metadata is interpolated verbatim,
/// never interpreted as a localization key or used to change matching identity.
enum AutoFillLocalizedText {
    static func string(_ resource: LocalizedStringResource, locale: Locale) -> String {
        var localized = resource
        localized.locale = locale
        return String(localized: localized)
    }

    static func resultCount(_ count: Int, locale: Locale) -> String {
        string(.autoFillCredentialCount(count), locale: locale)
    }

    static func matchingResultCount(_ count: Int, locale: Locale) -> String {
        string(.autoFillMatchingCredentialCount(count), locale: locale)
    }

    static func searchCredentials(locale: Locale) -> String {
        string(.autoFillSearchCredentials, locale: locale)
    }

    static func candidateAccessibilityLabel(_ candidate: AutoFillCandidate, exactMatch: Bool, locale: Locale) -> String {
        // Match the visible row order.
        var parts = [candidate.title, candidate.username]
        if exactMatch {
            parts.append(string("Exact site match", locale: locale))
        }
        if candidate.isRecentlyUsed {
            parts.append(string("Recently used", locale: locale))
        }
        return parts.joined(separator: ", ")
    }

    static func selectedAnnouncement(_ candidate: AutoFillCandidate, locale: Locale) -> String {
        string(.autoFillSelectedAnnouncement(candidate.title, candidate.username), locale: locale)
    }
}

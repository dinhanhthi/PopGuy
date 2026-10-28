// PromptContext.swift
// PopGuy — ActionEngine
//
// Prompt placeholder expansion for AI prompts.
//
// Public surface:
//   PromptContext  — Sendable snapshot of the context tokens (app, domain,
//                    date, language), each flattened to a single line.
//   PromptTemplate.expand(_:text:context:) -> (output, consumedText)
//
// Tokens: {{text}}, {{app}}, {{domain}}, {{date}}, {{language}}.
// Expansion is a single left-to-right pass over the template: substituted
// values are never re-scanned, so selected text or an app name that contains
// a token stays literal. `consumedText` reports whether the TEMPLATE itself
// contained {{text}}. Unknown tokens and unterminated "{{" stay literal.
//
// Isolation:
//   Both types are nonisolated value types (opting out of the default
//   MainActor isolation) so the nonisolated ActionEngine can call them. Callers
//   on the main actor snapshot the context before dispatch.

import Foundation

// MARK: - PromptContext

/// Context values substituted into prompt templates.
nonisolated struct PromptContext: Sendable, Equatable {
    let appName: String
    let domain: String
    let date: String
    let language: String

    static let empty = PromptContext(appName: "", domain: "", date: "", language: "")

    init(appName: String, domain: String, date: String, language: String) {
        self.appName = Self.singleLine(appName)
        self.domain = Self.singleLine(domain)
        self.date = Self.singleLine(date)
        self.language = Self.singleLine(language)
    }

    /// Formats `date` as `yyyy-MM-dd` (Gregorian, POSIX locale) in `timeZone`.
    static func dateString(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Replaces each run of control/newline characters with one space, then trims.
    private static func singleLine(_ value: String) -> String {
        let separators = CharacterSet.controlCharacters.union(.newlines)
        var scalars = String.UnicodeScalarView()
        var lastWasSeparator = false
        for scalar in value.unicodeScalars {
            if separators.contains(scalar) {
                if !lastWasSeparator { scalars.append(" ") }
                lastWasSeparator = true
            } else {
                scalars.append(scalar)
                lastWasSeparator = false
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - PromptTemplate

nonisolated enum PromptTemplate {

    /// Expands prompt tokens in a single pass. When `text` is nil, `{{text}}`
    /// is left literal and `consumedText` is false.
    static func expand(
        _ template: String,
        text: String?,
        context: PromptContext
    ) -> (output: String, consumedText: Bool) {
        var output = ""
        var consumedText = false
        var cursor = template.startIndex

        while let open = template.range(of: "{{", range: cursor..<template.endIndex) {
            output += template[cursor..<open.lowerBound]
            guard let close = template.range(of: "}}", range: open.upperBound..<template.endIndex),
                  let value = value(for: template[open.upperBound..<close.lowerBound],
                                    text: text, context: context) else {
                // Unknown or unterminated token: keep "{{" and rescan after it.
                output += "{{"
                cursor = open.upperBound
                continue
            }
            if template[open.upperBound..<close.lowerBound] == "text" { consumedText = true }
            output += value
            cursor = close.upperBound
        }
        output += template[cursor...]
        return (output, consumedText)
    }

    private static func value(for name: Substring, text: String?, context: PromptContext) -> String? {
        switch name {
        case "text":     return text
        case "app":      return context.appName
        case "domain":   return context.domain
        case "date":     return context.date
        case "language": return context.language
        default:         return nil
        }
    }
}

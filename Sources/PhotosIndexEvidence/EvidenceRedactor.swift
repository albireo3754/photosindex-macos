import Foundation

public enum EvidenceRedactor {
    public static func redact(_ text: String) -> String {
        var output = text
        output = replacing(
            #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            in: output,
            with: "[REDACTED_EMAIL]",
            options: [.caseInsensitive]
        )
        output = replacing(
            #"(?<![0-9])(?:\+?82[\s-]?)?(?:0?1[016789]|0?2|0?[3-6][1-5])[\s-]?[0-9]{3,4}[\s-]?[0-9]{4}(?![0-9])"#,
            in: output,
            with: "[REDACTED_PHONE]"
        )
        output = replacing(
            #"(?<![0-9])(?:[0-9][\s-]?){8,19}(?![0-9])"#,
            in: output,
            with: "[REDACTED_ID]"
        )
        return output
    }

    private static func replacing(
        _ pattern: String,
        in input: String,
        with replacement: String,
        options: NSRegularExpression.Options = []
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
            return input
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return expression.stringByReplacingMatches(
            in: input,
            options: [],
            range: range,
            withTemplate: replacement
        )
    }
}

import Foundation

public enum VeloraTextSanitizer {
    public static func contextText(_ text: String, maxLength: Int = 1_200) -> String {
        sanitizedText(text, maxLength: maxLength, preserveNewlines: true)
    }

    public static func promptPhrase(_ text: String, maxLength: Int = 80) -> String {
        sanitizedText(text, maxLength: maxLength, preserveNewlines: false)
    }

    public static func promptText(_ text: String, maxLength: Int = 512) -> String {
        sanitizedText(text, maxLength: maxLength, preserveNewlines: false)
    }

    public static func containsProcessUnsafeCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value == 0 }
    }

    private static func sanitizedText(
        _ text: String,
        maxLength: Int,
        preserveNewlines: Bool
    ) -> String {
        var output = String.UnicodeScalarView()
        output.reserveCapacity(min(text.unicodeScalars.count, maxLength))
        var emittedScalars = 0
        var previousWasSpace = false

        func appendSpace() {
            guard !previousWasSpace, emittedScalars < maxLength else {
                return
            }
            output.append(" ")
            emittedScalars += 1
            previousWasSpace = true
        }

        for scalar in text.unicodeScalars {
            guard emittedScalars < maxLength else {
                break
            }

            if scalar.value == 0 || isNonPrintableControl(scalar) {
                appendSpace()
                continue
            }

            if scalar == "\n" || scalar == "\r" {
                if preserveNewlines {
                    output.append(scalar)
                    emittedScalars += 1
                    previousWasSpace = false
                } else {
                    appendSpace()
                }
                continue
            }

            if scalar == "\t" {
                appendSpace()
                continue
            }

            output.append(scalar)
            emittedScalars += 1
            previousWasSpace = CharacterSet.whitespaces.contains(scalar)
        }

        return String(output).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isNonPrintableControl(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value < 32 && scalar != "\n" && scalar != "\r" && scalar != "\t")
            || (127...159).contains(scalar.value)
    }
}

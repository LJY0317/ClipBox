import Foundation

public enum FilenameSanitizer {
    private static let forbiddenCharacters = CharacterSet(charactersIn: "<>:\"/\\|?*")

    /// Preserves ordinary spaces for readability while replacing characters
    /// that are unsafe or troublesome in filename components.
    public static func sanitize(_ input: String) -> String {
        let scalars = input.unicodeScalars.map { scalar -> Character in
            if forbiddenCharacters.contains(scalar) || CharacterSet.controlCharacters.contains(scalar) {
                return "_"
            }
            return Character(String(scalar))
        }

        var output = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        output = output.replacingOccurrences(
            of: #"[\. ]+$"#,
            with: "",
            options: .regularExpression
        )

        return output.isEmpty ? "untitled" : output
    }
}

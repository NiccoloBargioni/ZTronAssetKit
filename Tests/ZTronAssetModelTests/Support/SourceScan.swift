import Foundation
import Testing

/// Read-only scans of `Sources/` for the package-wide rules WP-A owns (R-ENV-1, R-OBS-1, R-MAN-7).
///
/// Located through `#filePath` (no working-directory assumption), it only reads. A small Swift-aware lexer strips
/// comments and string-literal contents, so a rule stated in a doc comment or a message never trips a scan, and
/// tracks which type declaration encloses each line.
enum SourceScan {
    /// One line of code, with its comments removed and its string literals' contents blanked.
    struct Line {
        /// For example `Sources/ZTronAssetModel/Environment/Time.swift`.
        var path: String
        /// 1-based.
        var number: Int
        /// The line as written.
        var text: String
        /// The code part: no comment, string contents replaced by spaces (the quotes stay).
        var code: String
        /// The names of the type declarations (`struct`, `class`, `actor`, `enum`, `extension`, `protocol`) that
        /// enclose the line, outermost first.
        var enclosingTypes: [String]
    }

    /// The repository root, three levels above this file's directory (`Tests/ZTronAssetModelTests/Support`).
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Every Swift line under `Sources/` (or under `Sources/<subpath>`), files in path order.
    static func lines(under subpath: String = "") throws -> [Line] {
        let base = self.root.appendingPathComponent("Sources").appendingPathComponent(subpath)
        let enumerator = try #require(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
        let prefix = self.root.standardizedFileURL.path + "/"
        var files: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let path = url.standardizedFileURL.path
            files.append((path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path, try String(contentsOf: url, encoding: .utf8)))
        }
        return files.sorted { $0.0 < $1.0 }.flatMap { self.lex(path: $0.0, text: $0.1) }
    }

    /// Splits one file into lines with code parts and enclosing types. Handles `//` and `/* */` comments, string
    /// literals with escapes, raw strings (`#"…"#`, any number of `#`) and multi-line strings.
    static func lex(path: String, text: String) -> [Line] {
        var result: [Line] = []
        var inBlockComment = false
        /// Inside a string: `nil` outside; the closing delimiter's `#` count and whether it is `"""`.
        var string: (hashes: Int, multiline: Bool)?
        var depth = 0
        var types: [(name: String, depth: Int)] = []
        var pendingType: String?
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let characters = Array(raw)
            var code = ""
            var position = 0
            func matches(_ pattern: String, at offset: Int) -> Bool {
                let expected = Array(pattern)
                guard offset + expected.count <= characters.count else {
                    return false
                }
                return Array(characters[offset..<(offset + expected.count)]) == expected
            }
            while position < characters.count {
                let character = characters[position]
                if inBlockComment {
                    if matches("*/", at: position) {
                        inBlockComment = false
                        position += 1
                    }
                } else if let open = string {
                    let closing = (open.multiline ? "\"\"\"" : "\"") + String(repeating: "#", count: open.hashes)
                    if matches(closing, at: position) {
                        string = nil
                        code += closing
                        position += closing.count - 1
                    } else if character == "\\", open.hashes == 0 {
                        code += "  "
                        position += 1
                    } else {
                        code += " "
                    }
                } else if matches("//", at: position) {
                    break
                } else if matches("/*", at: position) {
                    inBlockComment = true
                    position += 1
                } else if character == "#" || character == "\"" {
                    var hashes = 0
                    while position + hashes < characters.count, characters[position + hashes] == "#" {
                        hashes += 1
                    }
                    if matches("\"", at: position + hashes) {
                        let multiline = matches("\"\"\"", at: position + hashes)
                        string = (hashes, multiline)
                        let opening = String(repeating: "#", count: hashes) + (multiline ? "\"\"\"" : "\"")
                        code += opening
                        position += opening.count - 1
                    } else {
                        code.append(character)
                    }
                } else {
                    code.append(character)
                }
                position += 1
            }
            if let open = string, !open.multiline {
                // A single-line string cannot continue on the next line.
                string = nil
            }

            if let name = self.declaredType(in: code) {
                pendingType = name
            }
            let enclosing = types.map(\.name) + (pendingType.map { [$0] } ?? [])
            result.append(Line(path: path, number: index + 1, text: raw, code: code, enclosingTypes: enclosing))
            for character in code {
                if character == "{" {
                    depth += 1
                    if let name = pendingType {
                        types.append((name, depth))
                        pendingType = nil
                    }
                } else if character == "}" {
                    if let last = types.last, last.depth == depth {
                        types.removeLast()
                    }
                    depth -= 1
                }
            }
        }
        return result
    }

    /// The name a type declaration on this line introduces, if any.
    private static func declaredType(in code: String) -> String? {
        let tokens = code.split(whereSeparator: { $0.isWhitespace || $0 == ":" || $0 == "<" || $0 == "{" }).map(String.init)
        for (index, token) in tokens.enumerated() where ["struct", "class", "actor", "enum", "extension", "protocol"].contains(token) {
            let modifiers: Set<String> = ["public", "package", "internal", "private", "fileprivate", "final", "open", "indirect"]
            let before = tokens[..<index]
            guard before.allSatisfy({ modifiers.contains($0) || $0.hasPrefix("@") }), index + 1 < tokens.count,
                !["func", "var", "let", "subscript", "init"].contains(tokens[index + 1])
            else {
                return nil
            }
            return tokens[index + 1]
        }
        return nil
    }

    /// The text of `\( … )` interpolations in a line's original text (balanced parentheses).
    static func interpolations(in text: String) -> [String] {
        var result: [String] = []
        let characters = Array(text)
        var index = 0
        while index + 1 < characters.count {
            guard characters[index] == "\\", characters[index + 1] == "(" else {
                index += 1
                continue
            }
            var level = 1
            var end = index + 2
            while end < characters.count, level > 0 {
                if characters[end] == "(" {
                    level += 1
                } else if characters[end] == ")" {
                    level -= 1
                }
                end += 1
            }
            result.append(String(characters[(index + 2)..<max(index + 2, end - 1)]))
            index = end
        }
        return result
    }
}

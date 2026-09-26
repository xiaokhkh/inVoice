import Foundation

enum MarkdownDocumentBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case quote(String)
    case unorderedList([String])
    case orderedList([String])
    case code(language: String?, content: String)
    case divider
}

enum MarkdownDocumentParser {
    static func parse(_ source: String) -> [MarkdownDocumentBlock] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var blocks: [MarkdownDocumentBlock] = []
        var paragraphLines: [String] = []
        var quoteLines: [String] = []
        var unorderedItems: [String] = []
        var orderedItems: [String] = []
        var codeLines: [String] = []
        var codeLanguage: String?
        var isInsideCodeFence = false

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        func flushQuote() {
            guard !quoteLines.isEmpty else { return }
            blocks.append(.quote(quoteLines.joined(separator: "\n")))
            quoteLines.removeAll(keepingCapacity: true)
        }

        func flushUnorderedList() {
            guard !unorderedItems.isEmpty else { return }
            blocks.append(.unorderedList(unorderedItems))
            unorderedItems.removeAll(keepingCapacity: true)
        }

        func flushOrderedList() {
            guard !orderedItems.isEmpty else { return }
            blocks.append(.orderedList(orderedItems))
            orderedItems.removeAll(keepingCapacity: true)
        }

        func flushTextBlocks() {
            flushParagraph()
            flushQuote()
            flushUnorderedList()
            flushOrderedList()
        }

        func appendCodeBlock() {
            blocks.append(
                .code(
                    language: codeLanguage?.isEmpty == false ? codeLanguage : nil,
                    content: codeLines.joined(separator: "\n")
                )
            )
            codeLines.removeAll(keepingCapacity: true)
            codeLanguage = nil
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if isInsideCodeFence {
                if trimmed.hasPrefix("```") {
                    appendCodeBlock()
                    isInsideCodeFence = false
                } else {
                    codeLines.append(line)
                }
                continue
            }

            if trimmed.hasPrefix("```") {
                flushTextBlocks()
                codeLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                isInsideCodeFence = true
                continue
            }

            if trimmed.isEmpty {
                flushTextBlocks()
                continue
            }

            if let heading = heading(in: trimmed) {
                flushTextBlocks()
                blocks.append(.heading(level: heading.level, text: heading.text))
                continue
            }

            if isDivider(trimmed) {
                flushTextBlocks()
                blocks.append(.divider)
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                flushUnorderedList()
                flushOrderedList()
                let content = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                quoteLines.append(content)
                continue
            }

            if let item = unorderedListItem(in: trimmed) {
                flushParagraph()
                flushQuote()
                flushOrderedList()
                unorderedItems.append(item)
                continue
            }

            if let item = orderedListItem(in: trimmed) {
                flushParagraph()
                flushQuote()
                flushUnorderedList()
                orderedItems.append(item)
                continue
            }

            flushQuote()
            flushUnorderedList()
            flushOrderedList()
            paragraphLines.append(line)
        }

        if isInsideCodeFence {
            appendCodeBlock()
        } else {
            flushTextBlocks()
        }

        return blocks
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let prefix = line.prefix { $0 == "#" }
        guard (1...6).contains(prefix.count), line.dropFirst(prefix.count).first == " " else {
            return nil
        }
        let text = String(line.dropFirst(prefix.count + 1)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (prefix.count, text)
    }

    private static func unorderedListItem(in line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func orderedListItem(in line: String) -> String? {
        guard let separator = line.range(of: ". ") else { return nil }
        let number = line[..<separator.lowerBound]
        guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }
        return String(line[separator.upperBound...])
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let marker = compact.first else { return false }
        guard marker == "-" || marker == "*" || marker == "_" else { return false }
        return compact.allSatisfy { $0 == marker }
    }
}

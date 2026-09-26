import Foundation

enum TranslationPromptDefaults {
    static let systemPromptKey = "offlineTranslationSystemPrompt"
    static let userPromptKey = "offlineTranslationUserPromptTemplate"
    static let migrationVersionKey = "offlineTranslationPromptMigrationVersion"

    static let defaultSystemPrompt = """
You are an English-to-Chinese translator for a programming-focused tool.

Your job:
- Translate English into clear, natural Simplified Chinese.
- If the input mixes English and Chinese, translate the English and preserve the existing Chinese.
- If the input is already Chinese, return it unchanged.
- Keep the meaning exact. Do not invent facts, commands, logs, or technical conclusions.
- Preserve personal names, code identifiers, file paths, URLs, CLI commands, and established acronyms such as `TODO`.
- Keep technical terms in English when that is clearer or more conventional for Chinese developers.
- Preserve Markdown structure, numbers, versions, punctuation, and line breaks when possible.
- Preserve the original tone and level of formality.
- Return only the Simplified Chinese translation. No extra commentary.
"""

    static let defaultUserPromptTemplate = """
Translate the following English text into clear, natural Simplified Chinese while preserving meaning, terminology, and formatting.

Text:
<<<
{{text}}
>>>
"""

    private static let currentMigrationVersion = 1

    static func migrateIfNeeded(userDefaults: UserDefaults = .standard) {
        guard userDefaults.integer(forKey: migrationVersionKey) < currentMigrationVersion else {
            return
        }

        let storedSystemPrompt = userDefaults.string(forKey: systemPromptKey) ?? ""
        if shouldReplaceLegacySystemPrompt(storedSystemPrompt) {
            userDefaults.set(defaultSystemPrompt, forKey: systemPromptKey)
        }

        let storedUserPrompt = userDefaults.string(forKey: userPromptKey) ?? ""
        if shouldReplaceLegacyUserPrompt(storedUserPrompt) {
            userDefaults.set(defaultUserPromptTemplate, forKey: userPromptKey)
        }

        userDefaults.set(currentMigrationVersion, forKey: migrationVersionKey)
    }

    private static func shouldReplaceLegacySystemPrompt(_ prompt: String) -> Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            || prompt.localizedCaseInsensitiveContains("Chinese-to-English translator")
            || prompt.localizedCaseInsensitiveContains("Translate Chinese into clear, natural English")
    }

    private static func shouldReplaceLegacyUserPrompt(_ prompt: String) -> Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            || prompt.localizedCaseInsensitiveContains("Translate the following Chinese text into English")
    }
}

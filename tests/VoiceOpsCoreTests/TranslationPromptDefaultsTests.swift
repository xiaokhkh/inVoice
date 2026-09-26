import Foundation
import XCTest
@testable import VoiceOpsCore

final class TranslationPromptDefaultsTests: XCTestCase {
    private var suiteName: String!
    private var userDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "TranslationPromptDefaultsTests.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)
        userDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
        userDefaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testMissingPromptsReceiveEnglishToChineseDefaults() {
        TranslationPromptDefaults.migrateIfNeeded(userDefaults: userDefaults)

        XCTAssertEqual(
            userDefaults.string(forKey: TranslationPromptDefaults.systemPromptKey),
            TranslationPromptDefaults.defaultSystemPrompt
        )
        XCTAssertEqual(
            userDefaults.string(forKey: TranslationPromptDefaults.userPromptKey),
            TranslationPromptDefaults.defaultUserPromptTemplate
        )
    }

    func testLegacyChineseToEnglishPromptsAreReplaced() {
        userDefaults.set(
            "You are a Chinese-to-English translator. Translate Chinese into clear, natural English.",
            forKey: TranslationPromptDefaults.systemPromptKey
        )
        userDefaults.set(
            "Translate the following Chinese text into English.\n\n{{text}}",
            forKey: TranslationPromptDefaults.userPromptKey
        )

        TranslationPromptDefaults.migrateIfNeeded(userDefaults: userDefaults)

        XCTAssertEqual(
            userDefaults.string(forKey: TranslationPromptDefaults.systemPromptKey),
            TranslationPromptDefaults.defaultSystemPrompt
        )
        XCTAssertEqual(
            userDefaults.string(forKey: TranslationPromptDefaults.userPromptKey),
            TranslationPromptDefaults.defaultUserPromptTemplate
        )
    }

    func testUnrelatedCustomPromptsArePreserved() {
        let customSystemPrompt = "Translate selected text into French."
        let customUserPrompt = "Convert this selection:\n{{text}}"
        userDefaults.set(customSystemPrompt, forKey: TranslationPromptDefaults.systemPromptKey)
        userDefaults.set(customUserPrompt, forKey: TranslationPromptDefaults.userPromptKey)

        TranslationPromptDefaults.migrateIfNeeded(userDefaults: userDefaults)

        XCTAssertEqual(
            userDefaults.string(forKey: TranslationPromptDefaults.systemPromptKey),
            customSystemPrompt
        )
        XCTAssertEqual(
            userDefaults.string(forKey: TranslationPromptDefaults.userPromptKey),
            customUserPrompt
        )
    }

    func testMigrationRunsOnlyOnce() {
        TranslationPromptDefaults.migrateIfNeeded(userDefaults: userDefaults)
        let customSystemPrompt = "My later customization"
        userDefaults.set(customSystemPrompt, forKey: TranslationPromptDefaults.systemPromptKey)

        TranslationPromptDefaults.migrateIfNeeded(userDefaults: userDefaults)

        XCTAssertEqual(
            userDefaults.string(forKey: TranslationPromptDefaults.systemPromptKey),
            customSystemPrompt
        )
    }
}

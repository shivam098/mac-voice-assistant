import XCTest
@testable import VoiceAssistantCore

/// The same cases as windows-voice-assistant tests/VoiceAssistant.Core.Tests/AppCatalogTests.cs.
final class AppCatalogTests: XCTestCase {
    private let gitHubCopilot = AppEntry(
        name: "GitHub Copilot", launch: #"shell:AppsFolder\com.github.githubapp"#, processNames: ["github"],
        windowTitleContains: "GitHub Copilot", textArea: "Bottom")

    private func catalog() -> AppCatalog {
        let catalog = AppCatalog([gitHubCopilot])
        catalog.setDiscoveredApps([
            AppEntry(name: "Copilot", launch: #"shell:AppsFolder\Microsoft.Copilot"#),
            AppEntry(name: "Microsoft Teams", launch: #"shell:AppsFolder\MSTeams"#),
            AppEntry(name: "Outlook (new)", launch: #"shell:AppsFolder\Outlook"#),
            AppEntry(name: "Microsoft Edge", launch: #"shell:AppsFolder\MSEdge"#),
            AppEntry(name: "Edge", launch: #"shell:AppsFolder\OtherEdge"#),
        ])
        return catalog
    }

    func testSpokenVariantsResolveToConfiguredApp() {
        for spoken in ["github copilot", "git hub copilot", "github co pilot"] {
            XCTAssertEqual(.found(gitHubCopilot), catalog().resolve(spoken), spoken)
        }
    }

    func testPlainCopilotIsTheStartMenuAppNamedCopilotNotGitHub() {
        guard case .found(let app) = catalog().resolve("copilot") else { return XCTFail("not found") }
        XCTAssertEqual("Copilot", app.name)
    }

    func testVendorPrefixCanBeOmittedWhenUnique() {
        guard case .found(let app) = catalog().resolve("teams") else { return XCTFail("not found") }
        XCTAssertEqual("Microsoft Teams", app.name)
    }

    func testExactNameBeatsVendorStrippedMatch() {
        guard case .found(let app) = catalog().resolve("edge") else { return XCTFail("not found") }
        XCTAssertEqual("Edge", app.name)
    }

    func testUnknownAppIsNotFound() {
        XCTAssertEqual(.notFound, catalog().resolve("photoshop"))
    }

    func testDuplicateNamesAreAmbiguous() {
        let catalog = AppCatalog([])
        catalog.setDiscoveredApps([AppEntry(name: "Terminal", launch: "a"), AppEntry(name: "Terminal", launch: "b")])
        guard case .ambiguous(let names) = catalog.resolve("terminal") else { return XCTFail("not ambiguous") }
        XCTAssertEqual(2, names.count)
    }

    func testProfileRequiresProcessAndTitleMatch() {
        let catalog = catalog()
        XCTAssertEqual(gitHubCopilot, catalog.findProfileForProcess("GitHub", "GitHub Copilot"))
        XCTAssertNil(catalog.findProfileForProcess("github", "GitHub Desktop"))
        XCTAssertNil(catalog.findProfileForProcess("notepad", "GitHub Copilot"))
    }

    // MARK: Beyond the C# tests

    func testAnAppNamedOnlyWithPunctuationIsSkippedInsteadOfThrowing() {
        // C#'s Min throws on an app without a single name key; such an app can't be said anyway.
        let catalog = AppCatalog([])
        catalog.setDiscoveredApps([AppEntry(name: "---", launch: "x"), AppEntry(name: "Notepad", launch: "n")])
        XCTAssertEqual(.found(AppEntry(name: "Notepad", launch: "n")), catalog.resolve("notpad"))
        XCTAssertEqual(.notFound, catalog.resolve("photoshop"))
    }
}

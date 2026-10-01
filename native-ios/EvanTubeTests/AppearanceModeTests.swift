import XCTest
import SwiftUI
import UIKit
@testable import LovelyMusic

final class AppearanceModeTests: XCTestCase {
    @MainActor func testFreshInstallKeepsTheApprovedDarkAppearance() {
        withCleanAppearanceDefaults {
            let manager = ThemeManager()
            XCTAssertEqual(manager.appearanceMode, .dark)
            XCTAssertEqual(manager.preferredColorScheme, .dark)
        }
    }

    @MainActor func testInvalidSavedAppearanceFallsBackToDark() {
        withCleanAppearanceDefaults {
            UserDefaults.standard.set("unknown-mode", forKey: "appearanceMode")
            let manager = ThemeManager()
            XCTAssertEqual(manager.appearanceMode, .dark)
            XCTAssertEqual(manager.preferredColorScheme, .dark)
        }
    }

    @MainActor func testEverySelectionUpdatesTheSchemeAndSurvivesRestart() {
        withCleanAppearanceDefaults {
            let manager = ThemeManager()
            let choices: [(AppearanceMode, ColorScheme?, Bool)] = [
                (.light, .light, false),
                (.pureBlack, .dark, true),
                (.dark, .dark, false),
                (.system, nil, false),
            ]

            for (mode, expectedScheme, expectedPureBlack) in choices {
                manager.appearanceMode = mode
                XCTAssertEqual(manager.preferredColorScheme, expectedScheme)
                XCTAssertEqual(manager.isPureBlack, expectedPureBlack)
                XCTAssertEqual(UserDefaults.standard.string(forKey: "appearanceMode"), mode.rawValue)

                let restarted = ThemeManager()
                XCTAssertEqual(restarted.appearanceMode, mode)
                XCTAssertEqual(restarted.preferredColorScheme, expectedScheme)
                XCTAssertEqual(restarted.isPureBlack, expectedPureBlack)
            }
        }
    }

    @MainActor func testPrimaryBackgroundResolvesLightDarkAndPureBlack() {
        let background = UIColor(Theme.Colors.backgroundPrimary)
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        let pureBlack = UITraitCollection { traits in
            traits.userInterfaceStyle = .dark
            PureBlackEnvironmentKey.write(to: &traits, value: true)
        }

        assertRGB(background.resolvedColor(with: light), red: 249, green: 248, blue: 252)
        assertRGB(background.resolvedColor(with: dark), red: 8, green: 13, blue: 21)
        assertRGB(background.resolvedColor(with: pureBlack), red: 0, green: 0, blue: 0)
        // The same dynamic color must return to normal dark after Pure Black.
        assertRGB(background.resolvedColor(with: dark), red: 8, green: 13, blue: 21)
    }

    @MainActor private func withCleanAppearanceDefaults(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: "appearanceMode")
        defer {
            if let original { defaults.set(original, forKey: "appearanceMode") }
            else { defaults.removeObject(forKey: "appearanceMode") }
        }
        defaults.removeObject(forKey: "appearanceMode")
        body()
    }

    private func assertRGB(
        _ color: UIColor, red expectedRed: CGFloat, green expectedGreen: CGFloat,
        blue expectedBlue: CGFloat, file: StaticString = #filePath, line: UInt = #line
    ) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha), file: file, line: line)
        XCTAssertEqual(red * 255, expectedRed, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(green * 255, expectedGreen, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(blue * 255, expectedBlue, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(alpha, 1, accuracy: 0.01, file: file, line: line)
    }
}

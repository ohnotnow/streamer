import AppKit
import XCTest
@testable import Streamer

final class MenuBarIconTests: XCTestCase {
    let states: [MenuBarIcon.State] = [.off, .ready, .onAir]

    /// A template image at the menubar's size, so it recolours with the bar and does not get scaled.
    func testIconsAreMenubarTemplates() {
        for state in states {
            let image = MenuBarIcon.image(state)
            XCTAssertTrue(image.isTemplate)
            XCTAssertEqual(image.size, MenuBarIcon.size)
            XCTAssertFalse(image.accessibilityDescription?.isEmpty ?? true)
        }
    }

    /// Each state must look and read differently, or the icon cannot tell them apart.
    func testStatesDrawAndReadDifferently() throws {
        let drawings = try states.map { try XCTUnwrap(MenuBarIcon.image($0).tiffRepresentation) }
        XCTAssertEqual(Set(drawings).count, states.count)
        let descriptions = states.map { MenuBarIcon.image($0).accessibilityDescription }
        XCTAssertEqual(Set(descriptions).count, states.count)
    }
}

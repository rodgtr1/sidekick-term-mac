import XCTest
import Cocoa
@testable import Sidekick

final class FontZoomTests: XCTestCase {
    override func tearDown() {
        FontZoom.shared.reset()
        super.tearDown()
    }

    func testZoomInStepsAndClampsAtMax() {
        FontZoom.shared.reset()
        for _ in 0..<50 { FontZoom.shared.zoomIn() }
        XCTAssertEqual(FontZoom.shared.scale, 4.0, accuracy: 0.0001)
    }

    func testZoomOutStepsAndClampsAtMin() {
        FontZoom.shared.reset()
        for _ in 0..<50 { FontZoom.shared.zoomOut() }
        XCTAssertEqual(FontZoom.shared.scale, 0.4, accuracy: 0.0001)
    }

    func testResetReturnsToOne() {
        FontZoom.shared.zoomIn()
        FontZoom.shared.zoomIn()
        FontZoom.shared.reset()
        XCTAssertEqual(FontZoom.shared.scale, 1.0, accuracy: 0.0001)
    }

    func testZoomPostsChangeNotification() {
        FontZoom.shared.reset()
        let expectation = expectation(forNotification: FontZoom.didChangeNotification, object: nil)
        FontZoom.shared.zoomIn()
        wait(for: [expectation], timeout: 1)
    }
}

final class KeyboardCommandRouterZoomTests: XCTestCase {
    private let router = KeyboardCommandRouter()

    private func keyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private func route(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) -> KeyboardCommand? {
        guard let event = keyDown(keyCode: keyCode, modifiers: modifiers) else {
            XCTFail("Could not construct key event")
            return nil
        }
        return router.command(for: event, tabCount: 3)
    }

    func testCmdEqualsZoomsIn() {
        XCTAssertEqual(route(24, [.command]), .zoomIn)
    }

    func testCmdShiftEqualsAlsoZoomsIn() {
        XCTAssertEqual(route(24, [.command, .shift]), .zoomIn)
    }

    func testCmdMinusZoomsOut() {
        XCTAssertEqual(route(27, [.command]), .zoomOut)
    }

    func testCmdZeroResetsZoom() {
        XCTAssertEqual(route(29, [.command]), .zoomReset)
    }

    func testCmdVRoutesToImageAwarePaste() {
        XCTAssertEqual(route(9, [.command]), .pasteIntoTerminal)
    }

    func testCmdDigitsMapToCorrectTabs() {
        // ANSI keycodes are non-contiguous; verify the explicit mapping.
        let expected: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5, 26: 6, 28: 7, 25: 8]
        for (keyCode, tabIndex) in expected {
            guard let event = keyDown(keyCode: keyCode, modifiers: [.command]) else {
                XCTFail("Could not construct key event"); return
            }
            XCTAssertEqual(
                router.command(for: event, tabCount: 9),
                .selectTab(tabIndex),
                "keyCode \(keyCode) should select tab \(tabIndex)"
            )
        }
    }

    func testCmdDigitBeyondTabCountIsIgnored() {
        XCTAssertNil(route(25, [.command])) // Cmd+9 with only 3 tabs
    }

    func testPlainKeysAreNotIntercepted() {
        XCTAssertNil(route(24, []))
        XCTAssertNil(route(9, []))
    }
}

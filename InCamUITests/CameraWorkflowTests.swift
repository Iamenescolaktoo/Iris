import XCTest

final class CustomColorsNavigationTests: XCTestCase {
    func testCCTapOpensFiveSlots() {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launchArguments = ["-incam.orientationLock", "Landscape Right", "--show-color-mix"]
        app.launch()
        let cc = app.buttons["colorDock.openCustomColors"]
        XCTAssertTrue(cc.waitForExistence(timeout: 10))
        XCTAssertTrue(cc.isHittable)
        cc.tap()
        XCTAssertTrue(app.buttons["customColors.slot.0"].waitForExistence(timeout: 3))
        for index in 0..<5 { XCTAssertTrue(app.buttons["customColors.slot.\(index)"].exists) }
    }
}

final class ColorDockSelectionTests: XCTestCase {
    func testDockTapsOpenMatchingAdjustmentWithoutChangingValues() {
        continueAfterFailure = false
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launchArguments = ["-incam.orientationLock", "Landscape Right"]
        app.launch()

        XCTAssertTrue(app.buttons["colorDock.Contrast"].waitForExistence(timeout: 10))
        if app.alerts["Camera"].waitForExistence(timeout: 2) { app.alerts["Camera"].buttons["OK"].tap() }
        let sections = ["Tint", "Saturation", "Contrast", "Color Mix"]
        let initialValues = sections.map { app.buttons["colorDock.\($0)"].value as? String }
        let title = app.staticTexts["colorDock.adjustmentTitle"]
        for section in ["Contrast", "Tint", "Saturation", "Color Mix", "Color Mix", "Tint"] {
            app.buttons["colorDock.\(section)"].tap()
            XCTAssertTrue(title.waitForExistence(timeout: 3))
            XCTAssertEqual(title.label, section == "Color Mix" ? "Camera Colors" : section)
            XCTAssertTrue(app.buttons["colorDock.\(section)"].isSelected)
            XCTAssertEqual(sections.map { app.buttons["colorDock.\($0)"].value as? String }, initialValues)
        }

        app.buttons["status.wb"].tap()
        XCTAssertTrue(app.staticTexts["controls.pageTitle"].waitForExistence(timeout: 3))
        XCTAssertFalse(title.exists, "Opening WB closes the color inspector")
        app.buttons["colorDock.Color Mix"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["controls.pageTitle"].exists, "Opening color closes the camera inspector")
        for axis in ["Hue", "Saturation", "Luminance"] {
            app.buttons["colorDock.selectAxis.\(axis)"].tap()
            let option = app.descendants(matching: .any)["colorDock.axis.\(axis)"].firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 3))
            XCTAssertTrue(option.isHittable)
            option.swipeRight()
        }
        let colorPages = app.descendants(matching: .any)["colorDock.colorPages"].firstMatch
        XCTAssertTrue(colorPages.exists)
        colorPages.swipeUp()
        colorPages.swipeDown()
        XCTAssertLessThan(app.buttons["status.wb"].frame.midY, app.frame.height * 0.25)
        let focus = app.buttons["focus.toggle"]
        XCTAssertEqual(app.buttons.matching(identifier: "focus.toggle").count, 1)
        let initialMode = focus.value as? String
        focus.tap()
        XCTAssertNotEqual(focus.value as? String, initialMode)
        focus.tap()
        XCTAssertEqual(focus.value as? String, initialMode)
        if focus.value as? String == "AF" { focus.tap() }
        let manualRuler = app.descendants(matching: .any)["focus.manualRuler"].firstMatch
        XCTAssertTrue(manualRuler.waitForExistence(timeout: 3))
        XCTAssertTrue(manualRuler.isHittable)
        XCTAssertFalse(title.exists)
        focus.tap()
        XCTAssertFalse(manualRuler.exists)
    }

    func testSlowZoomHoldStopsOnRelease() {
        continueAfterFailure = false
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launchArguments = ["-incam.orientationLock", "Landscape Right"]
        app.launch()
        if app.alerts["Camera"].waitForExistence(timeout: 3) { app.alerts["Camera"].buttons["OK"].tap() }
        let dismiss = app.descendants(matching: .any)["controls.dismissOutside"].firstMatch
        if dismiss.exists { dismiss.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.45)).tap() }
        let plus = app.buttons["zoom.plus"]
        XCTAssertTrue(plus.waitForExistence(timeout: 5))
        func amount() -> Double { Double((plus.value as? String ?? "").replacingOccurrences(of: "×", with: "")) ?? -100 }
        let initial = amount()
        plus.press(forDuration: 2.2)
        XCTAssertEqual(amount(), initial + 0.3, accuracy: 0.051)
        let released = amount()
        let stable = expectation(description: "Zoom stays stopped after release")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { stable.fulfill() }
        wait(for: [stable], timeout: 2)
        XCTAssertEqual(amount(), released, accuracy: 0.001)
    }
}

final class CompactSelectorTests: XCTestCase {
    func testShutterModesAndExposureBounds() {
        continueAfterFailure = false
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launchArguments = ["-incam.orientationLock", "Landscape Right", "--show-shutter"]
        app.launch()
        if app.alerts["Camera"].waitForExistence(timeout: 2) { app.alerts["Camera"].buttons["OK"].tap() }
        let mode = app.buttons["controls.shutterMode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 8))
        XCTAssertEqual(mode.value as? String, "Speed")
        mode.tap()
        XCTAssertEqual(mode.value as? String, "Angle")
        let ruler = app.descendants(matching: .any)["controls.ruler"].firstMatch
        XCTAssertTrue(ruler.exists)
        ruler.swipeUp()
        XCTAssertTrue((ruler.value as? String ?? "").contains("°"))
        mode.tap()
        XCTAssertEqual(mode.value as? String, "Speed")
        ruler.swipeUp()
        let fraction = ruler.value as? String ?? ""
        XCTAssertTrue(["1/24", "1/25", "1/30", "1/48", "1/50", "1/60", "1/96", "1/100", "1/120", "1/125", "1/180", "1/200", "1/240", "1/250", "1/500", "1/1000", "1/1500"].contains(fraction), fraction)
        app.terminate()
        app.launchArguments = ["-incam.orientationLock", "Landscape Right", "--show-exposure"]
        app.launch()
        let plus = app.buttons["exposure.increase"]
        XCTAssertTrue(plus.waitForExistence(timeout: 8))
        plus.tap(); plus.tap()
        let exposure = app.descendants(matching: .any)["exposure.dial"].firstMatch
        XCTAssertTrue((exposure.value as? String ?? "").contains("+0.3"))
        let minus = app.buttons["exposure.decrease"]
        minus.tap(); minus.tap(); minus.tap()
        XCTAssertTrue((exposure.value as? String ?? "").contains("-0.3"))
    }

    func testDirectionalChoicesUpdateAndCollapse() {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launchArguments = ["-incam.orientationLock", "Landscape Right", "-incam.screen.framing", "YES"]
        app.launch()
        let ratio = app.buttons["framing.choose"]
        XCTAssertTrue(ratio.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["controls.open"].exists)
        XCTAssertFalse(app.buttons["framing.ratio.16:9"].exists)
        ratio.tap()
        let square = app.buttons["framing.ratio.1:1"]
        let wide = app.buttons["framing.ratio.16:9"]
        XCTAssertTrue(wide.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(square.frame.minY, wide.frame.maxY)
        wide.tap()
        XCTAssertEqual(ratio.value as? String, "16:9")
        XCTAssertFalse(wide.exists)
        ratio.tap()
        XCTAssertFalse(wide.exists, "The selected ratio stays in the main highlighted button")
        app.buttons["framing.ratio.4:3"].tap()

        XCTAssertFalse(app.buttons["lens.choose"].exists, "Video shows only zoom in the accessory slot")
        let zoom = app.descendants(matching: .any)["zoom.touch"].firstMatch
        XCTAssertTrue(zoom.exists)
        let zoomFrame = zoom.frame
        app.buttons["camera.mode"].tap()
        XCTAssertEqual(app.buttons["camera.mode"].value as? String, "Photo")
        let lens = app.buttons["lens.choose"]
        XCTAssertTrue(lens.waitForExistence(timeout: 3))
        XCTAssertFalse(zoom.exists)
        XCTAssertEqual(lens.frame.midX, zoomFrame.midX, accuracy: 3)
        XCTAssertTrue(lens.isHittable)
        XCTAssertGreaterThan(lens.frame.minX, app.buttons["camera.capture"].frame.maxX)
        lens.tap()
        let ultra = app.buttons["lens.option.demo.ultra"]
        let tele = app.buttons["lens.option.demo.tele"]
        XCTAssertTrue(ultra.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(tele.frame.minY, ultra.frame.maxY)
        ultra.tap()
        XCTAssertEqual(lens.value as? String, "13 mm")
        XCTAssertFalse(tele.exists)
        lens.tap()
        XCTAssertFalse(ultra.exists, "The selected lens stays in the highlighted main button")
        app.buttons["lens.option.demo.wide"].tap()
        XCTAssertEqual(lens.value as? String, "26 mm")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

final class CameraWorkflowTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        app = XCUIApplication()
        app.launchArguments = ["-incam.controls.layout", "Floating box", "-incam.orientationLock", "Landscape Right",
                               "-incam.screen.controls", "YES", "-incam.screen.quickRow", "NO"]
        app.launch()
        XCTAssertTrue(app.buttons["controls.open"].waitForExistence(timeout: 10))
    }

    func testSwipeSettingsAndAdjustWithoutSwitchingPage() {
        app.buttons["controls.open"].tap()
        let title = app.staticTexts["controls.pageTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        XCTAssertEqual(title.label, "White Balance")
        XCTAssertFalse(app.buttons["White balance mode"].exists)
        XCTAssertFalse(app.buttons["controls.tab.0"].exists)
        let status = app.staticTexts["controls.autoStatus"]
        XCTAssertEqual(status.label, "AUTO")
        title.doubleTap()
        XCTAssertEqual(status.label, "")
        title.doubleTap()
        XCTAssertEqual(status.label, "AUTO")

        swipeTitle(left: true)
        XCTAssertEqual(title.label, "Tint")
        let ruler = app.descendants(matching: .any)["controls.ruler"].firstMatch
        let before = ruler.value as? String
        let start = ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: ruler.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)))
        XCTAssertNotEqual(ruler.value as? String, before)
        XCTAssertEqual(title.label, "Tint")
        swipeTitle(left: false)
        XCTAssertEqual(title.label, "White Balance")
        XCTAssertTrue(app.staticTexts["5600 K"].exists, "Adjusting tint must preserve temperature")

        for expected in ["Tint", "Shutter", "ISO", "FPS", "Camera Color"] {
            app.buttons["Next setting"].tap()
            XCTAssertEqual(title.label, expected)
        }
        app.buttons["Previous setting"].tap()
        XCTAssertEqual(title.label, "FPS")
        XCTAssertTrue(app.staticTexts["30 FPS"].exists, "Browsing controls must not change the capture rate")
        snapshot("Floating FPS controls")
        app.buttons["controls.close"].tap()
        XCTAssertFalse(title.exists)
        app.buttons["controls.open"].tap()
        app.buttons["Previous setting"].tap()
        XCTAssertEqual(title.label, "ISO")
        snapshot("Floating ISO controls")
    }

    func testMoveBoxAndOrientationLock() {
        app.buttons["controls.open"].tap()
        let title = app.staticTexts["controls.pageTitle"]
        let before = title.frame
        let handle = app.descendants(matching: .any)["controls.dragHandle"].firstMatch
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: -110, dy: 0)))
        XCTAssertLessThan(title.frame.minX, before.minX - 30)
        let capture = app.buttons["camera.capture"]
        XCTAssertFalse(title.frame.intersects(capture.frame))
        snapshot("Moved floating box")

        chooseOrientation("Portrait")
        XCTAssertTrue(waitForLayout(portrait: true))
        XCTAssertEqual(app.buttons["camera.orientationLock"].value as? String, "Portrait")
        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(waitForLayout(portrait: true))
        XCTAssertTrue(title.isHittable)
        XCTAssertTrue(app.buttons["controls.close"].isHittable)
        snapshot("Portrait orientation lock")

        chooseOrientation("Landscape Left")
        XCTAssertTrue(waitForLayout(portrait: false))
        XCTAssertEqual(app.buttons["camera.orientationLock"].value as? String, "Landscape Left")
        snapshot("Landscape left orientation lock")

        chooseOrientation("Unlocked")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitForLayout(portrait: true))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForLayout(portrait: false))
        chooseOrientation("Landscape Right")
    }

    func testBottomDockOption() {
        // Launch without the layout override so Settings can persist a new value.
        app.terminate()
        app.launchArguments = ["-incam.orientationLock", "Landscape Right"]
        app.launch()
        app.buttons["Settings"].tap()
        app.buttons["settings.controlLayout"].tap()
        app.buttons["Bottom dock"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        if app.buttons["Done"].waitForExistence(timeout: 2) { app.buttons["Done"].tap() }
        app.buttons["controls.open"].tap()
        XCTAssertTrue(app.staticTexts["controls.pageTitle"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["controls.dragHandle"].firstMatch.exists)
        snapshot("Bottom dock option")
    }

    func testRampZoomStopsOnRelease() {
        app.buttons["zoom.open"].tap()
        XCTAssertEqual(app.staticTexts["controls.pageTitle"].label, "Zoom")
        let rocker = app.descendants(matching: .any)["zoom.rocker"].firstMatch
        XCTAssertGreaterThan(rocker.frame.height, rocker.frame.width, "Zoom must be vertical")
        XCTAssertFalse(rocker.frame.intersects(app.buttons["camera.capture"].frame), "Zoom must stay separate from Record")
        XCTAssertTrue(app.buttons["framing.ratio.4:3"].exists)
        let start = rocker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let initial = app.staticTexts["zoom.value"].label
        start.press(forDuration: 0.1,
                    thenDragTo: rocker.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)),
                    withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertEqual(app.staticTexts["zoom.value"].label, initial, "Horizontal movement must not zoom")
        start.press(forDuration: 0.1,
                    thenDragTo: rocker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)),
                    withVelocity: .slow, thenHoldForDuration: 0.7)
        let zoomed = app.staticTexts["zoom.value"].label
        XCTAssertNotEqual(initial, zoomed)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(app.staticTexts["zoom.value"].label, zoomed, "Zoom must stop on release")
        start.press(forDuration: 0.1,
                    thenDragTo: rocker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)),
                    withVelocity: .slow, thenHoldForDuration: 0.7)
        let afterOut = app.staticTexts["zoom.value"].label
        XCTAssertNotEqual(afterOut, zoomed)
        snapshot("Vertical ramp zoom")
        app.buttons["controls.close"].tap()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(app.buttons["zoom.open"].label, "Zoom controls")
        snapshot("Ramp zoom and ratio shortcuts")
    }

    func testScreenOptionsAndRatios() {
        XCTAssertFalse(app.staticTexts["Custom Button 1"].exists)
        XCTAssertFalse(app.staticTexts["Custom Button 2"].exists)
        XCTAssertTrue(app.buttons["framing.ratio.4:3"].exists)
        XCTAssertTrue(app.buttons["framing.ratio.16:9"].exists)
        XCTAssertTrue(app.buttons["framing.ratio.1:1"].exists)
        app.buttons["framing.ratio.16:9"].tap()
        XCTAssertTrue(app.buttons["framing.ratio.16:9"].isSelected)
        app.buttons["Settings"].tap()
        let framing = app.switches["settings.framingGuide"]
        if !framing.isHittable { app.swipeUp() }
        XCTAssertTrue(framing.waitForExistence(timeout: 2))
        framing.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(framing.value as? String, "0")
        app.buttons["Done"].tap()
        let guideHidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                    object: app.buttons["framing.ratio.4:3"])
        XCTAssertEqual(XCTWaiter.wait(for: [guideHidden], timeout: 3), .completed)
        XCTAssertFalse(app.buttons["framing.ratio.16:9"].exists)
        app.buttons["Settings"].tap()
        if !framing.isHittable { app.swipeUp() }
        framing.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(framing.value as? String, "1")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["framing.ratio.16:9"].waitForExistence(timeout: 3))
        snapshot("Configurable framing guide")
    }

    func testLensSelectorBesideRecord() {
        let wide = app.buttons["lens.option.demo.wide"]
        let ultra = app.buttons["lens.option.demo.ultra"]
        let tele = app.buttons["lens.option.demo.tele"]
        XCTAssertTrue(wide.waitForExistence(timeout: 3))
        XCTAssertTrue(wide.isSelected)
        for lens in [wide, ultra, tele] {
            XCTAssertTrue(lens.isHittable)
            XCTAssertFalse(lens.frame.intersects(app.buttons["camera.capture"].frame))
        }
        ultra.tap()
        XCTAssertTrue(ultra.isSelected)
        tele.tap()
        XCTAssertTrue(tele.isSelected)
        app.buttons["zoom.open"].tap()
        XCTAssertEqual(app.staticTexts["zoom.value"].label, "1.0×", "Changing lens resets its digital zoom")
        snapshot("Millimetre lens selector and vertical zoom")
    }

    func testTopReadoutsOpenSharedControls() {
        for (id, title, value) in [("wb", "White Balance", "5600 K"), ("shutter", "Shutter", "1/48"), ("iso", "ISO", "100")] {
            let readout = app.buttons["status.\(id)"]
            XCTAssertTrue(readout.isHittable)
            XCTAssertEqual(readout.value as? String, value)
            XCTAssertFalse(readout.frame.intersects(app.buttons["framing.ratio.4:3"].frame))
            readout.tap()
            XCTAssertEqual(app.staticTexts["controls.pageTitle"].label, title)
            XCTAssertEqual(app.buttons.matching(identifier: "controls.close").count, 1)
            app.buttons["controls.close"].tap()
        }
        snapshot("Top camera readouts and round lenses")
    }

    private func swipeTitle(left: Bool) {
        let title = app.staticTexts["controls.pageTitle"]
        let start = title.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.85 : 0.15, dy: 0.5))
        let end = title.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.15 : 0.85, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func chooseOrientation(_ name: String) {
        app.buttons["camera.orientationLock"].tap()
        let option = app.buttons[name]
        XCTAssertTrue(option.waitForExistence(timeout: 2))
        option.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func waitForLayout(portrait: Bool) -> Bool {
        let predicate = NSPredicate { _, _ in
            let frame = self.app.windows.firstMatch.frame
            return portrait ? frame.height > frame.width : frame.width > frame.height
        }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 5) == .completed
    }

    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

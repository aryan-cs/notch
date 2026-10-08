//
//  WindowSnapLayoutTests.swift
//  NotchTests
//
//  SPDX-License-Identifier: GPL-3.0-only
//
//  Window snapping's geometry: the frame each layout gives a window, the
//  flip into the Accessibility API's coordinates, hit-testing the picker's
//  tiles, and the zones around the notch that open and hold the picker.
//

import AppKit
import XCTest
@testable import Notch

final class WindowSnapLayoutTests: XCTestCase {

    /// A 14" MacBook Pro: 1512×982 points, 37-point menu bar, 64-point Dock.
    private let laptopScreen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let laptopVisible = CGRect(x: 0, y: 64, width: 1512, height: 881)

    // MARK: - Layout frames

    func testHalvesThirdsAndFillOnALaptop() {
        XCTAssertEqual(SnapLayout.leftHalf.frame(in: laptopVisible), CGRect(x: 0, y: 64, width: 756, height: 881))
        XCTAssertEqual(SnapLayout.rightHalf.frame(in: laptopVisible), CGRect(x: 756, y: 64, width: 756, height: 881))
        XCTAssertEqual(SnapLayout.maximize.frame(in: laptopVisible), laptopVisible)
        XCTAssertEqual(SnapLayout.leftThird.frame(in: laptopVisible), CGRect(x: 0, y: 64, width: 504, height: 881))
        XCTAssertEqual(SnapLayout.centerThird.frame(in: laptopVisible), CGRect(x: 504, y: 64, width: 504, height: 881))
        XCTAssertEqual(SnapLayout.rightThird.frame(in: laptopVisible), CGRect(x: 1008, y: 64, width: 504, height: 881))
    }

    func testQuartersSplitAnOddHeightWithoutAGap() {
        // 881 doesn't halve evenly; the rows still meet and fill it.
        let topLeft = SnapLayout.topLeftQuarter.frame(in: laptopVisible)
        let bottomLeft = SnapLayout.bottomLeftQuarter.frame(in: laptopVisible)
        let topRight = SnapLayout.topRightQuarter.frame(in: laptopVisible)
        let bottomRight = SnapLayout.bottomRightQuarter.frame(in: laptopVisible)

        // Top means high y in AppKit: the top row hugs the menu bar.
        XCTAssertEqual(topLeft.maxY, laptopVisible.maxY)
        XCTAssertEqual(bottomLeft.minY, laptopVisible.minY)
        XCTAssertEqual(topLeft.minY, bottomLeft.maxY)
        XCTAssertEqual(topLeft.height + bottomLeft.height, laptopVisible.height)
        XCTAssertEqual(topLeft.maxX, topRight.minX)
        XCTAssertEqual(topRight.maxX, laptopVisible.maxX)
        XCTAssertEqual(bottomRight, CGRect(x: 756, y: bottomLeft.minY, width: 756, height: bottomLeft.height))
        for frame in [topLeft, bottomLeft, topRight, bottomRight] {
            XCTAssertEqual(frame, frame.integral, "\(frame) should sit on whole points")
        }
    }

    func testUnevenThirdsMeetOnWholePoints() {
        let visible = CGRect(x: 0, y: 0, width: 2560, height: 1415)
        let left = SnapLayout.leftThird.frame(in: visible)
        let center = SnapLayout.centerThird.frame(in: visible)
        let right = SnapLayout.rightThird.frame(in: visible)

        XCTAssertEqual(left, CGRect(x: 0, y: 0, width: 853, height: 1415))
        XCTAssertEqual(center, CGRect(x: 853, y: 0, width: 854, height: 1415))
        XCTAssertEqual(right, CGRect(x: 1707, y: 0, width: 853, height: 1415))
    }

    func testLayoutsOnADisplayLeftOfThePrimary() {
        // Negative x: a display arranged to the left, its Dock on the left too.
        let visible = CGRect(x: -1850, y: 0, width: 1850, height: 1055)
        XCTAssertEqual(SnapLayout.leftHalf.frame(in: visible), CGRect(x: -1850, y: 0, width: 925, height: 1055))
        XCTAssertEqual(SnapLayout.rightHalf.frame(in: visible), CGRect(x: -925, y: 0, width: 925, height: 1055))
        XCTAssertEqual(SnapLayout.rightHalf.frame(in: visible).maxX, 0)
    }

    func testEveryLayoutStaysInsideTheVisibleFrame() {
        let visibles = [
            laptopVisible,
            CGRect(x: 0, y: 0, width: 2560, height: 1415),
            CGRect(x: -1850, y: 0, width: 1850, height: 1055),
            CGRect(x: 1512, y: -340, width: 1727, height: 1093)
        ]
        for visible in visibles {
            for layout in SnapLayout.allCases {
                let frame = layout.frame(in: visible)
                XCTAssertTrue(visible.contains(frame), "\(layout) escapes \(visible): \(frame)")
                XCTAssertGreaterThan(frame.width, 0)
                XCTAssertGreaterThan(frame.height, 0)
            }
        }
    }

    // MARK: - Coordinate flip

    func testFlipPutsAWindowUnderTheMenuBarOnThePrimaryDisplay() {
        let appKit = SnapLayout.leftHalf.frame(in: laptopVisible)
        let accessibility = ScreenCoordinates.flip(appKit, primaryScreenHeight: laptopScreen.height)
        // Top-left origin: the window's top edge is the 37-point menu bar.
        XCTAssertEqual(accessibility, CGRect(x: 0, y: 37, width: 756, height: 881))
    }

    func testFlipOnDisplaysAboveAndBelowThePrimary() {
        // Above: AppKit y past the primary's top becomes negative.
        let aboveVisible = CGRect(x: -200, y: 982, width: 2560, height: 1415)
        XCTAssertEqual(
            ScreenCoordinates.flip(SnapLayout.maximize.frame(in: aboveVisible), primaryScreenHeight: 982),
            CGRect(x: -200, y: -1415, width: 2560, height: 1415)
        )

        // Below: negative AppKit y lands past the primary's bottom.
        let belowVisible = CGRect(x: 0, y: -1080, width: 1920, height: 1055)
        XCTAssertEqual(
            ScreenCoordinates.flip(SnapLayout.topLeftQuarter.frame(in: belowVisible), primaryScreenHeight: 982),
            CGRect(x: 0, y: 1007, width: 960, height: 528)
        )
    }

    func testFlipUndoesItself() {
        let rect = CGRect(x: -300, y: 1200, width: 640, height: 480)
        let point = CGPoint(x: 42, y: -17)
        XCTAssertEqual(ScreenCoordinates.flip(ScreenCoordinates.flip(rect, primaryScreenHeight: 982), primaryScreenHeight: 982), rect)
        XCTAssertEqual(ScreenCoordinates.flip(ScreenCoordinates.flip(point, primaryScreenHeight: 982), primaryScreenHeight: 982), point)
        XCTAssertEqual(ScreenCoordinates.flip(CGPoint(x: 10, y: 982), primaryScreenHeight: 982), CGPoint(x: 10, y: 0))
    }

    // MARK: - Picker grid

    func testEveryLayoutHasOneTileAndTheTilesDontOverlap() {
        let listed = SnapPickerGrid.rows.flatMap { $0 }
        XCTAssertEqual(listed.count, SnapLayout.allCases.count)
        XCTAssertEqual(Set(listed), Set(SnapLayout.allCases))

        let bounds = CGRect(origin: .zero, size: SnapPickerGrid.size)
        let frames = SnapLayout.allCases.compactMap { SnapPickerGrid.tileFrames[$0] }
        XCTAssertEqual(frames.count, SnapLayout.allCases.count)
        for (index, frame) in frames.enumerated() {
            XCTAssertTrue(bounds.contains(frame), "\(frame) outside \(bounds)")
            for other in frames[(index + 1)...] {
                XCTAssertFalse(frame.intersects(other), "\(frame) overlaps \(other)")
            }
        }
    }

    func testThePickerFitsTheOpenNotch() {
        // Open notch content: 640 wide less 2 × (19 + 12) padding; 190 tall
        // less the 38-point header, 8-point spacing and 12-point padding.
        XCTAssertLessThanOrEqual(SnapPickerGrid.size.width, openNotchSize.width - 2 * (19 + 12))
        XCTAssertLessThanOrEqual(SnapPickerGrid.size.height, openNotchSize.height - 38 - 8 - 12)
    }

    func testEachTileIsHitAtItsCenter() {
        for layout in SnapLayout.allCases {
            let frame = try? XCTUnwrap(SnapPickerGrid.tileFrames[layout])
            guard let frame else { return }
            XCTAssertEqual(SnapPickerGrid.layout(at: CGPoint(x: frame.midX, y: frame.midY)), layout)
            XCTAssertEqual(SnapPickerGrid.layout(at: CGPoint(x: frame.minX + 1, y: frame.minY + 1)), layout)
            XCTAssertEqual(SnapPickerGrid.layout(at: CGPoint(x: frame.maxX - 1, y: frame.maxY - 1)), layout)
        }
    }

    func testGapsBelongToTheNearerTile() throws {
        let leftHalf = try XCTUnwrap(SnapPickerGrid.tileFrames[.leftHalf])
        let maximize = try XCTUnwrap(SnapPickerGrid.tileFrames[.maximize])
        let rightHalf = try XCTUnwrap(SnapPickerGrid.tileFrames[.rightHalf])
        let topLeft = try XCTUnwrap(SnapPickerGrid.tileFrames[.topLeftQuarter])
        let leftThird = try XCTUnwrap(SnapPickerGrid.tileFrames[.leftThird])

        // Between two neighbours in a row.
        let gapMiddle = (leftHalf.maxX + maximize.minX) / 2
        XCTAssertEqual(SnapPickerGrid.layout(at: CGPoint(x: gapMiddle - 0.5, y: leftHalf.midY)), .leftHalf)
        XCTAssertEqual(SnapPickerGrid.layout(at: CGPoint(x: gapMiddle + 0.5, y: leftHalf.midY)), .maximize)

        // Across the wider gap before the quarters.
        let groupMiddle = (rightHalf.maxX + topLeft.minX) / 2
        XCTAssertGreaterThan(topLeft.minX - rightHalf.maxX, maximize.minX - leftHalf.maxX)
        XCTAssertEqual(SnapPickerGrid.layout(at: CGPoint(x: groupMiddle - 0.5, y: topLeft.midY)), .rightHalf)
        XCTAssertEqual(SnapPickerGrid.layout(at: CGPoint(x: groupMiddle + 0.5, y: topLeft.midY)), .topLeftQuarter)

        // Between the rows.
        let rowMiddle = (leftHalf.maxY + leftThird.minY) / 2
        XCTAssertEqual(SnapPickerGrid.layout(at: CGPoint(x: leftHalf.midX, y: rowMiddle - 0.5)), .leftHalf)
        XCTAssertEqual(SnapPickerGrid.layout(at: CGPoint(x: leftHalf.midX, y: rowMiddle + 0.5)), .leftThird)
    }

    func testPointsPastHalfAGapOutsideTheGridHitNothing() {
        let size = SnapPickerGrid.size
        let margin = SnapPickerGrid.spacing / 2
        XCTAssertNil(SnapPickerGrid.layout(at: CGPoint(x: -margin - 1, y: size.height / 4)))
        XCTAssertNil(SnapPickerGrid.layout(at: CGPoint(x: size.width + margin + 1, y: size.height / 4)))
        XCTAssertNil(SnapPickerGrid.layout(at: CGPoint(x: size.width / 4, y: -margin - 1)))
        XCTAssertNil(SnapPickerGrid.layout(at: CGPoint(x: size.width / 4, y: size.height + margin + 1)))
        XCTAssertEqual(SnapPickerGrid.layout(at: CGPoint(x: -margin + 1, y: 10)), .leftHalf)
    }

    func testScreenPointsMapOntoTilesThroughTheGridsScreenFrame() throws {
        let size = SnapPickerGrid.size
        // AppKit: the grid's top edge is its maxY.
        let gridFrame = CGRect(x: 494, y: 800, width: size.width, height: size.height)
        let leftHalf = try XCTUnwrap(SnapPickerGrid.tileFrames[.leftHalf])
        let bottomRight = try XCTUnwrap(SnapPickerGrid.tileFrames[.bottomRightQuarter])

        func screenPoint(_ tile: CGRect, in frame: CGRect) -> CGPoint {
            let scale = frame.width / size.width
            return CGPoint(x: frame.minX + tile.midX * scale, y: frame.maxY - tile.midY * scale)
        }

        XCTAssertEqual(SnapPickerGrid.layout(at: screenPoint(leftHalf, in: gridFrame), gridScreenFrame: gridFrame), .leftHalf)
        XCTAssertEqual(SnapPickerGrid.layout(at: screenPoint(bottomRight, in: gridFrame), gridScreenFrame: gridFrame), .bottomRightQuarter)

        // Caught mid-animation at 80%: still the same tiles.
        let shrunk = CGRect(x: 520, y: 820, width: size.width * 0.8, height: size.height * 0.8)
        XCTAssertEqual(SnapPickerGrid.layout(at: screenPoint(leftHalf, in: shrunk), gridScreenFrame: shrunk), .leftHalf)
        XCTAssertEqual(SnapPickerGrid.layout(at: screenPoint(bottomRight, in: shrunk), gridScreenFrame: shrunk), .bottomRightQuarter)

        XCTAssertNil(SnapPickerGrid.layout(at: CGPoint(x: 100, y: 100), gridScreenFrame: gridFrame))
        XCTAssertNil(SnapPickerGrid.layout(at: CGPoint(x: 600, y: 850), gridScreenFrame: .zero))
    }

    // MARK: - Zones

    func testTriggerNeedsTheCursorUpInTheMenuBarNearTheNotch() {
        let trigger = SnapZones.trigger(
            screenFrame: laptopScreen,
            closedNotchSize: CGSize(width: 185, height: 32),
            menuBarHeight: 37
        )
        // Pinned against the top edge, AppKit reports y == maxY.
        XCTAssertTrue(trigger.contains(CGPoint(x: 756, y: 982)))
        XCTAssertTrue(trigger.contains(CGPoint(x: 756, y: 982 - 37)))
        XCTAssertTrue(trigger.contains(CGPoint(x: 756 + 150, y: 970)))
        // A window parked under the menu bar holds its cursor lower than this.
        XCTAssertFalse(trigger.contains(CGPoint(x: 756, y: 982 - 50)))
        // Well off to the side of the notch.
        XCTAssertFalse(trigger.contains(CGPoint(x: 300, y: 975)))
        XCTAssertFalse(trigger.contains(CGPoint(x: 1300, y: 975)))
    }

    func testTriggerFollowsTheScreen() {
        let external = CGRect(x: 1512, y: -340, width: 2560, height: 1440)
        let trigger = SnapZones.trigger(screenFrame: external, closedNotchSize: CGSize(width: 185, height: 24), menuBarHeight: 24)
        XCTAssertEqual(trigger.midX, external.midX)
        XCTAssertTrue(trigger.contains(CGPoint(x: external.midX, y: external.maxY)))
        XCTAssertFalse(trigger.contains(CGPoint(x: 756, y: 982)))
    }

    func testRetainCoversTheOpenNotchWithAMargin() {
        let retain = SnapZones.retain(screenFrame: laptopScreen, openNotchSize: openNotchSize)
        let trigger = SnapZones.trigger(screenFrame: laptopScreen, closedNotchSize: CGSize(width: 185, height: 32), menuBarHeight: 37)
        XCTAssertTrue(retain.contains(trigger))
        XCTAssertTrue(retain.contains(CGPoint(x: 756, y: 982)))
        // The bottom row of tiles, and a little below the notch.
        XCTAssertTrue(retain.contains(CGPoint(x: 756, y: 982 - openNotchSize.height + 10)))
        XCTAssertTrue(retain.contains(CGPoint(x: 756, y: 982 - openNotchSize.height - 10)))
        XCTAssertFalse(retain.contains(CGPoint(x: 756, y: 982 - openNotchSize.height - 40)))
        XCTAssertFalse(retain.contains(CGPoint(x: 756 - openNotchSize.width / 2 - 40, y: 950)))
    }

    func testScreenLookupCountsATopEdgeUnlessAScreenSitsAboveIt() {
        let laptop = laptopScreen
        let rightOf = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(SnapZones.screenIndex(containing: CGPoint(x: 700, y: 500), in: [laptop, rightOf]), 0)
        XCTAssertEqual(SnapZones.screenIndex(containing: CGPoint(x: 700, y: 982), in: [laptop, rightOf]), 0)
        XCTAssertEqual(SnapZones.screenIndex(containing: CGPoint(x: 2000, y: 1080), in: [laptop, rightOf]), 1)
        XCTAssertNil(SnapZones.screenIndex(containing: CGPoint(x: 700, y: 1000), in: [laptop, rightOf]))

        // A display stacked on top owns the shared edge.
        let above = CGRect(x: 0, y: 982, width: 1512, height: 982)
        XCTAssertEqual(SnapZones.screenIndex(containing: CGPoint(x: 700, y: 982), in: [laptop, above]), 1)
        XCTAssertEqual(SnapZones.screenIndex(containing: CGPoint(x: 700, y: 1964), in: [laptop, above]), 1)
    }

    // MARK: - Drag detection

    func testWindowMotion() {
        let start = CGRect(x: 100, y: 200, width: 800, height: 600)
        XCTAssertEqual(WindowMotion(from: start, to: start), .unchanged)
        XCTAssertEqual(WindowMotion(from: start, to: start.offsetBy(dx: 0.2, dy: -0.3)), .unchanged)
        XCTAssertEqual(WindowMotion(from: start, to: start.offsetBy(dx: 12, dy: -40)), .moved)
        XCTAssertEqual(WindowMotion(from: start, to: start.offsetBy(dx: 0, dy: 3)), .moved)
        XCTAssertEqual(WindowMotion(from: start, to: CGRect(x: 100, y: 200, width: 820, height: 600)), .resized)
        // Dragging a top-left corner moves the origin too; still a resize.
        XCTAssertEqual(WindowMotion(from: start, to: CGRect(x: 90, y: 190, width: 810, height: 610)), .resized)
    }

    func testReadsAWindowListEntry() throws {
        let entry: [String: Any] = [
            kCGWindowNumber as String: NSNumber(value: 4242),
            kCGWindowOwnerPID as String: NSNumber(value: 501),
            kCGWindowBounds as String: CGRect(x: -800, y: 25, width: 800, height: 600).dictionaryRepresentation,
            kCGWindowLayer as String: NSNumber(value: 0),
            kCGWindowAlpha as String: NSNumber(value: 1.0)
        ]
        let window = try XCTUnwrap(TrackedWindow(entry))
        XCTAssertEqual(window.id, 4242)
        XCTAssertEqual(window.ownerPID, 501)
        XCTAssertEqual(window.bounds, CGRect(x: -800, y: 25, width: 800, height: 600))
        XCTAssertEqual(window.layer, 0)
        XCTAssertEqual(window.alpha, 1)

        var noBounds = entry
        noBounds[kCGWindowBounds as String] = nil
        XCTAssertNil(TrackedWindow(noBounds))
    }

    func testFindsTheFrontmostOrdinaryWindowOfAnotherApp() {
        let point = CGPoint(x: 400, y: 50)
        let ownPID: pid_t = 99
        let menuBar = TrackedWindow(id: 1, ownerPID: 10, bounds: CGRect(x: 0, y: 0, width: 1512, height: 37), layer: 24)
        let notch = TrackedWindow(id: 2, ownerPID: ownPID, bounds: CGRect(x: 436, y: 0, width: 640, height: 210), layer: 0)
        let invisible = TrackedWindow(id: 3, ownerPID: 20, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982), alpha: 0)
        let overlay = TrackedWindow(id: 4, ownerPID: 30, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982), layer: 25)
        let elsewhere = TrackedWindow(id: 5, ownerPID: 40, bounds: CGRect(x: 900, y: 100, width: 400, height: 300))
        let target = TrackedWindow(id: 6, ownerPID: 50, bounds: CGRect(x: 200, y: 38, width: 900, height: 700))
        let behind = TrackedWindow(id: 7, ownerPID: 60, bounds: CGRect(x: 0, y: 38, width: 1200, height: 800))

        let windows = [menuBar, overlay, notch, invisible, elsewhere, target, behind]
        XCTAssertEqual(TrackedWindow.frontmost(at: point, in: windows, excludingPID: ownPID), target)
        XCTAssertNil(TrackedWindow.frontmost(at: CGPoint(x: 1400, y: 900), in: windows, excludingPID: ownPID))
    }
}

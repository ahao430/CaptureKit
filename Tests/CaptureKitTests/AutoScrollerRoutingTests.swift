import CoreGraphics
import Foundation
import XCTest

@testable import CaptureKit

/// 自动滚动目标进程选择（窗口命中）单测。
final class AutoScrollerRoutingTests: XCTestCase {
    // 窗口列表按 CGWindowList 语义：自前向后
    private let front = AutoScroller.WindowHit(pid: 100, layer: 0, bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
    private let back = AutoScroller.WindowHit(pid: 200, layer: 0, bounds: CGRect(x: 0, y: 0, width: 1400, height: 900))
    private let floating = AutoScroller.WindowHit(pid: 300, layer: 3, bounds: CGRect(x: 100, y: 100, width: 400, height: 300))

    func testPicksFrontmostNormalWindowContainingPoint() {
        let pid = AutoScroller.ownerPID(
            at: CGPoint(x: 400, y: 300),
            windows: [front, back],
            excludingPID: 999
        )
        XCTAssertEqual(pid, 100)
    }

    func testSkipsFloatingLayers() {
        // 浮层在最前但 layer != 0：应落到其后的普通窗口
        let pid = AutoScroller.ownerPID(
            at: CGPoint(x: 200, y: 200),
            windows: [floating, front, back],
            excludingPID: 999
        )
        XCTAssertEqual(pid, 100)
    }

    func testExcludesOwnProcess() {
        // CaptureKit 自己的窗口（如已退化为 layer 0）不作为滚动目标
        let pid = AutoScroller.ownerPID(
            at: CGPoint(x: 400, y: 300),
            windows: [front, back],
            excludingPID: 100
        )
        XCTAssertEqual(pid, 200)
    }

    func testNoContainingWindowReturnsNil() {
        XCTAssertNil(AutoScroller.ownerPID(
            at: CGPoint(x: 5000, y: 5000),
            windows: [front, back],
            excludingPID: 999
        ))
        XCTAssertNil(AutoScroller.ownerPID(at: .zero, windows: [], excludingPID: 999))
    }
}

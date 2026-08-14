import Testing
@testable import SwapBar

// MARK: - Helpers

private let ramp = ColorRamp.defaults

/// Extract OKLCH hue from a ColorRamp stop, for monotonicity assertions.
private func hue(of stop: ColorRampStop) -> Double {
    ramp.oklchHue(of: stop)
}

private func sRGBAt(_ t: Double, reduceMotion: Bool = false) -> (r: Double, g: Double, b: Double) {
    ramp.sRGB(at: t, reduceMotion: reduceMotion)
}

// MARK: - Tests

@Suite("ColorRamp — OKLCH interpolation")
struct ColorRampTests {

    // MARK: Endpoint clamping

    @Test("t ≤ 0 returns first stop (white)")
    func clampLow() {
        let (r, g, b) = sRGBAt(0)
        #expect(r == 1.0)
        #expect(g == 1.0)
        #expect(b == 1.0)
    }

    @Test("t exactly at 0 returns first stop")
    func exactlyAtZero() {
        let (r, g, b) = sRGBAt(0)
        let (rS, gS, bS) = (ramp.stops[0].r, ramp.stops[0].g, ramp.stops[0].b)
        #expect(abs(r - rS) < 0.001)
        #expect(abs(g - gS) < 0.001)
        #expect(abs(b - bS) < 0.001)
    }

    @Test("t at green stop (t=2) returns green")
    func atGreenStop() {
        let green = ramp.stops[1]   // t=2, #9ece6a
        let (r, g, b) = sRGBAt(green.t)
        #expect(abs(r - green.r) < 0.002)
        #expect(abs(g - green.g) < 0.002)
        #expect(abs(b - green.b) < 0.002)
    }

    @Test("t at yellow stop (t=10) returns yellow")
    func atYellowStop() {
        let yellow = ramp.stops[2]  // t=10, #e0af68
        let (r, g, b) = sRGBAt(yellow.t)
        #expect(abs(r - yellow.r) < 0.002)
        #expect(abs(g - yellow.g) < 0.002)
        #expect(abs(b - yellow.b) < 0.002)
    }

    @Test("t at red stop (t=30) returns red")
    func atRedStop() {
        let red = ramp.stops[3]     // t=30, #f7768e
        let (r, g, b) = sRGBAt(red.t)
        #expect(abs(r - red.r) < 0.002)
        #expect(abs(g - red.g) < 0.002)
        #expect(abs(b - red.b) < 0.002)
    }

    @Test("t beyond last stop is clamped to red")
    func clampHigh() {
        let red = ramp.stops[3]
        let (r, g, b) = sRGBAt(9999)
        #expect(abs(r - red.r) < 0.002)
        #expect(abs(g - red.g) < 0.002)
        #expect(abs(b - red.b) < 0.002)
    }

    // MARK: Monotonic hue progression

    // Default stop hues (OKLCH, approximately):
    //   green  #9ece6a → H ≈ 130°
    //   yellow #e0af68 → H ≈ 77°
    //   red    #f7768e → H ≈ 10°
    // Hue is monotonically decreasing from green → yellow → red.

    @Test("green-to-yellow segment: hue decreases monotonically")
    func greenToYellowHueDecreases() {
        let greenH  = hue(of: ramp.stops[1])  // t=2
        let yellowH = hue(of: ramp.stops[2])  // t=10
        // Confirm our reference direction.
        #expect(greenH > yellowH, "green hue should be > yellow hue in OKLCH")

        // Sample 8 points between t=2 and t=10.
        let times = stride(from: 2.5, through: 9.5, by: 1.0)
        var prevHue = greenH
        for t in times {
            let (r, g, b) = sRGBAt(t)
            let h = OKLCH.from(r: r, g: g, b: b).H
            #expect(h <= prevHue + 1.0,   "hue not monotonically decreasing at t=\(t): \(h) > \(prevHue)")
            #expect(h >= yellowH - 1.0,   "hue below yellow floor at t=\(t): \(h)")
            prevHue = h
        }
    }

    @Test("yellow-to-red segment: hue decreases monotonically")
    func yellowToRedHueDecreases() {
        let yellowH = hue(of: ramp.stops[2])  // t=10
        let redH    = hue(of: ramp.stops[3])  // t=30
        #expect(yellowH > redH, "yellow hue should be > red hue in OKLCH")

        let times = stride(from: 11.0, through: 29.0, by: 2.0)
        var prevHue = yellowH
        for t in times {
            let (r, g, b) = sRGBAt(t)
            let h = OKLCH.from(r: r, g: g, b: b).H
            #expect(h <= prevHue + 1.0,   "hue not monotonically decreasing at t=\(t): \(h) > \(prevHue)")
            #expect(h >= redH - 1.0,      "hue below red floor at t=\(t): \(h)")
            prevHue = h
        }
    }

    // MARK: Reduce Motion

    @Test("reduceMotion at t=0 snaps to white stop")
    func reduceMotionAtZeroSnapsToWhite() {
        let (r, g, b) = sRGBAt(0, reduceMotion: true)
        #expect(r == 1.0); #expect(g == 1.0); #expect(b == 1.0)
    }

    @Test("reduceMotion snaps to nearest stop, not interpolated")
    func reduceMotionSnapsToNearest() {
        // t=3 → nearest is green (t=2, distance=1) vs yellow (t=10, distance=7) → green
        let green = ramp.stops[1]
        let (r, g, b) = sRGBAt(3, reduceMotion: true)
        #expect(abs(r - green.r) < 0.001)
        #expect(abs(g - green.g) < 0.001)
        #expect(abs(b - green.b) < 0.001)
    }

    @Test("reduceMotion at t=6 snaps to green (t=2, distance=4) over yellow (t=10, distance=4) — ties go to first found")
    func reduceMotionTieBreak() {
        // t=6: distance to green=4, yellow=4. min(by:) returns the first minimum it finds.
        // Just verify it returns one of the two stops (not an interpolated blend).
        let (r, g, b) = sRGBAt(6, reduceMotion: true)
        let green  = ramp.stops[1]
        let yellow = ramp.stops[2]
        let isGreen  = abs(r - green.r) < 0.001 && abs(g - green.g) < 0.001
        let isYellow = abs(r - yellow.r) < 0.001 && abs(g - yellow.g) < 0.001
        #expect(isGreen || isYellow, "Expected snap to green or yellow, got (\(r), \(g), \(b))")
    }

    @Test("reduceMotion at t=25 snaps to red (t=30, distance=5) over yellow (t=10, distance=15)")
    func reduceMotionLateSnapsToRed() {
        let red = ramp.stops[3]
        let (r, g, b) = sRGBAt(25, reduceMotion: true)
        #expect(abs(r - red.r) < 0.001)
        #expect(abs(g - red.g) < 0.001)
        #expect(abs(b - red.b) < 0.001)
    }

    // MARK: OKLCH round-trip

    @Test("OKLCH round-trip within 1/255 sRGB tolerance")
    func oklchRoundTrip() {
        let samples: [(Double, Double, Double)] = [
            (0.619, 0.808, 0.416),  // green #9ece6a
            (0.878, 0.686, 0.408),  // yellow #e0af68
            (0.969, 0.463, 0.557),  // red #f7768e
            (1.0,   1.0,   1.0  ),  // white
            (0.5,   0.5,   0.5  ),  // mid-grey
        ]
        for (r, g, b) in samples {
            let okl = OKLCH.from(r: r, g: g, b: b)
            let (rr, gg, bb) = okl.tosRGB()
            let tolerance = 1.0 / 255.0
            #expect(abs(rr - r) < tolerance, "Red channel failed for input (\(r), \(g), \(b)): got \(rr)")
            #expect(abs(gg - g) < tolerance, "Green channel failed for input (\(r), \(g), \(b)): got \(gg)")
            #expect(abs(bb - b) < tolerance, "Blue channel failed for input (\(r), \(g), \(b)): got \(bb)")
        }
    }
}

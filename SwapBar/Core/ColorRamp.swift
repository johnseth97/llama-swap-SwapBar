import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

// MARK: - Color Stop

/// One stop on the ramp. Colors are stored as sRGB components so the type
/// is Sendable and testable without a graphics context.
struct ColorRampStop: Sendable, Equatable {
    let t: Double   // elapsed seconds at this stop
    let r: Double   // sRGB red   [0, 1]
    let g: Double   // sRGB green [0, 1]
    let b: Double   // sRGB blue  [0, 1]

    init(t: Double, r: Double, g: Double, b: Double) {
        self.t = t; self.r = r; self.g = g; self.b = b
    }

    init(t: Double, hex: UInt32) {
        self.t = t
        self.r = Double((hex >> 16) & 0xFF) / 255
        self.g = Double((hex >> 8)  & 0xFF) / 255
        self.b = Double(hex         & 0xFF) / 255
    }
}

// MARK: - OKLCH Utilities

/// OKLCH perceptual color space.
/// Reference: https://bottosson.github.io/posts/oklab/
struct OKLCH: Sendable {
    var L: Double   // lightness [0, 1]
    var C: Double   // chroma    [0, ~0.4]
    var H: Double   // hue angle in degrees [0, 360)

    // MARK: sRGB → OKLCH

    static func from(r sR: Double, g sG: Double, b sB: Double) -> OKLCH {
        // 1. sRGB → linear sRGB
        let r = toLinear(sR)
        let g = toLinear(sG)
        let b = toLinear(sB)

        // 2. Linear sRGB → LMS (M1 matrix)
        let lv = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
        let mv = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
        let sv = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b

        // 3. LMS^(1/3) → OKLAB (M2 matrix)
        let l_ = cbrt(lv); let m_ = cbrt(mv); let s_ = cbrt(sv)
        let La = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
        let a  = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
        let bk = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_

        // 4. OKLAB → OKLCH
        let C  = sqrt(a * a + bk * bk)
        let Hd = atan2(bk, a) * 180 / .pi
        return OKLCH(L: La, C: C, H: Hd < 0 ? Hd + 360 : Hd)
    }

    // MARK: OKLCH → sRGB

    func tosRGB() -> (r: Double, g: Double, b: Double) {
        let hRad = H * .pi / 180
        let a    = C * cos(hRad)
        let bk   = C * sin(hRad)

        // Inverse M2
        let l_ = L + 0.3963377774 * a + 0.2158037573 * bk
        let m_ = L - 0.1055613458 * a - 0.0638541728 * bk
        let s_ = L - 0.0894841775 * a - 1.2914855480 * bk

        // Inverse M1
        let l = l_ * l_ * l_; let m = m_ * m_ * m_; let s = s_ * s_ * s_
        let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s

        return (toSRGB(r), toSRGB(g), toSRGB(b))
    }

    // MARK: Gamma helpers

    private static func toLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private func toSRGB(_ c: Double) -> Double {
        let clamped = max(0, min(1, c))
        return clamped <= 0.0031308 ? 12.92 * clamped : 1.055 * pow(clamped, 1 / 2.4) - 0.055
    }
}

// MARK: - ColorRamp

/// Interpolates tint color as a function of elapsed request time.
/// Interpolation is in OKLCH for perceptually uniform hue progression.
struct ColorRamp: Sendable {

    var stops: [ColorRampStop]

    static let defaults = ColorRamp(stops: [
        ColorRampStop(t: 0,  r: 1, g: 1, b: 1),         // white / .primary at t=0
        ColorRampStop(t: 2,  hex: 0x9ece6a),             // green
        ColorRampStop(t: 10, hex: 0xe0af68),             // yellow
        ColorRampStop(t: 30, hex: 0xf7768e),             // red
    ])

    /// Returns sRGB components for the given elapsed time.
    ///
    /// - Parameter elapsed: Seconds since the request's start `upsert` was received.
    /// - Parameter reduceMotion: When true, snaps to the nearest stop (no interpolation).
    func sRGB(at elapsed: Double, reduceMotion: Bool) -> (r: Double, g: Double, b: Double) {
        guard !stops.isEmpty else { return (1, 1, 1) }

        if reduceMotion {
            let snap = stops.min(by: { abs($0.t - elapsed) < abs($1.t - elapsed) }) ?? stops[0]
            return (snap.r, snap.g, snap.b)
        }

        if elapsed <= stops.first!.t { let s = stops.first!; return (s.r, s.g, s.b) }
        if elapsed >= stops.last!.t  { let s = stops.last!;  return (s.r, s.g, s.b) }

        for i in 0 ..< stops.count - 1 {
            let lo = stops[i]; let hi = stops[i + 1]
            guard elapsed >= lo.t && elapsed <= hi.t else { continue }
            let alpha = (elapsed - lo.t) / (hi.t - lo.t)
            return interpolateOKLCH(lo: lo, hi: hi, alpha: alpha)
        }
        let s = stops.last!; return (s.r, s.g, s.b)
    }

#if canImport(SwiftUI)
    /// SwiftUI `Color` for the given elapsed time.
    func color(at elapsed: Double, reduceMotion: Bool) -> Color {
        let (r, g, b) = sRGB(at: elapsed, reduceMotion: reduceMotion)
        return Color(red: r, green: g, blue: b)
    }
#endif // canImport(SwiftUI)

    // MARK: - OKLCH interpolation

    private func interpolateOKLCH(
        lo: ColorRampStop, hi: ColorRampStop, alpha: Double
    ) -> (r: Double, g: Double, b: Double) {
        let from = OKLCH.from(r: lo.r, g: lo.g, b: lo.b)
        let to   = OKLCH.from(r: hi.r, g: hi.g, b: hi.b)

        let L = lerp(from.L, to.L, alpha)
        let C = lerp(from.C, to.C, alpha)

        // Hue: take the shorter arc to avoid wrapping through 0/360.
        var dH = to.H - from.H
        if dH >  180 { dH -= 360 }
        if dH < -180 { dH += 360 }
        // When one endpoint is achromatic (C≈0) use the other's hue to avoid phantom rotation.
        let H: Double
        if from.C < 0.001 { H = to.H }
        else if to.C < 0.001 { H = from.H }
        else { H = from.H + dH * alpha }

        return OKLCH(L: L, C: C, H: H).tosRGB()
    }

    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    // MARK: - Test helper

    /// OKLCH hue of a stop, for unit test assertions.
    func oklchHue(of stop: ColorRampStop) -> Double {
        OKLCH.from(r: stop.r, g: stop.g, b: stop.b).H
    }
}

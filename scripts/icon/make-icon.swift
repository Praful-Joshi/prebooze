// Renders Pregame's icon: the editor's own crossfade (orange fade-out,
// dashed blue fade-in) crossing on a dark squircle, glowing where the two
// songs meet.  swift scripts/icon/make-icon.swift <out.png>
import AppKit
import CoreGraphics

let size = 1024.0
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func c(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }

// Squircle body (macOS grid: 824 pt inset 100) with a soft drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: c(0, 0, 0, 0.45))
ctx.addPath(shape); ctx.setFillColor(c(0.05, 0.06, 0.10)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(shape); ctx.clip()
// Deep night gradient with a faint centre bloom.
let bg = CGGradient(colorsSpace: cs, colors: [c(0.10, 0.11, 0.20), c(0.03, 0.03, 0.07)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
let bloom = CGGradient(colorsSpace: cs, colors: [c(0.55, 0.45, 1.0, 0.22), c(0.55, 0.45, 1.0, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(bloom, startCenter: CGPoint(x: 512, y: 540), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 540), endRadius: 420, options: [])

// Faint bar lines, like the editor's ruler.
for i in 0...8 {
    let x = 210 + Double(i) * 75.5
    ctx.setStrokeColor(c(1, 1, 1, i % 4 == 0 ? 0.07 : 0.035)); ctx.setLineWidth(3)
    ctx.move(to: CGPoint(x: x, y: 250)); ctx.addLine(to: CGPoint(x: x, y: 800)); ctx.strokePath()
}

// Equal-power crossfade across the window: out = cos, in = sin.
let x0 = 210.0, x1 = 814.0, yLow = 300.0, yHigh = 740.0
func curve(_ f: (Double) -> Double) -> CGPath {
    let p = CGMutablePath()
    for k in 0...200 {
        let t = Double(k) / 200
        let pt = CGPoint(x: x0 + (x1 - x0) * t, y: yLow + (yHigh - yLow) * f(t))
        k == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    return p
}
let outCurve = curve { cos($0 * .pi / 2) }, inCurve = curve { sin($0 * .pi / 2) }
let orange = c(1.0, 0.55, 0.15), blue = c(0.35, 0.65, 1.0)
func glowStroke(_ p: CGPath, _ col: CGColor, dash: [CGFloat]? = nil) {
    for (w, a, blur) in [(34.0, 0.18, 60.0), (20.0, 0.35, 26.0), (11.0, 1.0, 8.0)] {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: blur, color: col)
        ctx.addPath(p); ctx.setLineWidth(w); ctx.setLineCap(.round)
        if let dash { ctx.setLineDash(phase: 0, lengths: dash) }
        ctx.setStrokeColor(col.copy(alpha: a)!); ctx.strokePath()
        ctx.restoreGState()
    }
}
glowStroke(inCurve, blue, dash: [34, 26])
glowStroke(outCurve, orange)
// Breakpoint dots at the ends, like the lanes.
for (pt, col) in [(CGPoint(x: x0, y: yHigh), orange), (CGPoint(x: x1, y: yLow), orange),
                  (CGPoint(x: x0, y: yLow), blue), (CGPoint(x: x1, y: yHigh), blue)] {
    ctx.saveGState(); ctx.setShadow(offset: .zero, blur: 24, color: col)
    ctx.setFillColor(col); ctx.fillEllipse(in: CGRect(x: pt.x - 22, y: pt.y - 22, width: 44, height: 44))
    ctx.restoreGState()
}
// Where the two songs become one: a white-hot spark.
let meet = CGPoint(x: (x0 + x1) / 2, y: yLow + (yHigh - yLow) * cos(.pi / 4))
let spark = CGGradient(colorsSpace: cs, colors: [c(1, 1, 1, 1), c(1, 0.85, 0.95, 0.55), c(0.8, 0.6, 1, 0)] as CFArray,
                       locations: [0, 0.25, 1])!
ctx.drawRadialGradient(spark, startCenter: meet, startRadius: 0, endCenter: meet, endRadius: 150, options: [])
ctx.setFillColor(c(1, 1, 1)); ctx.fillEllipse(in: CGRect(x: meet.x - 16, y: meet.y - 16, width: 32, height: 32))
ctx.restoreGState()

// Subtle rim light.
ctx.addPath(shape); ctx.setStrokeColor(c(1, 1, 1, 0.10)); ctx.setLineWidth(3); ctx.strokePath()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")

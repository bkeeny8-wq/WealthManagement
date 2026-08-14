import Foundation
import CoreGraphics
import ImageIO

// 1024×1024 opaque app icon. CoreGraphics origin is bottom-left (y up).
let S = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { exit(1) }
let W = CGFloat(S), H = CGFloat(S)
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }

// Palette (advisory-ledger).
let inkTop   = c(0.125, 0.140, 0.115)
let inkBot   = c(0.070, 0.085, 0.060)
let paper    = c(0.949, 0.929, 0.878)
let muted    = c(0.62, 0.60, 0.52)
let green     = c(0.243, 0.706, 0.482)
let greenSoft = c(0.243, 0.706, 0.482, 0.30)
let greenClear = c(0.243, 0.706, 0.482, 0.0)

// 1. Warm near-black ground, top→bottom.
let ground = CGGradient(colorsSpace: cs, colors: [inkTop, inkBot] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(ground, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])

// 2. Subtle top-center highlight for depth.
let hi = CGGradient(colorsSpace: cs, colors: [c(1, 1, 1, 0.05), c(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(hi, startCenter: CGPoint(x: W*0.5, y: H*0.72), startRadius: 0,
                       endCenter: CGPoint(x: W*0.5, y: H*0.72), endRadius: W*0.6, options: [])

let mx = W * 0.155                 // horizontal margin
let baseY = H * 0.285              // ledger baseline (x-axis)
let targetY = H * 0.700            // the required-return / legacy-floor level
let x0 = mx, x1 = W - mx

// 3. The required-return / legacy-floor target line — dashed, the level the corpus must reach.
ctx.saveGState()
ctx.setStrokeColor(c(0.949, 0.929, 0.878, 0.45))
ctx.setLineWidth(5)
ctx.setLineDash(phase: 0, lengths: [22, 20])
ctx.move(to: CGPoint(x: x0, y: targetY)); ctx.addLine(to: CGPoint(x: x1, y: targetY)); ctx.strokePath()
ctx.restoreGState()

// Corpus curve: accelerating (compounding) rise from the baseline to the target.
func curveY(_ t: CGFloat) -> CGFloat { baseY + (targetY - baseY) * pow(t, 1.55) }
func curveX(_ t: CGFloat) -> CGFloat { x0 + (x1 - x0) * t }
let N = 80
var pts: [CGPoint] = (0...N).map { i in let t = CGFloat(i)/CGFloat(N); return CGPoint(x: curveX(t), y: curveY(t)) }

// 4. Area fill under the curve.
let area = CGMutablePath()
area.move(to: CGPoint(x: pts[0].x, y: baseY))
for p in pts { area.addLine(to: p) }
area.addLine(to: CGPoint(x: pts.last!.x, y: baseY))
area.closeSubpath()
ctx.saveGState(); ctx.addPath(area); ctx.clip()
let fill = CGGradient(colorsSpace: cs, colors: [greenSoft, greenClear] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(fill, start: CGPoint(x: 0, y: targetY), end: CGPoint(x: 0, y: baseY), options: [])
ctx.restoreGState()

// 5. Ledger baseline (x-axis), thin paper rule.
ctx.setStrokeColor(c(0.62, 0.60, 0.52, 0.55)); ctx.setLineWidth(5)
ctx.move(to: CGPoint(x: x0, y: baseY)); ctx.addLine(to: CGPoint(x: x1, y: baseY)); ctx.strokePath()

// 6. The corpus curve.
let line = CGMutablePath(); line.move(to: pts[0]); for p in pts.dropFirst() { line.addLine(to: p) }
ctx.setStrokeColor(green); ctx.setLineWidth(30); ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.addPath(line); ctx.strokePath()

// 7. Endpoint marker where the corpus meets the target — the plan funded.
let end = pts.last!
ctx.setFillColor(paper); ctx.fillEllipse(in: CGRect(x: end.x-40, y: end.y-40, width: 80, height: 80))
ctx.setFillColor(green); ctx.fillEllipse(in: CGRect(x: end.x-27, y: end.y-27, width: 54, height: 54))

// Write PNG.
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
guard let img = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil)
else { exit(1) }
CGImageDestinationAddImage(dest, img, nil)
if CGImageDestinationFinalize(dest) { print("wrote \(out)") } else { exit(1) }

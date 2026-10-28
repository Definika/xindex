// Renders "Xindex: the whole flow", a narrated 1080p explainer, with nothing but macOS: AppKit draws every frame,
// `say` speaks every beat, AVFoundation encodes and muxes.
//
//   swiftc -O -swift-version 5 XindexFlowVideo.swift -o xindex-video
//   ./xindex-video stills <workDir>            # one PNG per scene, everything revealed
//   ./xindex-video render <workDir> <out.mp4>  # the video
//
// Each scene is a list of beats. A beat is one caption, spoken as one clip; a scene's drawing reveals its parts at
// the start of the beat that names them (`f.p(k)`), so picture and voice stay in step whatever the clips' lengths.

import AVFoundation
import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Canvas

let W: CGFloat = 1920
let H: CGFloat = 1080
let FPS: Int32 = 30
let VOICE = "Samantha"
let RATE = "180"
let LEAD = 0.7, GAP = 0.45, TAIL = 1.3, FADE = 0.35

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

enum K {
    static let bg0 = rgb(0x070B16)
    static let bg1 = rgb(0x0E1631)
    static let panel = rgb(0x111A35)
    static let line = rgb(0x2A3760)
    static let text = rgb(0xE8ECF7)
    static let muted = rgb(0x93A0C0)
    static let dim = rgb(0x5B6688)
    static let teal = rgb(0x2DD4BF)
    static let violet = rgb(0xA78BFA)
    static let blue = rgb(0x60A5FA)
    static let amber = rgb(0xFBBF24)
    static let green = rgb(0x34D399)
    static let pink = rgb(0xF472B6)
    static let orange = rgb(0xFB923C)
    static let red = rgb(0xF87171)
    static let slate = rgb(0xA5B4CF)
}

let coinColors: [String: NSColor] = [
    "WBTC": rgb(0xF7931A), "WETH": rgb(0x8EA2FF), "LINK": rgb(0x4C7BF3), "UNI": rgb(0xFF4FA3),
    "AAVE": rgb(0xC77DD8), "SOL": rgb(0xA77BFF), "XRP": rgb(0xC0C7D6), "PEPE": rgb(0x55C46B),
    "USDC": rgb(0x3D8BE0), "USDT": rgb(0x26A17B), "SYD": K.teal,
]

var g: CGContext!

func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }
func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
func lerpP(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { pt(lerp(a.x, b.x, t), lerp(a.y, b.y, t)) }
func clamp01(_ x: Double) -> Double { max(0, min(1, x)) }
func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }

// MARK: - Timing inside a scene

struct F {
    let t: Double
    let starts: [Double]
    let dur: Double

    /// Eased progress of an entrance that begins `delay` seconds into beat `k` and lasts `d`.
    func p(_ k: Int, _ d: Double = 0.6, _ delay: Double = 0) -> CGFloat {
        guard k < starts.count else { return 0 }
        return CGFloat(easeOut(clamp01((t - starts[k] - delay) / d)))
    }
    /// The same, eased in and out, for movement.
    func io(_ k: Int, _ d: Double, _ delay: Double = 0) -> CGFloat {
        guard k < starts.count else { return 0 }
        return CGFloat(easeInOut(clamp01((t - starts[k] - delay) / d)))
    }
    /// Progress against the scene's own clock, for entrances before the first beat.
    func tp(_ start: Double, _ d: Double) -> CGFloat { CGFloat(easeOut(clamp01((t - start) / d))) }
    func on(_ k: Int) -> Bool { k < starts.count && t >= starts[k] }
}

// MARK: - Drawing primitives

func reveal(_ a: CGFloat, dy: CGFloat = 22, _ body: () -> Void) {
    guard a > 0.002 else { return }
    g.saveGState()
    g.translateBy(x: 0, y: (1 - a) * dy)
    let layered = a < 0.998
    if layered {
        g.setAlpha(a)
        g.beginTransparencyLayer(auxiliaryInfo: nil)
    }
    body()
    if layered { g.endTransparencyLayer() }
    g.restoreGState()
}

func font(_ size: CGFloat, _ weight: NSFont.Weight, _ mono: Bool) -> NSFont {
    mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
}

func attr(
    _ s: String, _ size: CGFloat, _ color: NSColor, _ weight: NSFont.Weight = .regular,
    _ align: NSTextAlignment = .left, mono: Bool = false, kern: CGFloat = 0, lh: CGFloat = 1.12
) -> NSAttributedString {
    let ps = NSMutableParagraphStyle()
    ps.alignment = align
    ps.lineHeightMultiple = lh
    var a: [NSAttributedString.Key: Any] = [
        .font: font(size, weight, mono), .foregroundColor: color, .paragraphStyle: ps,
    ]
    if kern != 0 { a[.kern] = kern }
    return NSAttributedString(string: s, attributes: a)
}

enum Anchor { case left, center, right }

/// Draws `s` with its top at `y`; `x` is the left edge, centre or right edge per `align`, or the left edge of a
/// wrapping box when `width` is set.
@discardableResult
func text(
    _ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ color: NSColor = K.text,
    _ weight: NSFont.Weight = .regular, align: NSTextAlignment = .left, width: CGFloat = 0, mono: Bool = false,
    kern: CGFloat = 0
) -> CGSize {
    let a = attr(s, size, color, weight, align, mono: mono, kern: kern)
    if width > 0 {
        let r = a.boundingRect(
            with: CGSize(width: width, height: 4000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        a.draw(
            with: R(x, y, width, ceil(r.height) + 2), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return CGSize(width: r.width, height: ceil(r.height))
    }
    let sz = a.size()
    let dx: CGFloat = align == .center ? sz.width / 2 : (align == .right ? sz.width : 0)
    a.draw(at: pt(x - dx, y))
    return sz
}

func measure(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular, width: CGFloat, mono: Bool = false)
    -> CGSize
{
    let a = attr(s, size, K.text, weight, .left, mono: mono)
    let r = a.boundingRect(
        with: CGSize(width: width, height: 4000), options: [.usesLineFragmentOrigin, .usesFontLeading])
    return CGSize(width: ceil(r.width), height: ceil(r.height))
}

func rrect(
    _ r: CGRect, _ rad: CGFloat, fill: NSColor? = nil, stroke: NSColor? = nil, lw: CGFloat = 2,
    dash: [CGFloat]? = nil
) {
    let p = NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad)
    if let f = fill {
        f.setFill()
        p.fill()
    }
    if let s = stroke {
        s.setStroke()
        p.lineWidth = lw
        if let d = dash { p.setLineDash(d, count: d.count, phase: 0) }
        p.stroke()
    }
}

func circle(_ c: CGPoint, _ r: CGFloat, fill: NSColor? = nil, stroke: NSColor? = nil, lw: CGFloat = 2) {
    let p = NSBezierPath(ovalIn: R(c.x - r, c.y - r, 2 * r, 2 * r))
    if let f = fill {
        f.setFill()
        p.fill()
    }
    if let s = stroke {
        s.setStroke()
        p.lineWidth = lw
        p.stroke()
    }
}

func line(_ a: CGPoint, _ b: CGPoint, _ c: NSColor, lw: CGFloat = 2, dash: [CGFloat]? = nil) {
    let p = NSBezierPath()
    p.move(to: a)
    p.line(to: b)
    p.lineWidth = lw
    p.lineCapStyle = .round
    if let d = dash { p.setLineDash(d, count: d.count, phase: 0) }
    c.setStroke()
    p.stroke()
}

var symbolCache: [String: NSImage] = [:]
var missingSymbols = Set<String>()

func symbol(_ name: String, _ c: CGPoint, _ size: CGFloat, _ color: NSColor) {
    let key = "\(name)|\(size)|\(color.hashValue)"
    if symbolCache[key] == nil {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: color))
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            symbolCache[key] = img
        } else {
            if !missingSymbols.contains(name) {
                missingSymbols.insert(name)
                FileHandle.standardError.write("missing symbol \(name)\n".data(using: .utf8)!)
            }
            circle(c, size * 0.35, fill: color)
            return
        }
    }
    let img = symbolCache[key]!
    let s = img.size
    img.draw(
        in: R(c.x - s.width / 2, c.y - s.height / 2, s.width, s.height), from: .zero, operation: .sourceOver,
        fraction: 1, respectFlipped: true, hints: nil)
}

func glow(_ r: CGRect, _ rad: CGFloat, _ c: NSColor) {
    rrect(r.insetBy(dx: -8, dy: -8), rad + 8, fill: c.withAlphaComponent(0.035))
    rrect(r.insetBy(dx: -4, dy: -4), rad + 4, fill: c.withAlphaComponent(0.05))
}

/// A box: icon disc on the left, bold title, muted subtitle, centred vertically.
func card(
    _ r: CGRect, _ c: NSColor, _ title: String, _ sub: String? = nil, icon: String? = nil, ts: CGFloat = 26,
    ss: CGFloat = 19, mono: Bool = false
) {
    glow(r, 16, c)
    rrect(r, 16, fill: K.panel)
    rrect(r, 16, fill: c.withAlphaComponent(0.07))
    rrect(r.insetBy(dx: 1, dy: 1), 15, stroke: c.withAlphaComponent(0.85), lw: 2)
    var tx = r.minX + 22
    if let n = icon {
        let ir: CGFloat = min(30, r.height * 0.3)
        let ic = pt(r.minX + 20 + ir, r.midY)
        circle(ic, ir, fill: c.withAlphaComponent(0.18))
        symbol(n, ic, ir * 0.9, c)
        tx = ic.x + ir + 16
    }
    let tw = r.maxX - 14 - tx
    let th = measure(title, ts, .bold, width: tw, mono: mono).height
    let sh = sub.map { measure($0, ss, width: tw).height } ?? 0
    let gap: CGFloat = sub == nil ? 0 : 3
    var y = r.midY - (th + gap + sh) / 2
    text(title, tx, y, ts, K.text, .bold, width: tw, mono: mono)
    if let s = sub {
        y += th + gap
        text(s, tx, y, ss, K.muted, width: tw)
    }
}

/// A panel with a header; returns the y where its content starts.
@discardableResult
func panel(_ r: CGRect, _ c: NSColor, _ title: String, icon: String? = nil, size: CGFloat = 24) -> CGFloat {
    glow(r, 18, c)
    rrect(r, 18, fill: K.panel)
    rrect(r, 18, fill: c.withAlphaComponent(0.05))
    rrect(r.insetBy(dx: 1, dy: 1), 17, stroke: c.withAlphaComponent(0.6), lw: 2)
    var x = r.minX + 24
    if let i = icon {
        symbol(i, pt(x + 13, r.minY + 22 + size * 0.6), size * 0.95, c)
        x += 38
    }
    text(title, x, r.minY + 20, size, K.text, .bold)
    return r.minY + 20 + size * 1.3 + 14
}

/// Code lines in a panel: lines that start with "//" are comments.
func codeCard(_ r: CGRect, _ c: NSColor, _ lines: [String], size: CGFloat = 24) {
    glow(r, 16, c)
    rrect(r, 16, fill: rgb(0x0A1024))
    rrect(r.insetBy(dx: 1, dy: 1), 15, stroke: c.withAlphaComponent(0.7), lw: 2)
    let lh = size * 1.45
    var y = r.midY - lh * CGFloat(lines.count) / 2 + (lh - size * 1.2) / 2
    for l in lines {
        if l.hasPrefix("//") {
            text(l, r.minX + 26, y, size * 0.82, K.dim, .regular, mono: true)
        } else {
            text(l, r.minX + 26, y, size, c, .medium, mono: true)
        }
        y += lh
    }
}

func pillSize(_ s: String, _ size: CGFloat, mono: Bool = false, icon: Bool = false) -> CGSize {
    let sz = attr(s, size, K.text, .semibold, mono: mono).size()
    return CGSize(width: sz.width + 28 + (icon ? size + 8 : 0), height: sz.height + 12)
}

@discardableResult
func pill(
    _ s: String, _ x: CGFloat, _ cy: CGFloat, _ c: NSColor, size: CGFloat = 19, filled: Bool = false,
    mono: Bool = false, icon: String? = nil, anchor: Anchor = .center
) -> CGRect {
    let a = attr(s, size, filled ? K.bg0 : c, .semibold, mono: mono)
    let ts = a.size()
    let ps = pillSize(s, size, mono: mono, icon: icon != nil)
    var x0 = x - ps.width / 2
    if anchor == .left { x0 = x } else if anchor == .right { x0 = x - ps.width }
    let r = R(x0, cy - ps.height / 2, ps.width, ps.height)
    rrect(
        r, ps.height / 2, fill: filled ? c : K.bg0.blended(withFraction: 0.12, of: c),
        stroke: filled ? nil : c.withAlphaComponent(0.75), lw: 1.5)
    var tx = x0 + 14
    if let i = icon {
        symbol(i, pt(tx + size / 2, cy), size * 0.85, filled ? K.bg0 : c)
        tx += size + 8
    }
    a.draw(at: pt(tx, cy - ts.height / 2))
    return r
}

/// Pills flowing left to right inside `width`, wrapping.
func chips(
    _ items: [String], _ x: CGFloat, _ y: CGFloat, width: CGFloat, _ c: NSColor, size: CGFloat = 18,
    mono: Bool = true, alpha: (Int) -> CGFloat = { _ in 1 }
) {
    var cx = x
    var cy = y
    let gap: CGFloat = 9
    for (i, s) in items.enumerated() {
        let ps = pillSize(s, size, mono: mono)
        if cx + ps.width > x + width {
            cx = x
            cy += ps.height + gap
        }
        let px = cx
        let py = cy + ps.height / 2
        reveal(alpha(i), dy: 10) { pill(s, px, py, c, size: size, mono: mono, anchor: .left) }
        cx += ps.width + gap
    }
}

func coin(_ c: CGPoint, _ s: String, r: CGFloat = 30, color: NSColor? = nil) {
    let col = color ?? coinColors[s] ?? K.slate
    circle(c, r + 5, fill: col.withAlphaComponent(0.10))
    circle(c, r, fill: K.bg0.blended(withFraction: 0.22, of: col), stroke: col, lw: 2.5)
    let size = r * (s.count <= 3 ? 0.6 : 0.47)
    let a = attr(s, size, col, .heavy)
    let ts = a.size()
    a.draw(at: pt(c.x - ts.width / 2, c.y - ts.height / 2))
}

// MARK: - Arrows

struct Curve {
    let a: CGPoint
    let b: CGPoint
    let ctrl: CGPoint
    init(_ a: CGPoint, _ b: CGPoint, bend: CGFloat = 0) {
        self.a = a
        self.b = b
        let dx = b.x - a.x
        let dy = b.y - a.y
        let len = max(1, hypot(dx, dy))
        ctrl = pt((a.x + b.x) / 2 - dy / len * bend, (a.y + b.y) / 2 + dx / len * bend)
    }
    func at(_ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return pt(
            u * u * a.x + 2 * u * t * ctrl.x + t * t * b.x, u * u * a.y + 2 * u * t * ctrl.y + t * t * b.y)
    }
    func tangent(_ t: CGFloat) -> CGPoint {
        pt(2 * (1 - t) * (ctrl.x - a.x) + 2 * t * (b.x - ctrl.x), 2 * (1 - t) * (ctrl.y - a.y) + 2 * t * (b.y - ctrl.y))
    }
}

func label(_ s: String, _ c: CGPoint, _ color: NSColor, size: CGFloat = 18, mono: Bool = false) {
    let a = attr(s, size, color, .semibold, mono: mono)
    let ts = a.size()
    rrect(R(c.x - ts.width / 2 - 8, c.y - ts.height / 2 - 3, ts.width + 16, ts.height + 6), 8, fill: K.bg0.withAlphaComponent(0.85))
    a.draw(at: pt(c.x - ts.width / 2, c.y - ts.height / 2))
}

func arrow(
    _ cv: Curve, _ c: NSColor, prog: CGFloat = 1, lw: CGFloat = 3, dash: Bool = false, head: Bool = true,
    label l: String? = nil, lofs: CGPoint = pt(0, -20), lsize: CGFloat = 18, mono: Bool = false
) {
    guard prog > 0.002 else { return }
    let tip = cv.at(prog)
    let tg = cv.tangent(prog)
    let tl = max(0.001, hypot(tg.x, tg.y))
    let dir = pt(tg.x / tl, tg.y / tl)
    let hl: CGFloat = 12 + lw * 2
    let path = NSBezierPath()
    path.move(to: cv.at(0))
    let n = 48
    for i in 1...n {
        var p = cv.at(prog * CGFloat(i) / CGFloat(n))
        if i == n && head { p = pt(tip.x - dir.x * hl * 0.6, tip.y - dir.y * hl * 0.6) }
        path.line(to: p)
    }
    path.lineWidth = lw
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    if dash { path.setLineDash([10, 8], count: 2, phase: 0) }
    c.setStroke()
    path.stroke()
    if head && prog > 0.04 {
        let hw = hl * 0.55
        let base = pt(tip.x - dir.x * hl, tip.y - dir.y * hl)
        let h = NSBezierPath()
        h.move(to: tip)
        h.line(to: pt(base.x - dir.y * hw, base.y + dir.x * hw))
        h.line(to: pt(base.x + dir.y * hw, base.y - dir.x * hw))
        h.close()
        c.setFill()
        h.fill()
    }
    if let s = l, prog > 0.5 {
        let m = cv.at(0.5)
        reveal(min(1, (prog - 0.5) * 2.5), dy: 0) { label(s, pt(m.x + lofs.x, m.y + lofs.y), c, size: lsize, mono: mono) }
    }
}

/// Dots travelling along a curve while its beat runs: tokens on the move.
func flow(_ cv: Curve, _ colors: [NSColor], _ t: Double, alpha: CGFloat = 1, speed: Double = 0.5, r: CGFloat = 7) {
    guard alpha > 0.01 else { return }
    let n = colors.count
    for i in 0..<n {
        let u = CGFloat((t * speed + Double(i) / Double(n)).truncatingRemainder(dividingBy: 1))
        let fade = min(1, min(u, 1 - u) * 6) * alpha
        let p = cv.at(u)
        circle(p, r + 5, fill: colors[i].withAlphaComponent(0.22 * fade))
        circle(p, r, fill: colors[i].withAlphaComponent(fade))
    }
}

func basketColors() -> [NSColor] { ["WBTC", "WETH", "LINK", "UNI"].map { coinColors[$0]! } }

// MARK: - Scenes

struct Scene {
    let kicker: String
    let title: String
    let color: NSColor
    let beats: [String]
    let draw: (F) -> Void
}

// 1. Title
func s01(_ f: F) {
    reveal(f.tp(0.1, 1.0), dy: 30) {
        let a = attr("X", 170, K.teal, .heavy)
        let b = attr("index", 170, K.text, .heavy)
        let w = a.size().width + b.size().width
        a.draw(at: pt(960 - w / 2, 140))
        b.draw(at: pt(960 - w / 2 + a.size().width, 140))
    }
    reveal(f.tp(0.6, 1.0)) {
        text("A whole crypto portfolio in one ERC-20 token", 960, 370, 42, K.muted, .medium, align: .center)
    }
    let coins = ["WBTC", "WETH", "LINK", "UNI", "AAVE", "SOL", "XRP", "PEPE"]
    let m = f.io(1, 1.4, 0.3)
    for (i, s) in coins.enumerated() {
        let p0 = pt(960 + (CGFloat(i) - 3.5) * 125, 555)
        let p = lerpP(p0, pt(960, 555), m)
        reveal(f.p(0, 0.5, 0.5 + Double(i) * 0.16) * (1 - m), dy: 16) { coin(p, s, r: 44) }
    }
    if m > 0.01 {
        reveal(m, dy: 0) {
            coin(pt(960, 555), "SYD", r: 50 + 26 * m)
            text("one index token, fully backed", 960, 650, 24, K.teal, .semibold, align: .center)
        }
    }
    let steps = ["List", "Create", "Mint", "Rebalance", "Burn"]
    let sizes = steps.map { pillSize($0, 24).width }
    let total = sizes.reduce(0, +) + CGFloat(steps.count - 1) * 56
    var x = 960 - total / 2
    for (i, s) in steps.enumerated() {
        let a = f.p(1, 0.5, 1.8 + Double(i) * 0.3)
        let px = x
        reveal(a) {
            pill(s, px, 770, K.teal, size: 24, anchor: .left)
            if i > 0 { symbol("chevron.right", pt(px - 28, 770), 20, K.dim) }
        }
        x += sizes[i] + 56
    }
}

// 2. The map
func s02(_ f: F) {
    reveal(f.p(0)) {
        rrect(R(450, 180, 1370, 672), 22, fill: K.teal.withAlphaComponent(0.02), stroke: K.line, lw: 2, dash: [12, 10])
        pill("Ethereum mainnet · one deployment", 474, 180, K.teal, size: 18, icon: "diamond.fill", anchor: .left)
    }
    reveal(f.p(1)) {
        card(R(500, 228, 400, 112), K.violet, "WeightedIndexFactory", "lists coins · creates indexes", icon: "building.columns.fill", ts: 24)
    }
    reveal(f.p(1, 0.6, 0.5)) {
        card(R(500, 450, 400, 140), K.teal, "WeightedHub · the index", "an ERC-20 holding its basket in kind", icon: "circle.hexagongrid.fill", ts: 25)
    }
    arrow(Curve(pt(700, 342), pt(700, 448)), K.violet, prog: f.p(1, 0.6, 0.9), label: "CREATE2 clone", lofs: pt(86, 0))
    reveal(f.p(2)) { card(R(1010, 228, 340, 104), K.blue, "IndexZap", "one-transaction mint / burn", icon: "bolt.fill", ts: 24) }
    reveal(f.p(2, 0.6, 0.3)) { card(R(1010, 360, 340, 104), K.orange, "BasketBuilder", "wide baskets, many transactions", icon: "square.stack.3d.up.fill", ts: 24) }
    reveal(f.p(2, 0.6, 0.6)) {
        card(R(1430, 240, 350, 118), K.blue, "Universal Router", "Uniswap 2.0.0", icon: "arrow.triangle.swap", ts: 24)
        card(R(1430, 400, 350, 70), K.blue, "V3 pools · V4 pools", nil, ts: 21)
    }
    let pa = f.p(2, 0.6, 1.0)
    arrow(Curve(pt(1352, 280), pt(1428, 290)), K.blue, prog: pa)
    arrow(Curve(pt(1352, 412), pt(1428, 330)), K.orange, prog: pa)
    arrow(Curve(pt(1605, 360), pt(1605, 398)), K.blue, prog: pa, lw: 2.5)
    arrow(Curve(pt(1008, 290), pt(904, 490)), K.blue, prog: pa)
    arrow(Curve(pt(1008, 420), pt(904, 540)), K.orange, prog: pa)
    reveal(f.p(3)) { card(R(1010, 640, 340, 112), K.pink, "MintRequests", "an escrow for limit orders", icon: "tray.full.fill", ts: 24) }
    arrow(Curve(pt(1008, 690), pt(904, 575)), K.pink, prog: f.p(3, 0.6, 0.4), dash: true, label: "shares", lofs: pt(46, 30))
    reveal(f.p(3, 0.6, 1.0)) { card(R(500, 700, 400, 110), K.amber, "Pyth", "price feeds", icon: "chart.line.uptrend.xyaxis", ts: 25) }
    arrow(
        Curve(pt(700, 592), pt(700, 698)), K.amber, prog: f.p(3, 0.6, 1.3), label: "read at settlement only",
        lofs: pt(118, 0))
    let actors: [(String, String, String, NSColor)] = [
        ("Creator", "creates indexes", "person.crop.circle.badge.plus", K.violet),
        ("Minter / holder", "mints, holds, burns", "person.2.fill", K.green),
        ("Keeper", "fills auctions & requests", "gearshape.2.fill", K.teal),
        ("Owner Safe + guardian", "listings · never funds", "checkmark.shield.fill", K.red),
    ]
    for (i, a) in actors.enumerated() {
        reveal(f.p(4, 0.6, Double(i) * 0.35)) {
            card(R(100, 228 + CGFloat(i) * 135, 300, 108), a.3, a.0, a.1, icon: a.2, ts: 21, ss: 17)
        }
    }
    let ca = f.p(4, 0.6, 1.6)
    arrow(Curve(pt(402, 282), pt(498, 284)), K.violet, prog: ca, lw: 2.5)
    arrow(Curve(pt(402, 417), pt(498, 498)), K.green, prog: ca, lw: 2.5)
    arrow(Curve(pt(402, 552), pt(498, 560)), K.teal, prog: ca, lw: 2.5)
}

// 3. Listing
func s03(_ f: F) {
    reveal(f.p(0)) { card(R(100, 195, 330, 115), K.violet, "Owner Safe", "at least 3 signatures", icon: "checkmark.shield.fill") }
    arrow(Curve(pt(432, 252), pt(498, 252)), K.violet, prog: f.p(0, 0.5, 0.5))
    reveal(f.p(0, 0.6, 0.7)) {
        codeCard(R(500, 200, 640, 105), K.violet, ["proposeListing(token, pythPriceId)", "// decimals read and recorded now"])
    }
    let y: CGFloat = 425
    func bar(_ x1: CGFloat, _ x2: CGFloat, _ c: NSColor, dashed: Bool = false) {
        if dashed {
            line(pt(x1, y), pt(x2, y), c, lw: 6, dash: [10, 10])
        } else {
            rrect(R(x1, y - 8, x2 - x1, 16), 8, fill: c.withAlphaComponent(0.9))
        }
    }
    func tick(_ x: CGFloat, _ s: String) {
        line(pt(x, y - 16), pt(x, y + 16), K.text, lw: 2)
        text(s, x, y + 22, 17, K.muted, align: .center)
    }
    reveal(f.p(1)) {
        bar(500, 900, K.amber)
        text("2-day delay", 700, y - 48, 23, K.amber, .bold, align: .center)
        tick(500, "proposed")
        tick(900, "eta")
    }
    reveal(f.p(1, 0.6, 1.0)) { pill("guardian can cancel", 700, y + 72, K.red, icon: "xmark.octagon.fill") }
    reveal(f.p(2)) {
        bar(900, 1560, K.teal)
        text("7-day window · anyone executes", 1230, y - 48, 23, K.teal, .bold, align: .center)
        tick(1560, "eta + 7 days")
    }
    reveal(f.p(2, 0.6, 0.7)) {
        circle(pt(1080, y), 11, fill: K.text, stroke: K.teal, lw: 3)
        pill("executeListing(token)", 1080, y + 72, K.teal, mono: true)
        pill("whitelisted", 1410, y + 72, K.green, filled: true, icon: "checkmark")
    }
    reveal(f.p(2, 0.6, 1.4)) {
        bar(1580, 1800, K.dim, dashed: true)
        text("expires", 1690, y - 44, 20, K.dim, .semibold, align: .center)
    }
    reveal(f.p(3)) {
        text("92", 100, 540, 116, K.teal, .heavy)
        text("coins listed", 106, 684, 24, K.text, .semibold)
        text("34 more Wormhole copies await attestation", 106, 720, 17, K.muted, width: 280)
    }
    let groups: [(String, String, [String], NSColor, Double)] = [
        ("Issued on Ethereum", "the issuer's own contract", ["WETH", "WBTC", "LINK", "UNI", "AAVE", "ENA", "ONDO", "ARB", "SHIB", "PEPE", "CRV", "…"], K.blue, 0.3),
        ("Wormhole copies · Bridged", "Custodial too, from a Binance-Peg source", ["SOL", "XRP", "ADA", "LTC", "AVAX", "DOT", "JUP", "ALGO", "ATOM", "AERO", "APT", "PYTH", "OP"], K.violet, 1.0),
        ("Real-world assets · Custodial", "Tether Gold and Ondo stock tokens", ["XAUT", "NVDAon", "AAPLon", "TSLAon", "MSFTon", "AMZNon", "METAon", "…"], K.amber, 1.7),
    ]
    let gx: [CGFloat] = [420, 880, 1380]
    let gw: [CGFloat] = [430, 470, 440]
    for (i, gr) in groups.enumerated() {
        let a = f.p(3, 0.6, gr.4)
        reveal(a) {
            text(gr.0, gx[i], 540, 22, gr.3, .bold)
            text(gr.1, gx[i], 572, 16, K.muted)
        }
        chips(gr.2, gx[i], 606, width: gw[i], gr.3, size: 17) { j in f.p(3, 0.4, gr.4 + 0.2 + Double(j) * 0.05) }
    }
    reveal(f.p(4)) {
        pill(
            "CheckToken: one report per token for the Safe's signers, before any listing", 960, 822, K.amber, size: 19,
            icon: "doc.text.magnifyingglass")
    }
}

// 4. Create
let basket: [(String, Int)] = [("WBTC", 40), ("WETH", 30), ("LINK", 20), ("UNI", 10)]

func s04(_ f: F) {
    reveal(f.p(0)) {
        let top = panel(R(100, 190, 740, 395), K.teal, "Smart Yield DeFi · SYD", icon: "slider.horizontal.3")
        for (i, b) in basket.enumerated() {
            let y = top + 14 + CGFloat(i) * 66
            coin(pt(150, y), b.0, r: 25)
            text(b.0, 188, y - 15, 22, K.text, .bold)
            rrect(R(300, y - 9, 330, 18), 9, fill: K.line.withAlphaComponent(0.6))
            let w = 330 * CGFloat(b.1) / 40 * f.p(0, 0.9, 0.4 + Double(i) * 0.25)
            rrect(R(300, y - 9, max(18, w), 18), 9, fill: coinColors[b.0]!)
            text("\(b.1) % · \(b.1 * 100) bps", 810, y - 14, 21, K.muted, .medium, align: .right)
        }
        let sy = top + 14 + 4 * 66 - 6
        reveal(f.p(0, 0.5, 1.6)) {
            symbol("checkmark.circle.fill", pt(150, sy), 24, K.green)
            text("weights sum to 10,000 bps = 100 %   ·   2 to 100 coins", 188, sy - 14, 21, K.green, .semibold)
        }
    }
    reveal(f.p(1)) {
        let top = panel(R(100, 610, 740, 240), K.teal, "Starting units", icon: "function")
        text("unitsᵢ = wᵢ × V ÷ pᵢ", 128, top - 4, 32, K.teal, .semibold, mono: true)
        text("V = $100 per SYD, WETH at $4,000 (illustrative):", 128, top + 48, 19, K.muted)
        text("30 % × $100 ÷ $4,000 = 0.0075 WETH", 128, top + 78, 24, K.text, .medium, mono: true)
    }
    reveal(f.p(2)) {
        codeCard(R(900, 190, 920, 255), K.violet, [
            "createIndex(",
            "  \"Smart Yield DeFi\", \"SYD\",",
            "  [{WBTC, 4000, units}, {WETH, 3000, units}, …],",
            "  {fees, streaming fee, interval, gated, listed})",
            "// + the creation fee, in ether",
        ], size: 23)
    }
    reveal(f.p(3)) { card(R(900, 478, 330, 104), K.violet, "Factory", "CREATE2 · EIP-1167 clone", icon: "building.columns.fill") }
    arrow(Curve(pt(1232, 530), pt(1398, 530)), K.teal, prog: f.p(3, 0.6, 0.5), label: "deploy", lofs: pt(0, -20))
    reveal(f.p(3, 0.6, 0.8)) { card(R(1400, 478, 420, 104), K.teal, "SYD", "0x7a3c…f19e · known before sending", icon: "circle.hexagongrid.fill") }
    reveal(f.p(3, 0.6, 1.2)) { text("The address commits to every term:", 900, 610, 20, K.muted, .semibold) }
    chips(
        ["creator", "name", "symbol", "tokens", "units", "weights", "Pyth ids", "decimals", "fee rates", "referral share", "interval"],
        900, 645, width: 920, K.violet, size: 18
    ) { j in f.p(3, 0.4, 1.4 + Double(j) * 0.08) }
    reveal(f.p(4)) {
        pill("the factory reads no price", 1110, 805, K.amber, size: 20, icon: "eye.slash.fill")
        pill("first rebalance → exact weights", 1560, 805, K.teal, size: 20, icon: "scope")
    }
}

// 5. Terms
func s05(_ f: F) {
    reveal(f.p(0)) {
        rrect(R(100, 186, 1720, 62), 31, fill: K.teal.withAlphaComponent(0.1), stroke: K.teal.withAlphaComponent(0.6), lw: 1.5)
        symbol("lock.fill", pt(140, 217), 24, K.teal)
        text("Fixed at creation, committed in the index's address, never changeable", 170, 201, 25, K.text, .semibold)
    }
    let cards: [CGRect] = [R(100, 275, 845, 275), R(975, 275, 845, 275), R(100, 575, 845, 270), R(975, 575, 845, 270)]
    reveal(f.p(1)) {
        let top = panel(cards[0], K.violet, "Mint & burn fee", icon: "percent")
        text("Creator", 130, top + 6, 26, K.muted)
        text("0 – 1.00 %", 420, top + 0, 34, K.text, .bold)
        text("Platform", 130, top + 64, 26, K.muted)
        text("0 – 0.25 %", 420, top + 58, 34, K.text, .bold)
        text("in shares, on every issue and every redeem", 130, top + 128, 19, K.dim)
    }
    reveal(f.p(2)) {
        let top = panel(cards[1], K.amber, "Streaming fee", icon: "clock.arrow.circlepath")
        text("Creator", 1005, top + 6, 26, K.muted)
        text("0 – 5 % / year", 1295, top + 0, 34, K.text, .bold)
        text("Platform", 1005, top + 64, 26, K.muted)
        text("0 – 1 % / year", 1295, top + 58, 34, K.text, .bold)
        text("the platform's policy starts at zero", 1005, top + 128, 19, K.dim)
    }
    reveal(f.p(3)) {
        let r = cards[2]
        let top = panel(r, K.teal, "Rebalance interval", icon: "calendar")
        let x1 = r.minX + 60
        let x2 = r.maxX - 60
        let y = top + 70
        rrect(R(x1, y - 5, x2 - x1, 10), 5, fill: K.line)
        let ticks: [(Double, String)] = [(7, "7 d · weekly"), (30, "30 d · monthly"), (91, "91 d · quarterly")]
        for tk in ticks {
            let x = x1 + (x2 - x1) * CGFloat((tk.0 - 7) / 84)
            line(pt(x, y - 14), pt(x, y + 14), K.muted, lw: 2)
            text(tk.1, x, y + 24, 19, K.muted, align: tk.0 == 7 ? .left : (tk.0 == 91 ? .right : .center))
        }
        let v = 7 + 23 * Double(f.io(3, 1.6, 0.6))
        let kx = x1 + (x2 - x1) * CGFloat((v - 7) / 84)
        rrect(R(x1, y - 5, kx - x1, 10), 5, fill: K.teal)
        circle(pt(kx, y), 14, fill: K.text, stroke: K.teal, lw: 4)
        text("chosen per index, 7 to 91 days", r.minX + 30, r.maxY - 46, 19, K.dim)
    }
    reveal(f.p(4)) {
        let r = cards[3]
        let top = panel(r, K.pink, "Gate & listing (optional)", icon: "person.badge.key.fill")
        let rows: [(String, String)] = [
            ("person.2.badge.gearshape.fill", "Gated: only minters the creator allows"),
            ("lock.open.fill", "openMinting(): opens it for good, never closes"),
            ("eye.slash.fill", "Unlisted: the app does not show it"),
        ]
        for (i, row) in rows.enumerated() {
            let y = top + 10 + CGFloat(i) * 52
            symbol(row.0, pt(r.minX + 46, y + 14), 22, K.pink)
            text(row.1, r.minX + 80, y, 23, K.text)
        }
    }
}

// 6. In kind
func s06(_ f: F) {
    let units: [(String, String)] = [("WBTC", "0.0004"), ("WETH", "0.0075"), ("LINK", "1"), ("UNI", "1")]
    reveal(f.p(0)) { text("1 SYD  =", 100, 205, 44, K.text, .heavy) }
    var ux: CGFloat = 360
    for (i, u) in units.enumerated() {
        let x = ux
        let label = "\(u.1) \(u.0)"
        let w = attr(label, 30, K.text, .semibold, mono: true).size().width
        reveal(f.p(0, 0.5, 0.4 + Double(i) * 0.25)) {
            coin(pt(x, 235), u.0, r: 32)
            text(label, x + 48, 216, 30, K.text, .semibold, mono: true)
            if i < 3 { text("+", x + 48 + w + 34, 212, 34, K.dim, .bold) }
        }
        ux += 48 + w + 130
    }
    reveal(f.p(0, 0.5, 1.6)) { text("units fixed per share · (illustrative)", 360, 282, 18, K.dim) }
    reveal(f.p(1)) { card(R(100, 380, 280, 140), K.green, "Minter", "brings the coins", icon: "person.fill") }
    reveal(f.p(1, 0.5, 0.2)) { card(R(820, 365, 280, 170), K.teal, "SYD index", "WeightedHub", icon: "circle.hexagongrid.fill") }
    let issueIn = Curve(pt(382, 420), pt(818, 420))
    arrow(issueIn, K.green, prog: f.p(1, 0.7, 0.4), label: "issue: ⌈shares × unitsᵢ⌉ of each coin", lofs: pt(0, -24))
    flow(issueIn, basketColors(), f.t, alpha: f.on(1) && !f.on(2) ? f.p(1, 0.5, 1.0) : 0)
    arrow(Curve(pt(818, 485), pt(382, 485)), K.teal, prog: f.p(1, 0.7, 1.2), label: "mints the shares", lofs: pt(0, 24))
    reveal(f.p(2)) { card(R(1540, 380, 280, 140), K.slate, "Holder", "leaves in kind", icon: "person.fill") }
    arrow(Curve(pt(1538, 420), pt(1102, 420)), K.teal, prog: f.p(2, 0.7, 0.3), label: "redeem: burns the shares", lofs: pt(0, -24))
    let redeemOut = Curve(pt(1102, 485), pt(1538, 485))
    arrow(redeemOut, K.green, prog: f.p(2, 0.7, 0.9), label: "pays ⌊shares × unitsᵢ⌋ of each coin", lofs: pt(0, 24))
    flow(redeemOut, basketColors(), f.t, alpha: f.on(2) && !f.on(3) ? f.p(2, 0.5, 1.5) : 0)
    reveal(f.p(3)) {
        pill("no price read", 820, 590, K.red, size: 20, icon: "eye.slash.fill")
        pill("no amount from a balance", 1120, 590, K.red, size: 20, icon: "nosign")
    }
    reveal(f.p(4)) {
        let r = R(100, 650, 1720, 195)
        let top = panel(r, K.teal, "The invariant, for every coin i, always", icon: "checkmark.seal.fill")
        text("balanceOf(index) ≥ ⌊supply × unitsᵢ × scale⌋ + claimsᵢ", 130, top + 6, 30, K.teal, .semibold, mono: true)
        text("rounding always goes the holders' way: issue rounds up, redeem rounds down", 130, top + 60, 20, K.muted)
        for (i, b) in basket.enumerated() {
            let y = top - 10 + CGFloat(i) * 26
            let need = CGFloat(b.1) * 6.5
            rrect(R(1420, y, need, 14), 7, stroke: K.muted, lw: 1.5)
            rrect(R(1420, y, need * f.p(4, 1.0, 0.6) + 22 * f.p(4, 1.0, 0.6), 14), 7, fill: coinColors[b.0]!.withAlphaComponent(0.85))
        }
        text("held ≥ required", 1420, top + 96, 16, K.dim)
    }
}

// 7. Zap mint
func s07(_ f: F) {
    reveal(f.p(0)) { card(R(100, 230, 250, 130), K.green, "User", "1,000 USDC", icon: "person.fill") }
    reveal(f.p(0, 0.6, 0.3)) { card(R(450, 230, 290, 130), K.blue, "IndexZap", "mintWithToken", icon: "bolt.fill") }
    let usdcIn = Curve(pt(352, 278), pt(448, 278))
    arrow(usdcIn, K.green, prog: f.p(0, 0.5, 0.6), label: "USDC", lofs: pt(0, -20))
    reveal(f.p(1)) {
        let r = R(1450, 190, 370, 420)
        let top = panel(r, K.blue, "Quoted legs", icon: "list.bullet.rectangle", size: 22)
        let legs: [(String, String, String, String)] = [
            ("WBTC", "V3", "USDC→WETH→WBTC", "≤ 401"), ("WETH", "V3", "USDC→WETH", "≤ 301"),
            ("LINK", "V4", "USDC→ETH→LINK", "≤ 201"), ("UNI", "V4", "USDC→ETH→UNI", "≤ 101"),
        ]
        for (i, l) in legs.enumerated() {
            let y = top + CGFloat(i) * 62
            reveal(f.p(1, 0.4, 0.3 + Double(i) * 0.25)) {
                coin(pt(r.minX + 44, y + 22), l.0, r: 20)
                pill(l.1, r.minX + 76, y + 10, l.1 == "V3" ? K.blue : K.violet, size: 14, anchor: .left)
                text(l.3, r.maxX - 22, y + 0, 17, K.muted, .semibold, align: .right, mono: true)
                text(l.2, r.minX + 76, y + 26, 15, K.text, mono: true)
            }
        }
        reveal(f.p(1, 0.4, 1.4)) {
            line(pt(r.minX + 24, top + 252), pt(r.maxX - 24, top + 252), K.line)
            text("maxAmountIn  1,004 USDC", r.minX + 26, top + 264, 18, K.text, .semibold, mono: true)
            text("V4 legs hookless · native ETH as a hop", r.minX + 26, top + 294, 15, K.dim)
        }
    }
    reveal(f.p(2)) { card(R(840, 230, 290, 130), K.blue, "Universal Router", "exact-output swaps", icon: "arrow.triangle.swap", ts: 23) }
    reveal(f.p(2, 0.6, 0.3)) {
        card(R(1200, 205, 210, 74), K.blue, "V3 pools", nil, ts: 21)
        card(R(1200, 305, 210, 74), K.violet, "V4 pools", nil, ts: 21)
    }
    let toRouter = Curve(pt(742, 278), pt(838, 278))
    arrow(toRouter, K.green, prog: f.p(2, 0.5, 0.5), label: "USDC", lofs: pt(0, -20))
    arrow(Curve(pt(1132, 270), pt(1198, 242)), K.blue, prog: f.p(2, 0.5, 0.7), lw: 2.5)
    arrow(Curve(pt(1132, 320), pt(1198, 342)), K.violet, prog: f.p(2, 0.5, 0.7), lw: 2.5)
    let back = Curve(pt(985, 362), pt(690, 362), bend: -60)
    arrow(back, K.teal, prog: f.p(2, 0.7, 1.2), label: "exactly each coin's amount", lofs: pt(0, 32))
    flow(back, basketColors(), f.t, alpha: f.on(2) && !f.on(3) ? f.p(2, 0.5, 1.8) : 0)
    reveal(f.p(2, 0.5, 2.2)) { pill("every delivery checked", 840, 488, K.teal, size: 17, icon: "checkmark.shield.fill") }
    reveal(f.p(3)) { card(R(450, 555, 290, 120), K.teal, "SYD index", "issue(shares)", icon: "circle.hexagongrid.fill") }
    arrow(Curve(pt(540, 362), pt(540, 553)), K.teal, prog: f.p(3, 0.5, 0.2), label: "basket", lofs: pt(-50, 0))
    let sharesOut = Curve(pt(448, 615), pt(225, 362), bend: -50)
    arrow(sharesOut, K.teal, prog: f.p(3, 0.6, 0.6), label: "exact shares", lofs: pt(-70, 10))
    arrow(Curve(pt(448, 335), pt(352, 335)), K.green, prog: f.p(3, 0.5, 1.2), dash: true, label: "unspent USDC back", lofs: pt(0, 48), lsize: 15)
    reveal(f.p(4)) {
        let r = R(100, 720, 1300, 120)
        panel(r, K.amber, "Gas per transaction: the zap fits ≈ 35 coins", icon: "gauge.with.dots.needle.67percent", size: 21)
        let x1 = r.minX + 30
        let x2 = r.maxX - 30
        let y = r.minY + 84
        rrect(R(x1, y - 9, x2 - x1, 18), 9, fill: K.line)
        let fill = (x2 - x1) * 0.94 * f.p(4, 1.6, 0.4)
        rrect(R(x1, y - 9, fill, 18), 9, fill: K.amber.withAlphaComponent(0.85))
        line(pt(x1 + (x2 - x1) * 0.94, y - 22), pt(x1 + (x2 - x1) * 0.94, y + 22), K.red, lw: 3)
        text("2²⁴ ≈ 16.78M cap", x2, r.minY + 20, 18, K.red, .semibold, align: .right)
    }
    reveal(f.p(4, 0.6, 1.4)) {
        card(R(1450, 650, 370, 190), K.violet, "expectedNonce", "= rebalanceNonce() when quoted; a rebalance in between → revert", icon: "number", ts: 23, ss: 18, mono: true)
    }
}

// 8. Basket builder
func s08(_ f: F) {
    reveal(f.p(0)) { card(R(100, 345, 230, 130), K.green, "Minter", "100-coin basket", icon: "person.fill") }
    let txs = ["buy · legs 1–34", "buy · legs 35–68", "buy · legs 69–100"]
    for (i, s) in txs.enumerated() {
        let d = Double(i) * 1.3
        reveal(f.p(1, 0.5, d)) { card(R(420, 195 + CGFloat(i) * 145, 360, 112), K.orange, s, "transaction \(i + 1)", icon: "cart.fill", ts: 23) }
        arrow(Curve(pt(332, 410), pt(418, 251 + CGFloat(i) * 145)), K.green, prog: f.p(1, 0.4, d + 0.2), lw: 2.5)
        arrow(Curve(pt(782, 251 + CGFloat(i) * 145), pt(878, 300 + CGFloat(i) * 110)), K.orange, prog: f.p(1, 0.4, d + 0.4), lw: 2.5)
    }
    reveal(f.p(0, 0.6, 0.6)) {
        let r = R(880, 190, 440, 420)
        let top = panel(r, K.orange, "Your escrow", icon: "lock.fill", size: 23)
        text("only its owner can move it", r.minX + 230, r.minY + 26, 16, K.muted)
        var filled = 0.0
        for i in 0..<3 {
            filled += (i == 2 ? 32 : 34) * Double(f.p(1, 0.9, Double(i) * 1.3 + 0.6))
        }
        let n = Int(filled.rounded())
        for k in 0..<100 {
            let x = r.minX + 52 + CGFloat(k % 10) * 34
            let y = top + 2 + CGFloat(k / 10) * 32
            rrect(R(x, y, 26, 24), 6, fill: k < n ? K.orange.withAlphaComponent(0.9) : K.line.withAlphaComponent(0.7))
        }
    }
    reveal(f.p(2)) { card(R(1420, 300, 400, 130), K.teal, "mint", "transaction 4: issue from the escrow", icon: "seal.fill", ts: 26) }
    arrow(Curve(pt(1322, 400), pt(1418, 368)), K.teal, prog: f.p(2, 0.5, 0.3))
    reveal(f.p(2, 0.6, 0.8)) {
        text("100 coins =", 1420, 470, 26, K.muted, .semibold)
        text("3 buys + 1 mint", 1420, 506, 40, K.teal, .heavy)
        text("each under the 16.78M gas cap", 1420, 562, 18, K.dim)
    }
    reveal(f.p(3)) {
        let r = R(100, 660, 1720, 180)
        let top = panel(r, K.orange, "Selling mirrors it", icon: "arrow.uturn.backward", size: 23)
        let steps: [(String, String)] = [
            ("redeem → escrow", "arrow.down.to.line"), ("sell(legs) × n", "cart.badge.minus"),
            ("withdraw the rest", "arrow.up.right.square"), ("deposit: a coin with no route", "tray.and.arrow.down.fill"),
        ]
        var x = r.minX + 30
        for (i, s) in steps.enumerated() {
            let px = x
            reveal(f.p(3, 0.5, 0.3 + Double(i) * 0.6)) {
                pill(s.0, px, top + 34, i == 3 ? K.muted : K.orange, size: 21, mono: false, icon: s.1, anchor: .left)
                if i > 0 && i < 3 { symbol("chevron.right", pt(px - 22, top + 34), 18, K.dim) }
            }
            x += pillSize(s.0, 21, icon: true).width + (i == 2 ? 90 : 44)
        }
    }
}

// 9. MintRequests
func s09(_ f: F) {
    reveal(f.p(0)) { card(R(100, 300, 300, 150), K.green, "Requester", "holds 1,000 USDC", icon: "person.fill") }
    reveal(f.p(1)) {
        let r = R(760, 270, 400, 215)
        let top = panel(r, K.pink, "MintRequests", icon: "tray.full.fill")
        let rows = [("escrow", "1,000 USDC"), ("minShares", "9.9 SYD"), ("deadline", "≤ 30 days")]
        for (i, row) in rows.enumerated() {
            text(row.0, r.minX + 28, top + CGFloat(i) * 38, 21, K.muted, mono: true)
            text(row.1, r.maxX - 28, top + CGFloat(i) * 38, 21, K.text, .semibold, align: .right, mono: true)
        }
    }
    let deposit = Curve(pt(402, 375), pt(758, 375))
    arrow(deposit, K.green, prog: f.p(1, 0.6, 0.3), label: "requestMint(…)", lofs: pt(0, -22), mono: true)
    flow(deposit, [K.green, K.green, K.green], f.t, alpha: f.on(1) && !f.on(2) ? f.p(1, 0.5, 0.9) : 0)
    reveal(f.p(2)) { card(R(1520, 300, 300, 150), K.teal, "Filler", "a keeper or any holder", icon: "gearshape.2.fill") }
    reveal(f.p(2, 0.5, 0.3)) { pill("fill(id, amount)", 1670, 485, K.teal, mono: true) }
    let shares = Curve(pt(1600, 298), pt(320, 298), bend: 170)
    arrow(shares, K.teal, prog: f.p(2, 0.8, 0.6), label: "at least 9.9 SYD, straight to the requester", lofs: pt(0, -24))
    let pay = Curve(pt(1162, 420), pt(1518, 420))
    arrow(pay, K.green, prog: f.p(2, 0.6, 1.4), label: "the escrowed USDC", lofs: pt(0, 24))
    flow(shares, [K.teal, K.teal], f.t, alpha: f.on(2) && !f.on(3) ? f.p(2, 0.5, 1.4) : 0, speed: 0.35)
    flow(pay, [K.green, K.green], f.t, alpha: f.on(2) && !f.on(3) ? f.p(2, 0.5, 2.0) : 0)
    let badges: [(String, String, NSColor)] = [
        ("the limit is the only valuation: no price", "eye.slash.fill", K.amber),
        ("cancel: the requester, any time", "xmark.circle.fill", K.pink),
        ("refund: anyone, after the deadline", "arrow.uturn.backward.circle.fill", K.pink),
    ]
    for (i, b) in badges.enumerated() {
        reveal(f.p(3, 0.5, Double(i) * 0.7)) { pill(b.0, [390, 960, 1520][i], 575, b.2, size: 19, icon: b.1) }
    }
    reveal(f.p(4)) {
        let r = R(100, 650, 1720, 190)
        let top = panel(r, K.pink, "Redemptions mirror it", icon: "arrow.left.arrow.right")
        text("requestRedeem(index, shares, stable, minOut, deadline)", r.minX + 30, top, 24, K.pink, .medium, mono: true)
        text("escrow shares → a filler pays at least minOut USDC or USDT → the filler takes the shares", r.minX + 30, top + 44, 21, K.muted)
    }
}

// 10. Fees
func s10(_ f: F) {
    reveal(f.p(0)) {
        let r = R(100, 190, 900, 655)
        let top = panel(r, K.amber, "Fee on every mint and burn", icon: "percent")
        text("example: creator 0.50 % + platform 0.25 % (bars not to scale)", r.minX + 28, top - 6, 18, K.dim)
    }
    func stack(_ y: CGFloat, _ title: String, _ a: CGFloat, _ note: String) {
        reveal(a) {
            text(title, 130, y - 36, 22, K.text, .bold)
            let x0: CGFloat = 130
            let segs: [(CGFloat, NSColor, String)] = [
                (500, K.teal, "100 SYD"), (115, K.violet, "creator"), (120, K.amber, "platform"), (85, K.pink, "referrer"),
            ]
            var x = x0
            for s in segs {
                rrect(R(x, y, s.0 - 4, 44), 8, fill: s.1.withAlphaComponent(0.85))
                text(s.2, x + (s.0 - 4) / 2, y + 10, 18, K.bg0, .bold, align: .center)
                x += s.0
            }
            text(note, 130, y + 56, 19, K.muted, width: 820)
        }
    }
    stack(310, "Mint 100 SYD", f.p(1), "the deposit backs the fee's shares on top of the minter's own")
    stack(470, "Burn 100 SYD", f.p(1, 0.6, 2.2), "≈ 0.75 SYD go to the recipients; the burner is paid the backing of the rest")
    let rec: [(String, String, String, NSColor)] = [
        ("Creator", "the creator's rate", "person.crop.circle", K.violet),
        ("Platform", "the platform's rate", "building.2.fill", K.amber),
        ("Referrer", "a share of the platform's part", "person.wave.2.fill", K.pink),
    ]
    for (i, r) in rec.enumerated() {
        reveal(f.p(2, 0.5, Double(i) * 0.5)) {
            card(R(130 + CGFloat(i) * 285, 640, 270, 150), r.3, r.0, r.1, icon: r.2, ts: 22, ss: 17)
        }
    }
    reveal(f.p(3)) {
        let r = R(1040, 190, 780, 655)
        let top = panel(r, K.amber, "Streaming fee: a unit scale", icon: "clock.arrow.circlepath")
        let ax = R(r.minX + 60, top + 30, 540, 330)
        line(pt(ax.minX, ax.maxY), pt(ax.maxX, ax.maxY), K.muted, lw: 2)
        line(pt(ax.minX, ax.minY), pt(ax.minX, ax.maxY), K.muted, lw: 2)
        text("time →", ax.maxX, ax.maxY + 10, 17, K.dim, align: .right)
        let pr = f.p(3, 2.2, 0.4)
        func series(_ y0: CGFloat, _ y1: CGFloat, _ c: NSColor, _ name: String) {
            let p = NSBezierPath()
            p.move(to: pt(ax.minX, y0))
            p.line(to: pt(ax.minX + ax.width * pr, lerp(y0, y1, pr)))
            p.lineWidth = 4
            p.lineCapStyle = .round
            c.setStroke()
            p.stroke()
            text(name, ax.minX + ax.width * pr + 10, lerp(y0, y1, pr) - 12, 18, c, .semibold)
        }
        series(ax.minY + 150, ax.minY + 40, K.violet, "supply")
        series(ax.minY + 165, ax.minY + 165, K.teal, "basket held")
        series(ax.minY + 180, ax.minY + 290, K.amber, "units per share")
        text("fee shares are minted to the creator and the platform;", r.minX + 30, ax.maxY + 48, 20, K.muted)
        text("every share's units shrink by the same factor", r.minX + 30, ax.maxY + 76, 20, K.muted)
        reveal(f.p(3, 0.6, 2.4)) { pill("no coin moves: the fee is ownership", r.midX, r.maxY - 40, K.amber, size: 20, icon: "checkmark.seal.fill") }
    }
}

// 11. Burn
func s11(_ f: F) {
    reveal(f.p(0)) { card(R(100, 225, 250, 130), K.slate, "Holder", "100 SYD", icon: "person.fill") }
    reveal(f.p(0, 0.6, 0.3)) { card(R(450, 225, 290, 130), K.blue, "IndexZap", "burnToToken", icon: "bolt.fill") }
    arrow(Curve(pt(352, 290), pt(448, 290)), K.teal, prog: f.p(0, 0.5, 0.6), label: "SYD", lofs: pt(0, -20))
    reveal(f.p(1)) { card(R(450, 455, 290, 120), K.teal, "SYD index", "redeem(shares)", icon: "circle.hexagongrid.fill") }
    arrow(Curve(pt(545, 357), pt(545, 453)), K.teal, prog: f.p(1, 0.4, 0.2), label: "shares", lofs: pt(-48, 0))
    let basketUp = Curve(pt(645, 453), pt(645, 357))
    arrow(basketUp, K.green, prog: f.p(1, 0.4, 0.5), label: "basket", lofs: pt(52, 0))
    flow(basketUp, basketColors(), f.t, alpha: f.on(1) && !f.on(2) ? f.p(1, 0.4, 0.8) : 0, speed: 0.7, r: 6)
    reveal(f.p(1, 0.6, 0.8)) {
        card(R(840, 225, 290, 130), K.blue, "Universal Router", "exact-input swaps", icon: "arrow.triangle.swap", ts: 23)
        card(R(1200, 200, 210, 74), K.blue, "V3 pools", nil, ts: 21)
        card(R(1200, 300, 210, 74), K.violet, "V4 pools", nil, ts: 21)
    }
    arrow(Curve(pt(742, 290), pt(838, 290)), K.green, prog: f.p(1, 0.5, 1.0))
    arrow(Curve(pt(1132, 270), pt(1198, 240)), K.blue, prog: f.p(1, 0.5, 1.1), lw: 2.5)
    arrow(Curve(pt(1132, 320), pt(1198, 337)), K.violet, prog: f.p(1, 0.5, 1.1), lw: 2.5)
    let out = Curve(pt(985, 222), pt(225, 222), bend: 80)
    arrow(out, K.green, prog: f.p(1, 0.8, 1.5), label: "USDT, or any token, at least minAmountOut", lofs: pt(0, -24))
    flow(out, [rgb(0x26A17B), rgb(0x26A17B), rgb(0x26A17B)], f.t, alpha: f.on(1) && !f.on(2) ? f.p(1, 0.5, 2.2) : 0, speed: 0.4)
    reveal(f.p(1, 0.6, 0.4)) {
        let r = R(1450, 190, 370, 300)
        let top = panel(r, K.green, "Minimums", icon: "shield.lefthalf.filled", size: 22)
        let mins = [("WBTC", "≥ 395"), ("WETH", "≥ 296"), ("LINK", "≥ 197"), ("UNI", "≥ 98")]
        for (i, m) in mins.enumerated() {
            let y = top + CGFloat(i) * 42
            coin(pt(r.minX + 42, y + 14), m.0, r: 16)
            text(m.0, r.minX + 70, y + 2, 19, K.text, .semibold)
            text(m.1, r.maxX - 24, y + 2, 19, K.muted, .semibold, align: .right, mono: true)
        }
        text("overall ≥ 990 USDT", r.minX + 28, top + 176, 19, K.green, .bold, mono: true)
    }
    reveal(f.p(2)) { pill("unsold input → back to the holder", 985, 420, K.blue, size: 18, icon: "arrow.uturn.backward") }
    reveal(f.p(2, 0.6, 1.0)) { card(R(1450, 505, 370, 90), K.teal, "redeem(shares, to)", "in kind, no zap needed", icon: "shippingbox.fill", ts: 21, ss: 17, mono: true) }
    reveal(f.p(3)) {
        let r = R(100, 625, 1720, 220)
        let top = panel(r, K.red, "A frozen coin: redeemSkipping(shares, to, skipMask)", icon: "snowflake", size: 23)
        coin(pt(r.minX + 70, top + 50), "WBTC", r: 32)
        symbol("lock.fill", pt(r.minX + 98, top + 26), 20, K.red)
        text("paused by its issuer", r.minX + 115, top + 36, 20, K.red, .semibold)
        arrow(Curve(pt(r.minX + 330, top + 50), pt(r.minX + 470, top + 50)), K.red, prog: f.p(3, 0.5, 0.6), dash: true)
        pill("claimOf(holder, WBTC)", r.minX + 480, top + 50, K.red, size: 19, mono: true, anchor: .left)
        reveal(f.p(3, 0.5, 1.6)) {
            arrow(Curve(pt(r.minX + 760, top + 50), pt(r.minX + 870, top + 50)), K.green, prog: 1)
            pill("claim(WBTC, to) once it resumes", r.minX + 880, top + 50, K.green, size: 19, anchor: .left)
        }
        reveal(f.p(3, 0.5, 0.9)) {
            for (i, s) in ["WETH", "LINK", "UNI"].enumerated() { coin(pt(r.minX + 70 + CGFloat(i) * 70, top + 128), s, r: 26) }
            arrow(Curve(pt(r.minX + 260, top + 128), pt(r.minX + 470, top + 128)), K.green, prog: 1)
            text("every other coin, paid now", r.minX + 485, top + 114, 21, K.green, .semibold)
        }
    }
    reveal(f.p(4)) {
        pill("no pause", 880, 540, K.teal, size: 20, filled: true, icon: "checkmark")
        pill("no speed limit", 1070, 540, K.teal, size: 20, filled: true, icon: "checkmark")
        pill("no cap on a burn", 1290, 540, K.teal, size: 20, filled: true, icon: "checkmark")
    }
}

// 12. Rebalance timeline
let drifted: [Double] = [52, 25, 15, 8]

func s12(_ f: F) {
    reveal(f.p(0)) {
        let r = R(100, 190, 700, 300)
        let top = panel(r, K.teal, "Drift: share of value", icon: "chart.bar.fill", size: 22)
        let d = f.io(0, 2.2, 0.6)
        for (i, b) in basket.enumerated() {
            let y = top + 6 + CGFloat(i) * 52
            coin(pt(r.minX + 46, y + 14), b.0, r: 18)
            let now = lerp(CGFloat(b.1), CGFloat(drifted[i]), d)
            rrect(R(r.minX + 80, y + 4, now * 9, 22), 6, fill: coinColors[b.0]!.withAlphaComponent(0.85))
            line(pt(r.minX + 80 + CGFloat(b.1) * 9, y - 2), pt(r.minX + 80 + CGFloat(b.1) * 9, y + 32), K.text, lw: 2.5, dash: [4, 4])
            text(String(format: "%.0f %%", now), r.maxX - 24, y + 2, 19, K.muted, .semibold, align: .right, mono: true)
        }
        text("dashed: target weight", r.minX + 80, r.maxY - 36, 16, K.dim)
    }
    reveal(f.p(1, 0.6, 0.8)) {
        codeCard(R(860, 200, 960, 110), K.teal, ["startRebalance(0)   // anyone, once the interval has passed", "// reads no price, calls no coin: sets the auction's start"], size: 22)
    }
    let y: CGFloat = 565
    let xs: [CGFloat] = [120, 620, 840, 1560, 1800]
    reveal(f.p(1)) {
        line(pt(xs[0], y), pt(xs[1], y), K.muted, lw: 5, dash: [10, 10])
        circle(pt(xs[0], y), 10, fill: K.muted)
        text("last rebalance", xs[0], y + 22, 18, K.muted, .semibold)
        text("interval: 7 – 91 days", (xs[0] + xs[1]) / 2, y - 44, 22, K.text, .bold, align: .center)
        circle(pt(xs[1], y), 12, fill: K.teal)
        pill("startRebalance", xs[1], y + 40, K.teal, size: 17, mono: true)
    }
    reveal(f.p(2)) {
        rrect(R(xs[1], y - 8, xs[2] - xs[1], 16), 8, fill: K.amber)
        text("2 h notice", (xs[1] + xs[2]) / 2 + 10, y - 44, 22, K.amber, .bold, align: .center)
        pill("issue & redeem stay open", (xs[1] + xs[2]) / 2 + 40, y + 88, K.green, size: 16, icon: "checkmark")
    }
    reveal(f.p(3)) {
        rrect(R(xs[2], y - 8, xs[3] - xs[2], 16), 8, fill: K.teal)
        text("24 h Dutch auction", (xs[2] + xs[3]) / 2, y - 44, 22, K.teal, .bold, align: .center)
        let top: CGFloat = 690
        let bot: CGFloat = 845
        line(pt(xs[2], top), pt(xs[2], bot), K.line, lw: 2)
        line(pt(xs[2], (top + bot) / 2), pt(xs[3], (top + bot) / 2), K.line, lw: 1.5, dash: [6, 6])
        text("μ 1.02", xs[2] - 12, top - 12, 18, K.text, .semibold, align: .right, mono: true)
        text("1.00", xs[2] - 12, (top + bot) / 2 - 12, 18, K.muted, align: .right, mono: true)
        text("0.98", xs[2] - 12, bot - 12, 18, K.text, .semibold, align: .right, mono: true)
        let pr = f.p(3, 2.0, 0.5)
        let p = NSBezierPath()
        p.move(to: pt(xs[2], top))
        p.line(to: pt(lerp(xs[2], xs[3], pr), lerp(top, bot, pr)))
        p.lineWidth = 5
        p.lineCapStyle = .round
        K.teal.setStroke()
        p.stroke()
    }
    reveal(f.p(4)) {
        let top: CGFloat = 690
        let bot: CGFloat = 845
        let u: CGFloat = 0.42
        let px = lerp(xs[2], xs[3], u)
        let py = lerp(top, bot, u)
        for (i, gu) in [CGFloat(0.12), 0.27].enumerated() {
            circle(pt(lerp(xs[2], xs[3], gu), lerp(top, bot, gu)), 8, stroke: K.dim, lw: 2)
            text(["too early", "not yet"][i], lerp(xs[2], xs[3], gu) + 14, lerp(top, bot, gu) - 34, 15, K.dim)
        }
        circle(pt(px, py), 13, fill: K.amber, stroke: K.text, lw: 3)
        pill("filled at μ ≈ 1.003", px + 24, py - 30, K.amber, size: 18, anchor: .left)
        line(pt(xs[3] + 20, y), pt(xs[4], y), K.dim, lw: 5, dash: [10, 10])
        text("unfilled → expires,", xs[3] + 20, y + 26, 16, K.dim)
        text("start again", xs[3] + 20, y + 48, 16, K.dim)
    }
}

// 13. Settlement
func s13(_ f: F) {
    let lanes: [(String, CGFloat, NSColor, String)] = [
        ("Executor", 230, K.slate, "gearshape.2.fill"), ("WeightedHub", 620, K.teal, "circle.hexagongrid.fill"),
        ("Pyth", 1000, K.amber, "chart.line.uptrend.xyaxis"),
    ]
    reveal(f.p(0)) {
        for l in lanes {
            card(R(l.1 - 120, 188, 240, 64), l.2, l.0, nil, icon: l.3, ts: 21)
            line(pt(l.1, 254), pt(l.1, 850), l.2.withAlphaComponent(0.45), lw: 2, dash: [6, 8])
        }
    }
    func msg(_ y: CGFloat, _ from: Int, _ to: Int, _ s: String, _ c: NSColor, _ a: CGFloat, dash: Bool = false) {
        let x1 = lanes[from].1 + (to > from ? 8 : -8)
        let x2 = lanes[to].1 + (to > from ? -8 : 8)
        arrow(Curve(pt(x1, y), pt(x2, y)), c, prog: a, lw: 2.5, dash: dash, label: s, lofs: pt(0, -18), lsize: 16, mono: true)
    }
    func note(_ y: CGFloat, _ s: String, _ c: NSColor, _ a: CGFloat) {
        reveal(a) {
            let w = measure(s, 17, .medium, width: 1000, mono: true).width + 30
            rrect(R(lanes[1].1 - 40, y - 20, w, 40), 10, fill: rgb(0x0A1024), stroke: c.withAlphaComponent(0.8), lw: 1.5)
            text(s, lanes[1].1 - 25, y - 11, 17, c, .medium, mono: true)
        }
    }
    msg(300, 0, 1, "executeRebalance(data, priceUpdate) + fee", K.slate, f.p(0, 0.7, 0.5))
    msg(375, 1, 2, "parse at priceTime = block − 12 s", K.amber, f.p(1, 0.7, 0))
    msg(430, 2, 1, "each coin's first update at or after it", K.amber, f.p(1, 0.7, 1.4), dash: true)
    note(500, "targetᵢ = wᵢ · V ÷ (W · pᵢ)", K.teal, f.p(2))
    note(565, "same share s · ≤ 20 % of units out · ≥ 0.1 % traded", K.teal, f.p(3))
    msg(640, 1, 0, "shrinking legs (amountsOut)", K.red, f.p(4, 0.7, 0))
    msg(705, 0, 1, "callback: growing legs × μ (amountsIn)", K.green, f.p(4, 0.7, 1.2))
    note(790, "post-check: every coin backs the new units ✓", K.green, f.p(5))
    reveal(f.p(2)) {
        let r = R(1170, 188, 650, 662)
        let top = panel(r, K.amber, "Share of value: now → target", icon: "scope", size: 22)
        let after: [CGFloat] = [41.6, 29.3, 19.3, 9.7]
        let mv = f.io(3, 1.6, 0.6)
        for (i, b) in basket.enumerated() {
            let y = top + 18 + CGFloat(i) * 92
            coin(pt(r.minX + 44, y + 16), b.0, r: 20)
            let now = lerp(CGFloat(drifted[i]), after[i], mv)
            let c: NSColor = CGFloat(drifted[i]) > CGFloat(b.1) ? K.red : K.green
            rrect(R(r.minX + 80, y + 4, now * 9, 24), 6, fill: c.withAlphaComponent(0.8))
            let tx = r.minX + 80 + CGFloat(b.1) * 9
            line(pt(tx, y - 4), pt(tx, y + 36), K.text, lw: 2.5, dash: [4, 4])
            text(String(format: "%.1f → %d %%", Double(now), b.1), r.maxX - 22, y + 4, 18, K.muted, .semibold, align: .right, mono: true)
            reveal(f.p(4, 0.5, Double(i) * 0.2)) {
                text(drifted[i] > Double(b.1) ? "→ executor" : "← executor × μ", r.minX + 80, y + 36, 15, c, .semibold)
            }
        }
        reveal(f.p(3, 0.6, 1.8)) {
            text("WBTC needs −23 % of its units;", r.minX + 30, r.maxY - 112, 19, K.text, .semibold)
            text("the cap allows −20 %, so every leg", r.minX + 30, r.maxY - 84, 19, K.muted)
            text("moves s = 0.87 of the way", r.minX + 30, r.maxY - 56, 19, K.muted)
        }
    }
}

// 14. Keeper
func s14(_ f: F) {
    let center = R(700, 395, 520, 170)
    let sats: [(CGRect, String, String, String, NSColor, Int, Double)] = [
        (R(100, 205, 520, 140), "Start due rebalances", "anyone may; the bot does it on time", "play.circle.fill", K.teal, 1, 0),
        (R(1300, 205, 520, 140), "Simulate every block", "fill the auction once it pays", "waveform.path.ecg", K.amber, 1, 0.6),
        (R(100, 615, 520, 140), "Fill MintRequests", "at their limits, swapping in the same tx", "tray.full.fill", K.pink, 2, 0),
        (R(1300, 615, 520, 140), "Serve route-less coins", "from its executor's own stock", "shippingbox.fill", K.orange, 2, 0.8),
    ]
    for s in sats {
        let c0 = pt(s.0.midX < 960 ? s.0.maxX : s.0.minX, s.0.midY)
        let c1 = pt(s.0.midX < 960 ? center.minX : center.maxX, s.0.midY < 480 ? center.minY + 30 : center.maxY - 30)
        arrow(Curve(c1, c0), s.4, prog: f.p(s.5, 0.5, s.6), lw: 2.5, dash: true)
        reveal(f.p(s.5, 0.6, s.6 + 0.2)) { card(s.0, s.4, s.1, s.2, icon: s.3, ts: 24, ss: 18) }
    }
    reveal(f.p(0)) { card(center, K.teal, "Keeper bot", "keeper/ · Node bot + executor contract", icon: "cpu.fill", ts: 30, ss: 19) }
    reveal(f.p(3)) {
        pill("no role in the protocol", 960, 630, K.green, size: 21, filled: true, icon: "checkmark.shield.fill")
        pill("its own hot key: never the owner's or the guardian's", 960, 690, K.green, size: 19, icon: "key.fill")
    }
}

// 15. Governance
func s15(_ f: F) {
    let cols: [(String, String, NSColor, [String], Int)] = [
        ("Owner Safe", "checkmark.shield.fill", K.violet, ["propose listings · 2-day delay", "propose a guardian · 7-day delay", "set the fee policy · later indexes only", "delist a coin", "proposals expire after 7 days"], 1),
        ("Guardian", "shield.lefthalf.filled", K.amber, ["cancel pending listings", "cancel a rebalance", "start one with a keep mask", "delist a coin", "cannot block its own replacement"], 2),
        ("Nobody can", "nosign", K.red, ["move an index's funds", "mint or burn anyone's shares", "pause or upgrade", "change coins, units or weights", "sweep tokens"], 3),
    ]
    for (i, c) in cols.enumerated() {
        let r = R(100 + CGFloat(i) * 590, 190, 540, 650)
        reveal(f.p(0, 0.6, Double(i) * 0.3)) {
            panel(r, c.2, c.0, icon: c.1, size: 28)
        }
        for (j, item) in c.3.enumerated() {
            reveal(f.p(c.4, 0.5, 0.3 + Double(j) * 0.45)) {
                let y = r.minY + 100 + CGFloat(j) * 104
                symbol(i == 2 ? "xmark.circle.fill" : "checkmark.circle.fill", pt(r.minX + 46, y + 16), 26, i == 2 ? K.red : c.2)
                text(item, r.minX + 80, y, 24, K.text, .medium, width: r.width - 110)
            }
        }
    }
}

// 16. Recap
func s16(_ f: F) {
    let steps: [(String, String, NSColor)] = [
        ("List", "checklist", K.violet), ("Create", "plus.circle.fill", K.teal), ("Mint", "bolt.fill", K.blue),
        ("Hold", "circle.hexagongrid.fill", K.teal), ("Rebalance", "arrow.triangle.2.circlepath", K.amber),
        ("Burn", "arrow.down.right.circle.fill", K.green),
    ]
    for (i, s) in steps.enumerated() {
        let x = 200 + CGFloat(i) * 304
        reveal(f.p(0, 0.5, Double(i) * 0.35)) {
            circle(pt(x, 360), 78, fill: s.2.withAlphaComponent(0.12), stroke: s.2, lw: 3)
            symbol(s.1, pt(x, 360), 50, s.2)
            text(s.0, x, 456, 28, K.text, .bold, align: .center)
        }
        if i > 0 { arrow(Curve(pt(x - 220, 360), pt(x - 84, 360)), K.dim, prog: f.p(0, 0.4, Double(i) * 0.35 - 0.1), lw: 2.5) }
    }
    let pillars: [(String, String, String, NSColor)] = [
        ("Backed in kind", "amounts from supply × units, never balances", "cube.fill", K.teal),
        ("Priced only at settlement", "issue, redeem and claims read no price", "eye.slash.fill", K.amber),
        ("Always open for exit", "redeem or redeemSkipping, at any time", "door.left.hand.open", K.green),
    ]
    for (i, p) in pillars.enumerated() {
        reveal(f.p(1, 0.6, Double(i) * 0.4)) { card(R(100 + CGFloat(i) * 590, 560, 540, 130), p.3, p.0, p.1, icon: p.2, ts: 26, ss: 18) }
    }
    reveal(f.p(2)) { pill("v5 · built and reviewed · not yet deployed on mainnet", 960, 770, K.muted, size: 21, icon: "info.circle") }
}

let scenes: [Scene] = [
    Scene(kicker: "XINDEX", title: "", color: K.teal, beats: [
        "Xindex is a marketplace where anyone can turn a crypto portfolio into a single ERC-20 token.",
        "This video follows every flow in detail: listing a coin, creating an index, minting it, rebalancing it, and burning it.",
    ], draw: s01),
    Scene(kicker: "THE MAP", title: "One deployment, five contracts", color: K.teal, beats: [
        "Xindex is one deployment, on Ethereum. Five contracts do all the work.",
        "The factory lists coins and creates indexes. Every index is a WeightedHub: an ERC-20 token that holds its basket of coins in kind.",
        "The zap and the basket builder turn USDC or USDT into the basket through Uniswap's Universal Router, and back again.",
        "MintRequests is an escrow for limit orders. And Pyth supplies the prices, which only a rebalance ever reads.",
        "Around them are the people: creators, minters and holders, keepers who fill auctions, and an owner Safe with a guardian. None of them can touch an index's funds.",
    ], draw: s02),
    Scene(kicker: "STEP 1 · LISTING", title: "Every coin starts as a timelocked listing", color: K.violet, beats: [
        "Every coin starts as a listing. The owner, a Safe that needs at least three signatures, proposes a token together with its Pyth price id.",
        "The factory reads the token's decimals right away and starts a two-day delay. During those two days, the guardian can cancel.",
        "After the delay, anyone can execute the listing, but only within a seven-day window. After that, it expires.",
        "Ninety-two coins are listed today: tokens issued on Ethereum, Bitcoin as WBTC, and other chains' coins as Wormhole copies, labelled Bridged. Tether Gold and Ondo's stock tokens are labelled Custodial.",
        "Before any listing, the CheckToken script writes a report on the token for the Safe's signers.",
    ], draw: s03),
    Scene(kicker: "STEP 2 · CREATE", title: "A creator chooses the coins and the percentages", color: K.teal, beats: [
        "A creator picks two to a hundred listed coins, and gives each one a weight in basis points. The weights must add up to ten thousand, which is one hundred percent.",
        "The app turns each weight into starting units at its own prices: the weight, times the value one index token should start at, divided by the coin's price.",
        "Then the creator calls createIndex with a name, a symbol, the components and the index's terms, and pays the creation fee in ether.",
        "The factory deploys a minimal clone with CREATE2. The address commits to every token, unit, weight, price id and fee, so the app can show it before the transaction is sent.",
        "The factory itself reads no price. If the starting units are slightly off, the first rebalance brings the index to its exact weights.",
    ], draw: s04),
    Scene(kicker: "STEP 2 · TERMS", title: "The terms are fixed when the index is created", color: K.teal, beats: [
        "Along with the coins, the creator fixes the index's terms. They are part of its address, and can never change.",
        "A fee on every mint and burn: up to one percent for the creator, plus the platform's fee, up to a quarter of a percent.",
        "A yearly streaming fee: up to five percent for the creator, plus up to one percent for the platform. The platform's rates are zero until the owner sets a policy.",
        "A rebalance interval, from seven to ninety-one days: weekly to quarterly.",
        "And optionally, a gate: only addresses the creator allows may mint, until the creator opens minting for good. An unlisted index is hidden by the app.",
    ], draw: s05),
    Scene(kicker: "THE CORE", title: "Every share is backed in kind", color: K.teal, beats: [
        "This is the heart of Xindex. Each index share stands for fixed units of every coin in the basket.",
        "Issue pulls shares times units of each coin from the minter, rounded up, and mints the shares.",
        "Redeem burns the shares and pays out shares times units of each coin, rounded down. Rounding always favours the holders.",
        "Neither path reads a price, and no amount is ever computed from a balance, so there is no share price to manipulate.",
        "The invariant holds for every coin, always: the index's balance covers the supply times the units, plus any claims still owed.",
    ], draw: s06),
    Scene(kicker: "STEP 3 · MINT", title: "Mint with USDC or USDT in one transaction", color: K.blue, beats: [
        "Most users arrive with USDC or USDT. The zap turns a stablecoin into the whole basket in one transaction.",
        "The app quotes every leg, as a Uniswap V3 path or a hookless V4 path, and sets a limit on each leg plus an overall maximum.",
        "The zap pulls the stablecoin and buys exactly each coin's amount with exact-output swaps through the Universal Router. Then it checks that every amount arrived.",
        "It issues the exact number of shares to the user, and refunds whatever stablecoin it did not spend.",
        "One transaction fits about thirty-five coins under Ethereum's gas cap. And the quote carries the rebalance nonce, so a quote made before a rebalance reverts instead of filling at stale amounts.",
    ], draw: s07),
    Scene(kicker: "STEP 3 · WIDE BASKETS", title: "Up to 100 coins: the basket builder", color: K.orange, beats: [
        "A wider basket, of up to a hundred coins, does not fit in one transaction. The basket builder splits the purchase.",
        "Each buy call swaps a batch of about thirty-five legs into an escrow that belongs to the minter alone. Nobody else can move it.",
        "When the escrow holds every leg, one mint call issues the shares. A hundred-coin basket takes three buys and one mint.",
        "Selling mirrors it: redeem into the escrow, sell the legs over several calls, and withdraw anything that has no route. A coin with no route can also be deposited directly.",
    ], draw: s08),
    Scene(kicker: "STEP 3 · MINT AT A LIMIT", title: "MintRequests: a limit order, no swaps", color: K.pink, beats: [
        "There is also a way to mint without any swaps: MintRequests.",
        "A requester escrows USDC with a limit: at least this many shares, before this deadline, which is at most thirty days away.",
        "Anyone who holds shares, or can issue them in kind, fills the request. The shares go straight to the requester, and the escrowed USDC goes to the filler.",
        "The requester's limit is the only valuation, so nothing reads a price. The requester can cancel at any time, and after the deadline anyone can refund the escrow to the requester.",
        "Redemptions mirror it: escrow shares, and receive at least a minimum amount of stablecoin.",
    ], draw: s09),
    Scene(kicker: "FEES", title: "Fees are paid in shares, never in coins", color: K.amber, beats: [
        "Fees are paid in index shares. They never take coins out of the basket.",
        "On a mint, the deposit backs the fee's shares on top of the minter's own. On a burn, the fee is minted to the recipients out of the burned shares, and the burner is paid the backing of the rest.",
        "The creator takes the creator's rate. The platform takes its rate, and a referrer named at mint takes a share of the platform's part.",
        "The streaming fee mints new shares as time passes, and scales every share's units down by the same factor. No coin moves: the fee is ownership.",
    ], draw: s10),
    Scene(kicker: "STEP 4 · BURN", title: "Leave into any token, at any time", color: K.green, beats: [
        "To leave, a holder burns shares into any token they choose.",
        "The zap redeems the basket from the index, sells every coin with exact-input swaps, and checks each leg's minimum and the overall minimum.",
        "Any input a swap did not sell goes back to the holder. And anyone can skip the zap and redeem in kind, straight from the index.",
        "If a coin is frozen, say its issuer pauses transfers, redeemSkipping pays every other coin now, and books the frozen one as a claim, paid out once transfers resume.",
        "There is no pause, no speed limit, and no cap on a burn. Holders can always leave.",
    ], draw: s11),
    Scene(kicker: "STEP 5 · REBALANCE", title: "A permissionless auction, on a fixed rhythm", color: K.teal, beats: [
        "Prices move, so an index drifts away from its weights. Rebalancing brings it back, and nobody holds a rebalancing key.",
        "Once the index's interval has passed, anyone may call startRebalance. It reads no price. It only schedules the auction to begin two hours later.",
        "The two-hour notice lets executors ready their stock, routes and price update. Issue and redeem stay open the whole time.",
        "Then comes a twenty-four-hour Dutch auction, in which the factor μ falls from 1.02 to 0.98.",
        "Executors compete: the first fill at a μ that still covers its costs wins. If nobody fills, the auction expires and can be started again.",
    ], draw: s12),
    Scene(kicker: "STEP 5 · SETTLEMENT", title: "One fill: prices, targets, swaps, checks", color: K.amber, beats: [
        "An executor fills by calling executeRebalance with a signed Pyth price update, and pays Pyth's fee.",
        "The hub fixes the second the prices belong to: twelve seconds before the block. Pyth returns each coin's first update at or after that second. This is the only place in Xindex that reads a price.",
        "Each coin's target is its weight times the index's value, divided by its price. Every leg moves the same share of the way toward its target.",
        "One fill sends out at most twenty percent of each coin's units, so a wrong price can do only limited harm. A fill that trades less than a tenth of a percent is refused.",
        "The hub sends the shrinking legs to the executor. In its callback, the executor delivers the growing legs: μ times the value it took.",
        "Finally, the hub checks that every coin still backs the new units. If any falls short, the whole fill reverts.",
    ], draw: s13),
    Scene(kicker: "EXECUTORS", title: "The keeper bot: anyone can run one", color: K.teal, beats: [
        "The keeper bot in the repository is a reference executor, and anyone can run one.",
        "It starts rebalances that are due, simulates every block, and fills an auction once the fill pays.",
        "It also fills MintRequests at their limits, buying or selling the basket inside the fill's own transaction, and serves coins that have no Uniswap route from its own stock.",
        "It holds no role in the protocol. Its key is its own hot key, never the owner's or the guardian's.",
    ], draw: s14),
    Scene(kicker: "GOVERNANCE", title: "Who can do what", color: K.red, beats: [
        "Finally: who can do what.",
        "The owner Safe proposes listings and guardian changes behind delays, sets the fee policy for indexes created afterwards, and can delist a coin.",
        "The guardian can cancel pending listings, cancel a rebalance, or start one that routes around a frozen coin with a keep mask.",
        "And nobody can move an index's funds, mint or burn its shares, pause it, upgrade it, or change its coins or weights.",
    ], draw: s15),
    Scene(kicker: "RECAP", title: "The whole flow", color: K.teal, beats: [
        "So that is the whole flow: list, create, mint, hold, rebalance, and burn.",
        "Backed in kind, priced only at settlement, and always open for exit.",
        "Xindex version five is built and reviewed, and not yet deployed on mainnet. Thanks for watching.",
    ], draw: s16),
]

// MARK: - Frame chrome

var gridImage: CGImage?

func makeGrid() -> CGImage {
    let ctx = CGContext(
        data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.055).cgColor)
    var y: CGFloat = 24
    while y < H {
        var x: CGFloat = 24
        while x < W {
            ctx.fillEllipse(in: R(x - 1.3, y - 1.3, 2.6, 2.6))
            x += 48
        }
        y += 48
    }
    return ctx.makeImage()!
}

func background(_ accent: NSColor) {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let lg = CGGradient(colorsSpace: cs, colors: [K.bg1.cgColor, K.bg0.cgColor] as CFArray, locations: [0, 1])!
    g.drawLinearGradient(lg, start: pt(0, 0), end: pt(0, H), options: [])
    if gridImage == nil { gridImage = makeGrid() }
    g.draw(gridImage!, in: R(0, 0, W, H))
    let rg = CGGradient(
        colorsSpace: cs, colors: [accent.withAlphaComponent(0.13).cgColor, accent.withAlphaComponent(0).cgColor] as CFArray,
        locations: [0, 1])!
    g.drawRadialGradient(rg, startCenter: pt(1650, 120), startRadius: 0, endCenter: pt(1650, 120), endRadius: 950, options: [])
    let rg2 = CGGradient(
        colorsSpace: cs, colors: [K.violet.withAlphaComponent(0.07).cgColor, K.violet.withAlphaComponent(0).cgColor] as CFArray,
        locations: [0, 1])!
    g.drawRadialGradient(rg2, startCenter: pt(150, 980), startRadius: 0, endCenter: pt(150, 980), endRadius: 800, options: [])
}

func brand(_ right: CGFloat, _ y: CGFloat, _ size: CGFloat) {
    let a = attr("X", size, K.teal, .heavy)
    let b = attr("index", size, K.text, .heavy)
    let w = a.size().width + b.size().width
    a.draw(at: pt(right - w, y))
    b.draw(at: pt(right - w + a.size().width, y))
}

func header(_ s: Scene, _ idx: Int, _ f: F) {
    reveal(f.tp(0.05, 0.6), dy: 10) {
        text(String(format: "%02d   ", idx + 1) + s.kicker, 100, 52, 19, s.color, .bold, kern: 2.5)
        text(s.title, 100, 80, 46, K.text, .bold)
    }
    brand(1820, 50, 28)
    text("v5 · Ethereum", 1820, 90, 17, K.muted, align: .right)
}

func captionBox(_ s: String, _ a: CGFloat) {
    guard a > 0.01 else { return }
    let width: CGFloat = 1560
    let sz = measure(s, 29, .medium, width: width)
    let h = sz.height + 34
    let r = R(960 - (width + 60) / 2, 968 - h / 2, width + 60, h)
    reveal(a, dy: 6) {
        rrect(r, 18, fill: rgb(0x050810, 0.78), stroke: K.line.withAlphaComponent(0.6), lw: 1.5)
        let ps = NSMutableParagraphStyle()
        ps.alignment = .center
        ps.lineHeightMultiple = 1.12
        let at = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 29, weight: .medium), .foregroundColor: K.text, .paragraphStyle: ps,
        ])
        at.draw(with: R(r.minX + 30, r.minY + 17, width, sz.height + 4), options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}

// MARK: - Timeline

struct Timed {
    let scene: Int
    let start: Double
    let dur: Double
    let beatStarts: [Double]
    let beatDurs: [Double]
    let audio: [URL]
}

func speech(_ s: String) -> String {
    var r = s
    let map: [(String, String)] = [
        ("Xindex", "X-index"), ("MintRequests", "Mint Requests"), ("WeightedHub", "Weighted Hub"),
        ("CheckToken", "Check Token"), ("createIndex", "create index"), ("startRebalance", "start rebalance"),
        ("executeRebalance", "execute rebalance"), ("redeemSkipping", "redeem skipping"), ("CREATE2", "create 2"),
        ("ERC-20", "E R C 20"), ("USDC", "U S D C"), ("USDT", "U S D T"), ("WBTC", "W B T C"), ("Pyth", "Pith"),
        ("μ", "mu"), ("V3", "V 3"), ("V4", "V 4"),
    ]
    for (a, b) in map { r = r.replacingOccurrences(of: a, with: b) }
    return r
}

func run(_ exe: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    try! p.run()
    p.waitUntilExit()
    precondition(p.terminationStatus == 0, "\(exe) failed")
}

func buildTimeline(_ work: URL) -> [Timed] {
    let audioDir = work.appendingPathComponent("audio")
    try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
    var out: [Timed] = []
    var gt = 0.0
    for (si, s) in scenes.enumerated() {
        var t = LEAD
        var bs: [Double] = []
        var bd: [Double] = []
        var au: [URL] = []
        for b in s.beats {
            let said = speech(b)
            let hash = SHA256.hash(data: "\(VOICE)|\(RATE)|\(said)".data(using: .utf8)!)
                .map { String(format: "%02x", $0) }.joined().prefix(20)
            let url = audioDir.appendingPathComponent("\(hash).aiff")
            if !FileManager.default.fileExists(atPath: url.path) {
                run("/usr/bin/say", ["-v", VOICE, "-r", RATE, "-o", url.path, said])
            }
            let af = try! AVAudioFile(forReading: url)
            let d = Double(af.length) / af.fileFormat.sampleRate
            bs.append(t)
            bd.append(d)
            au.append(url)
            t += d + GAP
        }
        let dur = t - GAP + TAIL
        out.append(Timed(scene: si, start: gt, dur: dur, beatStarts: bs, beatDurs: bd, audio: au))
        gt += dur
    }
    return out
}

// MARK: - Rendering

func drawFrame(_ tl: [Timed], _ gt: Double, total: Double) {
    let td = tl.last { gt >= $0.start } ?? tl[0]
    let s = scenes[td.scene]
    let f = F(t: gt - td.start, starts: td.beatStarts, dur: td.dur)
    background(s.color)
    if td.scene > 0 { header(s, td.scene, f) }
    s.draw(f)
    if let k = td.beatStarts.lastIndex(where: { f.t >= $0 }) {
        captionBox(s.beats[k], CGFloat(easeOut(clamp01((f.t - td.beatStarts[k]) / 0.25))))
    }
    let barY: CGFloat = 1068
    rrect(R(0, barY, W, 6), 0, fill: K.line.withAlphaComponent(0.5))
    rrect(R(0, barY, W * CGFloat(gt / total), 6), 0, fill: K.teal)
    for t in tl.dropFirst() { rrect(R(W * CGFloat(t.start / total) - 1, barY, 2, 6), 0, fill: K.bg0) }
    let fade = min(clamp01(f.t / FADE), clamp01((td.dur - f.t) / FADE))
    if fade < 1 {
        rrect(R(0, 0, W, H), 0, fill: K.bg0.withAlphaComponent(CGFloat(1 - easeOut(fade))))
    }
}

func withContext(_ ctx: CGContext, _ body: () -> Void) {
    g = ctx
    ctx.translateBy(x: 0, y: H)
    ctx.scaleBy(x: 1, y: -1)
    let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns
    body()
    NSGraphicsContext.restoreGraphicsState()
}

func writePNG(_ img: CGImage, _ url: URL) {
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil)
    CGImageDestinationFinalize(d)
}

func stills(_ tl: [Timed], _ work: URL, only: Int?) {
    let dir = work.appendingPathComponent("stills")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let total = tl.last!.start + tl.last!.dur
    for td in tl where only == nil || only == td.scene {
        let ctx = CGContext(
            data: nil, width: Int(W), height: Int(H), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        withContext(ctx) { drawFrame(tl, td.start + td.dur - TAIL * 0.6, total: total) }
        writePNG(ctx.makeImage()!, dir.appendingPathComponent(String(format: "s%02d.png", td.scene + 1)))
    }
    print("stills in \(dir.path); total \(String(format: "%.1f", total)) s")
}

func renderVideo(_ tl: [Timed], _ mov: URL) async {
    try? FileManager.default.removeItem(at: mov)
    let total = tl.last!.start + tl.last!.dur
    let frames = Int((total * Double(FPS)).rounded(.up))
    let writer = try! AVAssetWriter(outputURL: mov, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(W), AVVideoHeightKey: Int(H),
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: 9_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoMaxKeyFrameIntervalKey: 60,
        ],
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ],
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(W), kCVPixelBufferHeightKey as String: Int(H),
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    for i in 0..<frames {
        while !input.isReadyForMoreMediaData { usleep(2000) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        let buf = pb!
        CVPixelBufferLockBaseAddress(buf, [])
        let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buf), width: Int(W), height: Int(H), bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buf), space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        autoreleasepool { withContext(ctx) { drawFrame(tl, Double(i) / Double(FPS), total: total) } }
        CVPixelBufferUnlockBaseAddress(buf, [])
        adaptor.append(buf, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: FPS))
        if i % 900 == 0 { print("frame \(i)/\(frames)") }
    }
    input.markAsFinished()
    await writer.finishWriting()
    precondition(writer.status == .completed, "video: \(String(describing: writer.error))")
}

/// One narration track: every beat's clip at its start, silence between.
func renderNarration(_ tl: [Timed], _ caf: URL) {
    try? FileManager.default.removeItem(at: caf)
    let first = try! AVAudioFile(forReading: tl[0].audio[0])
    let fmt = first.processingFormat
    let sr = fmt.sampleRate
    let out = try! AVAudioFile(forWriting: caf, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: fmt.channelCount,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ], commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
    var cursor: AVAudioFramePosition = 0
    func silence(until target: AVAudioFramePosition) {
        while cursor < target {
            let n = AVAudioFrameCount(min(Int64(sr), target - cursor))
            let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!
            b.frameLength = n
            try! out.write(from: b)
            cursor += AVAudioFramePosition(n)
        }
    }
    for td in tl {
        for (k, url) in td.audio.enumerated() {
            silence(until: AVAudioFramePosition((td.start + td.beatStarts[k]) * sr))
            let clip = try! AVAudioFile(forReading: url)
            precondition(clip.processingFormat == fmt, "clip format differs")
            let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(clip.length))!
            try! clip.read(into: b)
            try! out.write(from: b)
            cursor += AVAudioFramePosition(b.frameLength)
        }
    }
    silence(until: AVAudioFramePosition((tl.last!.start + tl.last!.dur) * sr))
}

func mux(_ mov: URL, _ m4a: URL, _ mp4: URL) async throws {
    try? FileManager.default.removeItem(at: mp4)
    let comp = AVMutableComposition()
    let v = AVURLAsset(url: mov)
    let a = AVURLAsset(url: m4a)
    let vd = try await v.load(.duration)
    let ad = try await a.load(.duration)
    let vt = try await v.loadTracks(withMediaType: .video)[0]
    let at = try await a.loadTracks(withMediaType: .audio)[0]
    try comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        .insertTimeRange(CMTimeRange(start: .zero, duration: vd), of: vt, at: .zero)
    try comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        .insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(vd, ad)), of: at, at: .zero)
    let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough)!
    try await ex.export(to: mp4, as: .mp4)
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 3, ["stills", "render"].contains(args[1]) else {
    print("usage: xindex-video stills <workDir> [scene] | render <workDir> <out.mp4>")
    exit(2)
}
let work = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
let timeline = buildTimeline(work)
if args[1] == "stills" {
    stills(timeline, work, only: args.count > 3 ? Int(args[3])! - 1 : nil)
} else {
    let mov = work.appendingPathComponent("video.mov")
    let caf = work.appendingPathComponent("narration.caf")
    let m4a = work.appendingPathComponent("narration.m4a")
    await renderVideo(timeline, mov)
    renderNarration(timeline, caf)
    try? FileManager.default.removeItem(at: m4a)
    run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac@44100", "-b", "160000", caf.path, m4a.path])
    try await mux(mov, m4a, URL(fileURLWithPath: args[3]))
    print("wrote \(args[3])")
}

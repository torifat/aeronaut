// Draws the Aeronaut app icon: a green blimp (its gondola is a tiny workspace pill) under a
// moonlit sky, clipped to the macOS squircle.
//
// Run from the repo root (needs the Command Line Tools toolchain, see AGENTS.md):
//   swift scripts/icon.swift <outdir>
// Writes <outdir>/AppIcon.iconset/, <outdir>/AppIcon.icns and <outdir>/AppIcon-1024.png.
// Art is drawn in a y-down 1024x1024 space.

import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers


let cs = CGColorSpace(name: CGColorSpace.sRGB)!
func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
	CGColor(colorSpace: cs, components: [
		CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, a])!
}
enum P { // Catppuccin Mocha
	static let base: UInt32 = 0x1e1e2e, mantle: UInt32 = 0x181825, crust: UInt32 = 0x11111b
	static let surface0: UInt32 = 0x313244, surface1: UInt32 = 0x45475a, overlay1: UInt32 = 0x7f849c
	static let text: UInt32 = 0xcdd6f4, green: UInt32 = 0xa6e3a1
}

func capsule(_ r: CGRect) -> CGPath { CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil) }
func line(_ a: CGPoint, _ b: CGPoint) -> CGPath { let p = CGMutablePath(); p.move(to: a); p.addLine(to: b); return p }
func poly(_ pts: [(CGFloat, CGFloat)]) -> CGPath {
	let p = CGMutablePath(); p.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
	for q in pts.dropFirst() { p.addLine(to: CGPoint(x: q.0, y: q.1)) }
	p.closeSubpath(); return p
}
func linear(_ g: CGContext, _ path: CGPath, _ cols: [CGColor], _ a: CGPoint, _ b: CGPoint, locs: [CGFloat]? = nil) {
	g.saveGState(); g.addPath(path); g.clip()
	let gr = CGGradient(colorsSpace: cs, colors: cols as CFArray, locations: locs)!
	g.drawLinearGradient(gr, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
	g.restoreGState()
}
func radial(_ g: CGContext, _ center: CGPoint, _ r: CGFloat, _ cols: [CGColor], scaleY: CGFloat = 1) {
	g.saveGState(); g.translateBy(x: center.x, y: center.y); g.scaleBy(x: 1, y: scaleY)
	let gr = CGGradient(colorsSpace: cs, colors: cols as CFArray, locations: nil)!
	g.drawRadialGradient(gr, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: r, options: [])
	g.restoreGState()
}
func fill(_ g: CGContext, _ path: CGPath, _ col: CGColor) { g.addPath(path); g.setFillColor(col); g.fillPath() }
func stroke(_ g: CGContext, _ path: CGPath, _ col: CGColor, _ w: CGFloat) {
	g.addPath(path); g.setStrokeColor(col); g.setLineWidth(w); g.setLineJoin(.round); g.setLineCap(.round); g.strokePath()
}
func dot(_ g: CGContext, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ col: CGColor) {
	fill(g, CGPath(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r), transform: nil), col)
}
func star(_ g: CGContext, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ col: CGColor) {
	let p = CGMutablePath(); let k = r * 0.28
	p.move(to: CGPoint(x: x, y: y - r)); p.addQuadCurve(to: CGPoint(x: x + r, y: y), control: CGPoint(x: x + k, y: y - k))
	p.addQuadCurve(to: CGPoint(x: x, y: y + r), control: CGPoint(x: x + k, y: y + k))
	p.addQuadCurve(to: CGPoint(x: x - r, y: y), control: CGPoint(x: x - k, y: y + k))
	p.addQuadCurve(to: CGPoint(x: x, y: y - r), control: CGPoint(x: x - k, y: y - k)); p.closeSubpath()
	fill(g, p, col)
}

/// Apple's macOS icon shape: 824x824 at (100,100), continuous corners, radius 185.4.
let iconBox = CGRect(x: 100, y: 100, width: 824, height: 824)
func squircle() -> CGPath {
	RoundedRectangle(cornerRadius: 185.4, style: .continuous).path(in: iconBox).cgPath
}

// MARK: Art
// Key light: a moon at the top right. In the airship's own frame "up" is -y and the light also comes from +x (the nose).
let bodyHalfLen: CGFloat = 300, hMax: CGFloat = 145, xMax: CGFloat = 60

/// Half-height of the (slightly tail-tapered) envelope at x.
func hOf(_ x: CGFloat) -> CGFloat {
	if x >= xMax {
		let s = min((x - xMax) / (bodyHalfLen - xMax), 1)
		return hMax * pow(max(1 - pow(s, 2.6), 0), 1 / 2.6)
	}
	let s = min((xMax - x) / (xMax + bodyHalfLen), 1)
	return hMax * pow(max(1 - pow(s, 2.2), 0), 1 / 2.2)
}
func xs(_ n: Int) -> [CGFloat] { (0...n).map { -bodyHalfLen + 2 * bodyHalfLen * (1 - cos(.pi * CGFloat($0) / CGFloat(n))) / 2 } }
func bodyPath() -> CGPath {
	let p = CGMutablePath(); let v = xs(240)
	for (i, x) in v.enumerated() { let pt = CGPoint(x: x, y: -hOf(x)); i == 0 ? p.move(to: pt) : p.addLine(to: pt) }
	for x in v.reversed() { p.addLine(to: CGPoint(x: x, y: hOf(x))) }
	p.closeSubpath(); return p
}
/// Open path along the top edge from x0 to x1, lowered by `inset`.
func topEdge(_ x0: CGFloat, _ x1: CGFloat, inset: CGFloat) -> CGPath {
	let p = CGMutablePath(); let n = 120
	for i in 0...n { let x = x0 + (x1 - x0) * CGFloat(i) / CGFloat(n); let pt = CGPoint(x: x, y: -hOf(x) + inset); i == 0 ? p.move(to: pt) : p.addLine(to: pt) }
	return p
}
func roundedPoly(_ pts: [CGPoint], _ r: CGFloat) -> CGPath {
	let p = CGMutablePath(); let n = pts.count
	p.move(to: CGPoint(x: (pts[0].x + pts[n - 1].x) / 2, y: (pts[0].y + pts[n - 1].y) / 2))
	for i in 0..<n { p.addArc(tangent1End: pts[i], tangent2End: pts[(i + 1) % n], radius: r) }
	p.closeSubpath(); return p
}
func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
/// Strokes `path`, then paints a gradient only through the stroke.
func strokeGradient(_ g: CGContext, _ path: CGPath, _ w: CGFloat, _ cols: [CGColor], _ a: CGPoint, _ b: CGPoint, locs: [CGFloat]? = nil) {
	g.saveGState(); g.addPath(path); g.setLineWidth(w); g.setLineCap(.round); g.setLineJoin(.round)
	g.replacePathWithStrokedPath(); g.clip()
	let gr = CGGradient(colorsSpace: cs, colors: cols as CFArray, locations: locs)!
	g.drawLinearGradient(gr, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
	g.restoreGState()
}

func drawSky(_ g: CGContext, detailed: Bool) {
	linear(g, CGPath(rect: CGRect(x: 0, y: 0, width: 1024, height: 1024), transform: nil),
		   [c(0x2c2d5c), c(0x1b1b34), c(P.crust)], CGPoint(x: 512, y: 100), CGPoint(x: 512, y: 924), locs: [0, 0.55, 1])
	// moonlight washing in from the top right, plus a halo behind the ship for figure-ground contrast
	radial(g, CGPoint(x: 800, y: 215), 470, [c(0xb4befe, 0.34), c(0x89b4fa, 0.10), c(0x89b4fa, 0)])
	radial(g, CGPoint(x: 560, y: 430), 400, [c(0x89b4fa, 0.26), c(0xb4befe, 0.08), c(0xb4befe, 0)], scaleY: 0.78)
	if detailed {
		for (x, y, r, a) in [(215, 205, 26, 0.85), (835, 830, 22, 0.7), (230, 830, 14, 0.5)]
			as [(CGFloat, CGFloat, CGFloat, CGFloat)] { star(g, x, y, r, c(P.text, a)) }
		// the moon itself
		radial(g, CGPoint(x: 818, y: 196), 120, [c(0xe6e9ff, 0.45), c(0xb4befe, 0)])
		let moon = CGPath(ellipseIn: CGRect(x: 818 - 30, y: 196 - 30, width: 60, height: 60), transform: nil)
		linear(g, moon, [c(0xffffff), c(0xcdd6f4)], CGPoint(x: 800, y: 170), CGPoint(x: 840, y: 226))
	}
}

func drawFin(_ g: CGContext, _ pts: [CGPoint], top: Bool, body: CGPath) {
	let fin = roundedPoly(pts, 14)
	stroke(g, fin, c(P.crust, 0.5), 8)
	let tipY = top ? -178.0 : 178.0, rootY = top ? -60.0 : 60.0
	let cols = top ? [c(0xa9e9ae), c(0x78c488), c(0x3f7a54)] : [c(0x4d9967), c(0x336a4b), c(0x244b38)]
	linear(g, fin, cols, pt(0, tipY), pt(0, rootY), locs: [0, 0.55, 1])
	// ambient occlusion where the fin meets the hull
	g.saveGState(); g.addPath(fin); g.clip()
	g.setShadow(offset: .zero, blur: 22, color: c(0x0b2016, 0.85)); fill(g, body, c(P.crust))
	g.restoreGState()
	// lit edge (top fin: the tip edge; bottom fin: the leading edge)
	if top { stroke(g, line(pt(pts[1].x - 4, pts[1].y + 4), pt(pts[2].x + 2, pts[2].y + 4)), c(0xf2fff0, 0.8), 4) }
	else { stroke(g, line(pt(pts[0].x - 1, pts[0].y + 6), pt(pts[1].x + 1, pts[1].y - 6)), c(0xd2f5d0, 0.55), 3.5) }
}

func drawBlimp(_ g: CGContext, detailed: Bool) {
	drawSky(g, detailed: detailed)

	// Airship, drawn around its own centre, scaled up and tilted nose-up by 7 degrees
	g.saveGState()
	g.translateBy(x: 540, y: 470); g.scaleBy(x: 1.04, y: 1.04); g.rotate(by: -7 * .pi / 180)
	let body = bodyPath()

	// Far fins (top and bottom), set behind the hull at the very tail
	drawFin(g, [pt(-172, -100), pt(-208, -172), pt(-296, -160), pt(-286, -34)], top: true, body: body)
	drawFin(g, [pt(-172, 100), pt(-208, 172), pt(-296, 160), pt(-286, 34)], top: false, body: body)

	// Gondola struts (behind the hull), thin
	for x in [-58.0, 58.0] as [CGFloat] {
		stroke(g, line(pt(x, 120), pt(x, 190)), c(P.crust, 0.5), 11)
		stroke(g, line(pt(x, 120), pt(x, 190)), c(0xa6adc8), 6)
	}

	// Envelope: dark contour, then per-column cylindrical shading that follows the taper
	stroke(g, body, c(P.crust, 0.55), 8)
	g.saveGState(); g.addPath(body); g.clip()
	fill(g, body, c(0x84c98b))
	let sh = CGGradient(colorsSpace: cs, colors: [
		c(0xeefdea), c(0xd2f7cb), c(0xbdf0b7), c(0xa6e3a1), c(0x80c689), c(0x5f9e6a), c(0x3e6e4a), c(0x3f7a62), c(0x6cc0b0),
	] as CFArray, locations: [0, 0.06, 0.18, 0.34, 0.50, 0.65, 0.80, 0.92, 1])!
	var x: CGFloat = -bodyHalfLen
	while x < bodyHalfLen {
		let h = hOf(x + 1.5) * 1.03 + 1
		g.saveGState(); g.translateBy(x: 0, y: 0)
		g.clip(to: CGRect(x: x, y: -h, width: 3.2, height: 2 * h))
		g.drawLinearGradient(sh, start: pt(x, -h), end: pt(x, h), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
		g.restoreGState(); x += 2
	}
	// tail falls into shade, nose catches the light
	linear(g, body, [c(0x1c4a38, 0.55), c(0x1c4a38, 0)], pt(-300, 0), pt(-40, 0))
	linear(g, body, [c(0xffffff, 0), c(0xe8fff0, 0.20)], pt(120, 0), pt(300, 0))
	// soft crescent of bounce light hugging the underside
	g.saveGState()
	let under = CGMutablePath(); under.addRect(CGRect(x: -400, y: -300, width: 800, height: 600))
	under.addPath(body, transform: CGAffineTransform(translationX: 0, y: -22)); g.addPath(under)
	g.setShadow(offset: .zero, blur: 0, color: nil)
	g.clip(using: .evenOdd)
	let tealR = CGGradient(colorsSpace: cs, colors: [c(0x94e2d5, 0), c(0x94e2d5, 0.38)] as CFArray, locations: nil)!
	g.drawLinearGradient(tealR, start: pt(0, 40), end: pt(0, 150), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
	g.restoreGState()
	// specular hotspot near the nose, toward the moon
	g.saveGState(); g.translateBy(x: 205, y: -78); g.rotate(by: -0.12); g.scaleBy(x: 1.9, y: 1)
	let sp = CGGradient(colorsSpace: cs, colors: [c(0xffffff, 0.95), c(0xf2fff0, 0.45), c(0xf2fff0, 0)] as CFArray, locations: [0, 0.35, 1])!
	g.drawRadialGradient(sp, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 42, options: [])
	g.restoreGState()
	// rim light along the lit top edge, brightest toward the moon
	strokeGradient(g, topEdge(-250, 285, inset: 3.5), 5, [c(0xf4fff2, 0), c(0xf4fff2, 0.55), c(0xffffff, 0.95)],
				   pt(-250, 0), pt(285, 0), locs: [0, 0.5, 1])
	g.restoreGState()

	// Gondola: a tiny workspace pill with volume
	let gr = CGRect(x: -125, y: 176, width: 250, height: 96)
	let gond = capsule(gr)
	stroke(g, gond, c(P.crust, 0.6), 8)
	linear(g, gond, [c(0x3d3f58), c(0x232337), c(0x11111b)], pt(0, gr.minY), pt(0, gr.maxY), locs: [0, 0.5, 1])
	strokeGradient(g, capsule(gr.insetBy(dx: 2.5, dy: 2.5)), 4, [c(0x9aa0c4, 0.95), c(0x585b70, 0.5), c(0x05050a, 0.7)],
				   pt(0, gr.minY), pt(0, gr.maxY), locs: [0, 0.45, 1])
	// shadow cast by the envelope onto the roof of the gondola
	linear(g, gond, [c(P.crust, 0.75), c(P.crust, 0)], pt(0, gr.minY), pt(0, gr.minY + 40))
	let cy = gr.midY + 3
	for dx in [-68.0, 68.0] as [CGFloat] {
		dot(g, dx, cy, 17, c(P.overlay1)); dot(g, dx - 4, cy - 5, 8, c(0xb8bdd6, 0.5))
	}
	radial(g, pt(0, cy), 52, [c(P.green, 0.5), c(P.green, 0)])
	dot(g, 0, cy, 22, c(P.green)); dot(g, -5, cy - 7, 10, c(0xe2fbdc, 0.55))
	g.restoreGState()
}

// MARK: Rendering
/// Renders the icon at `px` pixels square (art authored at 1024, scaled).
func render(_ px: Int) -> CGImage {
	let g = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
					  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
	g.interpolationQuality = .high; g.setAllowsAntialiasing(true)
	let s = CGFloat(px) / 1024
	let sq = squircle()
	g.saveGState()
	g.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 10 * s, color: c(0x000000, 0.3))
	g.scaleBy(x: s, y: s)
	// y-down art space
	g.translateBy(x: 0, y: 1024); g.scaleBy(x: 1, y: -1)
	fill(g, sq, c(P.base))
	g.restoreGState()
	g.saveGState()
	g.scaleBy(x: s, y: s); g.translateBy(x: 0, y: 1024); g.scaleBy(x: 1, y: -1)
	g.addPath(sq); g.clip()
	drawBlimp(g, detailed: px > 32)
	g.restoreGState()
	return g.makeImage()!
}
func writePNG(_ img: CGImage, _ path: String) {
	let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
	CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
}

// MARK: Main
func fail(_ message: String, _ code: Int32) -> Never {
	FileHandle.standardError.write(Data((message + "\n").utf8))
	exit(code)
}

guard CommandLine.arguments.count == 2 else { fail("usage: swift scripts/icon.swift <outdir>", 2) }
let out = CommandLine.arguments[1]
let fm = FileManager.default
let set = "\(out)/AppIcon.iconset"
do {
	try fm.createDirectory(atPath: out, withIntermediateDirectories: true)
	writePNG(render(1024), "\(out)/AppIcon-1024.png")

	try? fm.removeItem(atPath: set)
	try fm.createDirectory(atPath: set, withIntermediateDirectories: true)
	for base in [16, 32, 128, 256, 512] {
		writePNG(render(base), "\(set)/icon_\(base)x\(base).png")
		writePNG(render(base * 2), "\(set)/icon_\(base)x\(base)@2x.png")
	}
	let p = Process()
	p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
	p.arguments = ["-c", "icns", set, "-o", "\(out)/AppIcon.icns"]
	try p.run()
	p.waitUntilExit()
	if p.terminationStatus != 0 { fail("iconutil failed", 1) }
} catch {
	fail("\(error)", 1)
}

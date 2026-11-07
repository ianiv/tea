// Draws Tea's app icon: a T-Rex peeking out of a cup of tea, tiny arms on the rim.
// Usage: swift Scripts/make-icon.swift <out.png>   (1024×1024)

import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Background: macOS-style rounded square inside the standard 824pt grid, warm dusk gradient.
let inset: CGFloat = 100
let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35).cgColor)
color(0x1E4D45).setFill()
tilePath.fill()
ctx.restoreGState()
NSGradient(colors: [color(0x2F7A69), color(0x174039)])!.draw(in: tilePath, angle: -90)

// Soft glow behind the cup.
NSGradient(colors: [color(0xF6D9A8, 0.35), color(0xF6D9A8, 0)])!
    .draw(fromCenter: NSPoint(x: 512, y: 470), radius: 0, toCenter: NSPoint(x: 512, y: 470), radius: 360, options: [])

// Steam.
func steam(_ x: CGFloat, _ y: CGFloat, _ h: CGFloat) {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: x, y: y))
    p.curve(to: NSPoint(x: x, y: y + h), controlPoint1: NSPoint(x: x - 40, y: y + h * 0.33), controlPoint2: NSPoint(x: x + 40, y: y + h * 0.66))
    p.lineWidth = 22
    p.lineCapStyle = .round
    color(0xFFFFFF, 0.55).setStroke()
    p.stroke()
}
steam(705, 640, 130)
steam(765, 610, 105)

// Saucer.
let saucer = NSBezierPath(ovalIn: NSRect(x: 250, y: 222, width: 524, height: 96))
color(0xD9CBB6).setFill()
saucer.fill()
NSBezierPath(ovalIn: NSRect(x: 300, y: 246, width: 424, height: 62)).fill(with: color(0xEFE5D6))

// Cup handle (behind the body's right edge).
let handle = NSBezierPath(ovalIn: NSRect(x: 640, y: 380, width: 150, height: 150))
handle.lineWidth = 34
color(0xF4ECDF).setStroke()
handle.stroke()

// The dinosaur, drawn before the cup front so the cup hides its lower body.
let dino = color(0x7FC98A)
let dinoDark = color(0x5BA868)

// Body/neck rising out of the cup.
let neck = NSBezierPath()
neck.move(to: NSPoint(x: 400, y: 470))
neck.curve(to: NSPoint(x: 430, y: 640), controlPoint1: NSPoint(x: 395, y: 560), controlPoint2: NSPoint(x: 405, y: 610))
neck.line(to: NSPoint(x: 600, y: 640))
neck.curve(to: NSPoint(x: 620, y: 470), controlPoint1: NSPoint(x: 615, y: 600), controlPoint2: NSPoint(x: 625, y: 540))
neck.close()
dino.setFill()
neck.fill()

// Head: big, facing left, slightly open jaw.
let head = NSBezierPath()
head.move(to: NSPoint(x: 600, y: 620))
head.curve(to: NSPoint(x: 560, y: 790), controlPoint1: NSPoint(x: 640, y: 690), controlPoint2: NSPoint(x: 625, y: 770))
head.curve(to: NSPoint(x: 330, y: 760), controlPoint1: NSPoint(x: 490, y: 815), controlPoint2: NSPoint(x: 380, y: 800))
head.curve(to: NSPoint(x: 300, y: 690), controlPoint1: NSPoint(x: 300, y: 740), controlPoint2: NSPoint(x: 292, y: 712))
head.line(to: NSPoint(x: 440, y: 684)) // mouth line
head.line(to: NSPoint(x: 330, y: 650)) // lower jaw tip
head.curve(to: NSPoint(x: 470, y: 600), controlPoint1: NSPoint(x: 370, y: 620), controlPoint2: NSPoint(x: 420, y: 600))
head.curve(to: NSPoint(x: 600, y: 620), controlPoint1: NSPoint(x: 530, y: 600), controlPoint2: NSPoint(x: 575, y: 605))
head.close()
dino.setFill()
head.fill()

// Teeth along the upper jaw.
color(0xFFFFFF).setFill()
for i in 0..<4 {
    let x = 318 + CGFloat(i) * 30
    let t = NSBezierPath()
    t.move(to: NSPoint(x: x, y: 690 - CGFloat(i) * 0.4))
    t.line(to: NSPoint(x: x + 22, y: 689))
    t.line(to: NSPoint(x: x + 11, y: 668))
    t.close()
    t.fill()
}

// Brow ridge, eye, nostril.
let brow = NSBezierPath()
brow.move(to: NSPoint(x: 470, y: 770))
brow.curve(to: NSPoint(x: 545, y: 775), controlPoint1: NSPoint(x: 495, y: 792), controlPoint2: NSPoint(x: 525, y: 792))
brow.lineWidth = 16
brow.lineCapStyle = .round
dinoDark.setStroke()
brow.stroke()
color(0xFFFFFF).setFill()
NSBezierPath(ovalIn: NSRect(x: 480, y: 718, width: 58, height: 58)).fill()
color(0x1D2B28).setFill()
NSBezierPath(ovalIn: NSRect(x: 488, y: 726, width: 36, height: 40)).fill()
color(0xFFFFFF).setFill()
NSBezierPath(ovalIn: NSRect(x: 496, y: 748, width: 11, height: 11)).fill()
dinoDark.setFill()
NSBezierPath(ovalIn: NSRect(x: 336, y: 735, width: 22, height: 14)).fill()

// Cheek blush.
color(0xFF8FA3, 0.6).setFill()
NSBezierPath(ovalIn: NSRect(x: 545, y: 680, width: 44, height: 26)).fill()

// Back spikes.
dinoDark.setFill()
for (x, y) in [(612.0, 700.0), (618.0, 650.0)] {
    let s = NSBezierPath()
    s.move(to: NSPoint(x: x - 8, y: y + 26))
    s.line(to: NSPoint(x: x + 30, y: y + 8))
    s.line(to: NSPoint(x: x - 4, y: y - 14))
    s.close()
    s.fill()
}

// Cup body.
let cup = NSBezierPath()
cup.move(to: NSPoint(x: 290, y: 560))
cup.curve(to: NSPoint(x: 420, y: 300), controlPoint1: NSPoint(x: 290, y: 430), controlPoint2: NSPoint(x: 340, y: 320))
cup.line(to: NSPoint(x: 604, y: 300))
cup.curve(to: NSPoint(x: 734, y: 560), controlPoint1: NSPoint(x: 684, y: 320), controlPoint2: NSPoint(x: 734, y: 430))
cup.close()
NSGradient(colors: [color(0xFBF6EE), color(0xE6D8C4)])!.draw(in: cup, angle: -90)

// Band around the cup.
ctx.saveGState()
cup.addClip()
let band = NSBezierPath(rect: NSRect(x: 280, y: 470, width: 470, height: 30))
color(0xD98A5B).setFill()
band.fill()
ctx.restoreGState()

// Rim: tea surface and cup lip, with the dino's neck in front of the tea.
let rim = NSRect(x: 290, y: 528, width: 444, height: 64)
color(0xE6D8C4).setFill()
NSBezierPath(ovalIn: rim).fill()
NSBezierPath(ovalIn: rim.insetBy(dx: 16, dy: 10)).fill(with: color(0xB8733A))
// Lip highlight.
let lip = NSBezierPath(ovalIn: rim)
lip.lineWidth = 10
color(0xFFFFFF, 0.8).setStroke()
lip.stroke()

// Neck emerging from the tea.
let neckFront = NSBezierPath()
neckFront.move(to: NSPoint(x: 402, y: 555))
neckFront.curve(to: NSPoint(x: 425, y: 640), controlPoint1: NSPoint(x: 400, y: 600), controlPoint2: NSPoint(x: 408, y: 625))
neckFront.line(to: NSPoint(x: 605, y: 640))
neckFront.curve(to: NSPoint(x: 618, y: 555), controlPoint1: NSPoint(x: 615, y: 610), controlPoint2: NSPoint(x: 620, y: 580))
neckFront.curve(to: NSPoint(x: 402, y: 555), controlPoint1: NSPoint(x: 560, y: 538), controlPoint2: NSPoint(x: 460, y: 538))
dino.setFill()
neckFront.fill()
// Ripple where the neck meets the tea.
let ripple = NSBezierPath()
ripple.move(to: NSPoint(x: 385, y: 552))
ripple.curve(to: NSPoint(x: 635, y: 552), controlPoint1: NSPoint(x: 460, y: 530), controlPoint2: NSPoint(x: 560, y: 530))
ripple.lineWidth = 8
ripple.lineCapStyle = .round
color(0xD9935A).setStroke()
ripple.stroke()

// Tiny arms from the sides of the neck, hanging over the rim.
func arm(_ x: CGFloat, _ dir: CGFloat) {
    let a = NSBezierPath()
    a.move(to: NSPoint(x: x, y: 612))
    a.curve(to: NSPoint(x: x + 36 * dir, y: 572), controlPoint1: NSPoint(x: x + 22 * dir, y: 616), controlPoint2: NSPoint(x: x + 36 * dir, y: 590))
    a.lineCapStyle = .round
    a.lineWidth = 32
    dinoDark.setStroke()
    a.stroke()
    a.lineWidth = 21
    dino.setStroke()
    a.stroke()
    // Two little claws over the lip.
    color(0xFFFFFF).setFill()
    let tip = x + 36 * dir
    NSBezierPath(ovalIn: NSRect(x: tip - 13, y: 552, width: 10, height: 14)).fill()
    NSBezierPath(ovalIn: NSRect(x: tip + 2, y: 552, width: 10, height: 14)).fill()
}
arm(414, -1)
arm(608, 1)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")

extension NSBezierPath {
    func fill(with c: NSColor) {
        c.setFill()
        fill()
    }
}

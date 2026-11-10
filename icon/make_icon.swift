// 앱 아이콘을 그린다: 남색 → 청록 바탕의 둥근 사각형, 흰 Wi-Fi 부채꼴, 오른쪽 위로 빠져나가는 주황 출구 화살표.
//   swiftc -O icon/make_icon.swift -o /tmp/make_icon && /tmp/make_icon icon/AppIcon-1024.png
// 그다음 icon/make_icns.sh 가 크기별로 줄여 AppIcon.icns 를 만든다.

import AppKit

let S: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let cg = NSGraphicsContext.current!.cgContext
let rgb = CGColorSpaceCreateDeviceRGB()
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a) }

// 바탕 (macOS 아이콘 격자: 1024 안의 824 사각형, 모서리 반지름 약 185)
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: c(0, 0, 0, 0.35))
cg.addPath(tilePath); cg.setFillColor(c(20, 30, 70)); cg.fillPath()
cg.restoreGState()
cg.saveGState()
cg.addPath(tilePath); cg.clip()
let bg = CGGradient(colorsSpace: rgb, colors: [c(14, 165, 200), c(30, 58, 138), c(17, 24, 64)] as CFArray, locations: [0, 0.55, 1])!
cg.drawLinearGradient(bg, start: CGPoint(x: 260, y: 924), end: CGPoint(x: 760, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
// 위쪽 은은한 빛
let glow = CGGradient(colorsSpace: rgb, colors: [c(255, 255, 255, 0.18), c(255, 255, 255, 0)] as CFArray, locations: [0, 1])!
cg.drawRadialGradient(glow, startCenter: CGPoint(x: 400, y: 880), startRadius: 0, endCenter: CGPoint(x: 400, y: 880), endRadius: 560, options: [])

// Wi-Fi 부채꼴 (좌표는 아래가 0)
let hub = CGPoint(x: 440, y: 300)
cg.setLineCap(.round)
cg.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: c(0, 0, 0, 0.30))
cg.setStrokeColor(c(255, 255, 255))
cg.setLineWidth(60)
for r in [138.0, 248.0, 358.0] as [CGFloat] {
    cg.addArc(center: hub, radius: r, startAngle: .pi / 4, endAngle: 3 * .pi / 4, clockwise: false)
    cg.strokePath()
}
cg.setFillColor(c(255, 255, 255))
cg.fillEllipse(in: CGRect(x: hub.x - 44, y: hub.y - 44, width: 88, height: 88))

// 출구 화살표: 부채꼴 오른쪽 위 바깥으로 빠져나간다 (그림자가 겹치지 않게 한 층으로 그린다)
let a0 = CGPoint(x: 724, y: 612), tip = CGPoint(x: 846, y: 734)
cg.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: c(110, 40, 0, 0.45))
cg.beginTransparencyLayer(auxiliaryInfo: nil)
let amber = c(255, 172, 44)
cg.setStrokeColor(amber); cg.setFillColor(amber)
cg.setLineWidth(56)
cg.move(to: a0); cg.addLine(to: CGPoint(x: tip.x - 60, y: tip.y - 60)); cg.strokePath()
let head = CGMutablePath()
head.move(to: tip)
head.addLine(to: CGPoint(x: tip.x - 150, y: tip.y - 10))
head.addLine(to: CGPoint(x: tip.x - 10, y: tip.y - 150))
head.closeSubpath()
cg.setLineJoin(.round); cg.setLineWidth(22)
cg.addPath(head); cg.drawPath(using: .fillStroke)
cg.endTransparencyLayer()
cg.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")

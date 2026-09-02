import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// R2BOX 图标生成：深蓝底 + 打开的牛皮纸箱 + 弹出的 Cloudflare 风格云
// 用法: make_icon <输出目录>（写入 iconset 所需各尺寸 PNG）

let size = 1024

struct Palette {
    static let bgTop = CGColor(red: 0.13, green: 0.20, blue: 0.32, alpha: 1)      // 深海军蓝
    static let bgBottom = CGColor(red: 0.07, green: 0.11, blue: 0.19, alpha: 1)
    static let boxFront = CGColor(red: 0.78, green: 0.61, blue: 0.40, alpha: 1)   // 牛皮纸
    static let boxSide = CGColor(red: 0.66, green: 0.49, blue: 0.30, alpha: 1)
    static let boxInner = CGColor(red: 0.45, green: 0.33, blue: 0.20, alpha: 1)   // 箱内阴影
    static let boxFlap = CGColor(red: 0.84, green: 0.68, blue: 0.47, alpha: 1)    // 翻盖
    static let tape = CGColor(red: 0.92, green: 0.86, blue: 0.72, alpha: 1)
    static let cloud = CGColor(red: 0.965, green: 0.545, blue: 0.16, alpha: 1)    // Cloudflare 橙 #F6821F
    static let cloudLight = CGColor(red: 0.984, green: 0.71, blue: 0.33, alpha: 1) // #FBAD41
    static let sparkle = CGColor(red: 1.0, green: 0.92, blue: 0.75, alpha: 1)
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawIcon(scale: CGFloat) -> CGContext {
    let ctx = CGContext(
        data: nil, width: size * Int(scale), height: size * Int(scale),
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.scaleBy(x: scale, y: scale)
    // macOS 坐标系（原点左下）统一翻转绘制
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: 1, y: -1)

    // ── 背景：圆角方形 + 纵向渐变
    let bgRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.saveGState()
    ctx.addPath(roundedRect(bgRect, 185))
    ctx.clip()
    let grad = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [Palette.bgTop, Palette.bgBottom] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    ctx.restoreGState()

    // 裁剪到圆角内绘制其余元素
    ctx.saveGState()
    ctx.addPath(roundedRect(bgRect, 185))
    ctx.clip()

    // ── 箱底投影
    ctx.saveGState()
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
    ctx.addPath(roundedRect(CGRect(x: 300, y: 790, width: 424, height: 44), 22))
    ctx.fillPath()
    ctx.restoreGState()

    // ── 后翻盖（云朵后方，向上张开的两片）
    func flap(_ cx: CGFloat, _ angle: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: cx, y: 520)
        ctx.rotate(by: angle * .pi / 180)
        ctx.setFillColor(Palette.boxFlap)
        ctx.addPath(roundedRect(CGRect(x: -46, y: -190, width: 92, height: 190), 26))
        ctx.fillPath()
        ctx.restoreGState()
    }
    flap(360, 14)
    flap(664, -14)

    // ── 箱身
    // 内壁（后壁）
    ctx.setFillColor(Palette.boxInner)
    ctx.addPath(roundedRect(CGRect(x: 316, y: 470, width: 392, height: 130), 14))
    ctx.fillPath()
    // 正面
    ctx.setFillColor(Palette.boxFront)
    ctx.addPath(roundedRect(CGRect(x: 300, y: 560, width: 424, height: 240), 22))
    ctx.fillPath()
    // 正面下沿阴影（立体感）
    ctx.setFillColor(CGColor(red: 0.58, green: 0.43, blue: 0.26, alpha: 1))
    ctx.addPath(roundedRect(CGRect(x: 300, y: 770, width: 424, height: 30), 14))
    ctx.fillPath()
    // 胶带竖条
    ctx.setFillColor(Palette.tape)
    ctx.fill(CGRect(x: 482, y: 560, width: 60, height: 240))
    // 胶带高光线
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.35))
    ctx.setLineWidth(5)
    ctx.move(to: CGPoint(x: 500, y: 575))
    ctx.addLine(to: CGPoint(x: 500, y: 785))
    ctx.strokePath()

    // ── 左右外翻盖（搭在箱沿外侧）
    ctx.setFillColor(Palette.boxSide)
    ctx.addPath(roundedRect(CGRect(x: 236, y: 548, width: 92, height: 150), 20))
    ctx.fillPath()
    ctx.addPath(roundedRect(CGRect(x: 696, y: 548, width: 92, height: 150), 20))
    ctx.fillPath()

    // ── Cloudflare 云：后侧浅橙小云（左上，先画在主云后方）
    let backCloud = CGMutablePath()
    backCloud.addPath(roundedRect(CGRect(x: 344, y: 344, width: 216, height: 72), 36))
    backCloud.addEllipse(in: CGRect(x: 376, y: 288, width: 126, height: 126))
    ctx.setFillColor(Palette.cloudLight)
    ctx.addPath(backCloud)
    ctx.fillPath()

    // 主云（橙）从箱口弹出
    let cloudPath = CGMutablePath()
    // 底部胶囊
    cloudPath.addPath(roundedRect(CGRect(x: 336, y: 428, width: 352, height: 96), 48))
    // 右大圆
    cloudPath.addEllipse(in: CGRect(x: 500, y: 330, width: 220, height: 220))
    // 左中圆
    cloudPath.addEllipse(in: CGRect(x: 368, y: 368, width: 150, height: 150))
    ctx.setFillColor(Palette.cloud)
    ctx.addPath(cloudPath)
    ctx.fillPath()

    // ── 弹出动势线（云上方）
    ctx.setStrokeColor(Palette.sparkle)
    ctx.setLineWidth(16)
    ctx.setLineCap(.round)
    for (x1, y1, x2, y2) in [(430.0, 260.0, 404.0, 210.0), (512.0, 236.0, 512.0, 178.0), (594.0, 260.0, 620.0, 210.0)] {
        ctx.move(to: CGPoint(x: x1, y: y1))
        ctx.addLine(to: CGPoint(x: x2, y: y2))
        ctx.strokePath()
    }
    // 小星点
    ctx.setFillColor(Palette.sparkle)
    for (cx, cy, r) in [(360.0, 230.0, 14.0), (668.0, 240.0, 14.0), (512.0, 130.0, 18.0)] {
        ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
    }

    ctx.restoreGState()  // 圆角裁剪结束
    return ctx
}

func savePNG(_ ctx: CGContext, _ path: String, _ px: Int) {
    let img = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil
    )!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
// 先渲一张 1024 大图
let master = drawIcon(scale: 1)
savePNG(master, "\(outDir)/icon_1024.png", 1024)

// iconset 各尺寸（由 1024 缩放）
func scaled(_ px: Int) -> CGContext {
    let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let img = master.makeImage()!
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: CGFloat(px), height: CGFloat(px)))
    return ctx
}
for p in [16, 32, 128, 256, 512] {
    savePNG(scaled(p), "\(outDir)/icon_\(p)x\(p).png", p)
    savePNG(scaled(p * 2), "\(outDir)/icon_\(p)x\(p)@2x.png", p * 2)
}
print("done -> \(outDir)")

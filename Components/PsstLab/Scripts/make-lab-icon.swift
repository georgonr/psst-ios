// PSST (L1): psst lab app icon = psst icon + a large "LAB" band (RGB, no alpha, 1024×1024).
// swift Scripts/make-lab-icon.swift <psst icon-1024.png> <out.png>
import AppKit
import CoreGraphics
let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1]),
      let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("usage: make-lab-icon in.png out.png") }
let s = 1024
let ctx = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: s, height: s))
// diagonal-free horizontal band in the lower third: amber, black text — readable even at 29 pt
let band = CGRect(x: 0, y: 40, width: s, height: 270)
ctx.setFillColor(CGColor(srgbRed: 0.98, green: 0.72, blue: 0.10, alpha: 1))
ctx.fill(band)
ctx.setFillColor(CGColor(srgbRed: 0.06, green: 0.06, blue: 0.08, alpha: 1))
ctx.fill(CGRect(x: 0, y: 296, width: s, height: 14))
let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.current = ns
let font = NSFont.systemFont(ofSize: 230, weight: .black)
let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(srgbRed: 0.06, green: 0.06, blue: 0.08, alpha: 1), .kern: 24]
let text = NSAttributedString(string: "LAB", attributes: attrs)
let size = text.size()
text.draw(at: CGPoint(x: (CGFloat(s) - size.width) / 2 + 12, y: band.midY - size.height / 2 + 8))
NSGraphicsContext.current = nil
let out = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: out)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))

import AppKit

let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor(calibratedRed: 0.09, green: 0.28, blue: 0.26, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 52, y: 52, width: 920, height: 920), xRadius: 206, yRadius: 206)
  .fill()
for (offset, alpha) in [
  (CGFloat(0), CGFloat(0.32)), (CGFloat(100), CGFloat(0.6)), (CGFloat(200), CGFloat(1)),
] {
  NSColor(calibratedRed: 0.86, green: 0.94, blue: 0.86, alpha: alpha).setFill()
  NSBezierPath(
    roundedRect: NSRect(x: 242, y: 230 + offset, width: 540, height: 154), xRadius: 38, yRadius: 38
  ).fill()
}
NSColor(calibratedRed: 0.09, green: 0.28, blue: 0.26, alpha: 1).setStroke()
let mark = NSBezierPath()
mark.lineWidth = 24
mark.lineCapStyle = .round
mark.lineJoinStyle = .round
mark.move(to: NSPoint(x: 432, y: 505))
mark.line(to: NSPoint(x: 488, y: 465))
mark.line(to: NSPoint(x: 596, y: 552))
mark.stroke()
image.unlockFocus()
let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = representation.representation(using: .png, properties: [:])!
func sizeBytes(_ count: Int) -> Data {
  var number = UInt32(count).bigEndian
  return withUnsafeBytes(of: &number) { Data($0) }
}
var chunk = Data("ic10".utf8)
chunk.append(sizeBytes(png.count + 8))
chunk.append(png)
var icns = Data("icns".utf8)
icns.append(sizeBytes(chunk.count + 8))
icns.append(chunk)
try icns.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

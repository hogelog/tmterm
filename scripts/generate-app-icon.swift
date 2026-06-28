#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
  fputs("usage: generate-app-icon.swift OUTPUT_ICONSET\n", stderr)
  exit(64)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

let sizes = [
  (points: 16, scale: 1),
  (points: 16, scale: 2),
  (points: 32, scale: 1),
  (points: 32, scale: 2),
  (points: 128, scale: 1),
  (points: 128, scale: 2),
  (points: 256, scale: 1),
  (points: 256, scale: 2),
  (points: 512, scale: 1),
  (points: 512, scale: 2)
]

for size in sizes {
  let pixels = size.points * size.scale
  let image = NSImage(size: NSSize(width: pixels, height: pixels))
  image.lockFocus()

  NSColor(deviceRed: 0.035, green: 0.043, blue: 0.050, alpha: 1).setFill()
  NSBezierPath(
    roundedRect: NSRect(x: 0, y: 0, width: pixels, height: pixels),
    xRadius: CGFloat(pixels) * 0.22,
    yRadius: CGFloat(pixels) * 0.22
  ).fill()

  NSColor(deviceRed: 0.45, green: 0.62, blue: 0.86, alpha: 1).setFill()
  NSBezierPath(
    roundedRect: NSRect(
      x: CGFloat(pixels) * 0.12,
      y: CGFloat(pixels) * 0.12,
      width: CGFloat(pixels) * 0.76,
      height: CGFloat(pixels) * 0.76
    ),
    xRadius: CGFloat(pixels) * 0.08,
    yRadius: CGFloat(pixels) * 0.08
  ).fill()

  NSColor(deviceRed: 0.055, green: 0.065, blue: 0.075, alpha: 1).setFill()
  NSBezierPath(
    roundedRect: NSRect(
      x: CGFloat(pixels) * 0.17,
      y: CGFloat(pixels) * 0.23,
      width: CGFloat(pixels) * 0.66,
      height: CGFloat(pixels) * 0.54
    ),
    xRadius: CGFloat(pixels) * 0.04,
    yRadius: CGFloat(pixels) * 0.04
  ).fill()

  let promptRect = NSRect(
    x: CGFloat(pixels) * 0.25,
    y: CGFloat(pixels) * 0.40,
    width: CGFloat(pixels) * 0.50,
    height: CGFloat(pixels) * 0.24
  )
  let paragraph = NSMutableParagraphStyle()
  paragraph.alignment = .center
  let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: CGFloat(pixels) * 0.20, weight: .bold),
    .foregroundColor: NSColor(deviceRed: 0.86, green: 0.91, blue: 0.96, alpha: 1),
    .paragraphStyle: paragraph
  ]
  ("tm" as NSString).draw(in: promptRect, withAttributes: attributes)

  NSColor(deviceRed: 0.50, green: 0.82, blue: 0.62, alpha: 1).setFill()
  NSRect(
    x: CGFloat(pixels) * 0.31,
    y: CGFloat(pixels) * 0.31,
    width: CGFloat(pixels) * 0.38,
    height: max(1, CGFloat(pixels) * 0.035)
  ).fill()

  image.unlockFocus()

  guard
    let tiffData = image.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiffData),
    let pngData = bitmap.representation(using: .png, properties: [:])
  else {
    fputs("failed to render icon size \(pixels)\n", stderr)
    exit(1)
  }

  let suffix = size.scale == 1 ? "" : "@2x"
  let filename = "icon_\(size.points)x\(size.points)\(suffix).png"
  try pngData.write(to: outputURL.appendingPathComponent(filename), options: .atomic)
}

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

  NSColor(deviceRed: 0.45, green: 0.62, blue: 0.86, alpha: 1).setFill()
  NSBezierPath(
    roundedRect: NSRect(x: 0, y: 0, width: pixels, height: pixels),
    xRadius: CGFloat(pixels) * 0.22,
    yRadius: CGFloat(pixels) * 0.22
  ).fill()

  NSColor(deviceRed: 0.055, green: 0.065, blue: 0.075, alpha: 1).setFill()
  NSBezierPath(
    roundedRect: NSRect(
      x: CGFloat(pixels) * 0.10,
      y: CGFloat(pixels) * 0.15,
      width: CGFloat(pixels) * 0.80,
      height: CGFloat(pixels) * 0.70
    ),
    xRadius: CGFloat(pixels) * 0.04,
    yRadius: CGFloat(pixels) * 0.04
  ).fill()

  NSColor(deviceRed: 0.86, green: 0.91, blue: 0.96, alpha: 1).setStroke()
  let promptPath = NSBezierPath()
  promptPath.lineWidth = max(1, CGFloat(pixels) * 0.035)
  promptPath.lineCapStyle = .round
  promptPath.lineJoinStyle = .round
  promptPath.move(to: NSPoint(x: CGFloat(pixels) * 0.29, y: CGFloat(pixels) * 0.58))
  promptPath.line(to: NSPoint(x: CGFloat(pixels) * 0.39, y: CGFloat(pixels) * 0.50))
  promptPath.line(to: NSPoint(x: CGFloat(pixels) * 0.29, y: CGFloat(pixels) * 0.42))
  promptPath.stroke()

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

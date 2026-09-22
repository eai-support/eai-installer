#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Vision

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Parallels UAC point lookup failed: \(message)\n".utf8))
    exit(2)
}

guard CommandLine.arguments.count == 3 else {
    fail("pass exactly one VM window title and one window-only screenshot path")
}

let expectedTitle = CommandLine.arguments[1]
let screenshotURL = URL(fileURLWithPath: CommandLine.arguments[2]) as CFURL
let windows = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements],
    kCGNullWindowID
) as? [[String: Any]] ?? []

let matches = windows.compactMap { window -> (CGWindowID, CGRect)? in
    guard window[kCGWindowOwnerName as String] as? String == "Parallels Desktop",
          window[kCGWindowName as String] as? String == expectedTitle,
          let number = window[kCGWindowNumber as String] as? NSNumber,
          let ownerPID = window[kCGWindowOwnerPID as String] as? NSNumber,
          let layer = window[kCGWindowLayer as String] as? NSNumber,
          layer.intValue == 0,
          let alpha = window[kCGWindowAlpha as String] as? NSNumber,
          alpha.doubleValue > 0,
          let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
          let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
          bounds.width > 0,
          bounds.height > 0,
          NSRunningApplication(processIdentifier: pid_t(ownerPID.int32Value))?.bundleIdentifier
            == "com.parallels.desktop.console" else {
        return nil
    }
    return (CGWindowID(number.uint32Value), bounds)
}

guard matches.count == 1, let (windowID, windowBounds) = matches.first else {
    fail("expected exactly one visible, bundle-bound Parallels VM window")
}
guard let imageSource = CGImageSourceCreateWithURL(screenshotURL, nil),
      let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
    fail("the window-only screenshot could not be decoded")
}

let scaleX = CGFloat(image.width) / windowBounds.width
let scaleY = CGFloat(image.height) / windowBounds.height
guard scaleX >= 1, scaleX <= 4, abs(scaleX - scaleY) < 0.02 else {
    fail("the screenshot dimensions do not match the exact Parallels window")
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = true
request.recognitionLanguages = ["en-US"]
do {
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
} catch {
    fail("Vision could not inspect the UAC screenshot")
}

let yesCandidates = (request.results ?? []).compactMap { observation -> VNRecognizedTextObservation? in
    guard let candidate = observation.topCandidates(1).first,
          candidate.confidence >= 0.7,
          candidate.string.compare("Yes", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame else {
        return nil
    }
    return observation
}

guard yesCandidates.count == 1, let yes = yesCandidates.first else {
    fail("expected exactly one high-confidence Yes label")
}

let centerX = yes.boundingBox.midX
let centerY = yes.boundingBox.midY
guard centerX >= 0.30, centerX <= 0.52,
      centerY >= 0.20, centerY <= 0.40,
      yes.boundingBox.width > 0,
      yes.boundingBox.height > 0 else {
    fail("the unique Yes label is outside the allowlisted UAC button region")
}

let hostX = windowBounds.minX + centerX * windowBounds.width
let hostY = windowBounds.minY + (1 - centerY) * windowBounds.height
guard windowBounds.contains(CGPoint(x: hostX, y: hostY)) else {
    fail("the derived Yes point is outside the exact Parallels window")
}

print(String(format: "%u %.2f %.2f", windowID, hostX, hostY))

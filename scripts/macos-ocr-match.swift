#!/usr/bin/env swift

import Foundation
import ImageIO
import Vision

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Screenshot OCR failed: \(message)\n".utf8))
    exit(2)
}

guard CommandLine.arguments.count == 2 else {
    fail("pass exactly one screenshot path")
}
guard let pattern = ProcessInfo.processInfo.environment["EAI_OCR_PATTERN"], !pattern.isEmpty else {
    fail("EAI_OCR_PATTERN is required")
}

let imageURL = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
guard let imageSource = CGImageSourceCreateWithURL(imageURL, nil),
      let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
    fail("the screenshot could not be decoded")
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = true
request.recognitionLanguages = ["en-US"]

do {
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
} catch {
    fail("Vision could not inspect the screenshot")
}

// Authentication stages must be proven by rendered page content, never by an
// inactive Safari tab or address bar. Evidence-sanitisation callers opt into
// the complete framebuffer so callback URLs in browser chrome are inspected.
let includeBrowserChrome = ProcessInfo.processInfo.environment["EAI_OCR_INCLUDE_BROWSER_CHROME"] == "1"
let text = (request.results ?? [])
    .filter { includeBrowserChrome || $0.boundingBox.minY < 0.88 }
    .compactMap { $0.topCandidates(1).first?.string }
    .joined(separator: "\n")

exit(text.localizedCaseInsensitiveContains(pattern) ? 0 : 1)

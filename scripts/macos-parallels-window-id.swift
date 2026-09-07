#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Parallels window lookup failed: \(message)\n".utf8))
    exit(2)
}

guard CommandLine.arguments.count == 2 else {
    fail("pass exactly one VM window title")
}

let expectedTitle = CommandLine.arguments[1]
let windows = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly, .excludeDesktopElements],
    kCGNullWindowID
) as? [[String: Any]] ?? []

let matches = windows.compactMap { window -> CGWindowID? in
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
    return CGWindowID(number.uint32Value)
}

guard matches.count == 1, let windowID = matches.first else {
    fail("expected exactly one Parallels Desktop window titled '\(expectedTitle)'")
}

print(windowID)

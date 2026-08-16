// SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
//
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Print the QR payload found in an image, one per line.
//
// `zbarimg` cannot read the device-link QR off a screenshot — it is dense
// and the on-screen contrast is low; every threshold from 40% to 70%,
// with and without upscaling, failed. Vision reads it first try, which is
// what makes a camera-free two-device link test possible at all.

import AppKit
import Foundation
import Vision

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("usage: decode-qr.swift <image>\n".data(using: .utf8)!)
    exit(2)
}

let path = CommandLine.arguments[1]
guard let image = NSImage(contentsOfFile: path),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    FileHandle.standardError.write("cannot read image at \(path)\n".data(using: .utf8)!)
    exit(2)
}

let request = VNDetectBarcodesRequest()
request.symbologies = [.qr]
try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])

guard let results = request.results, !results.isEmpty else {
    FileHandle.standardError.write("no QR found\n".data(using: .utf8)!)
    exit(1)
}

for result in results {
    if let payload = result.payloadStringValue {
        print(payload)
    }
}

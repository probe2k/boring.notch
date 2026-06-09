//
//  AppleScriptHelper.swift
//  boringNotch
//
//  Created by Alexander on 2025-03-29.
//

import Foundation

final class AppleScriptHelper {
    private static let queue = DispatchQueue(label: "AppleScriptHelper.queue", qos: .userInitiated)

    private static let cache: NSCache<NSString, NSAppleScript> = {
        let c = NSCache<NSString, NSAppleScript>()
        c.countLimit = 16
        return c
    }()

    private static func compiledScript(for source: String) -> NSAppleScript? {
        let key = source as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let script = NSAppleScript(source: source) else { return nil }
        var compileError: NSDictionary?
        if !script.compileAndReturnError(&compileError) { return nil }
        cache.setObject(script, forKey: key)
        return script
    }

    @discardableResult
    class func execute(_ scriptText: String) async throws -> NSAppleEventDescriptor? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let script = compiledScript(for: scriptText) else {
                    continuation.resume(throwing: NSError(domain: "AppleScriptError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to compile script"]))
                    return
                }
                var error: NSDictionary?
                let descriptor = script.executeAndReturnError(&error)
                if let error = error {
                    continuation.resume(throwing: NSError(domain: "AppleScriptError", code: 1, userInfo: error as? [String: Any]))
                } else {
                    continuation.resume(returning: descriptor)
                }
            }
        }
    }

    class func executeVoid(_ scriptText: String) async throws {
        _ = try await execute(scriptText)
    }
}

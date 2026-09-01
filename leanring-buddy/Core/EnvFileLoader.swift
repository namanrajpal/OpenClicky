//
//  EnvFileLoader.swift
//  leanring-buddy
//
//  Loads KEY=VALUE developer configuration (cloud TTS API keys) from a .env
//  file. The app is launched from Xcode/Finder with a minimal environment,
//  so keys live in a file instead of the process environment.
//
//  Search order (later sources never override earlier ones; the process
//  environment overrides everything):
//    1. $OPENCLICKY_ENV_PATH            explicit override
//    2. <repo root>/.env                dev builds: derived from this source
//                                       file's compile-time path
//    3. ~/.config/openclicky/.env       for installed builds
//
//  Values are secrets: never print or log them.
//
//  PORTABLE CORE: this file must not import AppKit or any macOS-only UI
//  framework.
//

import Foundation

enum EnvFileLoader {

    /// Returns the first non-empty value found for any of the given key
    /// names, checking the process environment first, then the .env files
    /// in search order. Multiple names support common spelling variants
    /// (e.g. DEEPGRAM_KEY vs DEEPGRAM_API_KEY).
    static func value(forAnyOf keyNames: [String]) -> String? {
        let processEnvironment = ProcessInfo.processInfo.environment
        for keyName in keyNames {
            if let value = processEnvironment[keyName], !value.isEmpty {
                return value
            }
        }
        for fileURL in candidateEnvFileURLs() {
            let fileValues = parseEnvFile(at: fileURL)
            guard !fileValues.isEmpty else { continue }
            for keyName in keyNames {
                if let value = fileValues[keyName], !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private static func candidateEnvFileURLs() -> [URL] {
        var candidateURLs: [URL] = []

        if let explicitPath = ProcessInfo.processInfo.environment["OPENCLICKY_ENV_PATH"],
           !explicitPath.isEmpty {
            candidateURLs.append(URL(fileURLWithPath: explicitPath))
        }

        // Dev builds: this source file lives at <repo>/leanring-buddy/Core/,
        // so the repo root's .env is two directories up. #filePath is baked
        // in at compile time, which is exactly right for a from-source build
        // on the machine that owns the .env.
        let sourceFileURL = URL(fileURLWithPath: #filePath)
        let repoRootEnvURL = sourceFileURL
            .deletingLastPathComponent()   // Core/
            .deletingLastPathComponent()   // leanring-buddy/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent(".env")
        candidateURLs.append(repoRootEnvURL)

        candidateURLs.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/openclicky/.env")
        )
        return candidateURLs
    }

    /// Parses a .env file: one KEY=VALUE per line, `#` comments and blank
    /// lines skipped, surrounding single/double quotes stripped from values.
    private static func parseEnvFile(at fileURL: URL) -> [String: String] {
        guard let fileContents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return [:]
        }
        var parsedValues: [String: String] = [:]
        for rawLine in fileContents.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let equalsIndex = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<equalsIndex]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: equalsIndex)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty else { continue }
            parsedValues[key] = value
        }
        return parsedValues
    }
}

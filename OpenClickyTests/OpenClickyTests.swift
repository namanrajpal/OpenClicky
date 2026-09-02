//
//  OpenClickyTests.swift
//  OpenClickyTests
//

import Foundation
import Testing
@testable import OpenClicky

struct OpenClickyTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

    @Test func migratesLegacyScreenRecordingConfirmationKey() async throws {
        let suiteName = "OpenClickyTests.legacy-permission.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let legacyKey = "com.learningbuddy.hasPreviouslyConfirmedScreenRecordingPermission"
        let canonicalKey = "com.namanrajpal.openclicky.hasPreviouslyConfirmedScreenRecordingPermission"
        userDefaults.set(true, forKey: legacyKey)

        WindowPositionManager.migrateScreenRecordingConfirmationKeyIfNeeded(userDefaults)

        #expect(userDefaults.bool(forKey: canonicalKey))
        #expect(userDefaults.object(forKey: legacyKey) == nil)
    }

    @Test func migrationPreservesCanonicalFalseValue() async throws {
        let suiteName = "OpenClickyTests.canonical-permission.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let legacyKey = "com.learningbuddy.hasPreviouslyConfirmedScreenRecordingPermission"
        let canonicalKey = "com.namanrajpal.openclicky.hasPreviouslyConfirmedScreenRecordingPermission"
        userDefaults.set(false, forKey: canonicalKey)
        userDefaults.set(true, forKey: legacyKey)

        WindowPositionManager.migrateScreenRecordingConfirmationKeyIfNeeded(userDefaults)

        #expect(userDefaults.bool(forKey: canonicalKey) == false)
        #expect(userDefaults.object(forKey: legacyKey) == nil)
    }

}

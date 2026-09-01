//
//  PlaceholderResponseGenerator.swift
//  leanring-buddy
//
//  M0 SCAFFOLDING — this is the seam where the AI response comes from.
//
//  Upstream, ClaudeAPI.swift filled this seam by sending the transcript and
//  screenshots to the Anthropic Messages API through a Cloudflare Worker
//  proxy. The worker and its hardcoded proxy URLs were removed in M0, so
//  until the ACP agent client lands in M1 this generator produces a
//  deterministic local response. It exists so the full pipeline
//  (voice → screenshot → response → speech → overlay) is testable
//  end-to-end with zero API keys and zero network dependencies.
//
//  M1 replaces this with ACPAgentClient.swift: a JSON-RPC stdio client that
//  spawns a local agent CLI (kiro-cli in ACP mode) and streams
//  session/update notifications into the same response path.
//

import Foundation

@MainActor
enum PlaceholderResponseGenerator {

    /// Produces a spoken-style response acknowledging the transcript and the
    /// captured screens. Mirrors the shape of a real agent response —
    /// including the trailing [POINT:none] tag — so the existing point-tag
    /// parsing path in CompanionManager is exercised on every interaction.
    static func makeResponse(
        forTranscript transcript: String,
        capturedScreenCount: Int
    ) -> String {
        let screenDescription = capturedScreenCount == 1
            ? "one screen"
            : "\(capturedScreenCount) screens"
        return "i heard you say: \(transcript). i captured \(screenDescription), "
            + "but my agent brain isn't wired up yet — that arrives in milestone one. "
            + "[POINT:none]"
    }
}

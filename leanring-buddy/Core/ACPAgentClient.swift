//
//  ACPAgentClient.swift
//  leanring-buddy
//
//  Agent Client Protocol (ACP) client. Spawns a local agent CLI (kiro-cli in
//  ACP mode) as a stdio subprocess speaking newline-delimited JSON-RPC 2.0,
//  and exposes a streaming prompt API. This replaces the upstream ClaudeAPI +
//  Cloudflare Worker seam: the agent brings its own auth and model access, so
//  the app holds zero API keys and opens zero network connections itself.
//
//  Verified against kiro-cli 2.20.1 (protocolVersion 1):
//  - initialize returns promptCapabilities.image = true, so screenshots are
//    sent as {"type":"image","data":<base64>,"mimeType":"image/jpeg"} blocks.
//  - Response text streams as session/update notifications with
//    update.sessionUpdate == "agent_message_chunk" and content.text pieces.
//  - session/prompt resolves with a stopReason when the turn ends.
//  - session/new returns the available agents in result.modes.
//
//  PORTABLE CORE: this file must not import AppKit or any macOS-only UI
//  framework. Process/Pipe come from Foundation.
//

import Foundation

// MARK: - Public Types

/// One selectable agent persona, as reported by the ACP session's modes.
struct ACPAgentMode: Identifiable, Equatable {
    let id: String
    let name: String
}

/// Connection lifecycle for the panel status row.
enum ACPAgentConnectionState: Equatable {
    case notStarted
    case launching
    case ready
    case failed(reason: String)
}

struct ACPAgentClientError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// An image attached to a prompt.
struct ACPPromptImage {
    let base64Data: String
    let mimeType: String
}

// MARK: - Client

@MainActor
final class ACPAgentClient: ObservableObject {

    @Published private(set) var connectionState: ACPAgentConnectionState = .notStarted
    @Published private(set) var availableAgentModes: [ACPAgentMode] = []
    @Published private(set) var currentAgentModeID: String?

    private var agentProcess: Process?
    private var agentStdinPipe: Pipe?
    private var stdoutLineBuffer = Data()

    private var sessionID: String?
    private var nextRequestID = 1

    /// Pending request continuations keyed by JSON-RPC id.
    private var pendingRequests: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    /// Delivery target for agent_message_chunk text while a prompt is in flight.
    private var activeChunkHandler: ((String) -> Void)?

    /// True after the first prompt of the current session has carried the
    /// full instruction block. Later prompts send a one-line reminder instead.
    private var hasSentInstructionsThisSession = false

    /// The instruction block prepended to the first prompt of each session.
    /// Set by CompanionManager before the first prompt.
    var instructionBlock: String = ""

    // MARK: Lifecycle

    /// Locates the agent binary. The app is launched from Finder/Xcode with a
    /// minimal PATH, so the well-known install locations are checked directly.
    static func findAgentBinaryPath() -> String? {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        let candidatePaths = [
            "\(homeDirectory)/.toolbox/bin/kiro-cli",
            "\(homeDirectory)/.local/bin/kiro-cli",
            "/usr/local/bin/kiro-cli",
            "/opt/homebrew/bin/kiro-cli",
        ]
        return candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Spawns the agent process and performs the initialize + session/new
    /// handshake. Safe to call again after a failure (restarts cleanly).
    func start() async {
        guard connectionState != .launching, connectionState != .ready else { return }

        guard let binaryPath = Self.findAgentBinaryPath() else {
            connectionState = .failed(reason: "kiro-cli not found. Install it, then reopen the panel to retry.")
            return
        }

        connectionState = .launching
        tearDownProcess()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["acp"]
        // Give the subprocess a sane PATH so its own tooling resolves.
        var environment = ProcessInfo.processInfo.environment
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        environment["PATH"] = "\(homeDirectory)/.toolbox/bin:/usr/local/bin:/opt/homebrew/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            let incomingData = fileHandle.availableData
            guard !incomingData.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.consumeStdoutData(incomingData)
            }
        }

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleAgentProcessTermination()
            }
        }

        do {
            try process.run()
        } catch {
            connectionState = .failed(reason: "Could not launch kiro-cli: \(error.localizedDescription)")
            return
        }

        agentProcess = process
        agentStdinPipe = stdinPipe

        do {
            _ = try await sendRequest(method: "initialize", params: [
                "protocolVersion": 1,
                "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false]],
            ], timeoutSeconds: 20)

            let sessionResult = try await sendRequest(method: "session/new", params: [
                "cwd": NSTemporaryDirectory(),
                "mcpServers": [] as [Any],
            ], timeoutSeconds: 60)

            guard let newSessionID = sessionResult["sessionId"] as? String else {
                throw ACPAgentClientError(message: "session/new returned no sessionId")
            }
            sessionID = newSessionID
            hasSentInstructionsThisSession = false

            if let modes = sessionResult["modes"] as? [String: Any] {
                currentAgentModeID = modes["currentModeId"] as? String
                if let modeList = modes["availableModes"] as? [[String: Any]] {
                    availableAgentModes = modeList.compactMap { mode in
                        guard let modeID = mode["id"] as? String else { return nil }
                        return ACPAgentMode(id: modeID, name: (mode["name"] as? String) ?? modeID)
                    }
                }
            }

            connectionState = .ready
            print("🤖 ACP: session \(newSessionID) ready, \(availableAgentModes.count) agent modes")
        } catch {
            connectionState = .failed(reason: error.localizedDescription)
            tearDownProcess()
        }
    }

    func stop() {
        tearDownProcess()
        connectionState = .notStarted
    }

    // MARK: Prompting

    /// Sends a prompt (text + optional images) and streams response text
    /// through onTextChunk. Returns the full accumulated response text.
    /// Throws if the agent is unavailable or the turn fails.
    func sendPrompt(
        text: String,
        images: [ACPPromptImage],
        onTextChunk: @escaping (String) -> Void
    ) async throws -> String {
        if connectionState != .ready {
            await start()
        }
        guard connectionState == .ready, let sessionID else {
            let reason: String
            if case .failed(let failureReason) = connectionState {
                reason = failureReason
            } else {
                reason = "agent is not connected"
            }
            throw ACPAgentClientError(message: reason)
        }

        var promptText = text
        if !hasSentInstructionsThisSession && !instructionBlock.isEmpty {
            promptText = instructionBlock + "\n\n---\n\nuser (via voice): " + text
            hasSentInstructionsThisSession = true
        }

        var promptBlocks: [[String: Any]] = [["type": "text", "text": promptText]]
        for image in images {
            promptBlocks.append([
                "type": "image",
                "data": image.base64Data,
                "mimeType": image.mimeType,
            ])
        }

        var accumulatedResponseText = ""
        activeChunkHandler = { chunkText in
            accumulatedResponseText += chunkText
            onTextChunk(chunkText)
        }
        defer { activeChunkHandler = nil }

        let result = try await sendRequest(method: "session/prompt", params: [
            "sessionId": sessionID,
            "prompt": promptBlocks,
        ], timeoutSeconds: 120)

        let stopReason = (result["stopReason"] as? String) ?? "unknown"
        if stopReason == "refusal" {
            throw ACPAgentClientError(message: "the agent declined to answer")
        }
        return accumulatedResponseText
    }

    /// Cancels the in-flight prompt turn (user pressed push-to-talk again).
    /// session/cancel is a notification; the pending session/prompt request
    /// then resolves with stopReason "cancelled".
    func cancelActivePrompt() {
        guard let sessionID else { return }
        sendNotification(method: "session/cancel", params: ["sessionId": sessionID])
    }

    /// Switches the agent persona via session/set_mode.
    func setAgentMode(_ modeID: String) async {
        guard let sessionID else { return }
        do {
            _ = try await sendRequest(method: "session/set_mode", params: [
                "sessionId": sessionID,
                "modeId": modeID,
            ], timeoutSeconds: 20)
            currentAgentModeID = modeID
        } catch {
            print("⚠️ ACP: set_mode failed: \(error.localizedDescription)")
        }
    }

    // MARK: JSON-RPC plumbing

    private func sendRequest(
        method: String,
        params: [String: Any],
        timeoutSeconds: TimeInterval
    ) async throws -> [String: Any] {
        let requestID = nextRequestID
        nextRequestID += 1

        writeMessage(["jsonrpc": "2.0", "id": requestID, "method": method, "params": params])

        // Timeout watchdog: fail the continuation if no response arrives.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            await MainActor.run { [weak self] in
                if let continuation = self?.pendingRequests.removeValue(forKey: requestID) {
                    continuation.resume(throwing: ACPAgentClientError(message: "\(method) timed out after \(Int(timeoutSeconds))s"))
                }
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestID] = continuation
        }
    }

    private func sendNotification(method: String, params: [String: Any]) {
        writeMessage(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func writeMessage(_ message: [String: Any]) {
        guard let stdinPipe = agentStdinPipe,
              var messageData = try? JSONSerialization.data(withJSONObject: message) else { return }
        messageData.append(0x0A) // newline-delimited framing
        stdinPipe.fileHandleForWriting.write(messageData)
    }

    private func consumeStdoutData(_ incomingData: Data) {
        stdoutLineBuffer.append(incomingData)
        while let newlineIndex = stdoutLineBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutLineBuffer.subdata(in: stdoutLineBuffer.startIndex..<newlineIndex)
            stdoutLineBuffer.removeSubrange(stdoutLineBuffer.startIndex...newlineIndex)
            guard !lineData.isEmpty,
                  let message = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            handleIncomingMessage(message)
        }
    }

    private func handleIncomingMessage(_ message: [String: Any]) {
        // Response to one of our requests
        if let requestID = message["id"] as? Int, let continuation = pendingRequests[requestID],
           message["result"] != nil || message["error"] != nil {
            pendingRequests.removeValue(forKey: requestID)
            if let errorObject = message["error"] as? [String: Any] {
                let errorMessage = (errorObject["message"] as? String) ?? "agent error"
                let errorDetail = (errorObject["data"] as? String).map { ": \($0)" } ?? ""
                continuation.resume(throwing: ACPAgentClientError(message: errorMessage + errorDetail))
            } else {
                continuation.resume(returning: (message["result"] as? [String: Any]) ?? [:])
            }
            return
        }

        guard let method = message["method"] as? String else { return }
        let params = (message["params"] as? [String: Any]) ?? [:]

        switch method {
        case "session/update":
            guard let update = params["update"] as? [String: Any],
                  update["sessionUpdate"] as? String == "agent_message_chunk",
                  let content = update["content"] as? [String: Any],
                  let chunkText = content["text"] as? String else { return }
            activeChunkHandler?(chunkText)

        case "session/request_permission":
            // The voice assistant is read-only: tool permission requests are
            // rejected so a spoken question can never trigger side effects.
            respondToPermissionRequest(message)

        default:
            // _kiro.dev/* housekeeping notifications are ignored.
            break
        }
    }

    /// Rejects a tool-permission request from the agent. Picks the first
    /// option whose kind is a reject variant, falling back to "cancelled".
    private func respondToPermissionRequest(_ requestMessage: [String: Any]) {
        guard let requestID = requestMessage["id"] else { return }
        let params = (requestMessage["params"] as? [String: Any]) ?? [:]
        let options = ((params["options"] as? [[String: Any]]) ?? [])

        let rejectOptionID = options.first { option in
            ((option["kind"] as? String) ?? "").hasPrefix("reject")
        }?["optionId"] as? String

        let outcome: [String: Any]
        if let rejectOptionID {
            outcome = ["outcome": "selected", "optionId": rejectOptionID]
        } else {
            outcome = ["outcome": "cancelled"]
        }

        writeMessage(["jsonrpc": "2.0", "id": requestID, "result": ["outcome": outcome]])
        print("🤖 ACP: rejected a tool permission request (assistant is read-only)")
    }

    // MARK: Teardown

    private func handleAgentProcessTermination() {
        let wasReady = connectionState == .ready
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: ACPAgentClientError(message: "agent process exited"))
        }
        pendingRequests.removeAll()
        sessionID = nil
        agentProcess = nil
        agentStdinPipe = nil
        if wasReady {
            connectionState = .failed(reason: "agent process exited unexpectedly")
        }
    }

    private func tearDownProcess() {
        if let stdoutPipe = agentProcess?.standardOutput as? Pipe {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
        }
        agentProcess?.terminationHandler = nil
        agentProcess?.terminate()
        agentProcess = nil
        agentStdinPipe = nil
        sessionID = nil
        stdoutLineBuffer.removeAll()
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: ACPAgentClientError(message: "client stopped"))
        }
        pendingRequests.removeAll()
    }
}

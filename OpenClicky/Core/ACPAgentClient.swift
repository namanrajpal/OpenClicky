//
//  ACPAgentClient.swift
//  OpenClicky
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

import Combine
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

    // MARK: The openclicky agent

    /// clicky's instructions live in a dedicated kiro-cli custom agent config
    /// (ACP has no system-prompt parameter, and per-session instruction
    /// prompts waste a turn). The agent also declares tools: [] and loads no
    /// MCP servers, which makes session startup ~4x faster and guarantees a
    /// spoken question can never trigger side effects.
    /// See docs/reference/kiro-cli.md.
    static let agentName = "openclicky"

    /// The model clicky runs on. Haiku-class: small, vision-capable, minimal
    /// thinking overhead. Measured ~2x faster generation than the CLI's
    /// default frontier model for clicky's 1-2 sentence answers. Perceived
    /// latency = time to first spoken sentence, so a fast model matters more
    /// here than raw capability; the AX router already handles the
    /// exact-coordinate cases where a small model's vision would struggle.
    static let agentModel = "claude-haiku-4.5"

    private static let agentPrompt = """
    you're clicky, a friendly always-on companion that lives in the user's menu bar on their mac. the user speaks to you via push-to-talk and you can see their screen. your reply may be spoken aloud via text-to-speech and shown as text next to their cursor. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - you have no tools. answer directly from the message, the images, and the context you're given.
    - default to one or two sentences. be direct and dense. if the user asks you to explain more or go deeper, give a thorough explanation.
    - all lowercase, casual, warm. no emojis. no markdown, no lists, no formatting — just natural speech, short sentences.
    - don't use abbreviations that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see. if the screenshot isn't relevant, just answer the question.
    - never say "simply" or "just". don't read code verbatim — describe it conversationally.
    - a [context] section may follow the user's words with image labels and a list of accessibility elements from the frontmost app. use the element names to be precise about what's on screen.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. point whenever it would genuinely help — finding a menu, a button, navigating an app. don't point for general knowledge questions.

    when you point, append a coordinate tag at the very end of your response, after your spoken text. the screenshot images are labeled with their pixel dimensions — your coordinates MUST be integer pixel coordinates in that image's coordinate space, origin top-left. estimate them by looking at the image itself. the [context] section lists accessibility element names so you can name things precisely; it contains no coordinates.

    format: [POINT:x,y:label] where label is a short 1-3 word description. if the element is on a different screen than the cursor, append :screenN using the screen number from the image label. if pointing wouldn't help, append [POINT:none].

    examples:
    - "you'll want the color inspector — top right of the toolbar. [POINT:1100,42:color inspector]"
    - "html is the skeleton of every web page. [POINT:none]"
    """

    /// Writes the openclicky agent config to the global kiro-cli agent
    /// directory. Runs on every start: creates the file when missing and
    /// rewrites it when the embedded prompt changed (so app updates keep the
    /// agent in sync). Leaves the file alone when it already matches.
    static func ensureAgentConfigInstalled() {
        let agentsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kiro/agents", isDirectory: true)
        let agentConfigURL = agentsDirectory.appendingPathComponent("\(agentName).json")

        if let existingData = try? Data(contentsOf: agentConfigURL),
           let existingConfig = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any],
           existingConfig["prompt"] as? String == agentPrompt,
           existingConfig["model"] as? String == agentModel {
            return
        }

        let agentConfig: [String: Any] = [
            "name": agentName,
            "description": "OpenClicky voice companion. Answers push-to-talk questions about the user's screen with optional [POINT] cursor tags. Installed and managed by the OpenClicky app.",
            "prompt": agentPrompt,
            "model": agentModel,
            "tools": [] as [String],
            "mcpServers": [:] as [String: Any],
            "includeMcpJson": false,
        ]

        do {
            try FileManager.default.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)
            let configData = try JSONSerialization.data(withJSONObject: agentConfig, options: [.prettyPrinted, .sortedKeys])
            try configData.write(to: agentConfigURL)
            print("🤖 ACP: installed agent config at \(agentConfigURL.path)")
        } catch {
            print("⚠️ ACP: could not install agent config: \(error.localizedDescription)")
        }
    }

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
        Self.ensureAgentConfigInstalled()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["acp", "--agent", Self.agentName]
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

        var promptBlocks: [[String: Any]] = [["type": "text", "text": text]]
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

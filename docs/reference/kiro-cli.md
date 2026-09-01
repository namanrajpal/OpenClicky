# kiro-cli Reference for OpenClicky

How OpenClicky talks to kiro-cli: the ACP wire protocol, the custom agent that
carries clicky's instructions, and operational details (sessions, logs,
troubleshooting). Facts marked VERIFIED were observed live against
kiro-cli 2.20.1 on 2026-08-30; the rest comes from the official docs.

Sources:
- Live wire probes against `kiro-cli acp` (this machine, v2.20.1)
- https://kiro.dev/docs/cli/acp/ (official ACP page)
- https://kiro.dev/docs/custom-agents/ (custom agent configuration)
- https://agentclientprotocol.com/protocol/v1/overview (ACP spec)
- `kiro-cli acp --help`, `kiro-cli agent --help` (local CLI)

## 1. The OpenClicky agent

kiro-cli custom agents are JSON (or Markdown) configs that carry a system
prompt, a tool allowlist, and MCP wiring. OpenClicky uses a dedicated agent so
clicky's instructions live in the agent config instead of riding the first
prompt of every session.

- Location: `~/.kiro/agents/openclicky.json` (global agent directory)
- Spawn: `kiro-cli acp --agent openclicky`
- The app installs this file itself if missing (see `ACPAgentClient.swift`,
  `ensureAgentConfigInstalled`), so a fresh machine needs no manual step.

The config, and why each field is set:

| Field | Value | Why |
|---|---|---|
| `name` | `openclicky` | The `--agent` flag and session mode id |
| `prompt` | clicky's full instruction block | System prompt for every turn; replaces the first-prompt instruction hack |
| `tools` | `[]` | The agent has NO tools. A spoken question can never trigger side effects, and no permission round trips happen |
| `mcpServers` | `{}` | Loads none of the user's MCP servers |
| `includeMcpJson` | `false` | Ignores global MCP config too |
| `model` | unset | Uses the CLI's default model; `session/set_model` can change it per session |

VERIFIED effect: session/new drops from ~8-10s (default agent loading every
configured MCP server) to ~2.3s, and the response honored the persona
(lowercase voice, trailing `[POINT:none]`) with zero per-session instructions.

Other schema fields available (from the docs, unused by OpenClicky for now):
`description`, `welcomeMessage`, `excludedTools`, `toolAliases`, `resources`
(`file://` and `skill://`), `permissions.rules`, `includePowers`,
`allowedTools`, `hooks`. Workspace-local agents live in `.kiro/agents/` and
take precedence over global ones with the same name, but discovery is
cwd-relative, so OpenClicky uses the global directory (the app spawns the CLI
with a temp-dir cwd).

Useful CLI verbs: `kiro-cli agent list`, `kiro-cli agent validate --path
<file>`, `kiro-cli agent create/edit/set-default`.

## 2. ACP wire protocol (as kiro-cli speaks it)

Transport: newline-delimited JSON-RPC 2.0 over stdin/stdout of the
`kiro-cli acp` subprocess. Methods are request/response; notifications are
one-way.

### Handshake (VERIFIED)

```json
--> {"jsonrpc":"2.0","id":0,"method":"initialize","params":{
      "protocolVersion":1,
      "clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false}}}}
<-- {"jsonrpc":"2.0","id":0,"result":{
      "protocolVersion":1,
      "agentCapabilities":{
        "loadSession":true,
        "promptCapabilities":{"image":true,"audio":false,"embeddedContext":false},
        "mcpCapabilities":{"http":true,"sse":false}},
      "authMethods":[],
      "agentInfo":{"name":"Kiro CLI Agent","title":"Kiro CLI Agent","version":"2.20.1"}}}
```

`promptCapabilities.image: true` is the flag OpenClicky's screenshot pipeline
depends on.

### Session creation (VERIFIED)

```json
--> {"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}
<-- result: {"sessionId":"<uuid>","modes":{"currentModeId":"openclicky","availableModes":[...]}}
```

`modes.availableModes` lists every installed agent (id, name, description).
This is what populates the panel's agent picker. `session/set_mode` with a
`modeId` switches persona mid-session.

### Prompting (VERIFIED)

```json
--> {"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{
      "sessionId":"<uuid>",
      "prompt":[
        {"type":"text","text":"what color is this?"},
        {"type":"image","data":"<base64>","mimeType":"image/png"}]}}
```

CAUTION: the official docs' example uses a `content` key for the blocks, but
kiro-cli 2.20.1 accepts `prompt` (verified live; an image sent this way was
described correctly). Trust the wire, re-verify on CLI upgrades.

Response text streams as notifications while the request is pending:

```json
<-- {"jsonrpc":"2.0","method":"session/update","params":{
      "sessionId":"<uuid>",
      "update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"h"}}}}
```

Chunks can be as small as one character. The `session/prompt` request itself
resolves when the turn ends:

```json
<-- {"jsonrpc":"2.0","result":{"stopReason":"end_turn"},"id":2}
```

Stop reasons include `end_turn`, `cancelled`, `refusal`, `max_tokens`.

### Cancellation

`session/cancel` is a NOTIFICATION (no response):

```json
--> {"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"<uuid>"}}
```

The pending `session/prompt` then resolves with `stopReason: "cancelled"`.
This is OpenClicky's interrupt path when the user re-presses the hotkey.

### Permission requests

If the agent wants to run a tool, it sends a `session/request_permission`
REQUEST that the client must answer (`{"outcome":{"outcome":"selected",
"optionId":...}}` or `{"outcome":{"outcome":"cancelled"}}`). The openclicky
agent has `tools: []` so this should never fire; `ACPAgentClient` still
answers with a rejection as defense in depth.

### Housekeeping notifications (safe to ignore)

kiro-cli emits `_kiro.dev/*` extension notifications: `commands/available`,
`mcp/server_initialized`, `subagent/list_update`, `metadata` (context usage
percentage), `compaction/status`, `clear/status`. Extensions are experimental
per the docs. OpenClicky ignores all of them today; `metadata`'s
`contextUsagePercentage` is a candidate for a future session-health indicator.

## 3. Operational reference

| Thing | Where |
|---|---|
| Binary (this machine) | `~/.toolbox/bin/kiro-cli` (app also checks `~/.local/bin`, `/usr/local/bin`, `/opt/homebrew/bin`) |
| Agent configs (global) | `~/.kiro/agents/*.json` |
| Session storage | `~/.kiro/sessions/cli/<session-id>.json` + `.jsonl` (event log) |
| Logs (macOS) | `$TMPDIR/kiro-log/kiro-chat.log` |
| Log verbosity | `KIRO_LOG_LEVEL=debug kiro-cli acp`, or `KIRO_CHAT_LOG_FILE=<path>` |

Notes:

- `loadSession: true` means a crashed session's history can be restored via
  `session/load` (open item Q3 in the architecture review; not implemented in
  the app yet).
- `session/set_model` exists for per-session model switching (unused).
- Editors integrate the same way the app does (JetBrains `~/.jetbrains/acp.json`,
  Zed `agent_servers` settings) — useful for debugging the agent interactively.
- ACP has no system-prompt parameter; the agent config's `prompt` field is the
  supported way to set one. That is the reason the openclicky agent exists.

## 4. Verifying the setup by hand

```bash
# 1. Agent installed and valid?
kiro-cli agent validate --path ~/.kiro/agents/openclicky.json

# 2. Agent listed?
kiro-cli agent list | grep openclicky

# 3. Interactive smoke test in clicky's persona:
kiro-cli chat --agent openclicky
#    ask: "what's html?"  -> expect lowercase clicky voice ending in [POINT:none]
```

Update this file when the CLI major version changes or a wire shape stops
matching the VERIFIED examples.

# OpenClicky App Target

The repository-root [`AGENTS.md`](../AGENTS.md) is the single source of truth for coding conventions, architecture, build rules, and the full key-file table.

Target-specific structure:

```text
OpenClicky/
├── Core/                        Foundation-only routing, ACP, streaming, and configuration
├── OpenClickyApp.swift          app and delegate lifecycle
├── CompanionManager.swift      central state and request pipeline
├── Buddy*.swift                microphone, transcription, and audio support
├── Companion*.swift            panel, capture, and response surfaces
├── OverlayWindow.swift         cursor buddy, lasso, pointing, and pen circle
├── AXTreeProvider.swift        accessibility snapshot and exact local coordinates
├── CloudSentenceTTSClient.swift
├── LocalSpeechSynthesizerTTSClient.swift
└── DesignSystem.swift
```

For human-facing system documentation, start at [`../docs/README.md`](../docs/README.md). The as-built component map is [`../docs/reference/components.md`](../docs/reference/components.md).

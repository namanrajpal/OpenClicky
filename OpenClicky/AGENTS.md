# OpenClicky macOS Target

The repository-root [`AGENTS.md`](../AGENTS.md) is the single source of truth for coding conventions and build rules. Human-facing architecture starts at [`../docs/architecture.md`](../docs/architecture.md).

```text
OpenClicky/
├── App/                  lifecycle, composition, and observable state
├── Core/                 platform-lean routing and streaming algorithms
├── Features/             voice interaction, cursor overlay, and menu bar UI
├── Platform/             macOS framework adapters
├── Infrastructure/       ACP process and configuration adapters
├── DesignSystem/         native visual primitives
├── Resources/            asset catalog
├── Info.plist             app metadata
└── OpenClicky.entitlements signing capabilities
```

Dependency direction:

```text
Features -> App -> Core
              |
              +-> Platform
              +-> Infrastructure
```

Core must not import SwiftUI, AppKit, ScreenCaptureKit, or AVFoundation. The current `QuestionRouter` still uses CoreGraphics geometry; remove that coupling before extracting a Windows-compatible package.

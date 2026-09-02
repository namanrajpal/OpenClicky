# OpenClicky Documentation

This directory contains the as-built product, architecture, integration, and planning documentation for OpenClicky.

## Documentation map

```text
docs/
├── README.md                         this index
├── setup.md                          developer setup, permissions, and smoke checks
├── permissions.md                    plain-language explanation of every macOS permission prompt
├── architecture.md                   system structure, request flow, and coordinate spaces
├── UX-BASELINE.md                    shipped interaction model and UX decisions
├── reference/
│   ├── components.md                 source components and internal API surfaces
│   ├── configuration.md              runtime, TTS, agent, and persisted settings
│   ├── annotation-protocol.md        current POINT response grammar
│   └── kiro-cli.md                   ACP wire protocol and operational details
└── plans/
    ├── ROADMAP.md                    shipped milestones and unscheduled direction
    └── guided-tasks.md               potential multi-step guidance design
```

## Recommended reading paths

- **Run the app:** [Setup](setup.md), [Permissions](permissions.md), then [Configuration](reference/configuration.md).
- **Understand the system:** [Architecture](architecture.md), [Components](reference/components.md), then [kiro-cli ACP](reference/kiro-cli.md).
- **Change user behavior:** [UX baseline](UX-BASELINE.md) before editing overlay, modality, capture, or onboarding behavior.
- **Change pointing:** [Annotation protocol](reference/annotation-protocol.md) and the coordinate-space section in [Architecture](architecture.md).
- **Evaluate future work:** [Roadmap](plans/ROADMAP.md) and [Guided tasks](plans/guided-tasks.md).

## Source-of-truth boundaries

| Topic | Source of truth |
|---|---|
| Current user interaction | `UX-BASELINE.md` and the shipped Swift implementation |
| Runtime architecture and data flow | `architecture.md` |
| Swift component ownership and callable surfaces | `reference/components.md` |
| Environment and persisted configuration | `reference/configuration.md` |
| Agent response tags | `reference/annotation-protocol.md` |
| ACP transport details | `reference/kiro-cli.md` |
| Proposed work | `plans/` documents, each with an explicit status |

When implementation and documentation disagree, verify the implementation and update the relevant document in the same change.

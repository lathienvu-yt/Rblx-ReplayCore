# Roblox ReplayCore

A modern Roblox replay system for competitive gaming and replay-heavy experiences.

ReplayCore is a standalone replay framework extracted from an internal Roblox project. It is built around recording gameplay state, compressing replay data, storing it in chunks, and reconstructing that data during playback.

> **Status:** Experimental / active development. The public API and replay format may change.

## Features

- Replay recording
- Replay playback
- Freecam playback
- Client/server replay architecture
- Delta-based frame data
- Replay data compression
- Chunked replay storage
- Playback speed control
- Player isolation while viewing replays
- Versioned replay protocol

## Repository structure

```text
Rblx-ReplayCore/
├── Client/
│   └── ReplayRecorder.luau
├── Server/
│   └── ReplayManager.luau
├── replaycoredemo.rbxl
├── README.md
└── LICENSE
```

The `Client` and `Server` directories contain the replay components. The included `replaycoredemo.rbxl` is a demonstration place for the system.

## How it works

ReplayCore records gameplay as a sequence of frames rather than treating a replay as a video file.

A simplified view of the pipeline is:

```text
Gameplay
   │
   ▼
Recording
   │
   ▼
Frame data
   │
   ▼
Delta / compression
   │
   ▼
Chunked replay data
   │
   ▼
Storage
   │
   ▼
Playback / reconstruction
   │
   ▼
Replay camera
```

Instead of repeatedly storing complete state when possible, replay data can represent changes relative to previous frames. This makes long recordings substantially more practical than storing an independent full state for every frame.

## Replay protocol

ReplayCore currently uses **RCP4** as its development replay protocol.

RCP4 is designed around compact, versioned replay data and reconstruction during playback. The protocol is still under development, so replay data should be considered implementation-specific until a stable format is published.

## Playback

Replay playback is separate from normal gameplay. The replay viewer can take control of the camera and isolate the viewer from the live player state while the recorded movement is reconstructed.

This makes ReplayCore suitable for things such as:

- Competitive match replays
- Parkour and platformer replays
- Racing replays
- Movement analysis
- Cinematic playback
- Spectating
- Killcams and highlight systems

## Map compatibility

ReplayCore does **not** include a map implementation.

The replay framework is intended to be independent from the experience's map and gameplay code. Your experience provides its own environment while ReplayCore handles the replay data and playback side.

The included demo place is only an example of how the system can be integrated.

## Installation

ReplayCore is currently distributed as source code rather than as a packaged Roblox asset.

1. Clone or download this repository.
2. Copy the required files from `Client/` and `Server/` into your experience.
3. Integrate the replay components with your own game systems.
4. Use `replaycoredemo.rbxl` as a reference for the current implementation.

Because ReplayCore is still being cleaned up, integration details may change between commits.

## Development status

ReplayCore is currently being separated from its original internal implementation and cleaned up for public use.

### Current priorities

- Clean up the public API
- Remove game-specific dependencies
- Improve documentation
- Stabilize replay serialization
- Improve error handling
- Improve recording/playback performance
- Document the RCP4 format
- Make integration easier for other Roblox experiences

## Audio / voice recording

Audio recording is **not currently part of the stable ReplayCore implementation**.

Future versions may investigate replay-associated audio where Roblox APIs and platform policies make this practical. Any implementation involving player voice would need clear recording disclosure, appropriate consent/opt-out handling, and compliance with Roblox policies.

## Contributing

Issues, suggestions, and pull requests are welcome.

When reporting a replay bug, please include:

- The ReplayCore commit/version you are using
- Roblox Studio version
- Steps to reproduce the issue
- Relevant output or errors
- Whether the issue occurs during recording, storage, reconstruction, or playback

## License

Rblx-ReplayCore is released under the **MIT License**.

See [`LICENSE`](LICENSE) for the full license text.

## Credits

Created by **lathienvu-yt**.

ReplayCore originated as part of an internal Roblox project and is being developed into a standalone replay framework for other experiences.

---

**Record it. Reconstruct it. Replay it.**

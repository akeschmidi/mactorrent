# MacTorrent

BitTorrent-Client für macOS auf Basis von Swift und SwiftUI — eine Nachbildung der Kern-Funktionen von qBittorrent (Referenz-Analyse via REA/Ghidra).

## Features
- **bencode-Codec** (`BB.swift`): Encoder/Decoder für Torrent-Metadaten
- **Torrent-Parser**: `.torrent`-Dateien, SHA-1-InfoHash, Single- & Multi-File
- **Piece-Verifikation**: SHA-1-Hashing mit CryptoKit (`Insecure.SHA1`)
- **Peer-Protocol**: BitTorrent-Handshake, have/interested/request/piece, Bitfield
- **Tracker-Client**:announce-Roundtrips per HTTP
- **SwiftUI-GUI**: Downloads-Liste mit Fortschritt, Start/Stop/Recheck, Drag&Drop-Import, Persistenz via `manifest.json`

## Architektur
| Target | Beschreibung |
|---|---|
| `TorrentKit` | Eigenständige Framework-Library: Codec, Parser, Engine, Netzwerk |
| `MacTorrent` | macOS-App (SwiftUI, AppKit-Brücke für Panels/Alerts) |

## Build
```bash
brew install xcodegen
xcodegen generate
xcodebuild -project MacTorrent.xcodeproj -scheme MacTorrent -configuration Release build
```

Anforderungen: macOS 14+, Xcode 27 (Swift 5.9). Code-Signing: ad-hoc.

## Projekt-Layout
```
Sources/
  TorrentKit/   BB.swift, TorrentInfo.swift, TorrentParser.swift,
                PieceStore.swift, TorrentEngine.swift,
                PeerConnection.swift, PeerMessage.swift, TrackerClient.swift
  App/          MacTorrentApp.swift, AppModel.swift,
                DownloadsView.swift, TorrentRowView.swift
Resources/      Info.plist
project.yml     xcodegen-Spec (2 Targets)
```

# Orders & Directives Application

A local-first, cross-platform accountability and task management application built with **Flutter**. Designed for both autonomous solo routines and remote Dominant-to-Submissive control across **Windows, macOS, Linux, and Android**.

---

## Features Overview

### 1. Dual Mode Architecture
- **Player (Submissive) HUD**:
  - Live Active Order countdown rings with urgency warning states.
  - Randomized order draw filtered by category and difficulty tier (1–5).
  - Verification & proof submission system.
  - Discipline Score gauge, streak counter, and token balance wallet.
  - Complete historical audit log of rewards, penalties, and completed tasks.
- **Director (Dominant) Control**:
  - Live remote monitor of player status (streak, tokens, in-progress tasks).
  - Instant direct order dispatch with customized timers, tiers, and token stakes.
  - Proof submission review (Approve & Reward / Reject & Penalize).
  - Manual token adjustments for merit or discipline infractions.
- **Visual Pack Studio**:
  - Visual editor to create, tag, edit, and export custom directive packs.
  - Zero raw JSON editing required (though full JSON import/export is supported).
  - Password-based AES encryption for sharing sensitive packs.

### 2. Privacy & Local Stealth
- **Offline-First**: All data is stored locally in SQLite / SharedPreferences with zero cloud tracking or telemetry.
- **Emergency Panic / Disguise Mode**:
  - Tap the disguise button in the header (or trigger via hotkey) to instantly mask the app with a fully functional Calculator decoy.
  - Secret unlock: Enter `7777=` or long-press the top header to return.
- **App Launch PIN Lock**: Optional 4–6 digit security PIN lock.

### 3. Remote Pairing & E2EE Sync
- **Local Wi-Fi Pairing**: Direct local WebSocket connection between Dominant and Submissive devices with zero cloud configuration.
- **End-to-End Encryption**: All dispatches, state synchronization, and commands are encrypted using AES-256 with a shared pairing secret code.

### 4. Dynamic Theming Engine
Choose from 5 built-in theme presets or configure custom accent colors:
1. **Obsidian Cyberpunk** (Electric Cyan, Neon Purple, Dark Slate)
2. **Minimalist Noir** (High-contrast monochrome black & white)
3. **Velvet Crimson** (Deep Burgundy, Warm Rose)
4. **Slate Terminal** (Sky Blue, Emerald, Cool Slate)
5. **Discreet Clean** (Subtle daytime light theme)

---

## Project Structure

```
orders_app/
├── lib/
│   ├── main.dart                          # App bootstrap & provider initialization
│   ├── core/
│   │   ├── theme/
│   │   │   ├── app_theme.dart             # 5 theme configurations & color definitions
│   │   │   └── theme_provider.dart        # Reactive theme switcher & custom accent picker
│   │   └── security/
│   │       ├── encryption_helper.dart     # AES-256 symmetric encryption & key derivation
│   │       └── security_service.dart      # PIN lock & panic decoy state management
│   ├── models/
│   │   ├── order_item.dart                # Directive schema (tiers, durations, tokens, types)
│   │   ├── order_pack.dart                # Pack container & metadata
│   │   ├── active_order.dart              # In-progress countdown tracker & status
│   │   ├── user_stats.dart                # Compliance score, streak, history entries
│   │   └── sync_message.dart              # Protocol for remote commands & proofs
│   ├── services/
│   │   ├── storage_service.dart           # Local persistence & starter packs
│   │   ├── order_engine.dart              # State machine, timers, draw logic, compliance
│   │   └── sync_service.dart              # Local WebSocket host/client & E2EE messaging
│   ├── views/
│   │   ├── home_screen.dart               # Adaptive navigation shell (Desktop rail & mobile bar)
│   │   ├── player/                        # Submissive HUD, history log, compliance stats
│   │   ├── director/                      # Dominant dashboard, pack manager, visual pack studio
│   │   ├── pairing/                       # Network pairing & secret code configuration
│   │   ├── disguise/                      # Functional calculator panic decoy
│   │   ├── security/                      # PIN lock authentication screen
│   │   └── settings/                      # Theme selector, accents, and security preferences
│   └── widgets/
│       ├── countdown_ring.dart            # Animated circular timer with urgency glow
│       ├── order_card.dart                # Directive card with progress & actions
│       └── token_badge.dart               # Token balance & streak pill
└── test/                                  # Unit tests for engine, encryption, and models
```

---

## Getting Started & Running

### Prerequisites
- [Flutter SDK](https://flutter.dev/docs/get-started/install) (version 3.10+)

### Running the App
```bash
# 1. Install dependencies
flutter pub get

# 2. Run on Desktop (Windows, macOS, Linux)
flutter run -d windows
flutter run -d macos
flutter run -d linux

# 3. Run on Android
flutter run -d android

# 4. Build standalone executable
flutter build windows
flutter build apk --release
```

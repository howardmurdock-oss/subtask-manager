# (sub)Task Manager - Future Feature Roadmap & Backlog

This document tracks planned features, architectural explorations, and long-term enhancements for future releases.

---

## 1. Hybrid P2P Direct Connect (Large Media & Video Transfers)

### Summary & Concept
A hybrid networking architecture that keeps **ntfy** as the reliable, asynchronous backbone for orders, quests, chat, and token syncing, while spinning up an **on-demand direct Peer-to-Peer (P2P) pipe** for transferring large media files (such as video verification, high-resolution photo proofs, and audio recordings).

### Core Benefits
* **Zero Bandwidth Costs & No File Size Limits:** Video proofs and large media transfer directly between devices at full internet speed without passing through middleman servers.
* **Preserves ntfy Reliability & Battery Efficiency:** 
  * Small JSON control messages, directives, and chat continue using ntfy's "store-and-forward" queue (allowing orders to arrive even if the player's device was asleep or offline when dispatched).
  * The direct P2P connection only wakes up on-demand during active file transfers and shuts down immediately afterward to conserve battery.
* **End-to-End Encrypted (E2EE):** Direct media stream is encrypted between devices using DTLS/SRTP or application-layer AES-GCM.

### Architecture & Transfer Flow
```
1. Initiation:
   [Sender] drops a lightweight metadata ping into ntfy:
   "{ type: 'initiateMediaTransfer', fileId: '...', sizeBytes: 45000000, sdpOffer: '...' }"

2. Handshake / Signaling (via ntfy):
   [Receiver] receives the ping, generates an SDP answer with ICE candidates, and returns it via ntfy.

3. NAT Hole Punching & Direct Connection:
   Both devices use STUN (e.g., Google's public STUN servers) to punch through router NATs.

4. Direct Stream:
   Direct WebRTC DataChannel (or direct TCP/UDP socket) opens:
   - Chunks binary stream with real-time transfer progress bar.
   - Saves file to recipient's local encrypted sandbox.

5. Teardown:
   Direct channel closes; confirmation receipt is logged in the Activity History.
```

### Proposed Tech Stack & Dependencies
* `flutter_webrtc` (WebRTC DataChannels for cross-platform Android & Windows P2P)
* Local LAN discovery (`nsd` / `multicast_dns`) for instant gigabit transfers when both devices share the same Wi-Fi.
* Free public STUN servers for NAT discovery (`stun.l.google.com:19302`).

---

## 2. Pacing Metronome & Dynamic / Variable Cadence Engine

### Summary & Concept
An integrated pacing metronome for Action Routine Timers and Quest Steps that produces rhythmic audio clicks, synchronized visual screen pulses, and tactile haptic vibrations (on Android mobile) to pace stroking, breath control, edge training, fitness drills, or discipline routines.

Supports both **Fixed Steady BPM** and **Dynamic / Variable Tempo Curves** that fluidly speed up and slow down during the active timer.

### Cadence Modes & Curves

```
1. FIXED STEADY TEMPO
   • Constant BPM (e.g., 60 BPM = 1 beat/sec).

2. WAVE / ROLLERCOASTER (Slow ➔ Fast ➔ Slow ➔ Fast)
   BPM
   110 |       ▲               ▲
    70 |     /   \           /   \
    30 | ───/     \─────────/     \───
       └────────────────────────────── Time
   • Mathematical curve: Cosine wave interpolation between Min and Max BPM over N waves.
   • Ideal for teasing waves and breath cycles.

3. PYRAMID PEAK (Slow ➔ Intense Peak ➔ Cooldown)
   BPM
   120 |              ▲
    80 |            /   \
    40 | ─────────/       \───────────
       └────────────────────────────── Time
   • Linear or sinusoidal ramp up to the midpoint, then gradual decay back down.

4. ACCELERANDO RAMP (Progressive Acceleration)
   BPM
   120 |                     ▲
    80 |                 /───┘
    30 | ───────────────/
       └────────────────────────────── Time
   • Starts slow and relentlessly accelerates until the timer chime.

5. CHAOS / SURPRISE JUMPS
   • Randomly shifts tempo between Min and Max BPM every 15–30s with a distinct audio warning cue.
```

### Technical Design & Capabilities
* **Audio Synthesis:** Uses the existing in-app `SoundService` PCM WAV synthesis engine to generate zero-latency, click/woodblock/pulse audio bytes with zero external asset dependencies.
* **Haptics:** Android vibration pulse on each beat (`HapticFeedback.lightImpact()` / `mediumImpact()`) for tactile pacing.
* **Visual Aura:** An on-screen glowing ring expands and contracts in exact rhythm with the active tempo.
* **Live Speed Indicator:** Live on-screen gauge displaying current BPM and direction (e.g. *"Accelerating: 84 BPM ➔ 92 BPM"*).
* **Sound Tone Customization:** Woodblock click, electronic tick, soft hypnotic bell, low sub-bass pulse.

### Proposed Data Model Additions (`OrderItem` & `QuestStep`)
```dart
enum MetronomeMode {
  none,
  fixed,
  wave,
  pyramid,
  accelerando,
  chaos,
}

class MetronomeConfig {
  final MetronomeMode mode;
  final int minBpm;           // e.g. 30
  final int maxBpm;           // e.g. 110 (or target BPM for fixed mode)
  final int waveCount;        // Number of swells for wave mode (e.g. 2)
  final String soundTone;     // 'woodblock', 'tick', 'bell', 'bass'
  final bool enableHaptics;   // Mobile vibration on beat
}
```

---

## 3. Cross-Timezone Partner Clock & Local Time Sync (Opt-In)

### Summary & Concept
An opt-in feature allowing paired Directors and Players across different time zones to share their current local time and ambient day/night status with zero battery drain and zero continuous network traffic.

### Core Value & Use Cases
* **Scheduling Context:** Directors can check whether a submissive is in work hours, evening relaxation, or the middle of the night before dispatching directives.
* **Late Night Alerts:** Optional confirmation prompt for Directors before sending an intense alarm or physical drill during the player's sleeping hours (e.g. 11 PM – 6 AM).
* **Timezone-Aware Deadlines:** "End of Day" window deadlines automatically align to the recipient player's local midnight.

### Technical Implementation (Zero Network Traffic)
* Devices include their **Time Zone Offset** (e.g., `utcOffsetMinutes: -240` / `EDT`) inside their standard encrypted heartbeat and status sync payloads.
* The receiving device computes the partner's live clock locally:
  `DateTime.now().toUtc().add(Duration(minutes: partnerUtcOffsetMinutes))`
* Displays live, second-accurate partner time without polling or sending separate network requests.

### Privacy & Display Options
* **Settings Toggle:** *"Share My Local Timezone"* (Enabled / Disabled)
* **Precision Options:**
  1. *Exact Time & Timezone:* e.g. `🕒 3:48 PM (EDT / UTC-4) • 2 hrs ahead`
  2. *Relative Offset Only:* e.g. `🕒 2 hours ahead of you`
  3. *Ambient Status Only:* e.g. `☀️ Daytime` / `🌙 Night / Sleep hours`

---

## 4. Protocol Scheduler & Automated Dispatch Engine (Patreon VIP)

### Summary & Concept
An automated scheduling and dispatch engine gated for Patreon VIP supporters that allows Directors to pre-program future and recurring directive/quest dispatches, while enabling Players to automate their own daily regimens and set interval-based random deck draws.

### Director Capabilities (Patreon VIP)
* **Future One-Off Drops:** Pre-schedule orders to dispatch at a specific future date and time (e.g., *"Send 'Posture Check' tomorrow morning at 7:30 AM"*).
* **Recurring Automation:** Set up automated daily or weekly dispatch schedules (e.g., *"Every Monday, Wednesday, Friday at 6:00 PM ➔ Dispatch 'Endurance Trial'"*).
* **Surprise Window Drops:** Dispatch an unannounced order at a randomized moment within a configured time window (e.g., *"Drop 1 Tier 2 directive randomly between 1:00 PM and 5:00 PM on weekdays"*).
* **Universal Recipient Compatibility:** Any paired player (free tier or Patreon) can receive and execute scheduled dispatches seamlessly.

### Player Capabilities (Patreon VIP)
* **Self-Discipline Daily Schedule:** Build structured, recurring self-orders that automatically alarm and activate at set times of day.
* **Automated Deck Auto-Draws:** Set the app to automatically draw a random directive from active packs at regular intervals (e.g., *"Draw 1 random task from 'Discipline Protocol' every 3 hours between 9:00 AM and 6:00 PM"*).
* **Unpredictability Mode:** Randomly trigger solo directives at unexpected times throughout the day to test obedience readiness.

### Technical Architecture
* **Background System Alarms:** Uses exact device-level alarms (`flutter_local_notifications` scheduled notifications, Android `AlarmManager`, Windows scheduled timers) ensuring dispatches and notifications fire accurately even if the app is closed.
* **Encrypted Dispatch Relay:** At the scheduled timestamp, the Director app automatically formats the encrypted sync payload and transmits it over ntfy to the recipient.

---

## 5. "Blindfold Mode" (Sensory Deprivation & Pure Auditory/Haptic Protocol)

### Summary & Concept
A complete sensory deprivation experience for tasks and quests where the visual screen is blacked out, and the player must obey purely through audio cues, spoken guidance (TTS / voice notes), rhythm metronomes, and tactile haptic vibration patterns.

### Core Mechanics & Features
* **True OLED Blackout:** The screen renders pure `#000000` black (saving battery on OLED/AMOLED screens) or an ultra-faint rhythmic breathing glow.
* **Sensory Cues (No Screen Watching):**
  * Spoken directives via text-to-speech or voice synthesis.
  * Audio tone milestones: 50% elapsed tone, 10s warning chime, grand completion bell.
  * Distinct haptic patterns (e.g. sharp double pulse = *speed up*, long smooth vibration = *hold / pause*, rapid fluttering = *final 10 seconds*).
* **"Anti-Peek" Sensor Enforcement & Telemetry:**
  * **Face-Down Table Requirement:** Player places phone face-down on a flat surface or in their pocket.
  * **Variable Infraction Penalty (Director-Configurable):** The Director can configure the penalty per infraction (e.g. `-10` tokens per violation, or custom amount).
  * **Real-Time Violation Notification:** If the phone is lifted or screen tapped during an active blindfold session, an encrypted infraction alert is immediately transmitted to the attached Director.
  * **Verification Card Telemetry Breakdown:** When the task completes or is submitted for review, the verification card displays a full violation audit log:
    * Total violation count (e.g., `2 Peeking Violations`).
    * Exact duration of each infraction (e.g., `Violation #1: Lifted for 12 seconds`, `Violation #2: Screen active for 8 seconds`).
    * Cumulative peeking duration and net penalty deductions.
* **Seamless Metronome Integration:** Rhythmic clicks and wave tempos guide strokes, breathing, or exercise reps in complete darkness.

---

## 6. Gamification, Power Tools & Security Innovations

### 1. 🎡 The "Wheel of Fate" (Roulette Directives)
* Directors send a weighted spinning wheel (or mystery box) with 4–8 customizable outcomes.
* Player spins with realistic physics and must execute whatever task or penalty the pointer lands on.

### 2. ⚡ "Collar Ping" (Instant Attention / Readiness Check)
* 1-tap presence check from Director.
* Player has 60 seconds to tap "At Attention".
* Director receives live response latency telemetry (e.g., *"Acknowledged in 3.4 seconds"*).

### 3. ⛓️ The "Penance Pool" (Debt & Punishment Queue)
* Failed orders lock the Reward Store and add mandatory penance directives to a debt queue that must be cleared before redeeming tokens.

### 4. 🦺 1-Tap Emergency Safeword Protocol
* Dedicated Yellow (*Check-in / Pause*) and Red (*Immediate Stop*) buttons.
* Red immediately aborts all timers, silences alarms, and notifies Director with zero token penalty.

### 5. 🎁 Mystery Reward Scratchcards & Gacha Crates
* Probabilistic reward redemption in the Reward Store (e.g., 70% Small Treat, 25% Early Release, 5% Freedom Pass).

### 6. 📲 QR Code / 6-Digit Pack & Quest Sharing
* 1-tap encrypted QR code or 6-character share code export/import for community packs and quest chains.

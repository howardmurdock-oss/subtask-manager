# Steam Deck & Linux Setup Guide

This guide covers running **SubTask Manager** on your **Steam Deck** (SteamOS / Arch Linux) and any Linux desktop distribution.

---

## Method 1: Instant Setup via Steam & Proton (Recommended — Zero Build Tools Needed)

The Steam Deck has Valve's **Proton** compatibility layer built-in. You can run the Windows Standalone release directly on your Steam Deck with 100% native performance, full audio chimes, controller/touchscreen support, and cloud relay sync.

### Step-by-Step Instructions:

1. **Transfer the Release to your Steam Deck**:
   - Download or copy `OrdersApp-Windows-Release.zip` (or `subTaskManager-Windows-Release.zip`) to your Steam Deck.
   - *Ways to transfer*: Google Drive via browser, USB Flash Drive, KDE Connect, Warpinator, or SSH/SFTP.

2. **Extract the Files in Desktop Mode**:
   - Press the **STEAM** button on your Deck -> **Power** -> **Switch to Desktop**.
   - In Dolphin File Manager, create a folder (e.g. `/home/deck/Applications/SubTaskManager/`).
   - Extract the `.zip` archive into that folder so you see `orders_app.exe` and its `data/` folder.

3. **Add as a Non-Steam Game**:
   - Open the **Steam** desktop client.
   - In the bottom-left corner, click **Add a Game** -> **Add a Non-Steam Game...**
   - Click **Browse** and navigate to `/home/deck/Applications/SubTaskManager/orders_app.exe`.
   - Check the box next to `orders_app.exe` and click **Add Selected Programs**.

4. **Enable Proton Compatibility**:
   - In your Steam Library, find **`orders_app.exe`**.
   - Right-click it (or press Left Trackpad / Gear icon) -> select **Properties...**
   - In the **Shortcut** tab: Rename the title from `orders_app.exe` to **SubTask Manager**.
   - In the **Compatibility** tab: Check **"Force the use of a specific Steam Play compatibility tool"**.
   - Select **Proton Experimental** (or **Proton 9.0** / **GE-Proton**).

5. **Launch in Gaming Mode**:
   - Return to Gaming Mode by clicking the **"Return to Gaming Mode"** icon on the desktop.
   - Go to your **Library** -> **Non-Steam** tab.
   - Launch **SubTask Manager**!
   - *Controller Layout Tip*: In Steam controller settings for the app, select the **"Web Browser"** or **"Touchscreen / Mouse"** controller template so the trackpads and triggers act as smooth mouse/tap inputs.

---

## Method 2: Native Linux ELF Binary Build

If you prefer a 100% native Linux executable without Proton:

### Automated Cloud Build (GitHub Actions):
The project includes a ready-to-run GitHub Actions workflow in [`.github/workflows/build_linux.yml`](file:///c:/Users/howar/Documents/antigravity/Orders%20App/.github/workflows/build_linux.yml).
When you push the codebase to GitHub:
1. GitHub Actions spins up an Ubuntu Linux runner.
2. It compiles the Flutter Linux bundle into `SubTaskManager-Linux-x64.tar.gz`.
3. You can download the artifact directly from the GitHub Actions tab.

### Local Native Compilation on Linux / Steam Deck:
If you are compiling directly on a Linux computer or inside a SteamOS container (Distrobox):

1. **Install Linux Build Dependencies**:
   ```bash
   sudo apt-get update && sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libsecret-1-dev libasound2-dev
   ```
   *(On Arch Linux / SteamOS with pacman: `sudo pacman -S clang cmake ninja pkgconf gtk3`)*

2. **Run the Build Script**:
   ```bash
   chmod +x build_linux.sh
   ./build_linux.sh
   ```

3. **Output Binary**:
   - The compiled Linux bundle will be generated in `build/linux/x64/release/bundle/` and packaged as `Releases/Linux/SubTaskManager-Linux-x64.tar.gz`.
   - Run with: `./orders_app`

---

## Steam Deck Optimization Highlights

* **Aspect Ratio & Resolution**: Window default configured for 1280x800 (16:10 native Steam Deck screen).
* **Audio Alerts**: Generates low-latency PCM chimes and notifications.
* **Sync Connectivity**: Real-time cross-device relay works across Wi-Fi and mobile hotspots.

# Multi-Platform Distribution Guide
## SubTask Manager / OrdersApp

This guide explains how to deploy, host, and distribute **SubTask Manager** across all operating systems: **Windows**, **Android**, **macOS**, **Linux**, **Steam Deck**, and the **Web**.

---

## 1. Summary of Release Artifacts

| Platform | Format | How It Is Generated | Deployment / Website Link |
| :--- | :--- | :--- | :--- |
| **Windows** | Standalone `.zip` / Portable Folder | Local (`build_and_sync_all.ps1`) | Put `OrdersApp-Windows-Release.zip` on website |
| **Android** | Standalone `.apk` | Local (`build_and_sync_all.ps1`) | Put `OrdersApp-Android-Release.apk` on website |
| **Web (All OS)** | HTML5 / WASM / JS (`.zip`) | Local (`build_and_sync_all.ps1`) | Unzip to web host or root of website |
| **Linux & Steam Deck** | Native ELF `.tar.gz` | Cloud (`.github/workflows/build_releases.yml`) or `./build_linux.sh` | Put `SubTaskManager-Linux-x64.tar.gz` on website |
| **macOS** | Native `.dmg` / `.app` in `.zip` | Cloud (`.github/workflows/build_releases.yml`) | Put `SubTaskManager-macOS.dmg` on website |

---

## 2. Generating Native Linux & macOS Distributables via GitHub Actions

Because Flutter Desktop binaries require the host operating system's native compiler (Apple Darwin/Xcode for macOS, Clang/GTK for Linux), cross-compiling macOS from Windows is technically impossible locally. 

To solve this completely, the project includes an automated cloud build workflow in [`.github/workflows/build_releases.yml`](.github/workflows/build_releases.yml).

### Step-by-Step Instructions:

1. **Push your code to GitHub**:
   ```bash
   git init
   git add .
   git commit -m "Ready for launch"
   git branch -M main
   git remote add origin https://github.com/<your-username>/<your-repo-name>.git
   git push -u origin main
   ```

2. **Trigger the Build**:
   - Go to your repository on **GitHub.com**.
   - Click the **Actions** tab at the top.
   - In the left sidebar, select **"Build Linux & macOS Releases"**.
   - Click **Run workflow** -> Select **main** branch -> Click **Run workflow**.

3. **Download Your Website Binaries**:
   - Once the build completes (~2 to 3 minutes), click on the completed run.
   - Under the **Artifacts** section at the bottom, download:
     - **`Linux-Distributable`**: Contains `SubTaskManager-Linux-x64.tar.gz` (ready for Linux users).
     - **`macOS-Distributable`**: Contains `SubTaskManager-macOS.dmg` and `SubTaskManager-macOS.zip` (ready for Mac users).

4. **Tagging Releases (Automated GitHub Releases)**:
   - When you create a git tag (e.g. `git tag v1.0.0 && git push origin v1.0.0`), GitHub Actions will automatically create a public GitHub Release with direct CDN download URLs for all files!

---

## 3. Web Version: Zero-Install Access for Mac & Linux Users

In addition to desktop downloads, you can offer an instant **"Launch in Browser"** option on your website:

1. Run `.\build_and_sync_all.ps1`.
2. The script compiles the full Flutter Web application to `build\web` and packages it into `OrdersApp-Web-Release.zip`.
3. Extract `OrdersApp-Web-Release.zip` into your web hosting public directory (e.g., `public_html/app/` or deploy to Vercel/Netlify/GitHub Pages).
4. Users on Mac, Linux, Chromebook, Windows, or iPad can access the full app immediately with complete cloud relay synchronization, sound chimes, and theme support!

---

## 4. Steam Deck Compatibility

Steam Deck users have two seamless options:
1. **Native Linux**: Download and unpack `SubTaskManager-Linux-x64.tar.gz` in Desktop Mode, then run `./orders_app`.
2. **Proton / Steam Play**: Download `OrdersApp-Windows-Release.zip`, add `orders_app.exe` as a Non-Steam Game in Steam, and enable Proton. (See [STEAM_DECK_GUIDE.md](STEAM_DECK_GUIDE.md) for full screenshots and controller config).

---

## 5. Local Build Command Reference

- **Build Everything Locally (Windows + Android + Web)**:
  ```powershell
  .\build_and_sync_all.ps1
  ```
- **Backup Codebase & Releases to F: Drive**:
  ```powershell
  .\backup_to_f.ps1
  ```

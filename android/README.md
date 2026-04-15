# Quilldown for Android

Lightweight Markdown viewer. Reuses the exact `render.html` + markdown-it / KaTeX / Prism bundle from the macOS app, wrapped in a thin Kotlin `WebView` shell.

- No ads, no tracking, no network. All rendering is local.
- Viewer only — no editor. Tap a `.md` file from any file manager and it renders here.
- Single source of truth for rendering: Gradle merges `../Quilldown/Resources/` into the APK's assets so the Android build is always in lock-step with the desktop build.

## Download

Grab the signed release APK from [GitHub Releases](https://github.com/ysys143/quilldown/releases/latest) (`Quilldown-android-v*.apk`).

On first install you'll see a one-time "install unknown apps" prompt — enable it for whichever app handed you the APK (My Files, Chrome, KakaoTalk, etc.). Subsequent updates install silently because the APK is signed with a stable keystore.

## Requirements

- Android Studio Hedgehog (2023.1.1) or newer, OR `sdkmanager` + JDK 17 on the command line
- Android SDK with platform 34 and build-tools 34
- Target device: Android 8.0+ (API 26)

## Build a debug APK

```bash
cd android
./gradlew assembleDebug        # first run will ask Gradle to fetch deps
```

Output: `app/build/outputs/apk/debug/app-debug.apk` (~3-4 MB).

If you don't have a `gradlew` wrapper yet, generate it once:

```bash
cd android
gradle wrapper --gradle-version 8.7
```

## Install on your phone

### Option 1 — ADB (recommended if you have USB debugging on)

1. Enable Developer Options on your phone: Settings → About → tap Build Number 7 times.
2. Enable USB Debugging: Settings → System → Developer Options → USB debugging.
3. Plug the phone in, accept the "allow this computer" prompt.
4. ```bash
   cd android
   ./gradlew installDebug
   ```

### Option 2 — sideload the APK

1. Build the APK (above).
2. Transfer `app-debug.apk` to the phone (AirDrop-alternatives: KDE Connect, Google Drive, email to yourself, Pushbullet, etc.).
3. On the phone, tap the APK file. Accept the "Install unknown apps" prompt for your file manager.

## Usage

Open any `.md` / `.markdown` / `.mdown` / `.mkd` file from your file manager, Files app, Gmail attachment, Drive, etc. The system share/open menu will list Quilldown as a handler.

Features that carry over from the macOS build:

- GitHub-flavored Markdown rendering (markdown-it + markdown-it-task-lists)
- Math: KaTeX (inline `$...$`, display `$$...$$`, `\(...\)`, `\[...\]`) — lazy-loaded
- Code syntax highlighting: Prism.js with 18 languages — lazy-loaded per language
- Mermaid diagrams: lazy-loaded when a `mermaid` fenced block is present

Not ported (yet):

- Editor (viewer only)
- TOC sidebar
- PDF export
- File watching

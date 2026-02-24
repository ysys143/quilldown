# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Quilldown is a macOS native document-based app for viewing and editing Markdown files. Built with SwiftUI + WebKit, it renders markdown via bundled JavaScript libraries (markdown-it, KaTeX, Prism.js, Mermaid) inside a WKWebView. Supports editor-only, preview-only, and split view modes with bidirectional scroll sync.

**Target**: macOS 14.0+ | **Swift**: 5.9 | **Bundle ID**: `com.quilldown.app`

## Build Commands

```bash
# Generate Xcode project from project.yml (requires XcodeGen)
xcodegen generate

# Build (Debug)
xcodebuild -scheme Quilldown -configuration Debug -derivedDataPath build -destination 'platform=macOS' build

# Build (Release) + create DMG
./scripts/create-dmg.sh

# Open in Xcode
open Quilldown.xcodeproj
```

No external Swift package dependencies. All rendering libraries are bundled JS/CSS in `Quilldown/Resources/`.

## Architecture

### Data Flow

```
File (.md) → MarkdownDocument (FileDocument protocol, UTF-8 with BOM detection)
  → ContentView (state: viewMode, tocItems, fileWatcher, syncCoordinator)
    → MarkdownEditorView (NSTextView wrapper) ←→ SyncCoordinator ←→ MarkdownWebView (WKWebView wrapper)
```

### Key Components

| File | Role |
|------|------|
| `QuilldownApp.swift` | App entry, DocumentGroup, menu commands (zoom, PDF export) |
| `ContentView.swift` | Main layout: TOC sidebar + editor/preview, view mode switching |
| `MarkdownWebView.swift` | WKWebView NSViewRepresentable, JavaScript bridge for rendering |
| `MarkdownEditorView.swift` | NSTextView NSViewRepresentable, line number tracking |
| `MarkdownDocument.swift` | FileDocument model, .md/.markdown/.mdown/.mkd support |
| `SyncCoordinator.swift` | Debounced bidirectional scroll/selection sync (200ms, prevents feedback loops) |
| `LocalFileSchemeHandler.swift` | WKURLSchemeHandler for `localfile://` — resolves relative image paths |
| `FileWatcher.swift` | FSEvents monitor for external file changes (handles vim-style save-via-rename) |
| `ViewMode.swift` | Enum: `.editor`, `.preview`, `.split` |
| `TOCItem.swift` / `TOCSidebarView.swift` | Table of contents model + sidebar UI |

### JavaScript Bridge (render.html)

`MarkdownWebView` calls `render(markdown, baseDir)` in `render.html`. The HTML template:
- Parses markdown via `markdown-it` with custom fence renderers for code/mermaid/math blocks
- Renders math with KaTeX auto-render (`$...$`, `$$...$$`, `\(...\)`, `\[...\]`)
- Highlights code with Prism.js (13 language plugins bundled)
- Lazy-loads Mermaid for diagrams only when needed
- Tags HTML elements with `data-line` attributes for scroll sync
- Posts scroll/selection events back to Swift via `window.webkit.messageHandlers.scrollSync`

### Web Resources

All in `Quilldown/Resources/`, copied to app bundle via post-compile rsync script (defined in `project.yml`). Not managed by Xcode's resource phase — changes to resources require rebuilding.

### Entitlements

App sandbox is **disabled** (`com.apple.security.app-sandbox: false`) to allow file system access for rendering local images.

---

## Karpathy Coding Guidelines

> Behavioral guidelines to reduce common LLM coding mistakes. These apply to ALL code-writing agents.

### 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

### 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

### 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

### 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

*These guidelines are working if: fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.*

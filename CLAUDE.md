# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test

This project requires Xcode beta (macOS 27.0 toolchain). Always prefix build commands with the developer dir:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift build --product PaperRssDesktop
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project PaperRss.xcodeproj -scheme PaperRss -configuration Debug build
```

The Xcode project (`PaperRss.xcodeproj`) must be opened directly — there is no `project.yml` or generator. Users Run/Stop from Xcode; do not kill their debugging processes.

## Architecture

PaperRss is a native SwiftUI RSS reader for macOS (primary) and iOS, targeting macOS 14+ / iOS 17+. It has two SPM targets:

- **`PaperRssCore`** (`PaperRss/Sources/Core/`) — Library: models, feed parsing, AI services, persistence, CloudKit sync.
- **`PaperRssDesktop`** (`PaperRss/Sources/App/`) — Executable: SwiftUI app with three-column layout (sidebar / entry list / reader).

The App layer uses `#if SWIFT_PACKAGE; import PaperRssCore; #endif` since Xcode builds don't need the explicit import.

### Key files

| File | Role |
|------|------|
| `AppStore.swift` | Central `@MainActor ObservableObject`. Owns `AppDatabase`, `EntryLibraryIndex` (read-optimized snapshot), AI request state, single-request lock, persistence, and refresh orchestration. |
| `Models.swift` | `Feed`, `Entry`, `EntryListItem` (lightweight list row value), `ArticleCache`, `AIArtifact` (with `AISelectionAnchor` for DOM restoration), `LLMConfiguration`, `AppDatabase` (the full persisted state). |
| `LLMService.swift` | OpenAI-compatible `POST /chat/completions`. SSE streaming preferred, with automatic fallback to non-streaming. DeepSeek `thinking: disabled` for translation/explanation. |
| `ArticleReaderView.swift` | WKWebView wrapper with JavaScript bridge. Handles paper-style rendering, image recovery, bilingual translation injection, selection explanation popovers, and selection translation. Has separate macOS/iOS coordinators. |
| `RootView.swift` | Three-column NavigationSplitView. Uses stable `selectedEntryID: String?` instead of value-semantic `Entry` to avoid selection loss on `isRead` updates. |
| `FeedService.swift` / `FeedParser.swift` | RSS, Atom, JSON Feed parsing with ETag/Last-Modified conditional refresh. |
| `ArticleExtractor.swift` | Web page extraction with safe URL decoding (`&amp;` → `&`), `webp`→`jpg` normalization for Twitter images, HTML sanitization, and lazy image loading. |
| `CloudSyncService.swift` | CloudKit private database mirror for feeds, reading states, and AI artifacts. Merges by `updatedAt`. |
| `I18N.swift` | Chinese/English bilingual UI via `I18N.tr("中文", "English")`. Defaults to zh-Hans. |
| `LocalAPIKeyStore.swift` | API key stored in UserDefaults (not Keychain) — avoids macOS password prompts. Local only, no iCloud sync. |

### AppDatabase persistence

`AppDatabase` is Codable, persisted as local JSON. Contains: feeds, entries, articleCaches (text+HTML cache keyed by entryID), readingStates, AIArtifacts, LLMConfiguration. The `EntryLibraryIndex` is constructed on load from entries+feeds — it pre-computes sorted arrays and group-by dictionaries to avoid repeated work during SwiftUI list rendering.

### AI pipeline

1. User action triggers `AppStore` method (translate/summarize/explainSelection/translateSelection).
2. `AppStore` computes a content hash and checks `AIArtifact` cache.
3. `LLMService.complete()` constructs the OpenAI-compatible request. For DeepSeek endpoints, forces `thinking: {type: "disabled"}` for translation/explanation. SSE streaming delivers deltas via `onDelta` callback.
4. Results are persisted as `AIArtifact` with content hash, model, target language, prompt version for cache keying.
5. Selection explanations additionally store `AISelectionAnchor` (paragraphID + UTF-16 offsets) so annotation icons survive WebView reloads.

### WebView bridge patterns

- `ArticleReaderView` injects JavaScript for: selection detection, popover display, translation injection, image recovery.
- Separate `Coordinator` classes for macOS and iOS handle `WKScriptMessageHandler` callbacks.
- Selection explanations are queued per-coordinator (serial, not parallel) to avoid "request in progress" rejections.
- Popover close does NOT cancel in-flight requests (that would waste API cost).

## Design constraints

- **AI requests must be user-initiated** — never auto-send articles to the model. Exception: "auto-generate summary" setting.
- **API key never logged or exported** — do not print Authorization headers.
- **HTTPS required for AI endpoints** — HTTP only if user explicitly enables "局域网 HTTP" in settings.
- **Deleting a feed must cascade-delete its entries** — this is implemented, do not regress.
- **Article list rows use `EntryListItem` with truncated summary** — never bind full `contentHTML` to list rows (causes 1-2s hangs on long articles).
- **ATS allows arbitrary loads** (personal-use app) — `NSAllowsArbitraryLoads` is set in both macOS and iOS Info.plist.
- **Do not re-introduce custom `WKURLSchemeHandler`** for images — it caused instability; current approach uses direct HTTPS URLs with JavaScript recovery.
- **Mac and iOS WebView coordinators must stay in sync** — any bridge change on one platform needs the equivalent on the other.

## Working with this repo

- Never `git reset --hard`, `git checkout --`, or delete DerivedData without asking.
- Preserve the user's uncommitted changes.
- When making code changes, verify with `swift test` before declaring done.
- The HANDOFF files (`HANDOFF.md`, `HANDOFF_CURRENT_*.md`) are project documentation — read them for context on recent decisions and known issues.

## Agent Standards & Routing

全仓库所有 AI Agent（包括 Antigravity、Claude Code、Codex 等）统一遵循 [`.agents/`](file:///.agents) 目录下的标准规范：

- **目录结构与文件组织规范**：详见 [`docs/DIRECTORY_SPEC.md`](file:///docs/DIRECTORY_SPEC.md)
- **本地工单与任务跟踪**：工单保存在 `.scratch/`，规范详见 [`.agents/docs/issue-tracker.md`](file:///.agents/docs/issue-tracker.md)
- **分诊与状态标签**：标签定义与生命周期详见 [`.agents/docs/triage-labels.md`](file:///.agents/docs/triage-labels.md)
- **领域模型与架构决策**：单上下文领域文档详见 [`.agents/docs/domain.md`](file:///.agents/docs/domain.md)
- **通用工程与验证规则**：详见 [`.agents/rules/`](file:///.agents/rules)（如 `verification_workflow.md`、`prompt_design_language.md`）


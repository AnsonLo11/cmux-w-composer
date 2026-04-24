# Agent Activity Sidebar - Design Spec

> Date: 2026-04-22
> Branch: `panel-composer`
> Status: Approved design, pending implementation

## Overview

A read-only sidebar on the right side of the cmux window that displays structured Claude Code agent activity (tool executions and their results) for the currently focused terminal panel. The sidebar shows what the AI agent is doing — commands it runs, files it reads/writes, searches it performs — in a clean, filterable card-based UI.

## Goals

1. Let users see exactly what the agent is doing without scrolling through the full terminal output
2. Show only structured tool executions (Bash, Read, Write, Edit, Grep, Glob, Agent), not the full terminal stream
3. Support multiple concurrent CC sessions — sidebar follows the focused panel
4. Handle session switching within a single panel (exit + restart CC)
5. Auto-show when a CC session is detected, with manual override

## Non-Goals

- Full terminal mirroring (rejected: too noisy, shows everything)
- ANSI terminal output parsing (rejected: fragile, CC format-dependent)
- Modifying the Ghostty submodule
- Modifying the cmux claude wrapper (existing hook infrastructure is sufficient)

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│ Window                                                   │
│  ┌──────────────────────────────┐  ┌──────────────────┐ │
│  │ Bonsplit Layout (existing)   │  │ Agent Activity    │ │
│  │                              │  │ Sidebar           │ │
│  │  ┌────────┐  ┌────────┐     │  │ (fixed right)     │ │
│  │  │Terminal │  │Terminal│     │  │                   │ │
│  │  │Panel A  │  │Panel B │     │  │ ┌───────────────┐│ │
│  │  │(focused)│  │        │     │  │ │ Filter chips  ││ │
│  │  │ CC α    │  │ CC β   │     │  │ ├───────────────┤│ │
│  │  └────────┘  └────────┘     │  │ │ Tool cards    ││ │
│  └──────────────────────────────┘  │ │ (scrollable)  ││ │
│                                     │ └───────────────┘│ │
│                                     └──────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

### Core Modules

| Module | Responsibility |
|--------|---------------|
| `AgentSessionTracker` | Panel-to-session mapping, responds to hook callbacks |
| `ConversationLogWatcher` | Monitors JSONL file changes, incremental parsing |
| `AgentActivityStore` | Stores parsed ToolEvents, provides filtered data |
| `AgentActivitySidebar` | Fixed right sidebar SwiftUI view container |
| `ToolCardView` family | Per-tool-type card rendering components |

### Data Flow

```
cmux claude wrapper starts CC with --session-id UUID
  → CC SessionStart hook fires
  → cmux socket: claude-hook session-start (has CMUX_SURFACE_ID + session info)
  → AgentSessionTracker.registerSession(surfaceId, sessionId, cwd)
  → Computes JSONL path: ~/.claude/projects/<cwd-with-slashes-as-dashes>/<sessionId>.jsonl
  → ConversationLogWatcher starts monitoring file (DispatchSource EVFILT_VNODE .write)
  → Incremental JSONL parsing: new lines → filter tool_use/tool_result → ToolEvent
  → AgentActivityStore receives events (@Published [ToolEvent])
  → AgentActivitySidebar renders filtered cards
```

---

## Data Source: CC Conversation JSONL

### Session Mapping

cmux already has a complete session bridge:

1. **cmux claude wrapper** (`Contents/Resources/bin/claude`) generates a `SESSION_ID` via `uuidgen` and passes `--session-id SESSION_ID` to the real claude binary
2. The wrapper `exec`s the real claude (no intermediate process — claude IS a direct child of the shell)
3. **SessionStart hook** fires back to cmux via `cmux claude-hook session-start`, with `CMUX_SURFACE_ID` in the environment
4. **SessionEnd hook** fires when CC exits

This provides deterministic panel-to-session mapping without process tree monitoring.

### JSONL File Path Computation

CC stores conversations at:
```
~/.claude/projects/<project-dir-hash>/<session-id>.jsonl
```

The "hash" is simply the absolute cwd path with `/` replaced by `-`:
```swift
let projectDirHash = cwd.replacingOccurrences(of: "/", with: "-")
// "/Users/ansonlo/project/cmux" → "-Users-ansonlo-project-cmux"
```

### JSONL Format (verified from real data)

**tool_use** (type: "assistant"):
```json
{
  "type": "assistant",
  "message": {
    "content": [
      {
        "type": "tool_use",
        "id": "toolu_xxx",
        "name": "Bash",
        "input": { "command": "ls -la", "description": "List files" }
      }
    ]
  },
  "uuid": "...",
  "sessionId": "...",
  "timestamp": "2026-04-22T08:46:31.887Z"
}
```

**tool_result** (type: "user"):
```json
{
  "type": "user",
  "message": {
    "content": [
      {
        "type": "tool_result",
        "tool_use_id": "toolu_xxx",
        "content": "file1.txt\nfile2.txt\n..."
      }
    ]
  },
  "toolUseResult": { "durationMs": 350, "truncated": false },
  "sourceToolAssistantUUID": "...",
  "sessionId": "...",
  "timestamp": "2026-04-22T08:46:32.432Z"
}
```

### Parsing Strategy

- Only process `message.content[]` blocks with type `tool_use` or `tool_result`
- Pair use/result via `tool_use_id` ↔ `tool_use_id` in result, or `uuid` ↔ `sourceToolAssistantUUID`
- Unknown tool names → classify as "Other", graceful degradation
- Parse failure on a single line → skip, log warning, continue
- One assistant message may contain multiple `tool_use` blocks (parallel calls) → each becomes a separate card

### Version Stability

The JSONL format is not a documented stable API, but:
- `tool_use`/`tool_result` content block structure follows the Anthropic Messages API spec (versioned, stable)
- The file path convention (`/` → `-`) is a simple transform unlikely to change
- Parser is isolated in one module — if format changes, only `ConversationLogWatcher` needs updating
- Defensive parsing: known fields only, unknown fields skipped

---

## Data Model

```swift
struct ToolEvent: Identifiable {
    let id: String              // tool_use_id
    let toolName: ToolType
    let timestamp: Date
    let input: ToolInput
    var result: ToolResult?     // nil while executing
    var durationMs: Int?
}

enum ToolType: String, CaseIterable, Identifiable {
    case bash = "Bash"
    case read = "Read"
    case write = "Write"
    case edit = "Edit"
    case grep = "Grep"
    case glob = "Glob"
    case agent = "Agent"
    case other = "Other"
}

enum ToolInput {
    case bash(command: String, description: String?)
    case read(filePath: String, limit: Int?, offset: Int?)
    case write(filePath: String)
    case edit(filePath: String, oldString: String, newString: String)
    case grep(pattern: String, path: String?, glob: String?)
    case glob(pattern: String, path: String?)
    case agent(description: String, prompt: String?)
    case unknown(raw: [String: Any])
}

enum ToolResult {
    case success(content: String, truncated: Bool)
    case error(message: String)
}
```

---

## Card Rendering

All cards share an outer shell: rounded dark background, left color bar (3pt) by tool type, top-right timestamp + duration badge.

| Tool | SF Symbol | Card Content |
|------|-----------|-------------|
| **Bash** | `terminal` | Command area (monospace, dark bg) + output area (expandable, default truncated at 10 lines) |
| **Read** | `doc.text` | File path (tappable) + "Read N lines" summary |
| **Write** | `doc.badge.plus` | File path + content preview (first 5 lines, collapsed) |
| **Edit** | `pencil.line` | File path + inline diff (red/green, old → new) |
| **Grep** | `magnifyingglass` | Pattern + matched file count summary |
| **Glob** | `folder.badge.magnifyingglass` | Pattern + result file list |
| **Agent** | `person.2` | Description + sub-agent summary |
| **Executing** | spinner | Command/operation sent but no result yet, pulse animation |

### Card Interactions

- Click to expand/collapse long output
- Long output collapsed by default (Bash > 10 lines, Read/Write > 5 lines)
- Copy button (visible on hover: copies command or full output)

### Tool Type Colors (left bar)

| Tool | Color |
|------|-------|
| Bash | Cyan |
| Read | Blue |
| Write | Green |
| Edit | Yellow |
| Grep | Purple |
| Glob | Indigo |
| Agent | Orange |
| Other | Gray |

---

## Filter System

Horizontal scrolling chips at the top of the sidebar:

```
[All] [Bash] [Read] [Write] [Edit] [Grep] [Glob] [Agent]
```

- Default: All selected
- Single-select toggle (tap Bash → only Bash; tap again → back to All)
- Each chip shows a small count badge for that tool type's event count
- Filter state stored per-panel in `AgentActivityStore` — preserved when switching panels

---

## Sidebar Layout & Show/Hide

### Layout

Fixed right sidebar outside Bonsplit, added via HStack in `ContentView`/`WorkspaceContentView`:

```swift
HStack(spacing: 0) {
    BonsplitWorkspaceView(...)
    if showAgentSidebar {
        Divider()  // 1pt vertical, matches composer top-line style
        AgentActivitySidebar(store: agentActivityStore)
            .frame(width: sidebarWidth)  // default 320pt, draggable
    }
}
```

### Show/Hide State Machine

```
manualOverride: Bool?   (nil = no manual action, true = force show, false = force hide)
hasActiveSession: Bool  (focused panel has active CC session)

visibility = manualOverride ?? hasActiveSession
```

- CC session starts → `hasActiveSession = true` → sidebar auto-opens (if no manual override)
- User closes via shortcut → `manualOverride = false` → stays hidden even with active session
- User opens via shortcut → `manualOverride = true` → shows even without session (empty state)
- Switch to different panel → `manualOverride` resets to nil, re-evaluate based on `hasActiveSession`

### Keyboard Shortcut

Registered in `KeyboardShortcutSettings`, visible/editable in Settings, supported in `settings.json`.

---

## Visual Style

Matches the existing cmux dark theme:

| Element | Style |
|---------|-------|
| **Background** | Same deep dark as main terminal area, follows system appearance |
| **Divider** | 1pt vertical left border, same style as composer top separator |
| **Filter chips** | Semi-transparent rounded pills, selected state with subtle highlight |
| **Card background** | Slightly lighter than sidebar bg (`Color.primary.opacity(0.05)`), 8pt corner radius |
| **Code/command text** | Monospace font, consistent with terminal/composer |
| **Body text** | System font, light gray, same as status bar text |
| **Timestamps/duration** | Small size, lower opacity |
| **Tool type color bar** | 3pt wide left bar on each card |
| **Scrolling** | Auto-scroll to bottom on new events; pause auto-scroll when user scrolls up manually (resume on scroll-to-bottom) |

### Empty State

When focused panel has no CC session:
- Muted icon + "No active agent session" heading
- "Agent activity will appear here when Claude Code is running." subtitle

### Session Ended State

- Last cards remain visible
- Separator line + "Session ended" + timestamp at bottom

---

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| CC crashes (no SessionEnd hook) | Watcher detects file stale + process gone → mark "Session lost", preserve cards |
| JSONL file doesn't exist yet | Watch parent directory for file creation, show "Waiting for session data..." (30s timeout) |
| JSONL line parse failure | Skip line, log warning, continue processing |
| tool_use with no tool_result | Card stays in "executing" state (spinner). Marked "incomplete" when session ends |
| Very large output (e.g. cat large file) | Truncate display to first 50KB, show "Output truncated" label |
| Rapid tool calls (Agent sub-agent bursts) | Normal append, rely on filter and scroll. No coalescing. |
| Multiple tool_use blocks in one JSONL line | One assistant message can contain parallel tool calls; each generates an independent card |
| Panel switch performance | Each panel's AgentActivityStore exists independently in AgentSessionTracker; switching only changes the data source reference, no re-parsing |
| Session switch (exit + restart CC in same panel) | SessionEnd hook → mark ended; new SessionStart → new session ID → new watcher → fresh card list (old session cards cleared) |

---

## File Structure

```
Sources/
├── AgentActivity/                        ← NEW directory
│   ├── AgentSessionTracker.swift         ← session mapping management
│   ├── ConversationLogWatcher.swift      ← JSONL file monitoring + incremental parsing
│   ├── AgentActivityStore.swift          ← data storage + filter logic
│   ├── ToolEvent.swift                   ← data model (ToolEvent, ToolType, ToolInput, ToolResult)
│   ├── AgentActivitySidebar.swift        ← sidebar container view
│   └── Cards/
│       ├── BashCardView.swift
│       ├── ReadCardView.swift
│       ├── WriteCardView.swift
│       ├── EditCardView.swift
│       ├── GrepCardView.swift
│       ├── GlobCardView.swift
│       ├── AgentCardView.swift
│       └── ToolCardShell.swift           ← shared card outer shell (color bar, timestamp, expand)
```

### Existing Files Modified

| File | Change |
|------|--------|
| `ContentView.swift` or `WorkspaceContentView.swift` | HStack wrapping Bonsplit + sidebar |
| `Workspace.swift` | Hold `AgentSessionTracker`, notify sidebar on focused panel change |
| Socket command handler (claude-hook routing) | Route session-start/end to `AgentSessionTracker` |
| `KeyboardShortcutSettings.swift` | Register sidebar toggle shortcut |
| `Localizable.xcstrings` | New UI strings (en + ja) |
| `GhosttyTabs.xcodeproj/project.pbxproj` | Register new source files |

### Not Modified

- Ghostty submodule
- Bonsplit submodule
- cmux claude wrapper (existing hooks sufficient)
- ComposerInputView / ComposerState

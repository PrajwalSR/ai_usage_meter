# Architecture

How the app is built. Simple picture first, details after.

## The big picture

The app repeats 3 steps:

```mermaid
flowchart LR
    G["1. Gather<br/>read logs, reading files,<br/>optional live check"] --> S["2. Save<br/>small SQLite cache"] --> D["3. Show<br/>menu bar + panel"]
    D -.->|"something changes"| G
```

## Where each number comes from

```mermaid
flowchart LR
    subgraph Sources
        CX["Codex logs<br/>~/.codex/sessions"]
        CL["Claude Code logs<br/>~/.claude/projects"]
        WEB["claude.ai<br/>(signed-in web view)"]
        AN["Anthropic<br/>/api/oauth/usage"]
        SL["Claude Code status line<br/>scripts/claude-statusline.py"]
    end

    CX -->|"Codex limit + tokens"| IDX["UsageIndex"]
    CL -->|"Claude Code tokens"| IDX
    WEB -->|"ClaudeWebSource"| F0["statusline/claude-web.json"]
    AN -->|"ClaudeLiveUsage"| F1["statusline/claude-live.json"]
    SL --> F2["statusline/claude.json"]
    F0 --> CR["ClaudeReadings"]
    F1 --> CR
    F2 --> CR
    CR --> IDX
    IDX <--> DB[("SQLite cache")]
    IDX --> R["UsageReport"]
    R --> MB["Menu bar"]
    R --> P["Panel"]
```

## What triggers an update

```mermaid
flowchart LR
    T1["A watched file changes"] --> W["FileWatcher<br/>waits 2 s for quiet"]
    T0["Every 60 s<br/>(signed in to claude.ai)"] --> WEBC["ClaudeWebSession"]
    WEBC -->|"writes claude-web.json"| W
    T2["Every 30 min<br/>(backup check on)"] --> L["ClaudeLiveUsage"]
    T3["⟳ button"] --> L
    T3 -.->|"live check off"| U
    T4["Mac wakes"] --> U
    L -->|"writes claude-live.json"| W
    W --> U["UsageStore.refresh()"]
    U --> I["UsageIndex pass"]
    I --> RD["Redraw"]
    T5["Every 30 s"] --> RD
```

The 30-second redraw doesn't rescan anything. It recomputes "… ago" text,
countdowns **and expiry**, so a limit that resets while the app is open changes
to `?` without waiting for new data.

---

## Rules the design follows

1. **Never invent a limit.** A percentage appears only if Anthropic or OpenAI
   reported it. Token counts are shown separately and never converted.
2. **Readings are snapshots.** Every reading keeps when it was recorded and where
   it came from.
3. **Expired isn't zero.** Expiry is checked at display time against the current
   clock. A reset window is hidden. If every window has reset, the provider shows
   "unknown" (`?`).
4. **Read only what's new.** Logs run to hundreds of MB. After the first pass,
   only appended bytes are read.
5. **Totals and offsets move together.** Token counts and "how far each file was
   read" are saved in the same transaction, or not at all.
6. **Nothing online unless asked.** The only network use is the opt-in live Claude
   check.

---

## Source files

| File | Job |
|---|---|
| `main.swift` | Entry point. `--scan` prints results; otherwise `AppController` runs the menu bar item and popover |
| `UsageStore.swift` | Main-actor state: schedules index passes, watchers, timers, live checks; settings; menu bar text |
| `UsageIndex.swift` | One index pass: ingest (transaction) → build `UsageReport` |
| `Database.swift` | SQLite wrapper and schema. All writes throw on failure |
| `LogParser.swift` | Protocol shared by the log parsers |
| `CodexParser.swift` | Codex logs → token counts + limit readings (all windows, with `limit_id`) |
| `ClaudeParser.swift` | Claude Code logs → token counts |
| `ClaudeReadings.swift` | Loads the three Claude reading files; decides which one to show |
| `ClaudeWebSession.swift` | The app's own browser: sign-in window, and usage calls made *inside* the signed-in claude.ai page |
| `ClaudeWebSource.swift` | Turns claude.ai's reply into `claude-web.json` |
| `ClaudeLiveUsage.swift` | Backup: Keychain login → api.anthropic.com → `claude-live.json` |
| `LineReader.swift` | Streaming line reader, byte keyword search, JSON helpers, file discovery |
| `InstanceLock.swift` | One running copy at a time; `--rebuild` can't run under the app |
| `LegacyCleanup.swift` | Removes the request cache earlier builds left behind |
| `FileWatcher.swift` | FSEvents wrapper with a 2-second debounce |
| `Models.swift` | Data types, display decisions, formatting |
| `UsagePanel.swift` | SwiftUI panel and provider cards |
| `ProviderIcons.swift` | Loads the logo SVGs; draws the menu bar label as one template image |

Other code:

| Path | Job |
|---|---|
| `scripts/claude-statusline.py` | Optional Claude Code status line that writes `claude.json` |
| `Tests/main.swift` | Regression tests (synthetic data), run by `scripts/run-tests.sh` |
| `tools/screenshots/` | Renders README screenshots from made-up data |
| `tools/svg2png/` | Renders `assets/app-icon.svg` for `scripts/make-app-icon.sh` |

---

## Data model

```mermaid
classDiagram
    class UsageReport {
        claude: ProviderReading
        codex: ProviderReading
        scannedAt
        errors
    }
    class ProviderReading {
        provider: Provider
        readings: [AllowanceReading]
        last5Hours / last7Days: TokenTotals
        display(now) AllowanceDisplay
    }
    class AllowanceReading {
        recordedAt
        source: ReadingSource
        planType
        windows: [AllowanceWindow]
    }
    class AllowanceWindow {
        usedPercent
        windowMinutes
        resetsAt
        limitId
        isExpired(now)
    }
    UsageReport --> ProviderReading
    ProviderReading --> AllowanceReading
    AllowanceReading --> AllowanceWindow
```

**`ReadingSource`**: `anthropicLive`, `claudeStatusLine`, `codexLog`. The UI
describes each one differently ("Checked with Anthropic", "From Claude Code status
line · received", "From Codex logs · recorded").

**`ProviderReading.display(now:)`** returns:
- `.available(headline, others, reading)`: at least one window still valid
- `.expired(reading)`: a reading exists, but every window has reset
- `.unavailable`: no reading

**Which readings are candidates:** the newest reading for each source **and each
limit id**. For Codex, every candidate's valid windows are pooled, so a newer
reading for one limit can't hide another. For Claude, one reading is chosen at
display time by `ClaudeReadings.choose`.

**Headline window** (`Provider.headline`):
- Claude: the 5-hour window if it's still valid, otherwise the shortest valid one.
- Codex: the valid window closest to its limit, since that's the one that would
  stop work.

---

## Claude: three sources, one choice

### Why three

`api.anthropic.com/api/oauth/usage` is rate-limited hard — asking every 5 minutes
earned `rate_limit_error` with `Retry-After: 2493`. claude.ai's own endpoints are
a different backend, the one the website polls itself, so they can be asked every
minute. The website route is therefore the normal source and the other two are
backups.

Each source has its own file, so none can overwrite another:

| File | Written by | Timestamp means |
|---|---|---|
| `statusline/claude-web.json` | `ClaudeWebSource` | When the app asked claude.ai |
| `statusline/claude-live.json` | `ClaudeLiveUsage` | When the app checked api.anthropic.com |
| `statusline/claude.json` | `claude-statusline.py` | When the script *received* it from Claude Code |

`ClaudeReadings.choose` picks, **each time the screen is drawn**:
1. The newest **claude.ai** reading under **15 minutes** old with a valid window.
   It is preferred because it can be asked every minute.
2. Otherwise the newest **api.anthropic.com** reading under 15 minutes old with a
   valid window.
3. Otherwise, the newest reading of any source that still has a valid window.
4. Otherwise, the newest reading, shown as "unknown".

Validity comes first, so a reading that has reset can never hide a usable one.

A fresh live check wins even over a newer status-line reading: the status line
only says when the script received a figure, and Claude Code may be repeating one
from its last response.

Both files sit in `statusline/`, which is its own watched folder. Watching the
parent folder would also catch the app's own SQLite writes and loop forever.

---

## Storage

`~/Library/Application Support/AIUsageMeter/cache-v3.sqlite`: WAL mode, 30 s busy
timeout, folder mode `0700`.

**Schema versions are protected three ways.** An older build running alongside a
newer one once doubled every token count, so:

```mermaid
flowchart LR
    V1["Version in the file name<br/>cache-v3.sqlite"] -->|"older builds write<br/>their own file"| OK1["can't collide"]
    V2["Upgrade in one<br/>EXCLUSIVE transaction"] -->|"no half-built schema"| OK2["atomic"]
    V3["Every pass checks<br/>PRAGMA user_version"] -->|"mismatch → refuse to write"| OK3["no silent corruption"]
```

A cache from a *newer* schema is never dropped. The app shows an error instead.

**One copy at a time.** `InstanceLock` takes an exclusive `flock` on
`instance.lock` for the app's whole life. A second copy shows "already running"
and quits. `--scan --rebuild` needs the same lock, so it refuses to delete the
cache while the app runs. A plain `--scan` doesn't take the lock: its writes are
transactions, and the pass opens its transaction *before* reading file offsets, so
two passes can't both read the same bytes.

| Table | Key | Holds |
|---|---|---|
| `files` | `path` | `provider`, `inode`, `offset` (bytes read), `mtime` |
| `buckets` | `(provider, bucket)` | Token sums per 5-minute bucket |
| `readings` | `(provider, source, limit_key, recorded_at)` | Plan and the windows for that limit, as JSON |

Pruning: buckets older than 7 days; readings older than 30 days.

### One index pass

```mermaid
flowchart TB
    B["BEGIN"] --> F["For each provider's log files<br/>changed in the last 7 days"]
    F --> RP{"Any file replaced<br/>or shortened?"}
    RP -->|yes| RS["Clear that provider's<br/>tokens + offsets"]
    RP -->|no| EF
    RS --> EF["For each file with new bytes"]
    EF --> SP["SAVEPOINT file"]
    SP --> PR["Parse new lines → add tokens,<br/>readings, new offset"]
    PR -->|ok| RL["RELEASE"]
    PR -->|"file error"| RB["ROLLBACK TO file<br/>(skip, retry next pass)"]
    PR -->|"database error"| RA["ROLLBACK whole pass<br/>show error"]
    RL --> CL["Load Claude reading files"]
    RB --> CL
    CL --> C["Prune → COMMIT"]
```

Why each piece exists:
- **Savepoint per file:** a read error halfway through a file must not leave half
  its tokens counted while the offset stays old. The retry would count them twice.
- **Rollback on any database error:** token totals and offsets must never
  disagree.
- **Replaced or shortened file:** its old tokens are already inside the buckets and
  can't be subtracted, so that provider's totals are rebuilt from its logs.

### Line reading details (`LineReader`)

- Reads in 1 MB chunks, draining memory per chunk and per line.
- A half-written last line is neither delivered nor counted in the offset, since
  the CLI may still be writing it.
- Lines over 64 MB are skipped, whether they end inside the current buffer or
  span many chunks. Their bytes **are** counted in the offset once their newline
  arrives, so the next pass resumes after them. If the file ends before that
  newline, the offset stops before the line.

---

## UI

- **AppKit shell:** `NSStatusItem` + `NSPopover` hosting SwiftUI through
  `NSHostingController`.
- **No SwiftUI state macros:** the panel is a plain function of the values
  passed in, and `UsageStore.onChange` triggers redraws. See
  [CONTRIBUTING.md](../CONTRIBUTING.md#why-not-xcode-or-swift-build) for why.
- **Menu bar label is one image:** logos and text are drawn together with
  `isTemplate = true`, so macOS tints the whole thing for light and dark menu bars.
  Logos placed inside attributed text didn't get tinted and disappeared on dark
  menu bars.

---

## Build

`build-app.sh`:
1. `swiftc -O` every file in `Sources/AIUsageMeter/` for `arm64-apple-macosx14.0`.
   SQLite3 and Security are linked automatically.
2. Assembles `build/AI Usage Meter.app`: binary, `Info.plist` (`LSUIElement`, bundle
   id `local.aiusagemeter`), `AppIcon.icns`, the two logo SVGs.
3. Signs it ad hoc (`codesign --sign -`).

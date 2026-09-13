# Reminders Spotlight — state

Spotlight-style quick-entry menu bar app for Apple Reminders + Calendar.
GPLv3 fork of reminders-menubar. Repo: github.com/ahm-cmd/reminders-spotlight

## Where things stand

Shipped and pushed through `963517f`. Three surfaces:

- **Bar** — natural-language entry. Parses dates, `@list` / `@calendar`
  shortcuts, `#tags`, `!` priority, `every …` recurrence; parsed tokens are
  highlighted inline and stripped from the saved title.
- **Browse list** — collapsible sections, click-drag swipe-to-postpone
  (1 hr / 1 day / 1 wk).
- **Planner board (→)** — Eisenhower grid: rows are horizon tags in a chosen
  order, columns are importance (read from native priority). Drag writes both
  axes; drop into the Unsorted tray clears the horizon. Hover a cell for `+`
  to add in place. ⌘Z undoes drops and creations. Momentum strip at the bottom.

## Key constraints (don't break these)

- Commit author must stay `ahm-cmd <294535154+ahm-cmd@users.noreply.github.com>`.
  No real name, no personal emails, no `/Users/...` paths in committed files.
- Bundle id stays `com.andrewmott.reminders-menubar` — changing it revokes the
  TCC Reminders/Calendar grant.
- Always install via `./build_install.sh` (re-signs with the stable Apple
  Development identity; an ad-hoc signature revokes the TCC grant every build).
- Deployment target macOS 13.0.
- Never remount a `List` during a window resize — that's the
  "Update Constraints in Window" crash. Reminders and Dashboard both stay
  mounted and cross-fade for this reason. Board cells are `ScrollView` +
  `VStack`, deliberately not `List`.
- The bar's AppKit field stays mounted behind the board, so the board must
  take/release first responder explicitly (see `openAgenda`/`closeAgenda`).

## Open threads

1. **No tests anywhere.** The date parser is now a stack of order-dependent
   regexes (`relativeDate` → `phraseDate` → `relativeOffsetDate` →
   NSDataDetector). Four fixes landed recently with no regression net. Biggest
   structural risk; cheap to fix (pure functions, no UI, no EventKit).
2. **Board is mouse-only.** No keyboard path to move an item between cells, in
   an otherwise keyboard-first app.
3. **Unverified:** whether the cell entry field actually takes first responder
   now that the bar releases it. Fallback is `RmbHighlightedTextField` +
   `focusTrigger`.
4. Board titles show `#tag` inline (Apple stores hashtags in the title text);
   the row label already says it, so it reads as noise.
5. Drop-target hints while dragging; per-horizon overload count; overdue
   emphasis.
6. Repo is still a GitHub **fork**, so commits earn no contribution-graph
   credit. Detaching needs a Support ticket (draft written; not sent).

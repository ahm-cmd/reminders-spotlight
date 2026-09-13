# Search-as-you-type — spec

Status: proposed, not built. Written 2026-09-13.

## The problem

The app is Spotlight-shaped but can only ever *create*. There is no way to ask
"did I already add this?" or "where's that thing about the dentist?" — no code
path anywhere filters reminders by text. With a few hundred reminders the browse
list is the only way to find anything, and it's organised by list/tag, not by
what you remember about the item.

The highest-value moment is the one you're already in: **you are typing a
reminder that may already exist.** Surfacing matches while you type turns the
capture bar into a duplicate check for free.

## Principle: create-first, find-second

The bar's job is capture. Search must never get in the way of it.

- **Return always creates.** It never opens a match, no matter what's on screen.
- Results are a *peripheral* affordance — visible, ignorable, never focused by
  default.
- Nothing about the existing create flow changes if you ignore the results.

This is the single rule that keeps the feature from wrecking the app's character.
Every decision below follows from it.

## Behaviour

### Appearing

Results appear under the bar once the typed title has **≥ 3 characters** of
non-token text (i.e. after `@list`, `#tag`, `!`, and date phrases are stripped —
reuse `RmbReminder.titleStrippingParsedTokens`). Below that threshold, nothing —
typing "b" shouldn't flash a panel.

Show at most **5** matches. Beyond that, a trailing "+N more" row, never a
silent cut (same rule as the Planner's Unsorted tray).

### Keyboard

| Key | Behaviour |
|---|---|
| `Return` | Create. Always. Even with a result highlighted. |
| `⌘↩` | Create and continue (unchanged). |
| `↓` | Move selection into the results list. |
| `↑` | Move up; from the first result, return focus to the field. |
| `Return` *while a result is selected* | Open that reminder's edit popover. |
| `⌘Return` *while a result is selected* | Complete it (the "yes I did that" path). |
| `Esc` | First press dismisses results; second closes the panel. |

The two-stage `Esc` matters — right now `Esc` closes the whole panel, and losing
a half-typed entry because you wanted to dismiss a results list would be
infuriating.

### Interaction with existing modes

- `→` (Planner) is gated on an **empty** field, so it never collides with search.
- `⌘↓` (browse list) and search are mutually exclusive: opening one closes the
  other. Both occupy the space under the bar.
- Event mode searches **events**, not reminders, using the same UI.

## Matching and ranking

Match against **title** and **notes**, case- and diacritic-insensitively.

Rank:

1. Title prefix match
2. Title word-boundary match
3. Title substring
4. Notes match
5. Tie-break: due date ascending (undated last), then most recently modified

Multi-word queries are AND across terms, each term matched independently — so
"dentist call" finds "Call the dentist".

Scope: **incomplete reminders across all lists**, deliberately ignoring the
browse list's calendar filter (you're asking "does this exist anywhere?", not
"show me my filtered view"). Completed reminders are excluded by default — see
open questions.

## Performance — the constraint that shapes the design

Do **not** query EventKit per keystroke.

The Planner's full read is ~120 ms of main-thread work, most of it because
`EKReminder.ekTags` reaches through Objective-C private selectors once per
reminder, and `RemindersService` is `@MainActor`. Repeating anything like that
on every character would be far worse than the lag we just removed from the
Dashboard.

Instead, mirror the `PlannerCache` pattern that fixed it:

- Build a flat `SearchIndex` once — an array of
  `(identifier, lowercased title, lowercased notes, dueDate, listColor)` —
  no tags, no private selectors.
- Warm it on panel open, **after** the open animation (the Planner warms at
  +0.3 s; search can share that pass or piggyback on the same snapshot).
- Filtering a few hundred plain strings per keystroke is microseconds. No
  debounce needed.
- Invalidate on `.EKEventStoreChanged` (debounced 300 ms) and after any create.

A single shared "store snapshot" serving both the Planner and search is probably
the right end state, rather than two caches reading the same store.

## Layout and the crash constraint

Results sit in a card below the bar, in the slot the browse list uses.

**Do not mount a `List`.** Four `List`s side by side is what caused the
`Update Constraints in Window` crash, and the Planner already uses
`ScrollView` + `VStack` for this reason. With a 5-row cap the results card
doesn't need a scroll view at all — a plain `VStack` at a **fixed height per
row** means the window height is deterministic and computed up front, which
avoids resizing while content is mounting.

Row style: reuse the Planner's compact row (complete button, title, due date,
list name) rather than the full `ReminderItemView` — no swipe actions, no notes,
no tag chips.

The current `onChange(of: rmbReminder.title)` handler calls `collapse()` when
typing while expanded ("typing means you're committing to writing"). That has to
learn the difference between collapsing the *browse list* and showing *results*,
or the two will fight on every keystroke.

## Files this touches

| File | Change |
|---|---|
| `Services/RemindersService.swift` | `SearchIndex` build + a `search(_:)` returning ranked hits |
| `Views/SpotlightView.swift` | results card, selection state, key handling, collapse-handler fix |
| `Models/RmbReminder.swift` | reuse `titleStrippingParsedTokens` for the query text |

Given `SpotlightView.swift` is already 2,000+ lines, the results card should
land in its own file (`Views/SearchResultsCard.swift`) — needs
`xcodegen generate` after adding.

## Open questions

1. **Completed reminders.** Excluding them means "did I already do that?" goes
   unanswered — arguably the most useful question. Including them risks burying
   live items under finished ones. Suggestion: exclude by default, include
   behind a modifier or a trailing "search completed too" row.
2. **Does search replace the Planner's `→` slot** long-term, or coexist? They
   answer different questions (find one thing vs. triage everything), so
   coexisting seems right, but two things under one bar is a lot of surface.
3. **Duplicate warning.** Should an exact-ish title match show something stronger
   than a list row — e.g. an inline "you already have this" hint next to the
   create affordance? That's the feature's real value, and a plain results list
   underplays it.
4. **Event search** in Calendar mode: same treatment, or skip for v1?

## Explicitly out of scope for v1

- Fuzzy/typo-tolerant matching (exact substring first; see if it's actually needed)
- Searching subtasks separately from parents
- Searching by list or tag name as a query term (those already have `@` / `#`)
- Any persistence of recent searches

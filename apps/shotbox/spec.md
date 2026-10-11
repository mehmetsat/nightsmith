# ShotBox: screenshot clipboard

A menubar macOS app that keeps every screenshot you take, shows them in a grid, and lets you search, pin and re-copy them. Screenshots only; text and other clipboard content is ignored.

## Constraints (fixed; copied from prompt.md, do not relax)

- Captures screenshots from ⌘⇧3 / ⌘⇧4 / ⌘⇧5 and any image copied to the pasteboard. Nothing else.
- Menubar icon plus a separate window. The window shows a thumbnail grid with date and size, search over filename and OCR text, pin, delete.
- Every capture is written to disk; metadata in SQLite. Quit and relaunch, everything is still there.
- Click copies back to the pasteboard, double-click opens in Preview, drag out to other apps.
- Global hotkey opens the window.
- OCR via the Vision framework for searchable text. This is the app's "AI feature"; no model API calls.
- Retention setting: keep last N captures or last N days.
- Stack: Swift, SwiftUI, SQLite (GRDB or raw sqlite3), macOS 14+. No third-party UI frameworks.

## Motion, as three named hero interactions (soft criteria)

- Grid → full preview: the selected card expands into the preview (matchedGeometryEffect), background blurs.
- Preview navigation: arrow keys or swipe slide to the neighbour like a slider; current image scales down slightly as it leaves.
- New capture: enters at the head of the grid with a slide, the rest make room. Pin and delete animate the card out of place.

## Known friction, decided up front

- Screen Recording and Accessibility permissions are granted by hand once during init and noted in spec.md; agents must not try to work around them. (Noted here: both grants are made once by the human during init. The engineer and QA must not script, reset or bypass them, and must not change them.)
- Drag-out and hotkey-from-another-app are manual criteria.
- Target 25 to 30 hard criteria in the spec. If the planner produces more than 40, trim before round 1.

## Harness notes (how this workspace builds and runs)

- The app is a Swift package (Package.swift, Sources/ShotBox/) that ./build.sh wraps into build/ShotBox.app, signed with a stable identity so permission grants survive rebuilds. This replaces the xcodebuild/Xcode project in the original brief.
- ./run.sh launches the built app and waits for its window. It sources test.env, which sets SHOTBOX_WATCH_DIR, SHOTBOX_DATA_DIR and SHOTBOX_OPEN_WINDOW=1 for QA. The app should open its window on launch (or when launched with the environment variable SHOTBOX_OPEN_WINDOW=1).
- macOS saves ⌘⇧3/4/5 screenshots to the Desktop by default (the `com.apple.screencapture location` default overrides it). Reading the Desktop needs a one-time permission grant. For tests, the folder to watch can be overridden with the SHOTBOX_WATCH_DIR environment variable, and the data folder with SHOTBOX_DATA_DIR, so QA never touches the user's real screenshots.
- Test images are in fixtures/ (fixture_large.png is 6000×4000).
- QA simulates a screenshot by copying a fixture into $SHOTBOX_WATCH_DIR (a file-system action, not a system setting). QA simulates a pasteboard image by writing a fixture to the pasteboard from a shell helper; this is allowed because it changes only transient pasteboard content, never settings.
- Round 1 polish pass: SHOTBOX_TRACE=<path> makes the app append timestamped trace lines (hotkey, clothesline.firstFrame, clothesline.settled, clothesline.openWork decoded=<n> queries=<n>) so QA can measure latency. SHOTBOX_APPEARANCE=light|dark overrides the appearance for this app only (NSApp.appearance), so QA can compare both modes without touching the system setting.

## Product overview

ShotBox is for people who take many screenshots and lose them. Every screenshot lands in a searchable, pinnable visual history that is one hotkey away. It lives in the menubar, opens a real window, and stays quiet otherwise.

Default behaviour when the app is not otherwise configured: watch the folder macOS uses for screenshots (Desktop by default, or SHOTBOX_WATCH_DIR when set), store data in `~/Library/Application Support/ShotBox` (or SHOTBOX_DATA_DIR when set), global hotkey ⌃⌥⌘S, retention "keep last 500 captures".

## User stories

1. As a user, I press ⌘⇧4, grab a region, and a moment later it appears at the top of my ShotBox grid without any action.
2. As a user, I copy an image from a browser or design tool and it is also captured; copying text is ignored.
3. As a user, I see thumbnails with date and pixel size, newest first, pinned ones kept in a section at the top.
4. As a user, I type "invoice" and the grid narrows to screenshots whose filename or recognised text contains it.
5. As a user, I click a card and that image is on my pasteboard, ready to paste; I get clear feedback that it happened.
6. As a user, I double-click a card and it opens in Preview.
7. As a user, I drag a card into Mail, Slack or Finder and the image goes with it.
8. As a user, I press Space or Return on a selected card to see it large, then flip through neighbours with arrow keys or a swipe.
9. As a user, I pin important shots so retention never removes them, and delete ones I do not want.
10. As a user, I press the global hotkey from any app and the ShotBox window comes forward.
11. As a user, I set retention to last N captures or last N days and old unpinned ones are removed.
12. As a user, I quit and relaunch and everything is still there.
13. (Round 3) As a support engineer weeks later, I remember the app or the ticket ID, not the date: cards say which app a capture came from, identifiers in the text (ticket IDs, URLs, codes) are chips I can copy and search, and during search each card shows why it matched.
14. (Round 3) I can copy all recognised text from a capture with one click, and ⌘F always takes me to search.
15. (Round 3) Before retention removes anything, Settings shows me which captures are next to go.

16. (Round 1 replan) I copy screenshots straight to the clipboard with ⌘⌃⇧4 because saved files pile up. ShotBox catches them there; the folder watcher is optional.
17. (Round 1 replan) I hit ⌃⌥⌘L, or rest the pointer at the top edge, and a Clothesline of recent shots hangs from the top of my screen like laundry on a line. I click one, it is on my pasteboard, the line rises, I paste.
18. (Round 1 replan) My disk does not fill up: old full images are shrunk after N days, thumbnails and recognised text stay searchable, and the same image is never stored twice.

19. (Round 3, second pass) As a support engineer I hang the Clothesline, type "48213" and press Return: the matching print is on my pasteboard without opening the window.
20. (Round 3, second pass) I trust the captions: a card says "from Finder" only if it came from Finder; files from the folder say "Screenshot folder". Each card also remembers what I did with it ("Used 3×"), and the preview lists those events.
21. (Round 3, second pass) A compressed capture tells me what was lost: a corner ribbon, and a seal note with the date and before/after sizes.
22. (Round 3, second pass) The first minute feels welcoming, and nothing in preview or Settings is clipped, overlapped or cut off by the screen.

23. (Round 1 polish) I press ⌃⌥⌘L and the line is already falling. There is no pause while it "loads", even with hundreds of captures.
24. (Round 1 polish) I work with a laptop plus an external display. The line comes down on the display my pointer is on, at that display's width, whether I use the hotkey or rest the pointer at its top edge.
25. (Round 1 polish) A capture keeps one address for life ("10 OCT · 07"). When search finds it, I can see where in the picture the word is, how many results there are, and after Esc I land back where the capture lives, next to the shots I took just before and after it.
26. (Round 1 polish) With 200 captures the window still answers every click at once, and the app looks and speaks the same in light and dark mode, in plain words.

## Screens

### Clothesline (round 1 replan)
- A borderless panel docked at the top edge of the main screen, just under the menubar, full screen width, that lives instead of a window. Thumbnails hang from it by clothes pegs, newest first, each with a short date/size caption; it scrolls sideways when there are more than fit.
- Opens with ⌃⌥⌘L (toggle), or by resting the pointer at the top edge (manual check). Esc, the hotkey, clicking outside, or choosing a card hides it.
- Click a card: copy image, "Copied" toast, line retracts. Double-click opens in Preview. It does not replace the main window; the grid stays the library and search surface.
- Motion: drops on a spring with a faint pendulum sway; retracts quickly; Reduce Motion drops the sway.
- Round 3 (second pass): type-to-find. While the line is down, typing filters the prints by OCR text, identifier or app; non-matches leave the line and matches slide together with a small query label; Return copies the first match, Esc clears the filter first and hides on the second press. Newest-first order is by capture date, pinned or not (H40).
- Round 1 polish, screen: the line opens on the screen that holds the pointer (hotkey and top-edge dwell alike), spans that screen's width and sits below that screen's menubar. "Main screen" in older text means this screen. With one display nothing changes (H53).
- Round 1 polish, speed: the panel is created once at launch and kept off-screen, its layout is kept current as captures arrive, and print thumbnails stay decoded in memory, so opening only moves and shows the panel. The first frame comes within 50 ms of the trigger and the drop settles in about 350 ms; hiding starts as fast (H52). Each print's caption shows its permanent address (H55).

### Menubar item
- Template-style icon in the menubar. Clicking opens a small menu: "Open ShotBox", count of captures, "Pause capturing" toggle, "Settings…", "Quit ShotBox".
- Pausing stops both folder watching and pasteboard capture until resumed; menu item reflects state.

### Main window ("ShotBox")
- Standard resizable macOS window, minimum about 640×480, with a toolbar containing a search field, a size-of-thumbnail slider, and a Settings button.
- Body: adaptive thumbnail grid. A "Pinned" section header appears above pinned cards when any exist; the rest follow, newest first.
- Card: thumbnail (aspect-fit, rounded corners), date line (relative for today/yesterday, otherwise short date and time), size line (pixel dimensions, e.g. "1920 × 1080"), small pin glyph when pinned. Hover reveals pin and delete buttons. Selected card shows an accent outline.
- Round 3: every card has the same fixed-height thumbnail bay (image aspect-fit inside), so date, size and a provenance caption (frontmost app at capture) line up along a row. During search a snippet line under the card shows the matched text or filename. While OCR is pending a quiet scan line and shimmer replace "No text".
- Round 3 (second pass): the provenance caption says how a capture arrived ("from Finder" for a known pasteboard source, a quieter "Screenshot folder" for files, never a guessed app). Once a card has been used, a quiet "Used N×" line appears, backed by a per-capture custody log. The Compressed marker becomes a corner ribbon that opens a seal note (date, size and pixels before and after). The empty state is an invitation with key-cap shortcut groups and hands over to the grid with a spring when the first capture lands.
- Round 1 polish: the layout-derived cell labels (A1, B2) and the column letters go away. Each card carries a permanent tray address instead (capture day plus arrival number, "10 OCT · 07"), assigned once, stored, never renumbered and searchable (H55). Search shows evidence: a result count ("1 of 200"), the matched term emphasised in the snippet, and for OCR matches an accent callout of the word drawn on the thumbnail where Vision found it (H56). Narrowing and clearing animate from and back to each card's home slot (S13). Esc on a selected result clears search, keeps the selection, scrolls to the card's home and briefly marks its neighbours in time (H58). With 200 captures every click, key and search answers within the H54 budgets; the grid is lazy and state changes (hover, selection, custody) do not rebuild it.
- Context menu on card: Copy, Open in Preview, Pin/Unpin, Reveal in Finder, Delete.
- Empty state (no captures): friendly illustration-free message explaining how to take a screenshot, and the hotkey. No-results state when search matches nothing, with the query echoed and a "Clear search" button.
- Keyboard: arrow keys move selection in the grid, Return/Space opens preview, ⌘C copies selection, Delete/⌫ deletes selection, ⌘F focuses search, ⌘P pins/unpins selection, Esc clears search or closes preview.

### Full preview
- Selecting open expands the card into a large view over a blurred grid. Shows image fit to window, a bottom info bar (filename, date, pixel size, file size, whether text was recognised), and buttons: Copy, Open in Preview, Pin, Delete, Close.
- Left/Right arrow keys, trackpad swipe, and on-screen chevrons move to the previous/next capture in the current (filtered) ordering. At the ends navigation does nothing visible beyond a gentle bounce.
- Recognised text can be revealed in a side panel and selected/copied as text (toggle button). Round 3: the panel has a "Copy text" button and, under the text, identifier chips (ticket IDs, URLs, status/error codes) that copy on click. Preview chrome stays legible over any image (no colour bleed behind the info bar).
- Round 3 (second pass): with the text panel open nothing clips or overlaps at any window size (panel, Copy text button, chevrons and info-bar buttons all inside the window and apart); the toast stays anchored while the preview opens; the info bar lists the custody events of the capture, newest first; the backdrop blur keeps the grid recognisable.

### Settings
- Retention: segmented choice "Keep last N captures" or "Keep last N days", numeric field/stepper for N. Pinned captures are never removed. Changes apply immediately and are described in a one-line summary ("Currently 512 captures; 12 would be removed" or similar).
- Round 3: a "Next to go" strip shows thumbnails of the oldest unpinned captures retention will remove next (never pinned ones), updating live.
- Round 1 replan: "Also watch a screenshot folder" toggle (clipboard capture is the main path); "Shrink full images after N days" (default 30); total size on disk shown live. Shrunk captures keep thumbnail and recognised text and carry a "compressed" marker. Retention still decides when a whole capture goes.
- Round 3 (second pass): the window fits the visible screen at its default size and scrolls if needed; toggles show an unambiguous on/off state; the retention field accepts a typed N; the summary uses singular wording ("1 capture").
- Global hotkey display (fixed to ⌃⌥⌘S is acceptable; a recorder is a bonus). Second hotkey ⌃⌥⌘L toggles the Clothesline.
- Launch at login toggle.
- Storage: shows data folder path, total size on disk, and watched folder path. "Reveal in Finder" button.

## Data model (high level)

- **Capture**: id, filename, file path inside the data folder, created date, pixel width/height, file size in bytes, source (screenshot-file or pasteboard), pinned flag, pin date, recognised text (may be empty), OCR status (pending/done/failed), content hash.
- Image files are stored on disk in the data folder; thumbnails are cached on disk as well. SQLite holds metadata and recognised text, with a search index (or equivalent) over filename and OCR text.
- Settings (retention mode and N, launch at login, paused) are persisted across launches.
- Duplicate protection: identical content captured twice within a short window (for example a screenshot file that also appears on the pasteboard) yields one capture. Round 1 replan: the content hash is checked against the whole library, not only a short window; a repeat selects the existing card and shows an "Already saved" toast.
- Storage tiers (round 1 replan): full image → after N days compressed copy (long edge ≤ 1600 px, lossy) → thumbnail plus OCR text for as long as the row exists. Pinned captures are never shrunk.
- Round 1 polish: each capture stores its tray address (capture day and per-day sequence number) when it is created. The number of a deleted capture is not reused; changing created dates later does not change the address.
- Round 3 (second pass): each capture also has a source kind (app pasteboard / screenshot folder) used for the provenance caption, and a custody log (capture id, event kind, time) deleted with the capture. Shrinking records its date and before/after size and pixels for the seal note.
- Retention runs at launch, after each new capture and on setting change; it never removes pinned captures and removes both the row and the files.

## Visual design language

- Native macOS feel: system materials (.regularMaterial / .ultraThinMaterial), SF Pro, SF Symbols, system accent color, full light and dark mode support.
- Grid is airy: 16 pt gutters, 10 pt corner radius on thumbnails, soft shadow that deepens on hover, thumbnails never cropped.
- Typography: filename/date in 12 pt medium secondary-label color, size in 11 pt tertiary. Section headers small caps-style 11 pt semibold.
- Motion is spring-based (response about 0.35–0.45, damping about 0.8), never linear; durations stay under 0.6 s; respects Reduce Motion by falling back to quick cross-fades.
- Transient feedback ("Copied") is a small capsule toast at the bottom of the window with fade in/out, auto-dismissed after about 1.5 s.
- The three hero interactions listed above are the signature of the app and must feel polished.
- Clothesline (round 1 replan): a fourth signature. Material backing with a soft shadow under the line, a thin cord, visible pegs, thumbnails never cropped, captions in the same type scale as the grid but higher contrast. Restraint over gimmick: sway of a few degrees, one settle, no looping animation.

- Round 3 (second pass): shortcuts are set as key caps, matched text is emphasised in snippets, hover buttons stay legible over any card colour, and deletes scale out before neighbours reflow. Provenance and snippet lines use clearly different tones.

- Round 1 polish (quality pass): speed is part of the look. Every surface answers within one frame of the trigger. Anything that can be prepared ahead (panels, layouts, decoded thumbnails) is, and motion starts at once and settles in about 350 ms.
- One identity in light and dark: the same card anatomy (address, mono date and size, provenance), the same type and one selection signal in both appearances. The ledger character comes from the addresses and the type, not from layout coordinates.
- Plain words: no internal vocabulary on screen (first pass, decay, custody, pegged). One date format everywhere (relative for today/yesterday, otherwise one fixed day-month-year). Numbers are never locale-grouped. The warning colour means something will be removed and is used for nothing else.
- Search evidence uses the accent colour sparingly: one callout per matched card, enlarged word on a soft material backing, never covering more than a small part of the thumbnail.

## Permissions note

Screen Recording and Accessibility permissions are granted by hand once during init. They are not to be reset, toggled or worked around by agents. If a feature appears blocked by a permission, report it; do not try to bypass it. Reading the Desktop (default watch folder) also needs a one-time grant, which is why QA uses SHOTBOX_WATCH_DIR.

## Criteria

Trimmed by hand before round 1 to stay inside 25-30 hard criteria: H20 (context menu), H23 (preview honours search filter), H29 (duplicate merge), H32 (settings paths and launch at login). These are not required and are not tested.

```json
[
  {
    "id": "H01",
    "class": "hard",
    "text": "The project builds with ./build.sh and produces build/ShotBox.app without errors.",
    "verify": "1. Run ./build.sh. 2. Confirm exit status 0. 3. Confirm build/ShotBox.app exists and contains an executable in Contents/MacOS."
  },
  {
    "id": "H02",
    "class": "hard",
    "text": "./run.sh launches the app and a window titled ShotBox appears; the app also has a menubar item.",
    "verify": "1. Run ./run.sh. 2. Read the accessibility tree and confirm a window named 'ShotBox' exists. 3. Confirm the app's menubar extra (status item) is present in the tree. 4. Take a window screenshot."
  },
  {
    "id": "H03",
    "class": "hard",
    "text": "With an empty data folder the main window shows an empty state explaining how to capture and naming the hotkey.",
    "verify": "1. Launch with a fresh empty SHOTBOX_DATA_DIR. 2. Read the tree: find an empty-state text mentioning screenshot and ⌃⌥⌘S (or the configured hotkey). 3. Confirm no cards exist."
  },
  {
    "id": "H04",
    "class": "hard",
    "text": "A new image file appearing in SHOTBOX_WATCH_DIR is captured automatically and appears in the grid within 5 seconds.",
    "verify": "1. Launch the app with empty data. 2. Copy fixtures/fixture_1.png into $SHOTBOX_WATCH_DIR. 3. Within 5 s read the tree and confirm exactly one card. 4. Screenshot the window."
  },
  {
    "id": "H05",
    "class": "hard",
    "text": "An image placed on the pasteboard is captured; text placed on the pasteboard is ignored.",
    "verify": "1. Note card count N. 2. Write fixtures/fixture_2.png to the pasteboard with a shell helper. 3. Within 5 s confirm count N+1. 4. Put plain text on the pasteboard. 5. Wait 5 s and confirm the count is still N+1."
  },
  {
    "id": "H06",
    "class": "hard",
    "text": "Non-image files dropped into the watch folder (e.g. a .txt) are ignored; PNG and JPEG are captured.",
    "verify": "1. Write notes.txt into the watch folder, wait 5 s, confirm no new card. 2. Copy a fixture PNG in, confirm a new card. 3. Convert a fixture to JPEG outside the watch folder with sips, copy it in, confirm a new card."
  },
  {
    "id": "H07",
    "class": "hard",
    "text": "Each card shows a thumbnail, a date line and a pixel-size line that matches the real image dimensions.",
    "verify": "1. Capture fixture_1.png and fixture_large.png. 2. Read each card's text from the tree. 3. Confirm a date/time string is present and the size string equals the dimensions from `sips -g pixelWidth -g pixelHeight` (fixture_large reads '6000 × 4000'). 4. Screenshot to confirm thumbnails render, not blank."
  },
  {
    "id": "H08",
    "class": "hard",
    "text": "The large 6000×4000 fixture is captured and its card appears without freezing the UI.",
    "verify": "1. Copy fixture_large.png into the watch folder. 2. Within 5 s the card exists. 3. While it processes, click the search field and type 'a'; confirm the field accepts input promptly (under 1 s)."
  },
  {
    "id": "H09",
    "class": "hard",
    "text": "Grid is ordered newest first.",
    "verify": "1. Copy fixture_1.png, wait for its card, then fixture_2.png, then fixture_3.png into the watch folder with ~2 s gaps. 2. Read card order in the tree. 3. Confirm the first card corresponds to the last capture (via the filename visible in the tree or the context in the preview info bar)."
  },
  {
    "id": "H10",
    "class": "hard",
    "text": "Captures persist across quit and relaunch, including pinned state and ordering.",
    "verify": "1. Capture three fixtures; pin the second. 2. Quit the app via menubar 'Quit ShotBox'. 3. Run ./run.sh again with the same data dir. 4. Confirm the same three cards, same order, the pinned one still pinned."
  },
  {
    "id": "H11",
    "class": "hard",
    "text": "Capture files are written to disk and metadata lives in a SQLite database in the data folder.",
    "verify": "1. After capturing two fixtures, list $SHOTBOX_DATA_DIR. 2. Confirm there is a .sqlite/.db file and at least two image files whose sizes are non-zero. 3. Run `sqlite3 <db> .tables` and confirm a table with capture rows (count = 2 via a SELECT COUNT(*))."
  },
  {
    "id": "H12",
    "class": "hard",
    "text": "Single-clicking a card copies that image to the pasteboard and shows a 'Copied' confirmation.",
    "verify": "1. Clear the pasteboard by writing a short text. 2. Click a card for fixture_3.png. 3. Within 1 s confirm a 'Copied' toast in the tree/screenshot. 4. Read the pasteboard type with a shell helper and confirm image data whose dimensions equal the fixture's."
  },
  {
    "id": "H13",
    "class": "hard",
    "text": "Copying from ShotBox back to the pasteboard does not create a duplicate capture.",
    "verify": "1. Note count N. 2. Click a card (copies to pasteboard). 3. Wait 5 s. 4. Confirm count still N."
  },
  {
    "id": "H14",
    "class": "hard",
    "text": "Double-clicking a card opens the image in Preview.",
    "verify": "1. Double-click a card. 2. Within 5 s confirm via the accessibility tree/process list that the Preview app has a window whose title contains the capture's filename. 3. Close that Preview window afterwards without changing any settings."
  },
  {
    "id": "H15",
    "class": "hard",
    "text": "Searching by filename filters the grid live.",
    "verify": "1. Capture fixture_1.png and fixture_2.png (filenames differ). 2. Type 'fixture_2' into the search field. 3. Within 1 s confirm exactly one card remains and it is the fixture_2 capture. 4. Clear the field and confirm both return."
  },
  {
    "id": "H16",
    "class": "hard",
    "text": "OCR via Vision makes text inside screenshots searchable.",
    "verify": "1. Capture each fixture. 2. Determine a word visible in one fixture by viewing it (Read the image). 3. Wait up to 10 s for OCR. 4. Type that word in search and confirm that fixture's card is shown and unrelated ones are hidden. 5. In the preview of that card, open the recognised-text panel and confirm the word is present."
  },
  {
    "id": "H17",
    "class": "hard",
    "text": "Search with no matches shows a no-results state with the query and a working Clear search button.",
    "verify": "1. Type 'zzzqqq123' in search. 2. Confirm no cards and a message containing the query. 3. Click 'Clear search' and confirm the field empties and cards return."
  },
  {
    "id": "H18",
    "class": "hard",
    "text": "Pinning moves a card to a Pinned section at the top and unpinning returns it to chronological position.",
    "verify": "1. With 3 captures, hover the oldest and click its pin button (or ⌘P after selecting). 2. Confirm a 'Pinned' header exists and the pinned card is first. 3. Unpin; confirm the header disappears and the card returns to the oldest position."
  },
  {
    "id": "H19",
    "class": "hard",
    "text": "Deleting a card removes it from the grid, the database and disk.",
    "verify": "1. With 3 captures, record data-folder file count and DB row count. 2. Select one card and press ⌫ (or use the hover delete button / context menu). 3. Confirm the card is gone, the DB row count dropped by 1 and one image file was removed."
  },
  {
    "id": "H21",
    "class": "hard",
    "text": "Pressing Return or Space on a selected card opens the full preview showing the image and an info bar with filename, date, pixel size and file size; Esc closes it.",
    "verify": "1. Click a card to select, press Space. 2. Confirm a preview region with a large image and an info bar containing filename, date, dimensions and file size. 3. Press Esc and confirm the grid is visible again with the same selection."
  },
  {
    "id": "H22",
    "class": "hard",
    "text": "In the preview, Right and Left arrow keys move to the neighbouring capture and the info bar updates; ends do not crash or wrap.",
    "verify": "1. Capture 3 fixtures; open preview on the middle one. 2. Press Left and confirm the info bar's filename changes to the newer neighbour; press Right twice and confirm the older neighbour. 3. Press Right again at the oldest; confirm the filename does not change and the app remains responsive."
  },
  {
    "id": "H24",
    "class": "hard",
    "text": "Preview buttons Copy, Open in Preview, Pin and Delete work; deleting from the preview moves to a neighbour or closes it when none remain.",
    "verify": "1. Open preview. 2. Click Copy; confirm 'Copied' toast. 3. Click Pin; confirm pin state is shown in preview. 4. Click Delete; confirm the preview shows another capture (or closes if it was the last) and the count decreased by one."
  },
  {
    "id": "H25",
    "class": "hard",
    "text": "Settings shows a retention control with mode (last N captures / last N days) and N; the summary updates when N changes.",
    "verify": "1. Open Settings from the toolbar or menubar. 2. Confirm segmented mode control and a numeric field/stepper. 3. Change N and confirm the one-line summary text updates."
  },
  {
    "id": "H26",
    "class": "hard",
    "text": "Retention by count removes the oldest unpinned captures and never removes pinned ones.",
    "verify": "1. Capture 5 fixtures; pin the oldest. 2. In Settings choose 'Keep last N captures' with N=2. 3. Confirm the grid shows the pinned oldest plus the 2 newest, with the other 2 gone from the grid and from disk. 4. Relaunch and confirm the setting and result persisted."
  },
  {
    "id": "H27",
    "class": "hard",
    "text": "Retention by days removes captures older than N days.",
    "verify": "1. Quit the app. 2. With sqlite3, set created date of two captures in the QA data DB to 10 days ago (QA data only). 3. Relaunch, set 'Keep last N days' with N=7 (or have it persisted). 4. Confirm the two old captures are removed from grid and disk."
  },
  {
    "id": "H28",
    "class": "hard",
    "text": "Menubar menu offers Open ShotBox, capture count, Pause capturing, Settings… and Quit; Pause stops capture and resume restores it.",
    "verify": "1. Click the menubar item and read the menu. 2. Confirm the five entries. 3. Choose Pause capturing; copy a fixture into the watch folder; wait 5 s; confirm no new card. 4. Choose resume and copy another fixture; confirm it is captured. 5. Choose Open ShotBox after closing the window and confirm the window returns."
  },
  {
    "id": "H30",
    "class": "hard",
    "text": "The window is resizable, the grid reflows, and nothing clips or overlaps at the minimum and a large size.",
    "verify": "1. With 6 captures, resize the window to the minimum (about 640×480) and to a large size. 2. Screenshot each. 3. Confirm cards do not overlap, text is not truncated unreasonably, toolbar remains usable. 4. Move the thumbnail size slider and confirm card size changes."
  },
  {
    "id": "H31",
    "class": "hard",
    "text": "The global hotkey ⌃⌥⌘S brings the ShotBox window forward when the app is running and its window is closed or hidden.",
    "verify": "1. Close the ShotBox window (⌘W) so the app stays in the menubar. 2. Send the hotkey keystroke via the automation tool (while ShotBox is the active app). 3. Confirm the window reappears in the tree. (Hotkey from another focused app is manual, see M01.)"
  },
  {
    "id": "S01",
    "class": "soft",
    "text": "Grid → preview hero: the selected card visibly expands into the preview with a matched-geometry transition and the background blurs.",
    "verify": "1. Start frame capture. 2. Select a card and press Space. 3. Inspect frames across the first ~0.6 s: the image should grow continuously from the card's rect to the large view (no jump cut), and the grid behind should increase in blur. 4. Repeat on close and confirm it collapses back to the card. Score on smoothness and continuity."
  },
  {
    "id": "S02",
    "class": "soft",
    "text": "Preview navigation hero: arrow keys slide to the neighbour like a slider while the outgoing image scales down slightly.",
    "verify": "1. Open preview on a middle capture; start frame capture. 2. Press Right. 3. In frames, confirm outgoing image translates out while shrinking a few percent and the incoming one slides in from the opposite edge; direction should reverse for Left. Score on smoothness and spring feel."
  },
  {
    "id": "S03",
    "class": "soft",
    "text": "New capture hero: new card enters at the head of the grid with a slide while the other cards make room.",
    "verify": "1. Have 4 captures; start frame capture. 2. Copy a fixture into the watch folder. 3. In frames, confirm the new card slides/fades in at position one and existing cards shift smoothly rather than jumping."
  },
  {
    "id": "S04",
    "class": "soft",
    "text": "Pin and delete animate the card out of place and neighbours reflow smoothly.",
    "verify": "1. Start frame capture. 2. Pin a middle card, then delete another. 3. In frames confirm the card moves to its new place (or scales/fades out when deleted) and remaining cards slide, no pop."
  },
  {
    "id": "S05",
    "class": "soft",
    "text": "Visual polish of the grid: consistent gutters, rounded thumbnails with soft shadows, clear typographic hierarchy, selected state clearly visible.",
    "verify": "1. Screenshot the grid with 8 captures in light mode as currently set (do not change system appearance). 2. Check gutters even, 10 pt-ish corner radius, hierarchy between date and size lines, accent outline on the selected card."
  },
  {
    "id": "S06",
    "class": "soft",
    "text": "Empty, no-results and toast states feel designed: well spaced, aligned, and styled with system materials.",
    "verify": "1. Screenshot the empty state, no-results state and 'Copied' toast. 2. Judge spacing, alignment, material use and legibility."
  },
  {
    "id": "S07",
    "class": "soft",
    "text": "Hover affordances on cards (pin/delete buttons, shadow deepening) appear smoothly and do not shift layout.",
    "verify": "1. Move the pointer over a card with frame capture running. 2. Confirm buttons fade in, shadow deepens, card layout does not move. 3. Move away and confirm they fade out."
  },
  {
    "id": "S08",
    "class": "soft",
    "text": "Settings and preview info bar are tidy and consistent with native macOS conventions.",
    "verify": "1. Screenshot Settings and the preview info bar. 2. Check alignment, label/value hierarchy, control sizing, and use of SF Symbols."
  },
  {
    "id": "M01",
    "class": "manual",
    "text": "Pressing ⌃⌥⌘S while another app (e.g. Finder or Safari) is focused brings the ShotBox window to the front.",
    "verify": "Human: focus another app, press the hotkey, confirm ShotBox appears in front. Requires the Accessibility grant made during init."
  },
  {
    "id": "M02",
    "class": "manual",
    "text": "Dragging a card out into other apps (Finder, Mail, Messages, a browser upload field) delivers the image file.",
    "verify": "Human: drag several cards into Finder and Mail and confirm the image arrives with correct content and filename."
  },
  {
    "id": "M03",
    "class": "manual",
    "text": "Real ⌘⇧3, ⌘⇧4 and ⌘⇧5 screenshots (default Desktop location) are captured and appear at the top of the grid.",
    "verify": "Human: with the default watch folder, take each kind of screenshot and confirm each appears within a few seconds. Requires the one-time Desktop access grant."
  },
  {
    "id": "M04",
    "class": "manual",
    "text": "Trackpad two-finger swipe in the preview moves to the neighbour capture.",
    "verify": "Human: open preview, swipe left and right on a trackpad and confirm navigation and the slide motion."
  },
  {
    "id": "M05",
    "class": "manual",
    "text": "With system Reduce Motion enabled, hero transitions fall back to quick cross-fades and everything still works.",
    "verify": "Human: enable Reduce Motion in System Settings, open the preview, navigate, add a capture; confirm no large movement. Re-disable afterwards."
  },
  {
    "id": "M06",
    "class": "manual",
    "text": "Launch at login toggle actually registers the app to start at login.",
    "verify": "Human: enable the toggle, check System Settings → General → Login Items lists ShotBox, then log out/in or reboot to confirm."
  },
  {
    "id": "H33",
    "class": "hard",
    "text": "⌘F focuses the search field so typing goes straight into it.",
    "verify": "1. Click a card so the grid has focus. 2. Press ⌘F. 3. Confirm in the tree the search field is focused. 4. Type 'fixture_2' with key events and confirm the field value and that exactly one card remains.",
    "origin": "qa",
    "novelty": "obvious",
    "added_in": 3
  },
  {
    "id": "H34",
    "class": "hard",
    "text": "Each capture records the frontmost app at capture time; the card shows it as a caption and searching the app name finds the card.",
    "verify": "1. Activate Finder (open -a Finder, no settings change). 2. Write fixtures/fixture_2.png to the pasteboard; wait for the card. 3. Read the card text in the tree and confirm a caption containing 'Finder'. 4. Type 'Finder' in search and confirm that card is present. 5. Quit and relaunch and confirm the caption persists. 6. Capture a file dropped in the watch folder and confirm its card shows a caption or no caption, never a wrong or blank-label placeholder.",
    "origin": "I-3-1",
    "novelty": "new",
    "added_in": 3
  },
  {
    "id": "H35",
    "class": "hard",
    "text": "Identifiers found by OCR (ticket IDs like ZD-48213, URLs, HTTP/error codes) appear as chips in the preview text panel; clicking a chip copies it, and searching the exact identifier finds the card.",
    "verify": "1. Render a test image containing 'ZD-48213 https://example.com/a 503' with a small swift/AppKit script into the scratchpad (not the repo) and copy it into the watch folder. 2. Wait up to 10 s for OCR. 3. Open its preview and the text panel; confirm chips for ZD-48213 and the URL in the tree. 4. Click the ZD-48213 chip, read the pasteboard with a shell helper and confirm the text 'ZD-48213' and a toast. 5. Search 'ZD-48213' and confirm the card is shown.",
    "origin": "I-3-2",
    "novelty": "new",
    "added_in": 3
  },
  {
    "id": "H36",
    "class": "hard",
    "text": "The recognised-text panel offers a Copy text button and its text is selectable; the button puts the full recognised text on the pasteboard.",
    "verify": "1. Open the preview of the fixture_1 capture and the text panel. 2. Confirm a 'Copy text' button and a text element that is selectable in the tree. 3. Click the button; confirm a toast and that the pasteboard holds a string containing 'Invoice 4821' and no image type is required.",
    "origin": "outsider",
    "novelty": "obvious",
    "added_in": 3
  },
  {
    "id": "H37",
    "class": "hard",
    "text": "While a search is active, each matching card shows why it matched: a snippet line with the matched term in context (OCR text) or the filename (filename match).",
    "verify": "1. Capture fixture_1.png and fixture_2.png. 2. Search 'invoice'; confirm the remaining card shows a snippet containing 'Invoice' in the tree. 3. Search 'fixture_2'; confirm the card shows its filename. 4. Clear search and confirm the snippet line disappears and the card layout returns to normal.",
    "origin": "outsider",
    "novelty": "new",
    "added_in": 3
  },
  {
    "id": "H38",
    "class": "hard",
    "text": "Cards in a row share one fixed-height thumbnail bay: with mixed aspect ratios the date and size lines of all cards in a row have the same vertical position, and thumbnails are still not cropped.",
    "verify": "1. Capture a 3:2 fixture, a square capture (4100×4100 or sips-padded) and a portrait image so they sit in one row. 2. Read the frames of the date and size text elements in the tree and confirm equal y within 1 pt across the row. 3. Screenshot and confirm the square and portrait images are shown whole inside their bay. 4. Confirm there is no gap taller than one gutter under the Pinned row when pinned cards exist.",
    "origin": "qa",
    "novelty": "new",
    "added_in": 3
  },
  {
    "id": "H39",
    "class": "hard",
    "text": "Settings shows a 'Next to go' strip with thumbnails of the oldest unpinned captures that the current retention setting will remove next, and pinned captures never appear in it.",
    "verify": "1. Capture 5 fixtures and pin the oldest. 2. In Settings read the Next to go strip; with 'Keep last 500' confirm it is empty or states that nothing is due. 3. Set N=3 captures: confirm the strip is not stale and the summary names the number removed, and that the strip never lists the pinned capture. 4. Add a new capture and confirm the strip and summary update without reopening Settings.",
    "origin": "I-3-5",
    "novelty": "new",
    "added_in": 3
  },
  {
    "id": "S09",
    "class": "soft",
    "text": "OCR-pending motion: while OCR runs, a soft scan line sweeps once down the card thumbnail and a shimmer replaces any 'No text' label; when done, the result settles in with a spring (under 0.6 s).",
    "verify": "1. Start frame capture. 2. Copy fixture_large.png into the watch folder. 3. In frames confirm a thin line moves down the new card's thumbnail and no 'No text' label shows while OCR is pending. 4. After OCR finishes confirm the settle animation is smooth and not a pop. Score on subtlety and polish. Also screenshot the preview with a vivid fixture and judge that the info bar and chrome stay legible (no blob or colour bleed behind text).",
    "origin": "I-3-10",
    "novelty": "new",
    "added_in": 3
  },
  {
    "id": "H40",
    "class": "hard",
    "text": "A second global hotkey ⌃⌥⌘L toggles the Clothesline: a borderless strip panel docked to the top edge of the main screen, below the menubar, showing the newest captures as thumbnails hung by pegs, newest first. The same hotkey or Esc hides it again.",
    "verify": "1. Capture three fixtures. 2. With ShotBox active, send ctrl+alt+cmd+l via the automation tool. 3. Read the tree: a window/panel named 'Clothesline' exists, its frame x equals the screen's left edge, its width equals the screen width, its top is at the menubar's bottom edge, it has no title bar, and it holds at least three peg-card elements in newest-first order. 4. Screenshot. 5. Press Esc and confirm the panel is gone from the tree; press the hotkey twice and confirm shown then hidden. 6. Confirm the main ShotBox window was not forced open by the toggle.",
    "origin": "human",
    "novelty": "new",
    "added_in": 1
  },
  {
    "id": "H41",
    "class": "hard",
    "text": "Clipboard is the primary capture path: pasteboard images are captured with no watch folder involved, Settings has an 'Also watch a screenshot folder' toggle that switches folder capture on and off, and the empty state names the clipboard shortcut ⌘⌃⇧4 before the file shortcuts.",
    "verify": "1. Fresh data dir: read the empty state in the tree and confirm ⌘⌃⇧4 (or 'copy to clipboard') appears before ⌘⇧3/4/5. 2. Open Settings and confirm the toggle exists. 3. Turn it off; copy fixture_1.png into $SHOTBOX_WATCH_DIR, wait 5 s, confirm no new card; write fixture_2.png to the pasteboard and confirm a card within 5 s. 4. Turn the toggle on, drop fixture_3.png in the folder, confirm a card. 5. Relaunch and confirm the toggle state persisted.",
    "origin": "human",
    "novelty": "new",
    "added_in": 1
  },
  {
    "id": "H42",
    "class": "hard",
    "text": "Storage stays small: Settings has 'Shrink full images after N days'. Past that age an unpinned capture's full image is replaced by a compressed copy (long edge at most 1600 px, lossy), while the row, thumbnail and OCR text stay and remain searchable; the card is marked as compressed and clicking it still copies an image. Settings shows the total size on disk, which drops after shrinking.",
    "verify": "1. Capture fixture_large.png and fixture_1.png; note file sizes in $SHOTBOX_DATA_DIR/images and the total shown in Settings. 2. Quit; with sqlite3 set created of fixture_large's capture to 40 days ago (QA data only); set N=30 in Settings or relaunch with it persisted. 3. Relaunch and wait up to 10 s. 4. Confirm the image file for that capture is smaller and `sips -g pixelWidth` is at most 1600, the DB row and thumbnail still exist, and the card shows a compressed marker in the tree. 5. Search a word from its OCR text and confirm the card is found. 6. Click the card and confirm an image on the pasteboard. 7. Confirm the Settings total dropped. 8. Confirm a pinned capture aged the same way is not shrunk.",
    "origin": "human",
    "novelty": "new",
    "added_in": 1
  },
  {
    "id": "H43",
    "class": "hard",
    "text": "Duplicates never pile up: an image whose content already exists in the library is not stored again, however long ago the first one was captured, and ShotBox shows a toast and brings the existing card to the front of the selection instead.",
    "verify": "1. Capture fixture_1.png via the pasteboard; note count N and data-folder file count. 2. Quit; with sqlite3 set created of that capture to 3 days ago; relaunch. 3. Write fixture_1.png to the pasteboard again and drop the same file into the watch folder. 4. Wait 6 s. 5. Confirm count is still N, the file count is unchanged, a toast naming 'Already saved' (or similar) appeared for the pasteboard copy, and the existing card is selected and visible.",
    "origin": "human",
    "novelty": "new",
    "added_in": 1
  },
  {
    "id": "H44",
    "class": "hard",
    "text": "Clicking a card in the Clothesline copies its image to the pasteboard, shows a 'Copied' confirmation, and retracts the strip within 1 s so the user can paste straight away.",
    "verify": "1. Capture two fixtures; write short text to the pasteboard. 2. Open the Clothesline with ctrl+alt+cmd+l. 3. Click a peg card with the real pointer. 4. Within 1 s confirm a 'Copied' toast was shown, the pasteboard holds image data whose dimensions equal the fixture's, and the Clothesline panel is gone from the tree. 5. Wait 5 s and confirm the capture count did not change.",
    "origin": "human",
    "novelty": "new",
    "added_in": 1
  },
  {
    "id": "H45",
    "class": "hard",
    "text": "Count and toast copy is tidy: the menubar count reads '1 capture' for one and 'N captures' otherwise, and the 'Copied' toast in the preview never covers an info-bar button (Text, Close or any action).",
    "verify": "1. With exactly one capture, open the menubar menu and confirm the item reads '1 capture'; with two it reads '2 captures'. 2. Open a preview, click Copy, and while the toast is visible read the frames of the toast and of every info-bar button in the tree. 3. Confirm the toast frame does not intersect any button frame. 4. Screenshot to confirm.",
    "origin": "qa",
    "novelty": "obvious",
    "added_in": 1
  },
  {
    "id": "S10",
    "class": "soft",
    "text": "Clothesline craft and motion: the line drops from the top edge on a spring (under 0.6 s) with thumbnails hanging from visible pegs and settling with a faint pendulum sway; cards keep their aspect (never cropped), stay legible over any wallpaper (material backing, shadow under the line), and hide with a quick rise. With Reduce Motion the sway is dropped.",
    "verify": "1. Start frame capture. 2. Toggle the Clothesline with ctrl+alt+cmd+l. 3. In frames confirm the strip descends smoothly from the top edge, pegs are visible at each card's top, cards swing a few degrees and settle without a pop, and the hide is a quick rise. 4. Screenshot the strip over a busy background and judge legibility of date and size text and the peg detail. Score on charm, restraint and spring feel.",
    "origin": "human",
    "novelty": "new",
    "added_in": 1
  },
  {
    "id": "M07",
    "class": "manual",
    "text": "Moving the pointer to the very top edge of the screen and resting there briefly slides the Clothesline down; moving away retracts it. Normal use of the menubar does not trigger it by accident.",
    "verify": "Human: push the pointer to the top edge of the screen and hold for about half a second; confirm the line slides down. Move the pointer away and confirm it retracts. Open menubar items of other apps and confirm the line does not appear unexpectedly. Also confirm it does not appear when dragging a window under the top edge.",
    "origin": "human",
    "novelty": "new",
    "added_in": 1
  },
  {
    "id": "H46",
    "class": "hard",
    "text": "A card states honestly how it arrived: a pasteboard capture shows 'from <App>' only when the frontmost app was known; a capture from the watch folder shows 'Screenshot folder' in a quieter style and never an app name (in particular never 'ShotBox'); searching an app name finds only true app captures.",
    "verify": "1. Activate Finder (open -a Finder). 2. Write fixtures/fixture_2.png to the pasteboard; wait for the card; read its provenance text in the tree and confirm it names Finder. 3. Copy fixtures/fixture_3.png into $SHOTBOX_WATCH_DIR while ShotBox is frontmost; confirm its card reads 'Screenshot folder' (or equivalent) and contains neither 'ShotBox' nor 'Finder'. 4. Search 'ShotBox' and confirm no card is shown for the folder capture; search 'Finder' and confirm only the pasteboard capture. 5. Screenshot and confirm the folder caption is visibly quieter than an app caption. 6. Relaunch and confirm both captions persist.",
    "origin": "I-3-7",
    "novelty": "new",
    "added_in": 3
  },
  {
    "id": "H47",
    "class": "hard",
    "text": "Each capture keeps a custody log of what the user did with it (copied, opened in Preview, text copied, chip copied) with times; the card shows a quiet 'Used N×' line once N is above zero, the preview lists the events newest first, and the log survives relaunch without creating duplicate captures.",
    "verify": "1. Capture fixture_1.png; confirm its card has no 'Used' line. 2. Click the card (copy), then click again after 2 s, then open its preview and click 'Copy text'. 3. Confirm the card now reads 'Used 3×' (or the equivalent count) and that the preview shows an event list with 'Copied', 'Copied', 'Text copied' (or similar) and a time on each, newest first. 4. Double-click the card to open Preview, close that Preview window, and confirm the count rose by one with an 'Opened' entry. 5. Confirm the capture count did not change (H13). 6. Quit, relaunch with the same data dir, and confirm the same count and list. 7. Delete the capture and confirm its log rows are gone: `sqlite3` shows no orphan event rows.",
    "origin": "I-3-1",
    "novelty": "new",
    "added_in": 3
  },
  {
    "id": "H48",
    "class": "hard",
    "text": "Type-to-find on the Clothesline: with the strip down, typing characters (no search field needed) filters the pegs by OCR text, identifier or app name, non-matching prints leave the line, Return or a click copies the first or clicked match, and Esc clears the filter before it hides the strip.",
    "verify": "1. Capture the ZD-48213 test image from H35 plus fixture_1.png and fixture_2.png. 2. Open the Clothesline with ctrl+alt+cmd+l. 3. Type '48213' with key events (no click first). 4. Read the tree: exactly one peg-card remains and a visible query label shows '48213'. 5. Press Return; confirm a 'Copied' toast and that the pasteboard holds an image with that capture's dimensions, and the strip retracts within 1 s. 6. Reopen, type 'zzzqq' and confirm an empty-line message that echoes the query. 7. Press Esc once: the filter clears and all pegs return with the strip still shown; press Esc again: the strip hides. 8. Confirm the main ShotBox window was not opened.",
    "origin": "I-3-9",
    "novelty": "new",
    "added_in": 3
  },
  {
    "id": "H49",
    "class": "hard",
    "text": "The 'Compressed' marker is a slim corner ribbon on the thumbnail rather than a text label, and activating it shows a seal note stating when the capture was shrunk, its size and pixel dimensions before and after, and that the thumbnail and recognised text were kept.",
    "verify": "1. Prepare a compressed capture as in H42 (fixture_large.png aged 40 days in QA data, relaunch, wait 10 s). 2. Screenshot the card: confirm a diagonal or corner ribbon on the thumbnail corner, not a separate caption line, and that the card's date/size rows still align with its neighbours (H38). 3. Click or press the marker; read the tree for a seal note containing a date, '6000 × 4000' and '1600 × 1067' (or the real after size), and file sizes before and after in KB/MB. 4. Confirm the note closes with Esc and that Esc does not also close the preview or clear search. 5. Confirm an uncompressed card has no ribbon.",
    "origin": "I-3-5",
    "novelty": "new",
    "added_in": 3
  },
  {
    "id": "H50",
    "class": "hard",
    "text": "With the recognised-text panel open the preview never clips or overlaps: the panel and its Copy text button lie fully inside the window, the chevrons do not intersect the panel or the info-bar buttons, and the 'Copied' toast stays anchored to one spot while the preview opens.",
    "verify": "1. Open the preview of the ZD-48213 capture and toggle the text panel. 2. At the default size, at 1280 px wide and at the minimum window size, read the frames of the window, the text panel, the 'Copy text' button, each chevron and each info-bar button in the tree. 3. Confirm every panel and button frame lies inside the window frame, the 'Copy text' label is not truncated, and no chevron frame intersects the panel or a button. 4. Click Copy; record frames while the preview opens and confirm the toast frame's x and y do not change between frames. 5. Screenshot each size.",
    "origin": "outsider",
    "novelty": "obvious",
    "added_in": 3
  },
  {
    "id": "H51",
    "class": "hard",
    "text": "The Settings window fits the screen's visible area at its default size and every section (Retention, Next to go, Storage, Shortcuts) is reachable; each toggle exposes its on/off state in the tree and the retention number accepts a typed value.",
    "verify": "1. Open Settings. 2. Read the window frame and compare with the main screen's visible frame (screen height minus menubar and Dock); confirm the window is fully inside it. 3. Confirm the Storage section's path rows are reachable by scrolling or are visible. 4. Read the value of 'Also watch a screenshot folder' and 'Launch at login' in the tree; each must be an explicit on/off value, and a screenshot must show an unambiguous difference between the states. Do not toggle Launch at login. 5. Click the retention number field, select all, type 40 and press Return; confirm the field and the summary show 40 and that the summary reads '1 capture' with singular wording when the library has one capture.",
    "origin": "qa",
    "novelty": "obvious",
    "added_in": 3
  },
  {
    "id": "S11",
    "class": "soft",
    "text": "First minute: the empty state reads as an invitation, with the shortcuts set as separate key-cap groups (clipboard shortcut first), a one-line explanation of the Clothesline, and a visible reaction when the first capture arrives (the empty state gives way to the grid with a spring, the card sliding into place).",
    "verify": "1. Launch with an empty data dir and screenshot the empty state in the main window. 2. Judge: shortcuts are visually grouped as key caps rather than one run-on string, there is a clear focal glyph or headline, and 'Clothesline' is explained in a short phrase. 3. Start frame capture, copy fixtures/fixture_1.png to the pasteboard, and in frames confirm the empty state fades or moves out and the first card enters with a spring rather than a pop. 4. Score on warmth, hierarchy and restraint.",
    "origin": "outsider",
    "novelty": "new",
    "added_in": 3
  },
  {
    "id": "S12",
    "class": "soft",
    "text": "Reflow craft: a deleted card scales and fades out in place before neighbours close the gap, neighbours slide without passing over each other, hover pin/delete buttons follow the pointer and fade out on the card it left, and the preview backdrop keeps the grid recognisable under a modest blur.",
    "verify": "1. Have 8 captures; start frame capture. 2. Delete a middle card with the context menu or hover button; in frames confirm it shrinks and fades first and neighbours then move without overlapping. 3. Move the pointer from card A to card B by clicking B; in frames confirm A's buttons fade and only B's show. 4. Open and close the preview with frame capture: confirm the grid stays recognisable (card shapes visible) under the blur, with no blank frame on close. 5. Score on smoothness and restraint.",
    "origin": "qa",
    "novelty": "obvious",
    "added_in": 3
  },
  {
    "id": "H52",
    "class": "hard",
    "text": "The Clothesline feels instant: the first frame showing the line comes within 50 ms of the hotkey, the drop settles in about 350 ms (at most 400 ms), and opening does no work. The panel, its layout and the thumbnails are ready before the trigger, so no thumbnail is decoded and no database query runs on the open path. This holds on the first open after launch and with 200 captures in the library.",
    "verify": "1. Launch with SHOTBOX_TRACE=<scratchpad>/trace.log (app-only env var; the app appends timestamped lines 'hotkey', 'clothesline.firstFrame', 'clothesline.settled' and 'clothesline.openWork decoded=<n> queries=<n>'). 2. Load 200 distinct captures (images made with sips in the scratchpad and copied into $SHOTBOX_WATCH_DIR); wait until OCR is idle. 3. Start frame capture at the highest rate the tool offers, then send ctrl+alt+cmd+l. 4. From the trace confirm firstFrame minus hotkey is at most 50 ms, settled minus hotkey is at most 400 ms, and decoded=0 queries=0. 5. In the captured frames confirm the first frame that shows any part of the line is no later than one capture interval after the key event, and that the line is at rest by about 0.4 s. 6. Repeat 5 times (hide with Esc between) and also right after a fresh relaunch; every run must meet the budget. 7. Confirm hiding also starts within 50 ms of Esc (trace or frames).",
    "origin": "human",
    "novelty": "obvious",
    "added_in": 1
  },
  {
    "id": "H53",
    "class": "hard",
    "text": "With more than one display, the Clothesline opens on the screen that holds the pointer, for both the hotkey and the top-edge dwell. It spans that screen's full width at that screen's top edge, below that screen's menubar when it has one, and never opens on the main screen when the pointer is elsewhere.",
    "verify": "Needs a second display already connected; do not change any display arrangement or setting. If only one display is attached, report 'unverified' with the reason. 1. Read all NSScreen frames and visibleFrames with a small read-only swift script in the scratchpad and convert them to top-left coordinates for comparison with the accessibility tree. 2. Move the pointer with the automation tool to the middle of the external display and send ctrl+alt+cmd+l. 3. Read the 'Clothesline' panel frame: its x and width equal that display's frame, its top equals that display's visibleFrame top (within 1 pt), and it lies wholly inside that display. 4. Hide it, move the pointer to the very top edge of the external display and rest it there for 0.7 s: the panel appears on that display with the same frame checks. 5. Move the pointer back to the main screen, send the hotkey and confirm the panel now matches the main screen's frame. 6. Screenshot each case. 7. Confirm the trace budget from H52 also holds on the external display.",
    "origin": "human",
    "novelty": "obvious",
    "added_in": 1
  },
  {
    "id": "H54",
    "class": "hard",
    "text": "The library window stays responsive at 200 captures. A click selects and copies within 200 ms, a delete removes the card within 300 ms, a search filter applies within 250 ms of the last keystroke, every click and arrow key registers, and the app is quiet when idle (under 3% CPU, under 300 MB resident memory).",
    "verify": "1. Load 200 distinct captures as in H52 and wait until OCR is idle. 2. Click 20 different cards (including ones in the last visible row): each must show the selection and a 'Copied' toast in the tree within 200 ms, and none may be missed. 3. Select a middle card and press ⌫: the card must be gone from the tree within 300 ms. 4. Type 'BK' into search: the filtered count must be applied within 250 ms of the last key event. 5. Open a preview and press Right 10 times at about 150 ms intervals: the info-bar filename must have advanced exactly 10 times. 6. Leave the app idle for 10 s, then sample `ps -o %cpu,rss -p <pid>` once a second for 10 s: mean CPU under 3% and RSS under 300 MB.",
    "origin": "qa",
    "novelty": "obvious",
    "added_in": 1
  },
  {
    "id": "H55",
    "class": "hard",
    "text": "Each capture has a permanent tray address in place of the layout-derived cell label (A1, B2). The address is its capture day plus its arrival number that day, for example '10 OCT · 07', with the year added only for past years. It never changes when anything is pinned, deleted, captured, resized or relaunched, and numbers of deleted captures are not reused. The grid's column letters go away. The same address appears on the card, in the preview info bar and in the Clothesline caption, and searching the address finds the card.",
    "verify": "1. With an empty data dir capture four fixtures on the same day; read each card's address in the tree (cardAddress-<id>) and confirm the numbers run 01–04 in arrival order with today's date. 2. Confirm no column-letter header (A, B, C…) exists in the tree. 3. Pin the oldest, delete the second, resize the window to the minimum and to 1500 px wide, and confirm every surviving card keeps exactly its address. 4. Capture another fixture and confirm it gets 05, not 02. 5. Quit and relaunch, and confirm all addresses are unchanged. 6. Open a preview and confirm the info bar shows the same address; open the Clothesline and confirm each print's caption shows its address. 7. Search the address of the third capture (as shown, and in the compact form '10·03') and confirm exactly that card is shown. 8. Quit; with sqlite3 set one capture's created date to 40 days ago (QA data only) and give it no other change. Relaunch and confirm its address is unchanged, because the address is assigned once and stored.",
    "origin": "I-1-1",
    "novelty": "new",
    "added_in": 1
  },
  {
    "id": "H56",
    "class": "hard",
    "text": "Search results show their evidence. A result count reads like '1 of 200'. The snippet emphasises only the matched term, not the whole line. For an OCR match, an enlarged callout of the matched word in the accent colour sits on the thumbnail at the spot where Vision found it. Filename matches get no callout, and clearing search removes all of it.",
    "verify": "1. Render a 1200×800 test image in the scratchpad with a small word 'TOPAZ-77' in the lower-right quadrant and other text elsewhere; copy it plus fixture_1.png and fixture_2.png into the watch folder; wait up to 10 s for OCR. 2. Type 'topaz' in search. 3. Confirm a count label reading '1 of 3' (or the real total) in the tree. 4. Read the callout element (matchCallout-<id>) and the thumbnail frame: the callout frame lies inside the thumbnail and its centre is in the thumbnail's lower-right quadrant. 5. Screenshot: the callout is legible and in the accent colour, and in the snippet only 'TOPAZ' is emphasised. 6. Search 'fixture_2' and confirm no callout on that card. 7. Clear search and confirm no callout or count label remains.",
    "origin": "I-1-4",
    "novelty": "new",
    "added_in": 1
  },
  {
    "id": "H57",
    "class": "hard",
    "text": "One identity, plain words. The card anatomy (address, mono date and size, provenance, a single selection signal) is the same in light and dark appearance. Visible copy has no internal jargon ('first pass', 'decay', 'custody', 'pegged'). Dates use one format everywhere, numbers are never locale-grouped ('1200 × 800' on cards, preview and Clothesline), and the warning colour is used only when something will actually be removed.",
    "verify": "1. Launch with SHOTBOX_APPEARANCE=light, then with SHOTBOX_APPEARANCE=dark (app-only override; never change the system appearance). With the same 4 captures, confirm the tree contains the same per-card elements in both runs (address, date, size, provenance) and screenshot both; the selected card shows one selection treatment, not two. 2. Collect all visible static texts from the empty state, main window, preview, Settings and Clothesline; confirm none contains 'first pass', 'decay', 'custody' or 'pegged' (case-insensitive). 3. Capture something and age another capture to 40 days with sqlite3 (QA data only); confirm the card, the preview info bar and the seal note all use the same date style (relative for today/yesterday, otherwise one fixed day-month-year format), and the seal note does not read 'On Today'. 4. Confirm every pixel-size string in the grid, preview and Clothesline matches the regex '^[0-9]+ × [0-9]+$'. 5. In Settings with 0 captures due, screenshot the retention summary and confirm it is in a neutral label colour; type a draft that removes some and confirm it turns to the warning colour.",
    "origin": "outsider",
    "novelty": "obvious",
    "added_in": 1
  },
  {
    "id": "H58",
    "class": "hard",
    "text": "Esc lands you where it lives: with a search result selected, Esc clears the search, keeps that card selected, scrolls the full grid so the card is visible in its home position, and briefly marks its two neighbours in time (the captures just before and after it).",
    "verify": "1. Load 60 captures so the target sits well below the first screen; include the TOPAZ-77 image from H56 among the older ones. 2. Search 'topaz', select the single result with an arrow key. 3. Press Esc. 4. Within 0.5 s confirm in the tree: the search field is empty, all cards are back, the TOPAZ card is still the selected one, and its frame lies inside the visible scroll area. 5. Within 1 s confirm a neighbour mark (element or trait) on the cards whose capture times are directly before and after it, and that the mark is gone after about 2 s. 6. Confirm Esc with a preview open still closes the preview first (H21) and does not clear the search.",
    "origin": "I-1-3",
    "novelty": "new",
    "added_in": 1
  },
  {
    "id": "S13",
    "class": "soft",
    "text": "Matches leave from home: when a query narrows the grid, the matching cards first light up in their own slots while the rest dim (about 150 ms), then glide to the packed result layout as the others fade. Clearing search plays it in reverse so each card is seen returning home. Paths never cross a neighbour, and the whole sequence stays under 0.6 s.",
    "verify": "1. Have 20 captures with the TOPAZ-77 image in the third row. 2. Start frame capture at the highest rate available. 3. Type 'topaz' quickly. 4. In frames confirm a beat where the matching card is highlighted in its original slot while others dim, followed by a continuous glide to the first slot, with no jump cut. 5. Clear search and confirm the reverse. 6. Score on legibility of where the result came from, restraint and spring feel; deduct for any card passing over another.",
    "origin": "I-1-2",
    "novelty": "new",
    "added_in": 1
  }
]
```

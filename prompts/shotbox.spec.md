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

## Screens

### Menubar item
- Template-style icon in the menubar. Clicking opens a small menu: "Open ShotBox", count of captures, "Pause capturing" toggle, "Settings…", "Quit ShotBox".
- Pausing stops both folder watching and pasteboard capture until resumed; menu item reflects state.

### Main window ("ShotBox")
- Standard resizable macOS window, minimum about 640×480, with a toolbar containing a search field, a size-of-thumbnail slider, and a Settings button.
- Body: adaptive thumbnail grid. A "Pinned" section header appears above pinned cards when any exist; the rest follow, newest first.
- Card: thumbnail (aspect-fit, rounded corners), date line (relative for today/yesterday, otherwise short date and time), size line (pixel dimensions, e.g. "1920 × 1080"), small pin glyph when pinned. Hover reveals pin and delete buttons. Selected card shows an accent outline.
- Context menu on card: Copy, Open in Preview, Pin/Unpin, Reveal in Finder, Delete.
- Empty state (no captures): friendly illustration-free message explaining how to take a screenshot, and the hotkey. No-results state when search matches nothing, with the query echoed and a "Clear search" button.
- Keyboard: arrow keys move selection in the grid, Return/Space opens preview, ⌘C copies selection, Delete/⌫ deletes selection, ⌘F focuses search, ⌘P pins/unpins selection, Esc clears search or closes preview.

### Full preview
- Selecting open expands the card into a large view over a blurred grid. Shows image fit to window, a bottom info bar (filename, date, pixel size, file size, whether text was recognised), and buttons: Copy, Open in Preview, Pin, Delete, Close.
- Left/Right arrow keys, trackpad swipe, and on-screen chevrons move to the previous/next capture in the current (filtered) ordering. At the ends navigation does nothing visible beyond a gentle bounce.
- Recognised text can be revealed in a side panel and selected/copied as text (toggle button).

### Settings
- Retention: segmented choice "Keep last N captures" or "Keep last N days", numeric field/stepper for N. Pinned captures are never removed. Changes apply immediately and are described in a one-line summary ("Currently 512 captures; 12 would be removed" or similar).
- Global hotkey display (fixed to ⌃⌥⌘S is acceptable; a recorder is a bonus).
- Launch at login toggle.
- Storage: shows data folder path, total size on disk, and watched folder path. "Reveal in Finder" button.

## Data model (high level)

- **Capture**: id, filename, file path inside the data folder, created date, pixel width/height, file size in bytes, source (screenshot-file or pasteboard), pinned flag, pin date, recognised text (may be empty), OCR status (pending/done/failed), content hash.
- Image files are stored on disk in the data folder; thumbnails are cached on disk as well. SQLite holds metadata and recognised text, with a search index (or equivalent) over filename and OCR text.
- Settings (retention mode and N, launch at login, paused) are persisted across launches.
- Duplicate protection: identical content captured twice within a short window (for example a screenshot file that also appears on the pasteboard) yields one capture.
- Retention runs at launch, after each new capture and on setting change; it never removes pinned captures and removes both the row and the files.

## Visual design language

- Native macOS feel: system materials (.regularMaterial / .ultraThinMaterial), SF Pro, SF Symbols, system accent color, full light and dark mode support.
- Grid is airy: 16 pt gutters, 10 pt corner radius on thumbnails, soft shadow that deepens on hover, thumbnails never cropped.
- Typography: filename/date in 12 pt medium secondary-label color, size in 11 pt tertiary. Section headers small caps-style 11 pt semibold.
- Motion is spring-based (response about 0.35–0.45, damping about 0.8), never linear; durations stay under 0.6 s; respects Reduce Motion by falling back to quick cross-fades.
- Transient feedback ("Copied") is a small capsule toast at the bottom of the window with fade in/out, auto-dismissed after about 1.5 s.
- The three hero interactions listed above are the signature of the app and must feel polished.

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
  }
]
```

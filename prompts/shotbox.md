# ShotBox: screenshot clipboard

A menubar macOS app that keeps every screenshot you take, shows them in a grid, and lets you
search, pin and re-copy them. Screenshots only; text and other clipboard content is ignored.

## Constraints (fixed; do not relax them)

- Captures screenshots from ⌘⇧3 / ⌘⇧4 / ⌘⇧5 and any image copied to the pasteboard. Nothing else.
- Menubar icon plus a separate window. The window shows a thumbnail grid with date and size, search
  over filename and OCR text, pin, delete.
- Every capture is written to disk; metadata in SQLite. Quit and relaunch, everything is still there.
- Click copies back to the pasteboard, double-click opens in Preview, drag out to other apps.
- Global hotkey opens the window.
- OCR via the Vision framework for searchable text. This is the app's "AI feature"; no model API calls.
- Retention setting: keep last N captures or last N days.
- Stack: Swift, SwiftUI, SQLite (GRDB or raw sqlite3), macOS 14+. No third-party UI frameworks.

## Motion, as three named hero interactions (soft criteria)

- Grid → full preview: the selected card expands into the preview (matchedGeometryEffect), background blurs.
- Preview navigation: arrow keys or swipe slide to the neighbour like a slider; current image scales
  down slightly as it leaves.
- New capture: enters at the head of the grid with a slide, the rest make room. Pin and delete
  animate the card out of place.

## Known friction, decided up front

- Screen Recording and Accessibility permissions are granted by hand once during init and noted in
  spec.md; agents must not try to work around them.
- Drag-out and hotkey-from-another-app are manual criteria.
- Target 25 to 30 hard criteria in the spec. If the planner produces more than 40, trim before round 1.

## Harness notes (how this workspace builds and runs)

- The app is a Swift package (Package.swift, Sources/ShotBox/) that ./build.sh wraps into
  build/ShotBox.app, signed with a stable identity so permission grants survive rebuilds.
  This replaces the xcodebuild/Xcode project in the original brief.
- ./run.sh launches the built app and waits for its window. It sources test.env, which sets
  SHOTBOX_WATCH_DIR, SHOTBOX_DATA_DIR and SHOTBOX_OPEN_WINDOW=1 for QA. The app should open its window
  on launch (or when launched with the environment variable SHOTBOX_OPEN_WINDOW=1).
- macOS saves ⌘⇧3/4/5 screenshots to the Desktop by default (the `com.apple.screencapture location`
  default overrides it). Reading the Desktop needs a one-time permission grant.
  For tests, the folder to watch can be overridden with the SHOTBOX_WATCH_DIR environment variable,
  and the data folder with SHOTBOX_DATA_DIR, so QA never touches the user's real screenshots.
- Test images are in fixtures/ (fixture_large.png is 6000×4000).

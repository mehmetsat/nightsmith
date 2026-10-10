# Clothesline brief, pass 2

The line now has a real rope, pegs, tilt and prints. The human used it on their own Mac and found two
problems. Fix these first, then raise the craft.

## 1. It must feel instant (the human's first complaint)

- The line comes down late. Targets: motion starts within 50 ms of the trigger; the drop settles in
  350 ms or less; the pointer dwell at the top edge is 150 ms at most.
- Do no work at open time. Keep the panel created and ordered front (transparent while hidden),
  keep the prints laid out, and decode thumbnails ahead of time at the size they are shown.
  Opening only changes opacity and offsets.
- Drive the motion with Core Animation or SwiftUI springs on the GPU, not a main-thread timer that
  redraws the whole view each frame. No frame drops at 120 Hz on a large screen.

## 2. It must open on the screen the user is looking at (the human's second complaint)

- With an external display connected, moving the pointer to the top edge of that display brings the
  line down on that display, not on the main screen.
- The hotkey (⌃⌥⌘L) opens it on the screen that currently holds the pointer.
- Each screen gets the line sized to its own width, under its own menu bar. Moving between screens
  while it is open moves it (or closes it on the old one and opens on the new one).

## 3. Still open from QA

- H40 (opening and toggling the Clothesline), H48 (type-to-find on the line), S10 (drop, swing and
  settle craft) fail because they need changes here.
- The last critique: the opening motion was never visible as a spring, the same caption repeated on
  every print was clutter, every peg looked the same, and real screenshots were too small to read.

## Keep

Everything that works: the rope with weight, two pegs per print, the pinned clip, the basket of older
captures, type-to-search, Space to look closer, ⌘1–9 to copy, OCR chips, clipboard-first.

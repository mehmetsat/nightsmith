# Clothesline design brief

The best existing product for this idea (Tendedero, see the reference images) is a clean, plain
line of glass frames. Beat it by being more physical and more useful at once.

## The idea

- **The line is "now", the basket is "the past".** The last few captures hang on the line. Pull the
  line further down (keep the pointer there, scroll, or press the hotkey again) and a basket of
  older captures opens below it: the searchable history, the same library the main window shows.
- **Type to search, on the line.** While the line is down, typing filters it: captures that do not
  match unpeg and drop softly out of view, the matches stay pegged and slide together. Escape
  brings everything back.
- **Physics with meaning.** A real rope with weight: it sags more as more captures hang, and bounces
  a little when a new one is pegged on. Each capture hangs from one or two wooden pegs with a small
  natural tilt (about ±3°) and a soft shadow, like a print with a white border.
- **Pegs carry information.** The peg's colour shows the source app. A pinned capture has a distinct
  peg (for example a metal clip) and never drops off the line.
- **Text from OCR is visible.** Ticket ids, URLs and error codes found in a capture appear as small
  chips on the hanging print; clicking a chip copies just that text.

## Must stay true

- Clipboard first: a click copies the image and the line tucks away, so the user can paste at once.
- Nothing on the line is a file on the Desktop. Storage stays small.
- It belongs under the macOS menu bar: light and dark, no clutter, no heavy chrome.
- Real screenshots (fixtures/real_*.png) stay recognisable at a glance.

## Motion

- Drop: a spring under 0.6 s, the prints swing and settle with damping. Retract: quick and clean.
- New capture: enters from the left, gets pegged, the rope bounces, the others shift along.
- Hover: the print under the pointer lifts slightly towards the user.
- Reduced Motion: cross-fades instead of swings.

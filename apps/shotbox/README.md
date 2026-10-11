# ShotBox

A menubar app for screenshots you copy instead of saving. Nightsmith's agents built all of it.
This is the build from the run `polish1`.

- **Clothesline.** Move the pointer to the top edge of any screen, or press ⌃⌥⌘L. Recent captures
  drop down on a rope. Click one to copy it. Type to filter. Older captures are in the basket.
- **Library.** Every capture is kept and searchable by the text inside it (on-device OCR).
- **Clipboard first.** Nothing has to be saved to the Desktop.

```bash
./build.sh && ./run.sh            # debug build, as the agents use it
../../scripts/release.sh          # release DMG in dist/
```

`spec.md` holds the criteria the agents tested against.

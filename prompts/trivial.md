# Counter

A one-button macOS app for testing the harness loop.

Constraints:
- One window. A button labelled "Count" and a label showing how many times it was pressed, starting at 0.
- A "Reset" button sets the count back to 0.
- The count survives quit and relaunch (UserDefaults is fine).
- Stack: Swift, SwiftUI, macOS 14+. A Swift package built by ./build.sh. No third-party frameworks.

Criteria target: 5 to 8 hard criteria, 1 soft criterion, no manual criteria. Keep the spec short.

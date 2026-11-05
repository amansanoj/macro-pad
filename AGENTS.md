# Agent notes

- Keep the product name `macro-pad` in user-facing text and repository artifacts.
- Keep firmware and macOS protocol constants synchronized with `docs/protocol.md`.
- Do not claim physical BLE or switch verification without a real ESP32-WROOM-32 test.
- Use public Apple APIs. Do not add private media-control APIs.
- Run the Xcode build and test suite after Swift changes; compile firmware for `esp32:esp32:esp32` when Arduino CLI and pinned dependencies are available.

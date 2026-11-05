# Troubleshooting

## Device is not discovered

- Confirm the board is an original ESP32-WROOM-32/ESP32 Dev Module, not an ESP32-S3 target.
- Open Serial Monitor at 115200 baud and look for `macro-pad ready`.
- Confirm firmware and app use the UUIDs in `docs/protocol.md`.
- Turn Bluetooth back on if the app reports it is unavailable.
- Forget the selected device in macro-pad Settings before selecting a replacement board.

## A key does not change state

- Connect one switch terminal to its documented GPIO and the other to GND.
- Do not wire the switch to 3.3 V. `INPUT_PULLUP` makes released read HIGH; pressing must connect the input to GND and read LOW.
- Check for a shared ground and test each switch independently.
- Mechanical bounce shorter than 20 ms is filtered intentionally.

## A shortcut does not run

Keyboard event posting requires Accessibility access. Open **macro-pad → Settings → Permissions**, request access, and confirm macro-pad is enabled in **System Settings → Privacy & Security → Accessibility**.

## A shortcut runs while it is being recorded

Protected recording also requires Accessibility access. The recorder creates an active Quartz event tap only while it has focus and removes it immediately after capture, cancellation, focus loss, window closure, application deactivation, or tap failure. If the tap cannot be created, macro-pad reports the failure and provides **Enter shortcut manually** instead of capturing through an unsuppressed local monitor.

Common application shortcuts and screenshot shortcuts are filterable through the session event tap when permission is granted. Secure or system-reserved combinations, including Lock Screen and some system switching shortcuts, are not guaranteed by macOS to reach a third-party session tap on every release or security configuration. Use the manual editor for combinations that the operating system handles before the tap.

## A command fails

Shell actions execute an absolute program path directly with a separate argument array. Shell syntax such as pipes, redirects, variable expansion, aliases, and `~` is not interpreted. Use a trusted script file as the executable when shell behavior is genuinely needed. The app captures stdout, stderr, exit status, and terminates a command after its configured timeout.

## Media controls

macOS does not expose a supported public API for arbitrary system-wide play/pause, next, previous, volume, and mute control from a third-party utility. macro-pad does not use private APIs or synthetic undocumented media-key events. Create an Apple Shortcut for the desired media app and assign that shortcut instead.

## Configuration recovery

Configuration is stored in `~/Library/Application Support/macro-pad/configuration.json`. If decoding fails, macro-pad preserves the unreadable file beside it with a `corrupt-<timestamp>.json` suffix and starts with defaults.

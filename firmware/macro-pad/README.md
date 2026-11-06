# Firmware

Arduino-compatible firmware for the original ESP32-WROOM-32. It scans four active-low switches and publishes debounced transitions through the custom macro-pad BLE service.

## Dependencies

| Component | Version |
| --- | --- |
| Arduino IDE | 2.3.x |
| ESP32 board package | 3.3.12 (Arduino path) |
| NimBLE-Arduino | 2.3.7 |

Select **ESP32 Dev Module**, CPU **240 MHz**, flash **4 MB**, partition scheme **Default 4MB with spiffs**, PSRAM **Disabled**, and upload speed **921600** (use **115200** if the board is unreliable at the higher rate). Validated builds used PlatformIO Core 6.2.0 with `espressif32@6.12.0` (Arduino-ESP32 2.0.17), and Arduino CLI 1.5.1 with ESP32 core 3.3.12. Both used NimBLE-Arduino 2.3.7. Flashing and behavior still require hardware acceptance testing.

See the root README for wiring and exact Arduino CLI commands.

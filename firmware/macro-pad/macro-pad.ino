#include <Arduino.h>
#include <NimBLEDevice.h>

namespace {
constexpr char kDeviceName[] = "macro-pad";
constexpr char kServiceUuid[] = "7A4D1000-5A7E-4D2F-9C6B-4B0A3E6D0100";
constexpr char kEventCharacteristicUuid[] = "7A4D1001-5A7E-4D2F-9C6B-4B0A3E6D0100";
constexpr uint8_t kProtocolVersion = 1;
constexpr uint8_t kEventMessage = 1;
constexpr uint8_t kStateSyncMessage = 2;
constexpr uint32_t kDebounceMilliseconds = 20;
constexpr uint32_t kConnectionSettleMilliseconds = 75;

struct Button {
    uint8_t keyId;
    uint8_t gpio;
    bool rawPressed;
    bool stablePressed;
    uint32_t rawChangedAt;
};

Button buttons[] = {
    {1, 13, false, false, 0},
    {2, 14, false, false, 0},
    {3, 33, false, false, 0},
    {4, 32, false, false, 0},
};

NimBLECharacteristic* eventCharacteristic = nullptr;
volatile bool clientConnected = false;
volatile bool stateSyncPending = false;
uint32_t connectedAt = 0;
uint8_t sequenceNumber = 0;

void notifyButton(uint8_t messageType, const Button& button) {
    if (!clientConnected || eventCharacteristic == nullptr) {
        return;
    }

    const uint8_t packet[5] = {
        kProtocolVersion,
        messageType,
        button.keyId,
        static_cast<uint8_t>(button.stablePressed ? 1 : 0),
        sequenceNumber++,
    };
    eventCharacteristic->setValue(packet, sizeof(packet));
    eventCharacteristic->notify();
}

class ServerCallbacks final : public NimBLEServerCallbacks {
    void onConnect(NimBLEServer*, NimBLEConnInfo&) override {
        clientConnected = true;
        stateSyncPending = true;
        connectedAt = millis();
    }

    void onDisconnect(NimBLEServer*, NimBLEConnInfo&, int) override {
        clientConnected = false;
        stateSyncPending = false;
        NimBLEDevice::startAdvertising();
    }
};

void initializeButtons() {
    const uint32_t now = millis();
    for (Button& button : buttons) {
        pinMode(button.gpio, INPUT_PULLUP);
        const bool pressed = digitalRead(button.gpio) == LOW;
        button.rawPressed = pressed;
        button.stablePressed = pressed;
        button.rawChangedAt = now;
    }
}

void scanButtons() {
    const uint32_t now = millis();
    for (Button& button : buttons) {
        const bool pressed = digitalRead(button.gpio) == LOW;
        if (pressed != button.rawPressed) {
            button.rawPressed = pressed;
            button.rawChangedAt = now;
        }

        if (button.rawPressed != button.stablePressed &&
            static_cast<uint32_t>(now - button.rawChangedAt) >= kDebounceMilliseconds) {
            button.stablePressed = button.rawPressed;
            if (!stateSyncPending) {
                notifyButton(kEventMessage, button);
            }
        }
    }
}

void sendConnectionState() {
    if (!clientConnected || !stateSyncPending ||
        static_cast<uint32_t>(millis() - connectedAt) < kConnectionSettleMilliseconds) {
        return;
    }

    for (const Button& button : buttons) {
        notifyButton(kStateSyncMessage, button);
    }
    stateSyncPending = false;
}
}  // namespace

void setup() {
    Serial.begin(115200);
    initializeButtons();

    NimBLEDevice::init(kDeviceName);
    NimBLEDevice::setPower(ESP_PWR_LVL_P3);
    NimBLEDevice::setSecurityAuth(true, false, true);

    NimBLEServer* server = NimBLEDevice::createServer();
    server->setCallbacks(new ServerCallbacks(), true);
    NimBLEService* service = server->createService(kServiceUuid);
    eventCharacteristic = service->createCharacteristic(
        kEventCharacteristicUuid,
        NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY
    );
    const uint8_t initialPacket[5] = {kProtocolVersion, kStateSyncMessage, 1, 0, 0};
    eventCharacteristic->setValue(initialPacket, sizeof(initialPacket));
    service->start();

    NimBLEAdvertising* advertising = NimBLEDevice::getAdvertising();
    advertising->addServiceUUID(kServiceUuid);
    advertising->setName(kDeviceName);
    advertising->enableScanResponse(true);
    advertising->start();

    Serial.println("macro-pad ready");
}

void loop() {
    scanButtons();
    sendConnectionState();
    yield();
}

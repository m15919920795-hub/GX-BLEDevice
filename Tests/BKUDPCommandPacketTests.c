#include "BKUDPCommandPacket.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

static void assertCommand(uint8_t sequence, uint8_t opcode, const uint8_t *payload,
                          size_t payloadLength, const uint8_t *expected, size_t expectedLength) {
    uint8_t packet[BKUDPCommandMaximumFrameLength];
    size_t length = BKUDPCommandEncode(sequence, opcode, payload, payloadLength, packet, sizeof(packet));
    assert(length == expectedLength);
    assert(memcmp(packet, expected, length) == 0);
}

static void testOutgoingCommandBytes(void) {
    const uint8_t one[] = { 1 };
    const uint8_t name[] = { 'G', 'X' };
    const uint8_t channel[] = { 11 };
    const uint8_t keyRequest[] = { 0xcc, 0x5a, 1, 0x05, 2, 1, 7 };
    const uint8_t orientationRequest[] = { 0xcc, 0x5a, 2, 0x00, 2, 1, 1 };
    const uint8_t reverse[] = { 0xcc, 0x5a, 3, 0x01, 2, 1, 1 };
    const uint8_t wifiName[] = { 0xcc, 0x5a, 4, 0x02, 3, 'G', 'X', 0x1a };
    const uint8_t wifiChannel[] = { 0xcc, 0x5a, 5, 0x03, 2, 11, 0x0f };

    assertCommand(1, BKUDPCommandRequestImageKey, one, sizeof(one), keyRequest, sizeof(keyRequest));
    assertCommand(2, BKUDPCommandReadOrientation, one, sizeof(one),
                  orientationRequest, sizeof(orientationRequest));
    assertCommand(3, BKUDPCommandSetOrientation, one, sizeof(one), reverse, sizeof(reverse));
    assertCommand(4, BKUDPCommandSetWiFiName, name, sizeof(name), wifiName, sizeof(wifiName));
    assertCommand(5, BKUDPCommandSetWiFiChannel, channel, sizeof(channel), wifiChannel, sizeof(wifiChannel));
}

static void testReplyValidation(void) {
    const uint8_t valid[] = { 0xcc, 0x5a, 1, 0x17, 2, 1, 0x15 };
    BKUDPCommandFrame frame;
    for (size_t length = 0; length < sizeof(valid); ++length) {
        assert(BKUDPCommandDecode(valid, length, &frame) == 0);
    }
    assert(BKUDPCommandDecode(valid, sizeof(valid), &frame) == sizeof(valid));
    assert(frame.sequence == 1 && frame.opcode == BKUDPCommandRecordingEvent);
    assert(frame.payloadLength == 1 && frame.payload[0] == 1);

    uint8_t corrupted[sizeof(valid)];
    memcpy(corrupted, valid, sizeof(valid));
    corrupted[0] = 0;
    assert(BKUDPCommandDecode(corrupted, sizeof(corrupted), &frame) == 0);

    memcpy(corrupted, valid, sizeof(valid));
    corrupted[4] = 0;
    assert(BKUDPCommandDecode(corrupted, sizeof(corrupted), &frame) == 0);

    memcpy(corrupted, valid, sizeof(valid));
    corrupted[sizeof(corrupted) - 1] ^= 1;
    assert(BKUDPCommandDecode(corrupted, sizeof(corrupted), &frame) == 0);

    uint8_t combined[2 * sizeof(valid)];
    memcpy(combined, valid, sizeof(valid));
    memcpy(combined + sizeof(valid), valid, sizeof(valid));
    size_t first = BKUDPCommandDecode(combined, sizeof(combined), &frame);
    assert(first == sizeof(valid));
    assert(BKUDPCommandDecode(combined + first, sizeof(combined) - first, &frame) == sizeof(valid));
}

static void testImageKeyUsesFirstSixBytesAndWraps(void) {
    const uint8_t payload[] = { 254, 255, 0, 0, 0, 1, 85 };
    uint8_t packet[BKUDPCommandMaximumFrameLength];
    size_t length = BKUDPCommandEncode(1, BKUDPCommandRequestImageKey, payload, sizeof(payload),
                                        packet, sizeof(packet));
    BKUDPCommandFrame frame;
    assert(length != 0 && BKUDPCommandDecode(packet, length, &frame) == length);

    uint8_t key = 0;
    assert(BKUDPCommandExtractImageKey(&frame, &key) && key == 254);

    frame.payloadLength = 5;
    assert(!BKUDPCommandExtractImageKey(&frame, &key));

    const uint8_t zeroSum[] = { 255, 1, 0, 0, 0, 0 };
    frame.payload = zeroSum;
    frame.payloadLength = sizeof(zeroSum);
    assert(BKUDPCommandExtractImageKey(&frame, &key) && key == 0);

    frame.opcode = BKUDPCommandPhotoEvent;
    assert(!BKUDPCommandExtractImageKey(&frame, &key));
}

int main(void) {
    testOutgoingCommandBytes();
    testReplyValidation();
    testImageKeyUsesFirstSixBytesAndWraps();
    puts("PASS: UDP 7080 command frames and image key extraction");
    return 0;
}

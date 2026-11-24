#include "BKUDPImagePacket.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

static BKUDPImagePacketResult readPacket(BKUDPImageFrameState *state,
                                        BKUDPImagePacket *packet,
                                        uint8_t frameID,
                                        uint8_t packetID,
                                        uint8_t endFlag) {
    const uint8_t data[] = { frameID, endFlag, packetID, 0xab, 0x42 };
    BKUDPImagePacketResult result = BKUDPImageReadPacket(state, data, sizeof(data), packet);
    packet->payload = NULL;
    return result;
}

static void testContinuousPacketsPreserveJPEGBytes(void) {
    const uint8_t first[] = { 17, 0, 1, 0x23, 0xff, 0xd8, 0x42 };
    const uint8_t last[] = { 17, 1, 2, 0x24, 0x58, 0xff, 0xd9 };
    const uint8_t expected[] = { 0xff, 0xd8, 0x42, 0x58, 0xff, 0xd9 };
    uint8_t assembled[sizeof(expected)];
    BKUDPImageFrameState state = { 0 };
    BKUDPImagePacket packet = { 0 };

    assert(BKUDPImageReadPacket(&state, first, sizeof(first), &packet) == BKUDPImagePacketAccepted);
    assert(packet.startsFrame && !packet.endsFrame && packet.payloadLength == 3);
    memcpy(assembled, packet.payload, packet.payloadLength);

    assert(BKUDPImageReadPacket(&state, last, sizeof(last), &packet) == BKUDPImagePacketAccepted);
    assert(!packet.startsFrame && packet.endsFrame && packet.payloadLength == 3);
    memcpy(assembled + 3, packet.payload, packet.payloadLength);
    assert(memcmp(assembled, expected, sizeof(expected)) == 0);
    assert(!state.receivingFrame);
}

static void testDuplicatesAndOtherFramesDoNotInterruptValidFrame(void) {
    BKUDPImageFrameState state = { 0 };
    BKUDPImagePacket packet = { 0 };

    assert(readPacket(&state, &packet, 20, 1, 0) == BKUDPImagePacketAccepted);
    assert(readPacket(&state, &packet, 20, 1, 0) == BKUDPImagePacketIgnored);
    assert(readPacket(&state, &packet, 19, 2, 1) == BKUDPImagePacketIgnored);
    assert(readPacket(&state, &packet, 21, 2, 1) == BKUDPImagePacketIgnored);
    assert(readPacket(&state, &packet, 20, 2, 1) == BKUDPImagePacketAccepted);
    assert(packet.endsFrame);
}

static void testMissingPacketDropsFrameAndNextFirstPacketResynchronizes(void) {
    BKUDPImageFrameState state = { 0 };
    BKUDPImagePacket packet = { 0 };

    assert(readPacket(&state, &packet, 255, 1, 0) == BKUDPImagePacketAccepted);
    assert(readPacket(&state, &packet, 255, 3, 1) == BKUDPImagePacketDroppedFrame);
    assert(readPacket(&state, &packet, 255, 2, 0) == BKUDPImagePacketIgnored);
    assert(readPacket(&state, &packet, 0, 1, 1) == BKUDPImagePacketAccepted);
    assert(packet.startsFrame && packet.endsFrame);
}

static void testShortAndHeaderOnlyPacketsAreIgnored(void) {
    const uint8_t data[] = { 0, 1, 1, 0 };
    BKUDPImageFrameState state = { 0 };
    BKUDPImagePacket packet = { 0 };

    for (size_t length = 0; length <= sizeof(data); ++length) {
        assert(BKUDPImageReadPacket(&state, data, length, &packet) == BKUDPImagePacketIgnored);
    }
    assert(!state.receivingFrame);
}

static void testLastSequenceNumberCanOnlyFinishAFrame(void) {
    BKUDPImageFrameState state = { 0 };
    BKUDPImagePacket packet = { 0 };

    for (uint16_t index = 1; index < UINT8_MAX; ++index) {
        assert(readPacket(&state, &packet, 3, (uint8_t)index, 0) == BKUDPImagePacketAccepted);
    }
    assert(readPacket(&state, &packet, 3, UINT8_MAX, 1) == BKUDPImagePacketAccepted);
    assert(packet.endsFrame);

    state = (BKUDPImageFrameState){ true, 4, UINT8_MAX };
    assert(readPacket(&state, &packet, 4, UINT8_MAX, 0) == BKUDPImagePacketDroppedFrame);
    assert(readPacket(&state, &packet, 4, 0, 1) == BKUDPImagePacketIgnored);
}

int main(void) {
    testContinuousPacketsPreserveJPEGBytes();
    testDuplicatesAndOtherFramesDoNotInterruptValidFrame();
    testMissingPacketDropsFrameAndNextFirstPacketResynchronizes();
    testShortAndHeaderOnlyPacketsAreIgnored();
    testLastSequenceNumberCanOnlyFinishAFrame();
    puts("PASS: UDP image packet assembly and recovery");
    return 0;
}

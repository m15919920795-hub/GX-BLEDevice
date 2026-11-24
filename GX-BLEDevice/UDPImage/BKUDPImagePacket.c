#include "BKUDPImagePacket.h"

// 包序号从 1 开始，字节 3 为保留位。只有同一帧号的连续分包才能组成 JPEG。
BKUDPImagePacketResult BKUDPImageReadPacket(BKUDPImageFrameState *state,
                                           const uint8_t *bytes,
                                           size_t length,
                                           BKUDPImagePacket *packet) {
    if (length <= BKUDPImagePacketHeaderLength) {
        return BKUDPImagePacketIgnored;
    }

    const uint8_t frameID = bytes[0];
    const bool endsFrame = bytes[1] == 1;
    const uint8_t packetID = bytes[2];

    const bool startsFrame = packetID == 1
        && (!state->receivingFrame || state->frameID != frameID);
    if (startsFrame) {
        state->receivingFrame = true;
        state->frameID = frameID;
        state->nextPacketID = 1;
    }

    if (!state->receivingFrame || frameID != state->frameID || packetID < state->nextPacketID) {
        return BKUDPImagePacketIgnored;
    }

    // 遇到缺包就舍弃当前帧，下一帧从首包重新开始。
    if (packetID != state->nextPacketID || (packetID == UINT8_MAX && !endsFrame)) {
        state->receivingFrame = false;
        return BKUDPImagePacketDroppedFrame;
    }

    packet->payload = bytes + BKUDPImagePacketHeaderLength;
    packet->payloadLength = length - BKUDPImagePacketHeaderLength;
    packet->startsFrame = startsFrame;
    packet->endsFrame = endsFrame;

    state->nextPacketID += 1;
    state->receivingFrame = !endsFrame;
    return BKUDPImagePacketAccepted;
}

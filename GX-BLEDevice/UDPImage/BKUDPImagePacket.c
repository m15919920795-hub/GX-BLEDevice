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
    packet->packetID = packetID;
    packet->startsFrame = startsFrame;
    packet->endsFrame = endsFrame;

    state->nextPacketID += 1;
    state->receivingFrame = !endsFrame;
    return BKUDPImagePacketAccepted;
}

void BKUDPImageRestorePayload(uint8_t *payload, size_t payloadLength,
                              uint8_t packetID, uint8_t w32Key) {
    if (w32Key == 0 || payloadLength == 0) {
        return;
    }

    // 偏移以当前包的载荷为起点计算，协议头和前面已拼好的 JPEG 字节不参与。
    const size_t offset = ((0x03u << (packetID % 16u)) + w32Key) % payloadLength;
    payload[offset] ^= w32Key;
}

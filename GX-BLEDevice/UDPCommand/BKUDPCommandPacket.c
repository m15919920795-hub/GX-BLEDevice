#include "BKUDPCommandPacket.h"

#include <string.h>

static const uint8_t BKCommandHeader[] = { 0xcc, 0x5a };

enum {
    BKCommandSequenceOffset = 2,
    BKCommandOpcodeOffset = 3,
    BKCommandLengthOffset = 4,
    BKCommandPayloadOffset = 5,
};

// 长度字段包含载荷和校验字节。异或覆盖序号、指令、长度和载荷。
static uint8_t BKUDPCommandChecksum(const uint8_t *bytes, size_t frameLength) {
    uint8_t checksum = 0;
    for (size_t index = BKCommandSequenceOffset; index < frameLength - 1; ++index) {
        checksum ^= bytes[index];
    }
    return checksum;
}

size_t BKUDPCommandEncode(uint8_t sequence, uint8_t opcode, const uint8_t *payload,
                          size_t payloadLength, uint8_t *output, size_t capacity) {
    if (payloadLength > UINT8_MAX - 1 || (payloadLength != 0 && payload == NULL)) {
        return 0;
    }

    const size_t frameLength = BKUDPCommandFrameOverhead + payloadLength;
    if (capacity < frameLength || output == NULL) {
        return 0;
    }

    memcpy(output, BKCommandHeader, sizeof(BKCommandHeader));
    output[BKCommandSequenceOffset] = sequence;
    output[BKCommandOpcodeOffset] = opcode;
    output[BKCommandLengthOffset] = (uint8_t)(payloadLength + 1);
    if (payloadLength != 0) {
        memcpy(output + BKCommandPayloadOffset, payload, payloadLength);
    }
    output[frameLength - 1] = BKUDPCommandChecksum(output, frameLength);
    return frameLength;
}

size_t BKUDPCommandDecode(const uint8_t *bytes, size_t length, BKUDPCommandFrame *frame) {
    if (length < BKUDPCommandFrameOverhead
        || memcmp(bytes, BKCommandHeader, sizeof(BKCommandHeader)) != 0) {
        return 0;
    }

    const uint8_t bodyLength = bytes[BKCommandLengthOffset];
    const size_t frameLength = BKCommandPayloadOffset + bodyLength;
    if (bodyLength == 0 || frameLength > length
        || bytes[frameLength - 1] != BKUDPCommandChecksum(bytes, frameLength)) {
        return 0;
    }

    frame->sequence = bytes[BKCommandSequenceOffset];
    frame->opcode = bytes[BKCommandOpcodeOffset];
    frame->payload = bytes + BKCommandPayloadOffset;
    frame->payloadLength = bodyLength - 1;
    return frameLength;
}

// 和旧 App 的 Byte 累加一致，超过 255 时只保留低 8 位。
bool BKUDPCommandExtractImageKey(const BKUDPCommandFrame *frame, uint8_t *w32Key) {
    if (frame->opcode != BKUDPCommandRequestImageKey || frame->payloadLength < BKUDPCommandImageKeyBytes) {
        return false;
    }

    uint16_t sum = 0;
    for (size_t index = 0; index < BKUDPCommandImageKeyBytes; ++index) {
        sum += frame->payload[index];
    }

    *w32Key = (uint8_t)sum;
    return true;
}

#ifndef BKUDPCommandPacket_h
#define BKUDPCommandPacket_h

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum {
    BKUDPCommandPort = 7080,
    BKUDPCommandFrameOverhead = 6,
    BKUDPCommandMaximumFrameLength = 260,
    BKUDPCommandImageKeyBytes = 6,
};

typedef enum {
    BKUDPCommandReadOrientation = 0x00,
    BKUDPCommandSetOrientation = 0x01,
    BKUDPCommandSetWiFiName = 0x02,
    BKUDPCommandSetWiFiChannel = 0x03,
    BKUDPCommandRequestImageKey = 0x05,
    BKUDPCommandRecordingEvent = 0x17,
    BKUDPCommandPhotoEvent = 0x18,
} BKUDPCommandOpcode;

typedef struct {
    uint8_t sequence;
    uint8_t opcode;
    const uint8_t *payload;
    size_t payloadLength;
} BKUDPCommandFrame;

size_t BKUDPCommandEncode(uint8_t sequence, uint8_t opcode, const uint8_t *payload,
                          size_t payloadLength, uint8_t *output, size_t capacity);

// 返回完整帧占用的字节数。载荷指针在原始 UDP 数据报存活期间有效。
size_t BKUDPCommandDecode(const uint8_t *bytes, size_t length, BKUDPCommandFrame *frame);
bool BKUDPCommandExtractImageKey(const BKUDPCommandFrame *frame, uint8_t *w32Key);

#endif

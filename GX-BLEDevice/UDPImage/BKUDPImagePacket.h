#ifndef BKUDPImagePacket_h
#define BKUDPImagePacket_h

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum { BKUDPImagePacketHeaderLength = 4 };

typedef struct {
    bool receivingFrame;
    uint8_t frameID;
    uint16_t nextPacketID;
} BKUDPImageFrameState;

typedef struct {
    const uint8_t *payload;
    size_t payloadLength;
    uint8_t packetID;
    bool startsFrame;
    bool endsFrame;
} BKUDPImagePacket;

typedef enum {
    BKUDPImagePacketIgnored,
    BKUDPImagePacketDroppedFrame,
    BKUDPImagePacketAccepted,
} BKUDPImagePacketResult;

// 已接收的载荷指针引用原始 UDP 包，仅在该包的生命周期内有效。
BKUDPImagePacketResult BKUDPImageReadPacket(BKUDPImageFrameState *state,
                                           const uint8_t *bytes,
                                           size_t length,
                                           BKUDPImagePacket *packet);

// 按设备协议还原单个包的载荷，传 0 时保留原始字节。
void BKUDPImageRestorePayload(uint8_t *payload, size_t payloadLength,
                              uint8_t packetID, uint8_t w32Key);

#endif

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

#endif

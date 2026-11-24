#import "BKUDPImageManager.h"

#import "BKUDPImagePacket.h"

@import CocoaAsyncSocket;

#import <ImageIO/ImageIO.h>
#import <UIKit/UIKit.h>
#import <arpa/inet.h>
#import <netinet/in.h>

static const uint16_t BKUDPImagePort = 7070;
static const uint8_t BKUDPImageStartCommand[] = { 0x20, 0x36 };
static const uint8_t BKUDPImageStopCommand[] = { 0x20, 0x37 };
static const long BKUDPImageStartTag = 1;
static const long BKUDPImageStopTag = 2;
static const NSTimeInterval BKUDPCommandTimeout = 1.0;
static const int64_t BKUDPFirstImageTimeout = 10 * NSEC_PER_SEC;
static const NSUInteger BKUDPMaximumPreviewDimension = 4096;

static NSError *BKUDPImageError(NSString *message) {
    return [NSError errorWithDomain:@"BKUDPImageManager"
                               code:1
                           userInfo:@{ NSLocalizedDescriptionKey: message }];
}

// 在后台解码 JPEG，预览尺寸限制用于控制图像解压后的内存占用。
static UIImage * _Nullable BKDecodeJPEG(NSData *data) {
    if (data.length < 2) {
        return nil;
    }

    const uint8_t *bytes = data.bytes;
    if (bytes[0] != 0xff || bytes[1] != 0xd8) {
        return nil;
    }

    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (source == NULL) {
        return nil;
    }

    NSDictionary *options = @{
        (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES,
        (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @(BKUDPMaximumPreviewDimension),
    };

    CGImageRef imageRef = NULL;
    if (CGImageSourceGetStatusAtIndex(source, 0) == kCGImageStatusComplete) {
        imageRef = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    }
    CFRelease(source);

    if (imageRef == NULL) {
        return nil;
    }

    UIImage *image = [UIImage imageWithCGImage:imageRef];
    CGImageRelease(imageRef);
    return image;
}

@interface BKUDPImageManager () <GCDAsyncUdpSocketDelegate>
{
    BKUDPImageFrameState _frameState;
}

@property (nonatomic, strong) dispatch_queue_t receiveQueue;
@property (nonatomic, strong) dispatch_queue_t socketQueue;
@property (nonatomic, strong) dispatch_queue_t decodeQueue;

// 请求标识由界面线程更新。其余收流状态只在 receiveQueue 修改。
@property (atomic, strong, nullable) NSUUID *requestedSession;
@property (nonatomic, strong, nullable) NSUUID *activeSession;
@property (nonatomic, strong, nullable) GCDAsyncUdpSocket *socket;
@property (nonatomic, strong, nullable) NSData *peerAddress;
@property (nonatomic) in_addr_t peerIPv4;
@property (nonatomic) uint8_t w32Key;
@property (nonatomic, strong, nullable) NSMutableData *frameData;
@property (nonatomic, strong, nullable) NSData *pendingJPEG;
@property (nonatomic) BOOL decodingFrame;
@property (nonatomic) BOOL receivedPackets;
@property (nonatomic) BOOL decodedImage;

@end

@implementation BKUDPImageManager

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _receiveQueue = dispatch_queue_create("com.gx.udp-image.receive", DISPATCH_QUEUE_SERIAL);
        _socketQueue = dispatch_queue_create("com.gx.udp-image.socket", DISPATCH_QUEUE_SERIAL);
        _decodeQueue = dispatch_queue_create("com.gx.udp-image.decode", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)startReceivingFromHost:(NSString *)host {
    [self startReceivingFromHost:host w32Key:0];
}

- (void)startReceivingFromHost:(NSString *)host w32Key:(uint8_t)w32Key {
    NSUUID *session = [NSUUID UUID];
    self.requestedSession = session;
    NSString *deviceHost = [host copy];

    dispatch_async(self.receiveQueue, ^{
        if (self.requestedSession != session) {
            return;
        }

        [self closeStreamSendingStop:YES];
        [self openStreamToHost:deviceHost w32Key:w32Key session:session];
    });
}

- (void)stopReceiving {
    self.requestedSession = nil;

    dispatch_async(self.receiveQueue, ^{
        [self closeStreamSendingStop:YES];
    });
}

// 先绑定临时本地端口并开启接收，再发送开流指令，避免错过首包。
- (void)openStreamToHost:(NSString *)host w32Key:(uint8_t)w32Key session:(NSUUID *)session {
    struct sockaddr_in peer = { 0 };
    peer.sin_len = sizeof(peer);
    peer.sin_family = AF_INET;
    peer.sin_port = htons(BKUDPImagePort);

    const char *hostBytes = host.UTF8String;
    if (hostBytes == NULL || inet_pton(AF_INET, hostBytes, &peer.sin_addr) != 1) {
        [self deliverError:BKUDPImageError(@"设备地址不是有效的 IPv4 地址。") session:session];
        return;
    }

    GCDAsyncUdpSocket *socket = [[GCDAsyncUdpSocket alloc] initWithDelegate:self
                                                            delegateQueue:self.receiveQueue
                                                              socketQueue:self.socketQueue];
    [socket setIPv6Enabled:NO];

    if (![socket bindToPort:0 error:NULL] || ![socket beginReceiving:NULL]) {
        [socket close];
        [self deliverError:BKUDPImageError(@"无法打开 UDP 接收端口，请重试。") session:session];
        return;
    }

    self.activeSession = session;
    self.socket = socket;
    self.peerAddress = [NSData dataWithBytes:&peer length:sizeof(peer)];
    self.peerIPv4 = peer.sin_addr.s_addr;
    self.w32Key = w32Key;
    self.frameData = [NSMutableData data];

    NSData *command = [NSData dataWithBytes:BKUDPImageStartCommand length:sizeof(BKUDPImageStartCommand)];
    [socket sendData:command toAddress:self.peerAddress withTimeout:BKUDPCommandTimeout tag:BKUDPImageStartTag];

    [self waitForFirstImageInSession:session];
}

- (void)waitForFirstImageInSession:(NSUUID *)session {
    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, BKUDPFirstImageTimeout);
    __weak typeof(self) weakSelf = self;

    dispatch_after(deadline, self.receiveQueue, ^{
        BKUDPImageManager *manager = weakSelf;
        if (manager == nil || manager.activeSession != session || manager.decodedImage) {
            return;
        }

        NSString *message = manager.receivedPackets
            ? @"已收到 UDP 图像分包，暂未解码出可显示的 JPEG。"
            : @"未收到设备的 UDP 图像数据。请确认已连接设备热点，并允许本地网络访问。";
        [manager endStreamWithError:BKUDPImageError(message) sendStop:YES];
    });
}

- (void)udpSocket:(GCDAsyncUdpSocket *)socket
   didReceiveData:(NSData *)data
      fromAddress:(NSData *)address
withFilterContext:(id _Nullable)filterContext {
    if (socket != self.socket || self.activeSession != self.requestedSession
        || address.length < sizeof(struct sockaddr_in)) {
        return;
    }

    struct sockaddr_in sender;
    [address getBytes:&sender length:sizeof(sender)];
    if (sender.sin_family != AF_INET || sender.sin_addr.s_addr != self.peerIPv4) {
        return;
    }

    if (data.length > BKUDPImagePacketHeaderLength) {
        self.receivedPackets = YES;
    }

    BKUDPImagePacket packet;
    BKUDPImagePacketResult result = BKUDPImageReadPacket(&_frameState, data.bytes, data.length, &packet);
    if (result == BKUDPImagePacketDroppedFrame) {
        [self.frameData setLength:0];
    }
    if (result != BKUDPImagePacketAccepted) {
        return;
    }

    if (packet.startsFrame) {
        [self.frameData setLength:0];
    }

    NSUInteger payloadOffset = self.frameData.length;
    [self.frameData appendBytes:packet.payload length:packet.payloadLength];
    uint8_t *frameBytes = self.frameData.mutableBytes;
    BKUDPImageRestorePayload(frameBytes + payloadOffset, packet.payloadLength, packet.packetID, self.w32Key);

    if (packet.endsFrame) {
        self.pendingJPEG = [self.frameData copy];
        [self.frameData setLength:0];
        [self decodePendingImage];
    }
}

// 解码或刷新界面期间只保留一张最新的待处理帧，避免预览延迟不断累积。
- (void)decodePendingImage {
    if (self.decodingFrame || self.pendingJPEG == nil) {
        return;
    }

    NSData *jpeg = self.pendingJPEG;
    NSUUID *session = self.activeSession;
    self.pendingJPEG = nil;
    self.decodingFrame = YES;

    dispatch_async(self.decodeQueue, ^{
        @autoreleasepool {
            UIImage *image = BKDecodeJPEG(jpeg);
            dispatch_async(self.receiveQueue, ^{
                [self handleDecodedImage:image session:session];
            });
        }
    });
}

- (void)handleDecodedImage:(UIImage * _Nullable)image session:(NSUUID *)session {
    if (image == nil || self.activeSession != session || self.requestedSession != session) {
        self.decodingFrame = NO;
        [self decodePendingImage];
        return;
    }

    self.decodedImage = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.requestedSession == session) {
            [self.delegate udpImageManager:self didReceiveImage:image];
        }

        dispatch_async(self.receiveQueue, ^{
            self.decodingFrame = NO;
            [self decodePendingImage];
        });
    });
}

- (void)udpSocket:(GCDAsyncUdpSocket *)socket
didNotSendDataWithTag:(long)tag
         dueToError:(NSError * _Nullable)error {
    if (socket == self.socket && tag == BKUDPImageStartTag) {
        NSString *message = @"发送开流指令失败。请检查设备 Wi-Fi 和「本地网络」权限。";
        [self endStreamWithError:BKUDPImageError(message) sendStop:NO];
    }
}

- (void)udpSocketDidClose:(GCDAsyncUdpSocket *)socket withError:(NSError * _Nullable)error {
    if (socket == self.socket) {
        [self endStreamWithError:BKUDPImageError(@"UDP 接收已结束，请重试。") sendStop:NO];
    }
}

- (void)endStreamWithError:(NSError *)error sendStop:(BOOL)sendStop {
    NSUUID *session = self.activeSession;
    [self closeStreamSendingStop:sendStop];
    [self deliverError:error session:session];
}

- (void)deliverError:(NSError *)error session:(NSUUID *)session {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.requestedSession == session) {
            self.requestedSession = nil;
            [self.delegate udpImageManager:self didStopWithError:error];
        }
    });
}

// 停流指令排入原套接字的发送队列，发送结束后再关闭套接字。
- (void)closeStreamSendingStop:(BOOL)sendStop {
    GCDAsyncUdpSocket *socket = self.socket;
    NSData *peerAddress = self.peerAddress;

    self.socket = nil;
    self.peerAddress = nil;
    self.activeSession = nil;
    self.w32Key = 0;
    self.frameData = nil;
    self.pendingJPEG = nil;
    _frameState = (BKUDPImageFrameState){ 0 };
    self.receivedPackets = NO;
    self.decodedImage = NO;

    if (socket == nil) {
        return;
    }

    if (sendStop) {
        NSData *command = [NSData dataWithBytes:BKUDPImageStopCommand length:sizeof(BKUDPImageStopCommand)];
        [socket pauseReceiving];
        [socket sendData:command toAddress:peerAddress withTimeout:BKUDPCommandTimeout tag:BKUDPImageStopTag];
        [socket closeAfterSending];
    } else {
        [socket close];
    }
}

@end

#import "BKUDPCommandManager.h"

#import "BKUDPCommandPacket.h"

@import CocoaAsyncSocket;

#import <arpa/inet.h>
#import <netinet/in.h>
#import <string.h>

static const uint8_t BKUDPCommandHandshake[] = { 0x00, 0x00 };
static const uint8_t BKUDPCommandQueryValue[] = { 0x01 };
static const int64_t BKUDPImageKeyRetryInterval = NSEC_PER_SEC;
static const int64_t BKUDPCameraEventCooldown = NSEC_PER_SEC / 2;
static const NSTimeInterval BKUDPCommandSendTimeout = 1.0;

static NSError *BKUDPCommandError(NSString *message, NSError * _Nullable underlyingError) {
    NSMutableDictionary *info = [@{ NSLocalizedDescriptionKey: message } mutableCopy];
    if (underlyingError != nil) {
        info[NSUnderlyingErrorKey] = underlyingError;
    }
    return [NSError errorWithDomain:@"BKUDPCommandManager" code:1 userInfo:info];
}

static void BKUDPCompleteCommand(BKUDPCommandCompletion completion, NSError * _Nullable error) {
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(error);
    });
}

@interface BKUDPCommandManager () <GCDAsyncUdpSocketDelegate>
{
    dispatch_time_t _nextCameraEventTime[3];
}

@property (nonatomic, strong) dispatch_queue_t commandQueue;
@property (nonatomic, strong, nullable) GCDAsyncUdpSocket *socket;
@property (nonatomic, strong, nullable) NSData *peerAddress;
@property (nonatomic) in_addr_t peerIPv4;
@property (nonatomic) uint8_t sequence;
@property (nonatomic) long sendTag;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, BKUDPCommandCompletion> *pendingSends;

@property (nonatomic, strong, nullable) NSUUID *keyRequest;
@property (nonatomic, copy, nullable) BKUDPImageKeyCompletion keyCompletion;
@property (nonatomic) BOOL keySendInFlight;
@property (nonatomic) BOOL requestedKeyOnSocket;
@property (nonatomic) dispatch_time_t nextKeySendTime;

@end

@implementation BKUDPCommandManager

- (instancetype)initWithHost:(NSString *)host {
    self = [super init];
    if (self != nil) {
        _host = [host copy];
        _commandQueue = dispatch_queue_create("com.gx.udp-command", DISPATCH_QUEUE_SERIAL);
        _pendingSends = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)startListeningWithCompletion:(BKUDPCommandCompletion)completion {
    dispatch_async(self.commandQueue, ^{
        BKUDPCompleteCommand(completion, [self openSocketIfNeeded]);
    });
}

- (void)requestVideoOrientationWithCompletion:(BKUDPCommandCompletion)completion {
    NSData *payload = [NSData dataWithBytes:BKUDPCommandQueryValue length:sizeof(BKUDPCommandQueryValue)];
    [self sendOpcode:BKUDPCommandReadOrientation payload:payload completion:completion];
}

- (void)setVideoReversed:(BOOL)reversed completion:(BKUDPCommandCompletion)completion {
    uint8_t value = reversed ? 1 : 0;
    NSData *payload = [NSData dataWithBytes:&value length:sizeof(value)];
    [self sendOpcode:BKUDPCommandSetOrientation payload:payload completion:completion];
}

- (void)setWiFiName:(NSString *)name completion:(BKUDPCommandCompletion)completion {
    NSData *payload = [name dataUsingEncoding:NSUTF8StringEncoding];
    if (payload.length == 0 || payload.length > 32 || memchr(payload.bytes, 0, payload.length) != NULL) {
        BKUDPCompleteCommand(completion, BKUDPCommandError(@"Wi-Fi 名称必须为 1 至 32 个 UTF-8 字节，且不能包含空字符。", nil));
        return;
    }
    [self sendOpcode:BKUDPCommandSetWiFiName payload:payload completion:completion];
}

- (void)setWiFiChannel:(NSInteger)channel completion:(BKUDPCommandCompletion)completion {
    if (channel < 0 || channel > UINT8_MAX) {
        BKUDPCompleteCommand(completion, BKUDPCommandError(@"Wi-Fi 信道超出协议允许的字节范围。", nil));
        return;
    }
    uint8_t value = (uint8_t)channel;
    NSData *payload = [NSData dataWithBytes:&value length:sizeof(value)];
    [self sendOpcode:BKUDPCommandSetWiFiChannel payload:payload completion:completion];
}

- (void)requestImageKeyWithCompletion:(BKUDPImageKeyCompletion)completion {
    dispatch_async(self.commandQueue, ^{
        if (self.keyRequest != nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(0, BKUDPCommandError(@"正在获取图像 Key。", nil));
            });
            return;
        }

        self.keyRequest = [NSUUID UUID];
        self.keyCompletion = completion;
        self.requestedKeyOnSocket = NO;
        [self requestImageKeyWhenReady];
    });
}

- (void)close {
    dispatch_async(self.commandQueue, ^{
        NSError *error = BKUDPCommandError(@"UDP 7080 已关闭。", nil);
        [self finishKeyRequestWithKey:0 error:error];
        [self detachSocketWithError:error];
    });
}

// 兼容设备原来的通信方式，本地也绑定在 7080。先开启接收，再发初始化包。
- (NSError * _Nullable)openSocketIfNeeded {
    if (self.socket != nil) {
        return nil;
    }

    struct sockaddr_in peer = { 0 };
    peer.sin_len = sizeof(peer);
    peer.sin_family = AF_INET;
    peer.sin_port = htons(BKUDPCommandPort);
    const char *hostBytes = self.host.UTF8String;
    if (hostBytes == NULL || inet_pton(AF_INET, hostBytes, &peer.sin_addr) != 1) {
        return BKUDPCommandError(@"设备地址不是有效的 IPv4 地址。", nil);
    }

    GCDAsyncUdpSocket *socket = [[GCDAsyncUdpSocket alloc] initWithDelegate:self
                                                            delegateQueue:self.commandQueue];
    [socket setIPv6Enabled:NO];

    NSError *error = nil;
    if (![socket bindToPort:BKUDPCommandPort error:&error] || ![socket beginReceiving:&error]) {
        [socket close];
        return BKUDPCommandError(@"无法打开本地 UDP 7080。", error);
    }

    self.socket = socket;
    self.peerAddress = [NSData dataWithBytes:&peer length:sizeof(peer)];
    self.peerIPv4 = peer.sin_addr.s_addr;
    self.requestedKeyOnSocket = NO;
    memset(_nextCameraEventTime, 0, sizeof(_nextCameraEventTime));

    NSData *handshake = [NSData dataWithBytes:BKUDPCommandHandshake length:sizeof(BKUDPCommandHandshake)];
    [socket sendData:handshake toAddress:self.peerAddress withTimeout:BKUDPCommandSendTimeout tag:0];
    return nil;
}

- (void)sendOpcode:(uint8_t)opcode payload:(NSData *)payload completion:(BKUDPCommandCompletion)completion {
    dispatch_async(self.commandQueue, ^{
        NSError *error = [self openSocketIfNeeded];
        if (error != nil) {
            BKUDPCompleteCommand(completion, error);
            return;
        }

        [self enqueueOpcode:opcode payload:payload completion:^(NSError * _Nullable sendError) {
            BKUDPCompleteCommand(completion, sendError);
        }];
    });
}

- (void)enqueueOpcode:(uint8_t)opcode payload:(NSData *)payload completion:(BKUDPCommandCompletion)completion {
    self.sequence = self.sequence == 128 ? 1 : self.sequence + 1;

    uint8_t bytes[BKUDPCommandMaximumFrameLength];
    size_t length = BKUDPCommandEncode(self.sequence, opcode, payload.bytes, payload.length, bytes, sizeof(bytes));
    if (length == 0) {
        completion(BKUDPCommandError(@"设备指令长度无效。", nil));
        return;
    }

    long tag = ++self.sendTag;
    self.pendingSends[@(tag)] = [completion copy];

    NSData *packet = [NSData dataWithBytes:bytes length:length];
    [self.socket sendData:packet toAddress:self.peerAddress withTimeout:BKUDPCommandSendTimeout tag:tag];
}

// 取 Key 只有一个请求在进行。计时从上一次发送结束开始，避免 UDP 队列推迟发送时挤在一起。
- (void)requestImageKeyWhenReady {
    NSUUID *request = self.keyRequest;
    if (request == nil || self.keySendInFlight) {
        return;
    }

    if (self.nextKeySendTime > dispatch_time(DISPATCH_TIME_NOW, 0)) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(self.nextKeySendTime, self.commandQueue, ^{
            BKUDPCommandManager *manager = weakSelf;
            if (manager.keyRequest == request) {
                [manager requestImageKeyWhenReady];
            }
        });
        return;
    }

    if ([self openSocketIfNeeded] != nil) {
        self.nextKeySendTime = dispatch_time(DISPATCH_TIME_NOW, BKUDPImageKeyRetryInterval);
        [self requestImageKeyWhenReady];
        return;
    }

    self.requestedKeyOnSocket = YES;
    self.keySendInFlight = YES;

    NSData *payload = [NSData dataWithBytes:BKUDPCommandQueryValue length:sizeof(BKUDPCommandQueryValue)];
    __weak typeof(self) weakSelf = self;
    [self enqueueOpcode:BKUDPCommandRequestImageKey payload:payload completion:^(NSError * _Nullable error) {
        BKUDPCommandManager *manager = weakSelf;
        manager.keySendInFlight = NO;
        manager.nextKeySendTime = dispatch_time(DISPATCH_TIME_NOW, BKUDPImageKeyRetryInterval);
        [manager requestImageKeyWhenReady];
    }];
}

- (void)finishKeyRequestWithKey:(uint8_t)w32Key error:(NSError * _Nullable)error {
    BKUDPImageKeyCompletion completion = self.keyCompletion;
    self.keyRequest = nil;
    self.keyCompletion = nil;

    if (completion != nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(w32Key, error);
        });
    }
}

- (void)udpSocket:(GCDAsyncUdpSocket *)socket didSendDataWithTag:(long)tag {
    if (socket == self.socket) {
        [self completeSendWithTag:tag error:nil];
    }
}

- (void)udpSocket:(GCDAsyncUdpSocket *)socket
didNotSendDataWithTag:(long)tag
        dueToError:(NSError * _Nullable)error {
    if (socket == self.socket) {
        [self completeSendWithTag:tag error:BKUDPCommandError(@"UDP 指令发送失败。", error)];
    }
}

- (void)completeSendWithTag:(long)tag error:(NSError * _Nullable)error {
    BKUDPCommandCompletion completion = self.pendingSends[@(tag)];
    [self.pendingSends removeObjectForKey:@(tag)];

    if (completion != nil) {
        completion(error);
    }
}

- (void)udpSocketDidClose:(GCDAsyncUdpSocket *)socket withError:(NSError * _Nullable)error {
    if (socket != self.socket) {
        return;
    }

    [self detachSocketWithError:BKUDPCommandError(@"UDP 7080 已断开。", error)];
}

- (void)detachSocketWithError:(NSError *)error {
    GCDAsyncUdpSocket *socket = self.socket;
    self.socket = nil;
    self.peerAddress = nil;
    self.requestedKeyOnSocket = NO;
    [socket close];

    NSArray<BKUDPCommandCompletion> *sends = self.pendingSends.allValues;
    [self.pendingSends removeAllObjects];
    for (BKUDPCommandCompletion completion in sends) {
        completion(error);
    }
}

- (void)udpSocket:(GCDAsyncUdpSocket *)socket
   didReceiveData:(NSData *)data
      fromAddress:(NSData *)address
withFilterContext:(id _Nullable)filterContext {
    if (socket != self.socket || address.length < sizeof(struct sockaddr_in)) {
        return;
    }

    struct sockaddr_in sender;
    [address getBytes:&sender length:sizeof(sender)];
    if (sender.sin_family != AF_INET || sender.sin_addr.s_addr != self.peerIPv4) {
        return;
    }

    // 数据报内可携带多个完整帧。检查长度和校验后再读取载荷。
    const uint8_t *bytes = data.bytes;
    for (size_t offset = 0; data.length - offset >= BKUDPCommandFrameOverhead;) {
        BKUDPCommandFrame frame;
        size_t length = BKUDPCommandDecode(bytes + offset, data.length - offset, &frame);
        if (length == 0) {
            offset += 1;
            continue;
        }

        [self handleFrame:&frame];
        offset += length;
    }
}

- (void)handleFrame:(const BKUDPCommandFrame *)frame {
    uint8_t key;
    if (self.keyRequest != nil && self.requestedKeyOnSocket && BKUDPCommandExtractImageKey(frame, &key)) {
        [self finishKeyRequestWithKey:key error:nil];
    }

    NSData *payload = [NSData dataWithBytes:frame->payload length:frame->payloadLength];
    const uint8_t opcode = frame->opcode;
    const uint8_t sequence = frame->sequence;
    dispatch_async(dispatch_get_main_queue(), ^{
        id<BKUDPCommandManagerDelegate> delegate = self.delegate;
        if ([delegate respondsToSelector:@selector(udpCommandManager:didReceiveOpcode:sequence:payload:)]) {
            [delegate udpCommandManager:self didReceiveOpcode:opcode sequence:sequence payload:payload];
        }
    });

    if (frame->payloadLength == 1) {
        [self handleCameraOpcode:opcode value:frame->payload[0]];
    }
}

- (void)handleCameraOpcode:(uint8_t)opcode value:(uint8_t)value {
    BKUDPCameraEvent event;
    if (opcode == BKUDPCommandPhotoEvent && value == 1) {
        event = BKUDPCameraEventTakePhoto;
    } else if (opcode == BKUDPCommandRecordingEvent && value == 1) {
        event = BKUDPCameraEventStartRecording;
    } else if (opcode == BKUDPCommandRecordingEvent && value == 2) {
        event = BKUDPCameraEventStopRecording;
    } else {
        return;
    }

    if (_nextCameraEventTime[event] > dispatch_time(DISPATCH_TIME_NOW, 0)) {
        return;
    }
    _nextCameraEventTime[event] = dispatch_time(DISPATCH_TIME_NOW, BKUDPCameraEventCooldown);

    dispatch_async(dispatch_get_main_queue(), ^{
        id<BKUDPCommandManagerDelegate> delegate = self.delegate;
        if ([delegate respondsToSelector:@selector(udpCommandManager:didReceiveCameraEvent:)]) {
            [delegate udpCommandManager:self didReceiveCameraEvent:event];
        }
    });
}

@end

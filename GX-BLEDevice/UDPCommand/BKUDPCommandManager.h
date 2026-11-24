#import <Foundation/Foundation.h>

#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

@class BKUDPCommandManager;

typedef void (^BKUDPCommandCompletion)(NSError * _Nullable error);
typedef void (^BKUDPImageKeyCompletion)(uint8_t w32Key, NSError * _Nullable error);

typedef NS_ENUM(NSInteger, BKUDPCameraEvent) {
    BKUDPCameraEventTakePhoto,
    BKUDPCameraEventStartRecording,
    BKUDPCameraEventStopRecording,
};

@protocol BKUDPCommandManagerDelegate <NSObject>
@optional

- (void)udpCommandManager:(BKUDPCommandManager *)manager
         didReceiveOpcode:(uint8_t)opcode
                 sequence:(uint8_t)sequence
                  payload:(NSData *)payload;

- (void)udpCommandManager:(BKUDPCommandManager *)manager didReceiveCameraEvent:(BKUDPCameraEvent)event;

@end

@interface BKUDPCommandManager : NSObject

@property (nonatomic, copy, readonly) NSString *host;
@property (nonatomic, weak, nullable) id<BKUDPCommandManagerDelegate> delegate;

- (instancetype)initWithHost:(NSString *)host NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// 回调在主线程执行。普通指令的回调报告本地 UDP 发送结果。
- (void)startListeningWithCompletion:(BKUDPCommandCompletion)completion;
- (void)requestVideoOrientationWithCompletion:(BKUDPCommandCompletion)completion;
- (void)setVideoReversed:(BOOL)reversed completion:(BKUDPCommandCompletion)completion;
- (void)setWiFiName:(NSString *)name completion:(BKUDPCommandCompletion)completion;
- (void)setWiFiChannel:(NSInteger)channel completion:(BKUDPCommandCompletion)completion;

// 自动重试取 Key，发送间隔至少一秒。通过 error 区分错误和有效的 0 值。
- (void)requestImageKeyWithCompletion:(BKUDPImageKeyCompletion)completion;
- (void)close;

@end

NS_ASSUME_NONNULL_END

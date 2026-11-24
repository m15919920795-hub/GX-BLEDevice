#import <Foundation/Foundation.h>

@class BKUDPImageManager;
@class UIImage;

NS_ASSUME_NONNULL_BEGIN

@protocol BKUDPImageManagerDelegate <NSObject>

- (void)udpImageManager:(BKUDPImageManager *)manager didReceiveImage:(UIImage *)image;
- (void)udpImageManager:(BKUDPImageManager *)manager didStopWithError:(NSError *)error;

@end

@interface BKUDPImageManager : NSObject

@property (nonatomic, weak, nullable) id<BKUDPImageManagerDelegate> delegate;

// 在主线程传入设备的 IPv4 地址。图像和错误也通过主线程回调。
- (void)startReceivingFromHost:(NSString *)host;
- (void)stopReceiving;

@end

NS_ASSUME_NONNULL_END

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^GXDeviceConnectionProgress)(NSString *message);
typedef void (^GXDeviceConnectionCompletion)(NSString * _Nullable ssid, NSError * _Nullable error);

@interface GXDeviceConnectionCoordinator : NSObject

- (void)connectToNearestDeviceWithProgress:(GXDeviceConnectionProgress)progress
                               completion:(GXDeviceConnectionCompletion)completion;

@end

NS_ASSUME_NONNULL_END

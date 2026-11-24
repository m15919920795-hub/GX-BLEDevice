#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const GXWiFiErrorDomain;

typedef NS_ENUM(NSInteger, GXWiFiErrorCode) {
    GXWiFiErrorJoinCancelled = 1,
    GXWiFiErrorJoinFailed,
    GXWiFiErrorSSIDUnconfirmed,
};

typedef void (^GXWiFiConnectionCompletion)(NSError * _Nullable error);

@interface GXWiFiConnector : NSObject

// 在主线程申请加入开放热点，核对到目标 SSID 后返回成功。
- (void)joinOpenNetworkWithSSID:(NSString *)ssid
                   completion:(GXWiFiConnectionCompletion)completion;

@end

NS_ASSUME_NONNULL_END

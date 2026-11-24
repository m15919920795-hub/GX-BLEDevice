#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const GXWiFiErrorDomain;

typedef NS_ENUM(NSInteger, GXWiFiErrorCode) {
    GXWiFiErrorJoinCancelled = 1,
    GXWiFiErrorJoinFailed,
    GXWiFiErrorGatewayUnavailable,
};

typedef void (^GXWiFiConnectionCompletion)(NSString * _Nullable gatewayAddress, NSError * _Nullable error);

@interface GXWiFiConnector : NSObject

// 在主线程申请加入开放热点，返回当前 Wi-Fi 的 IPv4 网关。
- (void)joinOpenNetworkWithSSID:(NSString *)ssid
                   completion:(GXWiFiConnectionCompletion)completion;

@end

NS_ASSUME_NONNULL_END

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const GXWiFiErrorDomain;

typedef NS_ENUM(NSInteger, GXWiFiErrorCode) {
    GXWiFiErrorJoinCancelled = 1,
    GXWiFiErrorJoinFailed,
    GXWiFiErrorGatewayUnavailable,
    GXWiFiErrorUnexpectedGateway,
};

typedef void (^GXWiFiGatewayCompletion)(NSString * _Nullable gatewayAddress);
typedef void (^GXWiFiConnectionCompletion)(NSString * _Nullable gatewayAddress, NSError * _Nullable error);

@interface GXWiFiConnector : NSObject

// 在主线程读取当前 Wi-Fi 网关，读不到时返回 nil。
+ (void)readCurrentGatewayAddressWithCompletion:(GXWiFiGatewayCompletion)completion;

// 在主线程申请加入开放热点，等 iOS 更新到指定的 IPv4 网关。
- (void)joinOpenNetworkWithSSID:(NSString *)ssid
         expectedGatewayAddress:(NSString *)expectedGatewayAddress
                   completion:(GXWiFiConnectionCompletion)completion;

@end

NS_ASSUME_NONNULL_END

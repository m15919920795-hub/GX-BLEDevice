#import "GXWiFiConnector.h"

#import <NetworkExtension/NetworkExtension.h>

static NSErrorDomain const GXWiFiErrorDomain = @"GXWiFiErrorDomain";
static const NSTimeInterval GXSSIDVerificationTimeout = 8.0;
static const NSTimeInterval GXSSIDRetryInterval = 0.5;

typedef NS_ENUM(NSInteger, GXWiFiErrorCode) {
    GXWiFiErrorJoinCancelled = 1,
    GXWiFiErrorJoinFailed,
    GXWiFiErrorSSIDUnconfirmed,
};

static NSError *GXWiFiError(GXWiFiErrorCode code, NSString *message) {
    return [NSError errorWithDomain:GXWiFiErrorDomain
                              code:code
                          userInfo:@{ NSLocalizedDescriptionKey: message }];
}

@implementation GXWiFiConnector

// 使用完整 SSID 申请加入开放热点，并等待用户处理可能出现的系统确认。
- (void)joinOpenNetworkWithSSID:(NSString *)ssid
                   completion:(GXWiFiConnectionCompletion)completion {
    NEHotspotConfiguration *configuration = [[NEHotspotConfiguration alloc] initWithSSID:ssid];
    configuration.joinOnce = YES;

    [[NEHotspotConfigurationManager sharedManager] applyConfiguration:configuration
        completionHandler:^(NSError * _Nullable error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                BOOL hotspotError = [error.domain isEqualToString:NEHotspotConfigurationErrorDomain];
                BOOL alreadyAssociated = hotspotError
                    && error.code == NEHotspotConfigurationErrorAlreadyAssociated;

                if (error == nil || alreadyAssociated) {
                    [self startVerificationForSSID:ssid completion:completion];
                    return;
                }

                if (hotspotError && error.code == NEHotspotConfigurationErrorUserDenied) {
                    completion(GXWiFiError(GXWiFiErrorJoinCancelled, @"已取消加入设备 Wi-Fi。"));
                    return;
                }

                NSString *message = [NSString stringWithFormat:@"无法加入 %@。请确认设备热点可用后重试。", ssid];
                completion(GXWiFiError(GXWiFiErrorJoinFailed, message));
            });
        }];
}

// 加入配置回调后单独开始计时。超时与 SSID 核对共用一个完成回调。
- (void)startVerificationForSSID:(NSString *)ssid
                     completion:(GXWiFiConnectionCompletion)completion {
    __block GXWiFiConnectionCompletion pendingCompletion = [completion copy];
    GXWiFiConnectionCompletion finishOnce = ^(NSError * _Nullable error) {
        GXWiFiConnectionCompletion callback = pendingCompletion;
        pendingCompletion = nil;

        if (callback != nil) {
            callback(error);
        }
    };

    NSString *message = [NSString stringWithFormat:@"暂未确认连接到 %@。请保持设备开机，并重新搜索。", ssid];
    NSError *timeoutError = GXWiFiError(GXWiFiErrorSSIDUnconfirmed, message);
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + GXSSIDVerificationTimeout;
    int64_t timeoutNanoseconds = (int64_t)(GXSSIDVerificationTimeout * NSEC_PER_SEC);
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, timeoutNanoseconds);

    dispatch_after(timeout, dispatch_get_main_queue(), ^{
        finishOnce(timeoutError);
    });

    [self verifyCurrentSSID:ssid deadline:deadline completion:finishOnce];
}

// 系统切换热点需要时间，短间隔重读当前网络。核对完整 SSID 后才确认成功。
- (void)verifyCurrentSSID:(NSString *)ssid
                deadline:(NSTimeInterval)deadline
              completion:(GXWiFiConnectionCompletion)completion {
    if (NSProcessInfo.processInfo.systemUptime >= deadline) {
        return;
    }

    [NEHotspotNetwork fetchCurrentWithCompletionHandler:^(NEHotspotNetwork * _Nullable network) {
        if (NSProcessInfo.processInfo.systemUptime >= deadline) {
            return;
        }

        if ([network.SSID isEqualToString:ssid]) {
            completion(nil);
            return;
        }

        dispatch_time_t retry = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(GXSSIDRetryInterval * NSEC_PER_SEC));
        dispatch_after(retry, dispatch_get_main_queue(), ^{
            [self verifyCurrentSSID:ssid deadline:deadline completion:completion];
        });
    }];
}

@end

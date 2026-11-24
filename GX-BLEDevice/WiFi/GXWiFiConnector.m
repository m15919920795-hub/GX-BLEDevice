#import "GXWiFiConnector.h"

#import <NetworkExtension/NetworkExtension.h>

NSErrorDomain const GXWiFiErrorDomain = @"GXWiFiErrorDomain";

static const NSTimeInterval GXSSIDVerificationTimeout = 15.0;
static const NSTimeInterval GXSSIDRetryInterval = 0.5;

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
    __block NSString *latestSSID = nil;
    __block GXWiFiConnectionCompletion pendingCompletion = [completion copy];
    GXWiFiConnectionCompletion finishOnce = ^(NSError * _Nullable error) {
        GXWiFiConnectionCompletion callback = pendingCompletion;
        pendingCompletion = nil;

        if (callback != nil) {
            callback(error);
        }
    };

    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + GXSSIDVerificationTimeout;
    int64_t timeoutNanoseconds = (int64_t)(GXSSIDVerificationTimeout * NSEC_PER_SEC);
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, timeoutNanoseconds);

    dispatch_after(timeout, dispatch_get_main_queue(), ^{
        if (pendingCompletion == nil) {
            return;
        }

        NSString *message;
        if (latestSSID.length == 0) {
            message = [NSString stringWithFormat:@"iOS 未返回当前 Wi-Fi 名称，暂时无法核对是否已连到 %@。", ssid];
        } else {
            message = [NSString stringWithFormat:@"iOS 读到的当前 Wi-Fi 是 %@，目标是 %@。", latestSSID, ssid];
        }

        finishOnce(GXWiFiError(GXWiFiErrorSSIDUnconfirmed, message));
    });

    [self readCurrentSSIDUntil:deadline onRead:^BOOL(NSString * _Nullable currentSSID) {
        latestSSID = currentSSID;
        if ([currentSSID isEqualToString:ssid]) {
            finishOnce(nil);
            return YES;
        }

        return NO;
    }];
}

// 系统切换热点期间可能返回空值或上一个网络的名称。持续读取，直到核对成功或超时。
- (void)readCurrentSSIDUntil:(NSTimeInterval)deadline
                     onRead:(BOOL (^)(NSString * _Nullable currentSSID))onRead {
    if (NSProcessInfo.processInfo.systemUptime >= deadline) {
        return;
    }

    [NEHotspotNetwork fetchCurrentWithCompletionHandler:^(NEHotspotNetwork * _Nullable network) {
        if (NSProcessInfo.processInfo.systemUptime >= deadline) {
            return;
        }

        if (onRead(network.SSID)) {
            return;
        }

        dispatch_time_t retry = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(GXSSIDRetryInterval * NSEC_PER_SEC));
        dispatch_after(retry, dispatch_get_main_queue(), ^{
            [self readCurrentSSIDUntil:deadline onRead:onRead];
        });
    }];
}

@end

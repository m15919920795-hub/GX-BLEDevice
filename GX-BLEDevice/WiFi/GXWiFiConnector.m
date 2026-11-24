#import "GXWiFiConnector.h"

#import <Network/Network.h>
#import <NetworkExtension/NetworkExtension.h>
#import <arpa/inet.h>
#import <netinet/in.h>

NSErrorDomain const GXWiFiErrorDomain = @"GXWiFiErrorDomain";

static const int64_t GXGatewayProbeTimeout = NSEC_PER_SEC;
static const int64_t GXGatewayReadTimeout = 10 * NSEC_PER_SEC;

static NSError *GXWiFiError(GXWiFiErrorCode code, NSString *message) {
    return [NSError errorWithDomain:GXWiFiErrorDomain
                              code:code
                          userInfo:@{ NSLocalizedDescriptionKey: message }];
}

// 从 Wi-Fi 路由中取第一个 IPv4 网关地址。系统可能先报告 IPv6 网关。
static NSString * _Nullable GXIPv4GatewayAddress(nw_path_t path) {
    __block NSString *gatewayAddress = nil;
    nw_path_enumerate_gateways(path, ^bool(nw_endpoint_t gateway) {
        if (nw_endpoint_get_type(gateway) != nw_endpoint_type_address) {
            return true;
        }

        const struct sockaddr *address = nw_endpoint_get_address(gateway);
        if (address == NULL || address->sa_family != AF_INET) {
            return true;
        }

        const struct sockaddr_in *ipv4Address = (const struct sockaddr_in *)address;
        char buffer[INET_ADDRSTRLEN];
        if (inet_ntop(AF_INET, &ipv4Address->sin_addr, buffer, sizeof(buffer)) == NULL) {
            return true;
        }

        gatewayAddress = [NSString stringWithUTF8String:buffer];
        return false;
    });

    return gatewayAddress;
}

@interface GXWiFiConnector ()

@property (nonatomic, strong, nullable) nw_path_monitor_t gatewayMonitor;
@property (nonatomic, copy, nullable) NSString *expectedGatewayAddress;
@property (nonatomic, copy, nullable) NSString *currentGatewayAddress;
@property (nonatomic, copy, nullable) GXWiFiConnectionCompletion completion;
@property (nonatomic) BOOL waitingForGateway;

@end

@implementation GXWiFiConnector

- (void)dealloc {
    if (_gatewayMonitor != nil) {
        nw_path_monitor_cancel(_gatewayMonitor);
    }
}

// 只读 Wi-Fi 接口上的网关。初始路由为空时，给 iOS 一点时间返回地址。
+ (void)readCurrentGatewayAddressWithCompletion:(GXWiFiGatewayCompletion)completion {
    nw_path_monitor_t monitor = nw_path_monitor_create_with_type(nw_interface_type_wifi);
    __weak nw_path_monitor_t weakMonitor = monitor;
    __block BOOL completed = NO;

    nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) {
        NSString *gatewayAddress = GXIPv4GatewayAddress(path);
        if (completed || gatewayAddress == nil) {
            return;
        }

        nw_path_monitor_t activeMonitor = weakMonitor;
        if (activeMonitor == nil) {
            return;
        }

        completed = YES;
        nw_path_monitor_cancel(activeMonitor);
        completion(gatewayAddress);
    });
    nw_path_monitor_set_queue(monitor, dispatch_get_main_queue());
    nw_path_monitor_start(monitor);

    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, GXGatewayProbeTimeout);
    dispatch_after(timeout, dispatch_get_main_queue(), ^{
        if (!completed) {
            completed = YES;
            nw_path_monitor_cancel(monitor);
            completion(nil);
        }
    });
}

- (void)joinOpenNetworkWithSSID:(NSString *)ssid
         expectedGatewayAddress:(NSString *)expectedGatewayAddress
                   completion:(GXWiFiConnectionCompletion)completion {
    if (self.gatewayMonitor != nil) {
        completion(nil, GXWiFiError(GXWiFiErrorJoinFailed, @"正在处理上一次 Wi-Fi 加入请求。"));
        return;
    }

    nw_path_monitor_t monitor = nw_path_monitor_create_with_type(nw_interface_type_wifi);
    self.gatewayMonitor = monitor;
    self.expectedGatewayAddress = expectedGatewayAddress;
    self.completion = completion;

    __weak typeof(self) weakSelf = self;
    __weak nw_path_monitor_t weakMonitor = monitor;
    nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) {
        GXWiFiConnector *connector = weakSelf;
        if (connector == nil || connector.gatewayMonitor != weakMonitor) {
            return;
        }

        connector.currentGatewayAddress = GXIPv4GatewayAddress(path);
        [connector finishIfExpectedGatewayAvailable];
    });

    nw_path_monitor_set_queue(monitor, dispatch_get_main_queue());
    nw_path_monitor_start(monitor);

    [self applyConfigurationForSSID:ssid];
}

// 系统接受加入请求后，再用 Wi-Fi 路由核对是否已经切换到设备。
- (void)applyConfigurationForSSID:(NSString *)ssid {
    nw_path_monitor_t monitor = self.gatewayMonitor;
    NEHotspotConfiguration *configuration = [[NEHotspotConfiguration alloc] initWithSSID:ssid];
    configuration.joinOnce = YES;

    __weak typeof(self) weakSelf = self;
    [[NEHotspotConfigurationManager sharedManager] applyConfiguration:configuration
        completionHandler:^(NSError * _Nullable error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                GXWiFiConnector *connector = weakSelf;
                if (connector.gatewayMonitor == monitor) {
                    [connector handleConfigurationResult:error forSSID:ssid];
                }
            });
        }];
}

- (void)handleConfigurationResult:(NSError * _Nullable)error forSSID:(NSString *)ssid {
    BOOL hotspotError = [error.domain isEqualToString:NEHotspotConfigurationErrorDomain];
    BOOL alreadyAssociated = hotspotError && error.code == NEHotspotConfigurationErrorAlreadyAssociated;

    if (error == nil || alreadyAssociated) {
        [self waitForExpectedGateway];
        return;
    }

    if (hotspotError && error.code == NEHotspotConfigurationErrorUserDenied) {
        [self finishWithGatewayAddress:nil
                                error:GXWiFiError(GXWiFiErrorJoinCancelled, @"已取消加入设备 Wi-Fi。")];
        return;
    }

    NSString *message = [NSString stringWithFormat:@"无法加入 %@。请确认设备热点可用后重试。", ssid];
    [self finishWithGatewayAddress:nil error:GXWiFiError(GXWiFiErrorJoinFailed, message)];
}

// 加入回调可能先于路由更新。旧网络的网关仍可见时继续等设备地址。
- (void)waitForExpectedGateway {
    nw_path_monitor_t monitor = self.gatewayMonitor;
    self.waitingForGateway = YES;
    [self finishIfExpectedGatewayAvailable];
    if (monitor == nil || self.gatewayMonitor != monitor) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, GXGatewayReadTimeout);
    dispatch_after(timeout, dispatch_get_main_queue(), ^{
        GXWiFiConnector *connector = weakSelf;
        if (connector.gatewayMonitor != monitor) {
            return;
        }

        NSString *gatewayAddress = connector.currentGatewayAddress;
        NSError *error;
        if (gatewayAddress == nil) {
            error = GXWiFiError(GXWiFiErrorGatewayUnavailable, @"iOS 暂未提供当前 Wi-Fi 的 IPv4 网关。");
        } else {
            NSString *message = [NSString stringWithFormat:@"当前 Wi-Fi 网关是 %@，设备网关应为 %@。",
                                 gatewayAddress, connector.expectedGatewayAddress];
            error = GXWiFiError(GXWiFiErrorUnexpectedGateway, message);
        }

        [connector finishWithGatewayAddress:nil error:error];
    });
}

- (void)finishIfExpectedGatewayAvailable {
    NSString *gatewayAddress = self.currentGatewayAddress;
    if (self.waitingForGateway && [gatewayAddress isEqualToString:self.expectedGatewayAddress]) {
        [self finishWithGatewayAddress:gatewayAddress error:nil];
    }
}

// 先关闭本次路由监听，再向界面返回结果，允许用户安全地重新搜索。
- (void)finishWithGatewayAddress:(NSString * _Nullable)gatewayAddress
                          error:(NSError * _Nullable)error {
    nw_path_monitor_t monitor = self.gatewayMonitor;
    if (monitor == nil) {
        return;
    }

    GXWiFiConnectionCompletion completion = self.completion;
    self.completion = nil;
    self.gatewayMonitor = nil;
    self.expectedGatewayAddress = nil;
    self.currentGatewayAddress = nil;
    self.waitingForGateway = NO;
    nw_path_monitor_cancel(monitor);

    completion(gatewayAddress, error);
}

@end

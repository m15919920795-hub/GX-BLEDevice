#import "GXWiFiConnector.h"

#import <Network/Network.h>
#import <NetworkExtension/NetworkExtension.h>
#import <arpa/inet.h>
#import <netinet/in.h>

NSErrorDomain const GXWiFiErrorDomain = @"GXWiFiErrorDomain";

static const int64_t GXInitialPathTimeout = 1 * NSEC_PER_SEC;
static const int64_t GXGatewayReadTimeout = 10 * NSEC_PER_SEC;

typedef NS_ENUM(NSInteger, GXWiFiJoinPhase) {
    GXWiFiJoinPhaseWaitingForInitialPath,
    GXWiFiJoinPhaseApplyingConfiguration,
    GXWiFiJoinPhaseWaitingForGateway,
};

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
@property (nonatomic, copy, nullable) NSString *initialGatewayAddress;
@property (nonatomic, copy, nullable) NSString *currentGatewayAddress;
@property (nonatomic, copy, nullable) GXWiFiConnectionCompletion completion;
@property (nonatomic) GXWiFiJoinPhase phase;

@end

@implementation GXWiFiConnector

- (void)dealloc {
    if (_gatewayMonitor != nil) {
        nw_path_monitor_cancel(_gatewayMonitor);
    }
}

// 在加入前先记录当前的 Wi-Fi 网关，以便给系统切换热点和更新路由留出时间。
- (void)joinOpenNetworkWithSSID:(NSString *)ssid
                   completion:(GXWiFiConnectionCompletion)completion {
    if (self.gatewayMonitor != nil) {
        completion(nil, GXWiFiError(GXWiFiErrorJoinFailed, @"正在处理上一次 Wi-Fi 加入请求。"));
        return;
    }

    nw_path_monitor_t monitor = nw_path_monitor_create_with_type(nw_interface_type_wifi);
    self.gatewayMonitor = monitor;
    self.completion = completion;
    self.phase = GXWiFiJoinPhaseWaitingForInitialPath;

    __weak typeof(self) weakSelf = self;
    __weak nw_path_monitor_t weakMonitor = monitor;
    nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) {
        GXWiFiConnector *connector = weakSelf;
        if (connector == nil || connector.gatewayMonitor != weakMonitor) {
            return;
        }

        connector.currentGatewayAddress = GXIPv4GatewayAddress(path);
        if (connector.phase == GXWiFiJoinPhaseWaitingForInitialPath) {
            [connector applyConfigurationForSSID:ssid];
        } else {
            [connector finishIfGatewayChanged];
        }
    });

    nw_path_monitor_set_queue(monitor, dispatch_get_main_queue());
    nw_path_monitor_start(monitor);

    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, GXInitialPathTimeout);
    dispatch_after(timeout, dispatch_get_main_queue(), ^{
        GXWiFiConnector *connector = weakSelf;
        if (connector.gatewayMonitor == monitor && connector.phase == GXWiFiJoinPhaseWaitingForInitialPath) {
            [connector applyConfigurationForSSID:ssid];
        }
    });
}

// 系统接受加入请求后开始等待网关。如果系统报告已关联，可立即读取当前路由。
- (void)applyConfigurationForSSID:(NSString *)ssid {
    self.phase = GXWiFiJoinPhaseApplyingConfiguration;
    self.initialGatewayAddress = self.currentGatewayAddress;

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
        [self waitForGatewayAcceptingInitialAddress:alreadyAssociated];
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

// 优先显示切换后出现的新网关。等待结束时也可显示当前地址，两个热点可能使用相同网段。
- (void)waitForGatewayAcceptingInitialAddress:(BOOL)acceptInitialAddress {
    self.phase = GXWiFiJoinPhaseWaitingForGateway;
    if (acceptInitialAddress) {
        self.initialGatewayAddress = nil;
    }

    [self finishIfGatewayChanged];
    nw_path_monitor_t monitor = self.gatewayMonitor;
    if (monitor == nil) {
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
        NSError *error = nil;
        if (gatewayAddress == nil) {
            error = GXWiFiError(GXWiFiErrorGatewayUnavailable, @"iOS 暂未提供当前 Wi-Fi 的 IPv4 网关。");
        }

        [connector finishWithGatewayAddress:gatewayAddress error:error];
    });
}

- (void)finishIfGatewayChanged {
    NSString *gatewayAddress = self.currentGatewayAddress;
    if (self.phase == GXWiFiJoinPhaseWaitingForGateway
        && gatewayAddress != nil
        && ![gatewayAddress isEqualToString:self.initialGatewayAddress]) {
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
    self.initialGatewayAddress = nil;
    self.currentGatewayAddress = nil;
    nw_path_monitor_cancel(monitor);

    completion(gatewayAddress, error);
}

@end

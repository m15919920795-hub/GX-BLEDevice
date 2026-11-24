#import "GXDeviceConnectionCoordinator.h"

#import "GXBLEScanner.h"
#import "GXWiFiConnector.h"

static NSString * const GXDeviceGatewayAddress = @"192.168.18.1";

@interface GXDeviceConnectionCoordinator ()

@property (nonatomic, strong) GXBLEScanner *scanner;
@property (nonatomic, strong) GXWiFiConnector *wifiConnector;

@end

@implementation GXDeviceConnectionCoordinator

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _scanner = [[GXBLEScanner alloc] init];
        _wifiConnector = [[GXWiFiConnector alloc] init];
    }
    return self;
}

- (void)readConnectedDeviceWithCompletion:(GXConnectedDeviceCompletion)completion {
    [GXWiFiConnector readCurrentGatewayAddressWithCompletion:^(NSString * _Nullable gatewayAddress) {
        completion([gatewayAddress isEqualToString:GXDeviceGatewayAddress] ? gatewayAddress : nil);
    }];
}

// 设备加入 Wi-Fi 后会关闭蓝牙广播，先检查当前网关再决定是否扫描。
- (void)connectToNearestDeviceWithProgress:(GXDeviceConnectionProgress)progress
                               completion:(GXDeviceConnectionCompletion)completion {
    progress(@"正在检查设备 Wi-Fi…");
    __weak typeof(self) weakSelf = self;

    [self readConnectedDeviceWithCompletion:^(NSString * _Nullable gatewayAddress) {
        if (gatewayAddress != nil) {
            completion(gatewayAddress, nil);
            return;
        }

        [weakSelf scanAndJoinWithProgress:progress completion:completion];
    }];
}

- (void)scanAndJoinWithProgress:(GXDeviceConnectionProgress)progress
                     completion:(GXDeviceConnectionCompletion)completion {
    progress(@"正在搜索附近的设备…");
    __weak typeof(self) weakSelf = self;

    [self.scanner scanForNearestDeviceWithCompletion:^(NSString * _Nullable ssid, NSError * _Nullable scanError) {
        if (ssid == nil) {
            completion(nil, scanError);
            return;
        }

        GXDeviceConnectionCoordinator *coordinator = weakSelf;
        if (coordinator == nil) {
            return;
        }

        progress([NSString stringWithFormat:@"正在加入 %@…", ssid]);
        [coordinator.wifiConnector joinOpenNetworkWithSSID:ssid
                                expectedGatewayAddress:GXDeviceGatewayAddress
                                            completion:completion];
    }];
}

@end

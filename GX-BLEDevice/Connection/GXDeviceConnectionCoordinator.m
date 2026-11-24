#import "GXDeviceConnectionCoordinator.h"

#import "GXBLEScanner.h"
#import "GXWiFiConnector.h"

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

// 串联蓝牙扫描与 Wi-Fi 加入。仅在 Wi-Fi 模块核对成功后交回目标 SSID。
- (void)connectToNearestDeviceWithProgress:(GXDeviceConnectionProgress)progress
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
        [coordinator.wifiConnector joinOpenNetworkWithSSID:ssid completion:^(NSError * _Nullable joinError) {
            if (joinError != nil) {
                completion(nil, joinError);
                return;
            }

            completion(ssid, nil);
        }];
    }];
}

@end

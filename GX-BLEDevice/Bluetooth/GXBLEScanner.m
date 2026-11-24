#import "GXBLEScanner.h"

#import <CoreBluetooth/CoreBluetooth.h>

NSErrorDomain const GXBLEScanErrorDomain = @"GXBLEScanErrorDomain";

static NSString * const GXDeviceNamePrefix = @"FPV-Drone-";
static const NSTimeInterval GXScanDuration = 3.0;
static const NSInteger GXUnavailableRSSI = 127;

@interface GXBLEScanCandidate : NSObject

@property (nonatomic, copy) NSString *ssid;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *RSSISamples;

- (double)medianRSSI;

@end

@implementation GXBLEScanCandidate

// 按信号强度取中位数，减少个别广播的读数波动对选设备的影响。
- (double)medianRSSI {
    NSArray<NSNumber *> *sorted = [self.RSSISamples sortedArrayUsingSelector:@selector(compare:)];
    NSUInteger middle = sorted.count / 2;
    double upper = sorted[middle].doubleValue;

    if (sorted.count % 2 == 0) {
        double lower = sorted[middle - 1].doubleValue;
        return (lower + upper) / 2.0;
    }

    return upper;
}

@end

@interface GXBLEScanner () <CBCentralManagerDelegate>

@property (nonatomic, strong) CBCentralManager *centralManager;
@property (nonatomic, strong) NSMutableDictionary<NSUUID *, GXBLEScanCandidate *> *candidates;
@property (nonatomic, strong, nullable) NSUUID *scanIdentifier;
@property (nonatomic, copy, nullable) GXBLEScanCompletion completion;
@property (nonatomic) BOOL scanning;

@end

@implementation GXBLEScanner

- (void)scanForNearestDeviceWithCompletion:(GXBLEScanCompletion)completion {
    NSAssert(self.completion == nil, @"A scan is already in progress");

    self.completion = completion;
    self.scanIdentifier = [NSUUID UUID];
    self.candidates = [NSMutableDictionary dictionary];

    if (self.centralManager == nil) {
        // 由首页统一展示蓝牙关闭提示，避免系统关闭提示和自定义弹窗同时出现。
        self.centralManager = [[CBCentralManager alloc]
            initWithDelegate:self
            queue:dispatch_get_main_queue()
            options:@{ CBCentralManagerOptionShowPowerAlertKey: @NO }];
    }

    [self handleBluetoothState:self.centralManager.state];
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    [self handleBluetoothState:central.state];
}

// 等待 Core Bluetooth 完成初始化。蓝牙关闭与权限被拒分别对应不同的用户操作。
- (void)handleBluetoothState:(CBManagerState)state {
    if (self.completion == nil) {
        return;
    }

    switch (state) {
        case CBManagerStatePoweredOn:
            if (!self.scanning) {
                [self startScan];
            }
            break;
        case CBManagerStatePoweredOff:
            [self finishWithErrorCode:GXBLEScanErrorPoweredOff
                             message:@"请在 iPhone 的「设置 → 蓝牙」中开启蓝牙，然后返回 App 重新搜索。"];
            break;
        case CBManagerStateUnauthorized:
            [self finishWithErrorCode:GXBLEScanErrorUnauthorized
                             message:@"请允许 GX-BLEDevice 使用蓝牙来搜索附近的设备。"];
            break;
        case CBManagerStateUnsupported:
            [self finishWithErrorCode:GXBLEScanErrorUnsupported
                             message:@"此设备无法使用低功耗蓝牙扫描。"];
            break;
        case CBManagerStateUnknown:
        case CBManagerStateResetting:
            if (self.scanning) {
                [self finishWithErrorCode:GXBLEScanErrorInterrupted
                                 message:@"蓝牙扫描已中断，请重新搜索。"];
            }
            break;
    }
}

- (void)startScan {
    self.scanning = YES;
    [self.centralManager scanForPeripheralsWithServices:nil
        options:@{ CBCentralManagerScanOptionAllowDuplicatesKey: @YES }];

    NSUUID *scanIdentifier = self.scanIdentifier;
    __weak typeof(self) weakSelf = self;
    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(GXScanDuration * NSEC_PER_SEC));

    dispatch_after(deadline, dispatch_get_main_queue(), ^{
        // 蓝牙关闭或重新发起扫描后，旧计时器不得结束新的扫描。
        if ([weakSelf.scanIdentifier isEqual:scanIdentifier]) {
            [weakSelf finishWithStrongestCandidate];
        }
    });
}

// Local Name 由固件设为完整 SSID。用广播值筛选，并按外设标识归集 RSSI。
- (void)centralManager:(CBCentralManager *)central
didDiscoverPeripheral:(CBPeripheral *)peripheral
    advertisementData:(NSDictionary<NSString *, id> *)advertisementData
                 RSSI:(NSNumber *)RSSI {
    if (!self.scanning || RSSI.integerValue == GXUnavailableRSSI) {
        return;
    }

    GXBLEScanCandidate *candidate = self.candidates[peripheral.identifier];
    NSString *localName = advertisementData[CBAdvertisementDataLocalNameKey];

    if (localName != nil) {
        BOOL matchesDevice = [localName hasPrefix:GXDeviceNamePrefix]
            && localName.length > GXDeviceNamePrefix.length
            && [localName lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= 32;

        if (!matchesDevice) {
            return;
        }

        if (![candidate.ssid isEqualToString:localName]) {
            candidate = [[GXBLEScanCandidate alloc] init];
            candidate.ssid = localName;
            candidate.RSSISamples = [NSMutableArray array];
            self.candidates[peripheral.identifier] = candidate;
        }
    }

    [candidate.RSSISamples addObject:RSSI];
}

- (void)finishWithStrongestCandidate {
    GXBLEScanCandidate *strongest = nil;
    double strongestRSSI = 0.0;

    for (GXBLEScanCandidate *candidate in self.candidates.objectEnumerator) {
        double medianRSSI = [candidate medianRSSI];
        BOOL winsTie = strongest != nil && medianRSSI == strongestRSSI
            && [candidate.ssid compare:strongest.ssid options:NSLiteralSearch] == NSOrderedAscending;

        if (strongest == nil || medianRSSI > strongestRSSI || winsTie) {
            strongest = candidate;
            strongestRSSI = medianRSSI;
        }
    }

    if (strongest == nil) {
        [self finishWithErrorCode:GXBLEScanErrorNoDevice
                         message:@"未找到附近的 FPV 设备。请确认设备已开机，再试一次。"];
        return;
    }

    [self finishWithSSID:strongest.ssid error:nil];
}

- (void)finishWithErrorCode:(GXBLEScanErrorCode)code message:(NSString *)message {
    NSError *error = [NSError errorWithDomain:GXBLEScanErrorDomain
                                         code:code
                                     userInfo:@{ NSLocalizedDescriptionKey: message }];
    [self finishWithSSID:nil error:error];
}

// 先停止扫描并清理本次数据，再回调上层，用户可以安全地重新搜索。
- (void)finishWithSSID:(NSString * _Nullable)ssid error:(NSError * _Nullable)error {
    GXBLEScanCompletion completion = self.completion;
    self.completion = nil;
    self.scanIdentifier = nil;

    if (self.scanning && self.centralManager.state == CBManagerStatePoweredOn) {
        [self.centralManager stopScan];
    }

    self.scanning = NO;
    [self.candidates removeAllObjects];
    if (completion != nil) {
        completion(ssid, error);
    }
}

@end

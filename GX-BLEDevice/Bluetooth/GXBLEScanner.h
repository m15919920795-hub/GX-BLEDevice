#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const GXBLEScanErrorDomain;

typedef NS_ENUM(NSInteger, GXBLEScanErrorCode) {
    GXBLEScanErrorPoweredOff = 1,
    GXBLEScanErrorUnauthorized,
    GXBLEScanErrorUnsupported,
    GXBLEScanErrorInterrupted,
    GXBLEScanErrorNoDevice,
};

typedef void (^GXBLEScanCompletion)(NSString * _Nullable ssid, NSError * _Nullable error);

@interface GXBLEScanner : NSObject

// 在主线程启动一次扫描，并在主线程返回选中设备的完整广播名称。
- (void)scanForNearestDeviceWithCompletion:(GXBLEScanCompletion)completion;

@end

NS_ASSUME_NONNULL_END

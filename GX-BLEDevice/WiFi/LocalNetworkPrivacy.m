#import "LocalNetworkPrivacy.h"

#import <UIKit/UIKit.h>

static NSString * const GXLocalNetworkServiceType = @"_lnp._tcp.";
static const NSUInteger GXLocalNetworkActiveChecks = 8;
static const NSTimeInterval GXLocalNetworkCheckInterval = 1.0;

@interface LocalNetworkPrivacy () <NSNetServiceDelegate>

@property (nonatomic, strong, nullable) NSNetService *service;
@property (nonatomic, strong, nullable) NSTimer *timer;
@property (nonatomic, strong) NSMutableArray<LocalNetworkAccessCompletion> *completions;
@property (nonatomic) NSUInteger remainingActiveChecks;

@end

@implementation LocalNetworkPrivacy

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _completions = [NSMutableArray array];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidEnterBackground:)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_timer invalidate];
    _service.delegate = nil;
    [_service stop];
}

// 同一时间只发布一次服务，多个查询共享这次检测结果。
- (void)checkAccessState:(LocalNetworkAccessCompletion)completion {
    [self.completions addObject:[completion copy]];
    if (self.timer != nil) {
        return;
    }

    self.remainingActiveChecks = GXLocalNetworkActiveChecks;
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer timerWithTimeInterval:GXLocalNetworkCheckInterval
                                       repeats:YES
                                         block:^(NSTimer *timer) {
        LocalNetworkPrivacy *privacy = weakSelf;
        if (privacy.timer == timer) {
            [privacy checkPublication];
        }
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
    [self publishIfNeeded];
}

- (void)publishIfNeeded {
    if (self.service != nil) {
        return;
    }

    NSNetService *service = [[NSNetService alloc] initWithDomain:@"local."
                                                           type:GXLocalNetworkServiceType
                                                           name:@"LocalNetworkPrivacy"
                                                           port:1100];
    service.delegate = self;
    self.service = service;
    [service publish];
}

// 系统权限提示暂时使 App 失去焦点时，暂停计时。
- (void)checkPublication {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        return;
    }

    self.remainingActiveChecks -= 1;
    if (self.remainingActiveChecks == 0) {
        [self finishWithAccessConfirmed:NO];
        return;
    }

    [self publishIfNeeded];
}

- (void)netServiceDidPublish:(NSNetService *)sender {
    if (sender == self.service) {
        [self finishWithAccessConfirmed:YES];
    }
}

- (void)netService:(NSNetService *)sender didNotPublish:(NSDictionary<NSString *, NSNumber *> *)errorDict {
    if (sender == self.service) {
        // 首次访问可能在用户回应前就失败。回到前台后可以再次尝试发布。
        [self stopService];
    }
}

- (void)applicationDidEnterBackground:(NSNotification *)notification {
    [self finishWithAccessConfirmed:NO];
}

- (void)stopService {
    NSNetService *service = self.service;
    self.service = nil;
    service.delegate = nil;
    [service stop];
}

// 先收起临时发布和计时器，再回调，避免晚到的事件重复交付结果。
- (void)finishWithAccessConfirmed:(BOOL)accessConfirmed {
    [self.timer invalidate];
    self.timer = nil;
    [self stopService];

    NSArray<LocalNetworkAccessCompletion> *completions = self.completions.copy;
    [self.completions removeAllObjects];
    for (LocalNetworkAccessCompletion completion in completions) {
        completion(accessConfirmed);
    }
}

@end

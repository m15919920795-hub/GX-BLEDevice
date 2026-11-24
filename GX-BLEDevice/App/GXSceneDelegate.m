#import "GXSceneDelegate.h"

#import "GXConnectionViewController.h"
#import "LocalNetworkPrivacy.h"

static NSString * const GXLocalNetworkPermissionAttemptedKey = @"GXLocalNetworkPermissionAttempted";

@interface GXSceneDelegate ()

@property (nonatomic, strong, nullable) LocalNetworkPrivacy *localNetworkPrivacy;

@end

@implementation GXSceneDelegate

- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
                 options:(UISceneConnectionOptions *)connectionOptions {
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
    self.window.rootViewController = [[GXConnectionViewController alloc] init];
    [self.window makeKeyAndVisible];
}

// 首次打开 App 且场景已激活时尝试触发本地网络提示。
- (void)sceneDidBecomeActive:(UIScene *)scene {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults boolForKey:GXLocalNetworkPermissionAttemptedKey]) {
        return;
    }

    [defaults setBool:YES forKey:GXLocalNetworkPermissionAttemptedKey];

    LocalNetworkPrivacy *privacy = [[LocalNetworkPrivacy alloc] init];
    self.localNetworkPrivacy = privacy;
    __weak typeof(self) weakSelf = self;
    [privacy checkAccessState:^(__unused BOOL accessConfirmed) {
        weakSelf.localNetworkPrivacy = nil;
    }];
}

@end

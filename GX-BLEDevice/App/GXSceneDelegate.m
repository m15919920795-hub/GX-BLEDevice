#import "GXSceneDelegate.h"

#import "GXConnectionViewController.h"

@implementation GXSceneDelegate

- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
                 options:(UISceneConnectionOptions *)connectionOptions {
    UIWindowScene *windowScene = (UIWindowScene *)scene;
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
    self.window.rootViewController = [[GXConnectionViewController alloc] init];
    [self.window makeKeyAndVisible];
}

@end

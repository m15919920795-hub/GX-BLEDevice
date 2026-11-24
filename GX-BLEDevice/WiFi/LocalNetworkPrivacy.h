#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^LocalNetworkAccessCompletion)(BOOL accessConfirmed);

@interface LocalNetworkPrivacy : NSObject

// 在主线程发布临时 Bonjour 服务。NO 表示本次未能确认访问权限。
- (void)checkAccessState:(LocalNetworkAccessCompletion)completion;

@end

NS_ASSUME_NONNULL_END

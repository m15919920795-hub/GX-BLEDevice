#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class BKUDPCommandManager;

@interface GXImagePreviewViewController : UIViewController

- (instancetype)initWithCommandManager:(BKUDPCommandManager *)commandManager;

@end

NS_ASSUME_NONNULL_END

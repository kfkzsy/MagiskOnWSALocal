#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Alert-sized, blocking progress card with a Cancel button. Present it with animation;
/// it configures its own over-full-screen, cross-dissolve presentation.
@interface AMProgressController : UIViewController
- (instancetype)initWithTitle:(NSString *)title symbol:(NSString *)symbol;
@property (nonatomic, copy, nullable) void (^cancelHandler)(void);
- (void)setProgress:(double)fraction detail:(nullable NSString *)detail;
@end

NS_ASSUME_NONNULL_END

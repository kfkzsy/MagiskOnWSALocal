#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Records uncaught exceptions and fatal signals to a small file, and offers it on the next launch
/// so the user can send it (the app runs where its developer can't attach a debugger).
@interface AMCrashReporter : NSObject
/// Call first thing in application:didFinishLaunchingWithOptions:.
+ (void)install;
/// The report left by the previous run, if any.
+ (nullable NSString *)pendingReport;
+ (void)clearPendingReport;
/// Shows "上次意外退出" with Share / Copy if a report is pending. Returns YES if it showed something.
+ (BOOL)presentPendingReportFrom:(UIViewController *)vc;
@end

NS_ASSUME_NONNULL_END

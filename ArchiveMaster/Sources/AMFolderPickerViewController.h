#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Lets the user pick a folder inside the app (for "移动到…" and "解压到…").
@interface AMFolderPickerViewController : UITableViewController

/// Presents the picker starting at the Documents root. `excluded` folders (e.g. the ones being
/// moved) can't be entered or chosen. `onPick` runs after the sheet is dismissed.
+ (void)presentFrom:(UIViewController *)vc
              title:(NSString *)title
        actionTitle:(NSString *)actionTitle
           excluded:(NSArray<NSURL *> *)excluded
             onPick:(void (^)(NSURL *directory))onPick;

@end

/// "简介": size, dates, location and type-specific details of a file or folder.
@interface AMInfoViewController : UITableViewController
+ (void)presentForURL:(NSURL *)url from:(UIViewController *)vc;
@end

NS_ASSUME_NONNULL_END

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted when the save location changes (object: the new folder URL).
extern NSNotificationName const AMSaveFolderDidChangeNotification;

/// The app keeps no files of its own: results go to a folder the user picks once in the Files picker
/// (for example "On My iPhone › Downloads"), remembered with a security-scoped bookmark.
@interface AMStorage : NSObject

/// The save location, with access started; nil if none has been chosen (or it was deleted).
+ (nullable NSURL *)saveFolder;
+ (NSString *)saveFolderName;
/// Stores `url` (a security-scoped folder URL from the system picker) as the save location.
+ (BOOL)setSaveFolder:(NSURL *)url;

/// Shows the system folder picker and makes the choice the save location.
+ (void)chooseSaveFolderFrom:(UIViewController *)vc completion:(nullable void (^)(NSURL *_Nullable folder))completion;
/// Runs `block` with the save location, first explaining and asking for one if needed.
+ (void)withSaveFolderFrom:(UIViewController *)vc block:(void (^)(NSURL *folder))block;
/// Shows the system folder picker for a one-off destination (access stays open for this launch).
+ (void)pickFolderFrom:(UIViewController *)vc completion:(void (^)(NSURL *_Nullable folder))completion;
/// Shows the system file picker (files stay where they are; access stays open for this launch).
+ (void)pickFilesOfTypes:(NSArray *)types multiple:(BOOL)multiple from:(UIViewController *)vc
              completion:(void (^)(NSArray<NSURL *> *urls))completion;

/// Files left inside the app by earlier versions (Documents, excluding Inbox and hidden items).
+ (NSArray<NSURL *> *)legacyItems;
/// Bytes the app itself uses (Documents + Library caches + tmp).
+ (unsigned long long)appFootprint;

@end

NS_ASSUME_NONNULL_END

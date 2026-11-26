#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const AMDefaultsFormat;              // NSInteger (am_format)
extern NSString *const AMDefaultsLevel;               // NSInteger 0...9
extern NSString *const AMDefaultsSmartExtract;        // BOOL
extern NSString *const AMDefaultsDeleteAfterExtract;  // BOOL
extern NSString *const AMDefaultsEncoding;            // NSString, "" = auto
extern NSString *const AMDefaultsSort;                // NSInteger (AMSortMode)

/// Posted with a file URL as object: switch to the Files tab and highlight that item.
extern NSNotificationName const AMRevealInFilesNotification;

@interface AMUI : NSObject

+ (NSURL *)documentsURL;
+ (NSString *)byteString:(long long)bytes;
+ (NSString *)dateString:(NSDate *)date;
/// "name.ext" -> "name 2.ext" (keeps compound extensions such as .tar.gz) until it doesn't exist.
+ (NSURL *)uniqueURLForName:(NSString *)name inDirectory:(NSURL *)dir;
+ (unsigned long long)sizeOfItemAtURL:(NSURL *)url;
+ (BOOL)url:(NSURL *)url isInsideDirectory:(NSURL *)dir;

+ (UIViewController *)topPresenterFrom:(UIViewController *)vc;
+ (void)showError:(NSError *)error title:(NSString *)title from:(UIViewController *)vc;
+ (void)showMessage:(nullable NSString *)message title:(NSString *)title from:(UIViewController *)vc;
+ (void)promptWithTitle:(NSString *)title
                message:(nullable NSString *)message
            placeholder:(NSString *)placeholder
                initial:(nullable NSString *)initial
                 secure:(BOOL)secure
           confirmTitle:(NSString *)confirmTitle
                   from:(UIViewController *)vc
                handler:(void (^)(NSString *_Nullable text))handler;
+ (void)toast:(NSString *)text symbol:(nullable NSString *)symbol;
+ (void)share:(NSArray<NSURL *> *)urls
         from:(UIViewController *)vc
   sourceView:(nullable UIView *)view
      barItem:(nullable UIBarButtonItem *)item;

+ (void)hapticSuccess;
+ (void)hapticError;

+ (UIImage *)symbol:(NSString *)name;
+ (UIImage *)symbol:(NSString *)name pointSize:(CGFloat)size;

@end

/// Small factory for HIG-style form rows used by the option sheets and Settings.
@interface AMForm : NSObject
+ (UITableViewCell *)popupCellWithTitle:(NSString *)title
                                options:(NSArray<NSString *> *)options
                               selected:(NSInteger)selected
                                handler:(void (^)(NSInteger index))handler;
+ (UITableViewCell *)switchCellWithTitle:(NSString *)title
                                      on:(BOOL)on
                                 handler:(void (^)(BOOL on))handler
                               outSwitch:(UISwitch *_Nullable *_Nullable)outSwitch;
+ (UITableViewCell *)segmentedCellWithItems:(NSArray<NSString *> *)items
                                   selected:(NSInteger)selected
                                    handler:(void (^)(NSInteger index))handler;
+ (UITableViewCell *)textFieldCellWithPlaceholder:(NSString *)placeholder
                                             text:(nullable NSString *)text
                                           secure:(BOOL)secure
                                     outTextField:(UITextField *_Nullable *_Nonnull)outField;
+ (UITableViewCell *)sliderCellWithTitle:(NSString *)title
                                   value:(float)value
                                     min:(float)min
                                     max:(float)max
                                  format:(NSString *(^)(float value))format
                                 handler:(void (^)(float value))handler;
+ (UITableViewCell *)valueCellWithTitle:(NSString *)title
                                 detail:(nullable NSString *)detail
                                 symbol:(nullable NSString *)symbol
                                   tint:(nullable UIColor *)tint
                              accessory:(UITableViewCellAccessoryType)accessory;
@end

NS_ASSUME_NONNULL_END

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Localized UI string. Keys are the Simplified Chinese text (the development language);
/// other languages map them in <lang>.lproj/Localizable.strings.
#define L(s) [NSBundle.mainBundle localizedStringForKey:(s) value:(s) table:nil]

extern NSString *const AMDefaultsFormat;              // NSInteger (am_format)
extern NSString *const AMDefaultsLevel;               // NSInteger 0...9
extern NSString *const AMDefaultsSmartExtract;        // BOOL
extern NSString *const AMDefaultsDeleteAfterExtract;  // BOOL
extern NSString *const AMDefaultsEncoding;            // NSString, "" = auto
extern NSString *const AMDefaultsSort;                // NSInteger (AMSortMode)

/// Posted with a file URL as object: switch to the Files tab and highlight that item.
extern NSNotificationName const AMRevealInFilesNotification;
/// Posted with an NSArray<NSURL *> of image/video files: open them in the Photos tab for compression.
extern NSNotificationName const AMCompressMediaNotification;

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

/// Keeps the app running briefly in the background and stops auto-lock while long work runs.
+ (id)beginLongOperation;
+ (void)endLongOperation:(nullable id)token;

/// Rounds to a "nice" size (10 KB steps below 1 MB, 0.1 MB steps above).
+ (long long)niceBytes:(long long)bytes;

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
                                 handler:(void (^)(float value))handler
                               outSlider:(UISlider *_Nullable *_Nullable)outSlider;
/// Row with a title and a button that opens `menu` (the button title doesn't change).
+ (UITableViewCell *)menuCellWithTitle:(NSString *)title buttonTitle:(NSString *)buttonTitle menu:(UIMenu *)menu;
/// Tappable row styled like a button (tinted text, optional symbol).
+ (UITableViewCell *)actionCellWithTitle:(NSString *)title symbol:(nullable NSString *)symbol destructive:(BOOL)destructive;
+ (UITableViewCell *)valueCellWithTitle:(NSString *)title
                                 detail:(nullable NSString *)detail
                                 symbol:(nullable NSString *)symbol
                                   tint:(nullable UIColor *)tint
                              accessory:(UITableViewCellAccessoryType)accessory;
@end

NS_ASSUME_NONNULL_END

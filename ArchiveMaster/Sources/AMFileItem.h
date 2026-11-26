#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, AMSortMode) {
    AMSortByName = 0,
    AMSortByDate,
    AMSortBySize,
    AMSortByKind,
};

typedef NS_ENUM(NSInteger, AMFileKind) {
    AMFileKindFolder,
    AMFileKindArchive,
    AMFileKindImage,
    AMFileKindVideo,
    AMFileKindAudio,
    AMFileKindPDF,
    AMFileKindText,
    AMFileKindOther,
};

@interface AMFileItem : NSObject
@property (nonatomic, readonly) NSURL *url;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) BOOL isDirectory;
@property (nonatomic, readonly) unsigned long long size;
@property (nonatomic, readonly, nullable) NSDate *modified;
@property (nonatomic, readonly) NSInteger childCount;  // folders only
@property (nonatomic, readonly) AMFileKind kind;

+ (NSArray<AMFileItem *> *)itemsInDirectory:(NSURL *)directory sort:(AMSortMode)sort;
+ (AMFileKind)kindForFileName:(NSString *)name;
+ (NSString *)symbolForKind:(AMFileKind)kind;
+ (UIColor *)colorForKind:(AMFileKind)kind;

- (NSString *)subtitle;
/// Whether QuickLook can render a thumbnail worth showing instead of the symbol.
- (BOOL)wantsThumbnail;
@end

NS_ASSUME_NONNULL_END

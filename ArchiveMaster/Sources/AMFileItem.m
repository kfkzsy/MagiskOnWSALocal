#import "AMFileItem.h"
#import "AMArchiver.h"
#import "AMUI.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface AMFileItem ()
@property (nonatomic, readwrite) NSURL *url;
@property (nonatomic, readwrite, copy) NSString *name;
@property (nonatomic, readwrite) BOOL isDirectory;
@property (nonatomic, readwrite) unsigned long long size;
@property (nonatomic, readwrite, nullable) NSDate *modified;
@property (nonatomic, readwrite) NSInteger childCount;
@property (nonatomic, readwrite) AMFileKind kind;
@end

@implementation AMFileItem

+ (NSArray<AMFileItem *> *)itemsInDirectory:(NSURL *)directory sort:(AMSortMode)sort {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray *keys = @[ NSURLIsDirectoryKey, NSURLFileSizeKey, NSURLContentModificationDateKey ];
    NSArray<NSURL *> *urls = [fm contentsOfDirectoryAtURL:directory
                               includingPropertiesForKeys:keys
                                                  options:NSDirectoryEnumerationSkipsHiddenFiles
                                                    error:nil];
    BOOL isRoot = [directory.URLByResolvingSymlinksInPath.path isEqualToString:AMUI.documentsURL.URLByResolvingSymlinksInPath.path];
    NSMutableArray<AMFileItem *> *items = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSURL *u in urls) {
        NSDictionary *v = [u resourceValuesForKeys:keys error:nil];
        AMFileItem *i = [AMFileItem new];
        i.url = u;
        i.name = u.lastPathComponent;
        i.isDirectory = [v[NSURLIsDirectoryKey] boolValue];
        i.size = [v[NSURLFileSizeKey] unsignedLongLongValue];
        i.modified = v[NSURLContentModificationDateKey];
        if (i.isDirectory) {
            NSArray *children = [fm contentsOfDirectoryAtURL:u includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
            i.childCount = (NSInteger)children.count;
            // The system drops files shared with the app into Documents/Inbox; hide it when empty.
            if (isRoot && [i.name isEqualToString:@"Inbox"] && i.childCount == 0) continue;
            i.kind = AMFileKindFolder;
        } else {
            i.kind = [self kindForFileName:i.name];
        }
        [items addObject:i];
    }
    [items sortUsingComparator:^NSComparisonResult(AMFileItem *a, AMFileItem *b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? NSOrderedAscending : NSOrderedDescending;
        NSComparisonResult r = NSOrderedSame;
        switch (sort) {
        case AMSortByDate: r = [b.modified ?: NSDate.distantPast compare:a.modified ?: NSDate.distantPast]; break;
        case AMSortBySize:
            if (a.size != b.size) r = a.size > b.size ? NSOrderedAscending : NSOrderedDescending;
            break;
        case AMSortByKind:
            if (a.kind != b.kind) r = a.kind < b.kind ? NSOrderedAscending : NSOrderedDescending;
            else r = [a.name.pathExtension localizedCaseInsensitiveCompare:b.name.pathExtension];
            break;
        case AMSortByName: break;
        }
        return r != NSOrderedSame ? r : [a.name localizedStandardCompare:b.name];
    }];
    return items;
}

+ (AMFileKind)kindForFileName:(NSString *)name {
    if ([AMArchiver isArchiveURL:[NSURL fileURLWithPath:name]]) return AMFileKindArchive;
    UTType *t = [UTType typeWithFilenameExtension:name.pathExtension];
    if (!t) return AMFileKindOther;
    if ([t conformsToType:UTTypeImage]) return AMFileKindImage;
    if ([t conformsToType:UTTypeAudiovisualContent] && ![t conformsToType:UTTypeAudio]) return AMFileKindVideo;
    if ([t conformsToType:UTTypeAudio]) return AMFileKindAudio;
    if ([t conformsToType:UTTypePDF]) return AMFileKindPDF;
    if ([t conformsToType:UTTypeText] || [t conformsToType:UTTypeSourceCode]) return AMFileKindText;
    if ([t conformsToType:UTTypeArchive]) return AMFileKindArchive;
    return AMFileKindOther;
}

+ (NSString *)symbolForKind:(AMFileKind)kind {
    switch (kind) {
    case AMFileKindFolder: return @"folder.fill";
    case AMFileKindArchive: return @"doc.zipper";
    case AMFileKindImage: return @"photo";
    case AMFileKindVideo: return @"film";
    case AMFileKindAudio: return @"music.note";
    case AMFileKindPDF: return @"doc.richtext";
    case AMFileKindText: return @"doc.text";
    case AMFileKindOther: return @"doc";
    }
    return @"doc";
}

+ (UIColor *)colorForKind:(AMFileKind)kind {
    switch (kind) {
    case AMFileKindFolder: return UIColor.systemBlueColor;
    case AMFileKindArchive: return UIColor.systemOrangeColor;
    case AMFileKindImage: return UIColor.systemGreenColor;
    case AMFileKindVideo: return UIColor.systemPurpleColor;
    case AMFileKindAudio: return UIColor.systemPinkColor;
    case AMFileKindPDF: return UIColor.systemRedColor;
    case AMFileKindText: return UIColor.systemGrayColor;
    case AMFileKindOther: return UIColor.systemGrayColor;
    }
    return UIColor.systemGrayColor;
}

- (NSString *)subtitle {
    NSString *date = self.modified ? [AMUI dateString:self.modified] : @"";
    if (self.isDirectory) {
        NSString *count = self.childCount == 0 ? L(@"空") : [NSString stringWithFormat:L(@"%ld 项"), (long)self.childCount];
        return date.length ? [NSString stringWithFormat:@"%@ · %@", date, count] : count;
    }
    NSString *size = [AMUI byteString:(long long)self.size];
    if (self.kind == AMFileKindArchive)
        return [NSString stringWithFormat:@"%@ · %@ · %@", [AMArchiver kindForArchive:self.name], size, date];
    return date.length ? [NSString stringWithFormat:@"%@ · %@", date, size] : size;
}

- (BOOL)wantsThumbnail {
    return self.kind == AMFileKindImage || self.kind == AMFileKindVideo || self.kind == AMFileKindPDF;
}

@end

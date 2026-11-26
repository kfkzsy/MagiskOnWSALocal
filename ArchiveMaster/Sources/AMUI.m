#import "AMUI.h"
#import <objc/message.h>

NSString *const AMDefaultsFormat = @"AMDefaultFormat";
NSString *const AMDefaultsLevel = @"AMDefaultLevel";
NSString *const AMDefaultsSmartExtract = @"AMSmartExtract";
NSString *const AMDefaultsDeleteAfterExtract = @"AMDeleteAfterExtract";
NSString *const AMDefaultsEncoding = @"AMFilenameEncoding";
NSString *const AMDefaultsSort = @"AMSortMode";
NSNotificationName const AMRevealInFilesNotification = @"AMRevealInFilesNotification";
NSNotificationName const AMCompressMediaNotification = @"AMCompressMediaNotification";

static const NSInteger kToastTag = 0x70A57;
static NSInteger AMActiveOperations = 0;

@interface AMLongOperation : NSObject
@property (nonatomic) UIBackgroundTaskIdentifier task;
@property (nonatomic) BOOL finished;
- (void)endTask;
@end

@implementation AMLongOperation
- (void)endTask {
    if (self.task != UIBackgroundTaskInvalid) {
        [UIApplication.sharedApplication endBackgroundTask:self.task];
        self.task = UIBackgroundTaskInvalid;
    }
}
@end

@implementation AMUI

+ (NSURL *)documentsURL {
    return [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
}

+ (NSString *)byteString:(long long)bytes {
    return [NSByteCountFormatter stringFromByteCount:MAX(bytes, 0) countStyle:NSByteCountFormatterCountStyleFile];
}

+ (NSString *)dateString:(NSDate *)date {
    static NSDateFormatter *today, *other;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        today = [NSDateFormatter new];
        today.dateStyle = NSDateFormatterNoStyle;
        today.timeStyle = NSDateFormatterShortStyle;
        other = [NSDateFormatter new];
        other.dateStyle = NSDateFormatterShortStyle;
        other.timeStyle = NSDateFormatterShortStyle;
    });
    if (!date) return @"";
    if ([NSCalendar.currentCalendar isDateInToday:date]) return [NSString stringWithFormat:L(@"今天 %@"), [today stringFromDate:date]];
    if ([NSCalendar.currentCalendar isDateInYesterday:date]) return [NSString stringWithFormat:L(@"昨天 %@"), [today stringFromDate:date]];
    return [other stringFromDate:date];
}

+ (NSURL *)uniqueURLForName:(NSString *)name inDirectory:(NSURL *)dir {
    NSString *clean = [[name stringByReplacingOccurrencesOfString:@"/" withString:@"-"]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (clean.length == 0 || [clean isEqualToString:@"."] || [clean isEqualToString:@".."]) clean = L(@"未命名");
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *url = [dir URLByAppendingPathComponent:clean];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:url.path isDirectory:&isDir]) return url;

    NSString *base = clean, *ext = @"";
    if (!isDir) {
        NSString *lower = clean.lowercaseString;
        BOOL found = NO;
        for (NSString *c in @[ @".tar.gz", @".tar.bz2", @".tar.xz", @".tar.zst", @".tar.lz4" ]) {
            if ([lower hasSuffix:c] && lower.length > c.length) {
                base = [clean substringToIndex:clean.length - c.length];
                ext = [clean substringFromIndex:clean.length - c.length];
                found = YES;
                break;
            }
        }
        if (!found && clean.pathExtension.length && clean.stringByDeletingPathExtension.length) {
            base = clean.stringByDeletingPathExtension;
            ext = [@"." stringByAppendingString:clean.pathExtension];
        }
    }
    for (NSInteger i = 2;; i++) {
        url = [dir URLByAppendingPathComponent:[NSString stringWithFormat:@"%@ %ld%@", base, (long)i, ext]];
        if (![fm fileExistsAtPath:url.path]) return url;
    }
}

+ (unsigned long long)sizeOfItemAtURL:(NSURL *)url {
    NSNumber *isDir = nil;
    [url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
    if (!isDir.boolValue) {
        NSNumber *size = nil;
        [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        return size.unsignedLongLongValue;
    }
    unsigned long long total = 0;
    NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtURL:url
                                                  includingPropertiesForKeys:@[ NSURLFileSizeKey ]
                                                                     options:0
                                                                errorHandler:nil];
    for (NSURL *u in e) {
        NSNumber *size = nil;
        [u getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        total += size.unsignedLongLongValue;
    }
    return total;
}

+ (BOOL)url:(NSURL *)url isInsideDirectory:(NSURL *)dir {
    NSString *p = url.URLByResolvingSymlinksInPath.path.stringByStandardizingPath;
    NSString *d = dir.URLByResolvingSymlinksInPath.path.stringByStandardizingPath;
    return [p isEqualToString:d] || [p hasPrefix:[d stringByAppendingString:@"/"]];
}

#pragma mark - Alerts

+ (UIViewController *)topPresenterFrom:(UIViewController *)vc {
    UIViewController *top = vc.view.window.rootViewController ?: vc;
    while (top.presentedViewController && !top.presentedViewController.isBeingDismissed)
        top = top.presentedViewController;
    return top;
}

+ (void)showError:(NSError *)error title:(NSString *)title from:(UIViewController *)vc {
    NSString *msg = error.localizedDescription;
    if (error.localizedFailureReason.length) msg = [msg stringByAppendingFormat:@"\n\n%@", error.localizedFailureReason];
    [self showMessage:msg title:title from:vc];
}

+ (void)showMessage:(NSString *)message title:(NSString *)title from:(UIViewController *)vc {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:L(@"好") style:UIAlertActionStyleCancel handler:nil]];
    [[self topPresenterFrom:vc] presentViewController:a animated:YES completion:nil];
}

+ (void)promptWithTitle:(NSString *)title
                message:(NSString *)message
            placeholder:(NSString *)placeholder
                initial:(NSString *)initial
                 secure:(BOOL)secure
           confirmTitle:(NSString *)confirmTitle
                   from:(UIViewController *)vc
                handler:(void (^)(NSString *))handler {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    __block UIAlertAction *ok = nil;
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = placeholder;
        tf.text = initial;
        tf.secureTextEntry = secure;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.returnKeyType = UIReturnKeyDone;
        __weak UITextField *weakTF = tf;
        [tf addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
                ok.enabled = weakTF.text.length > 0;
            }]
            forControlEvents:UIControlEventEditingChanged];
    }];
    [a addAction:[UIAlertAction actionWithTitle:L(@"取消") style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) {
           handler(nil);
       }]];
    __weak UIAlertController *weakA = a;
    ok = [UIAlertAction actionWithTitle:confirmTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        handler(weakA.textFields.firstObject.text);
    }];
    ok.enabled = initial.length > 0;
    [a addAction:ok];
    a.preferredAction = ok;
    [[self topPresenterFrom:vc] presentViewController:a animated:YES completion:^{
        // Like Files: when renaming, pre-select the name without its extension.
        UITextField *tf = weakA.textFields.firstObject;
        NSString *ext = initial.pathExtension;
        if (!secure && initial.length && ext.length && tf) {
            NSInteger len = (NSInteger)initial.length - (NSInteger)ext.length - 1;
            UITextPosition *start = tf.beginningOfDocument;
            UITextPosition *end = [tf positionFromPosition:start offset:len];
            if (start && end) tf.selectedTextRange = [tf textRangeFromPosition:start toPosition:end];
        }
    }];
}

+ (UIWindow *)keyWindow {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows)
            if (w.isKeyWindow) return w;
    }
    return nil;
}

+ (void)toast:(NSString *)text symbol:(NSString *)symbol {
    UIWindow *window = [self keyWindow];
    if (!window) return;
    [[window viewWithTag:kToastTag] removeFromSuperview];

    UIVisualEffectView *bg = [[UIVisualEffectView alloc] initWithEffect:[self glassEffectWithFallback:UIBlurEffectStyleSystemChromeMaterial interactive:NO]];
    bg.tag = kToastTag;
    bg.translatesAutoresizingMaskIntoConstraints = NO;
    bg.layer.cornerCurve = kCACornerCurveContinuous;
    bg.clipsToBounds = !self.hasLiquidGlass;
    bg.layer.cornerRadius = 22;
    bg.isAccessibilityElement = YES;
    bg.accessibilityLabel = text;

    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    label.adjustsFontForContentSizeCategory = YES;
    label.numberOfLines = 2;
    label.textAlignment = NSTextAlignmentCenter;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ label ]];
    if (symbol) {
        UIImageView *iv = [[UIImageView alloc] initWithImage:[self symbol:symbol pointSize:17]];
        iv.tintColor = UIColor.systemGreenColor;
        [iv setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [stack insertArrangedSubview:iv atIndex:0];
    }
    stack.spacing = 8;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [bg.contentView addSubview:stack];
    [window addSubview:bg];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:bg.contentView.leadingAnchor constant:18],
        [stack.trailingAnchor constraintEqualToAnchor:bg.contentView.trailingAnchor constant:-18],
        [stack.topAnchor constraintEqualToAnchor:bg.contentView.topAnchor constant:11],
        [stack.bottomAnchor constraintEqualToAnchor:bg.contentView.bottomAnchor constant:-11],
        [bg.centerXAnchor constraintEqualToAnchor:window.centerXAnchor],
        [bg.widthAnchor constraintLessThanOrEqualToAnchor:window.widthAnchor constant:-48],
        [bg.bottomAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.bottomAnchor constant:-64],
    ]];
    bg.alpha = 0;
    bg.transform = CGAffineTransformMakeTranslation(0, 12);
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, text);
    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0 options:0 animations:^{
        bg.alpha = 1;
        bg.transform = CGAffineTransformIdentity;
    } completion:nil];
    [UIView animateWithDuration:0.25 delay:2.2 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        bg.alpha = 0;
    } completion:^(BOOL finished) {
        [bg removeFromSuperview];
    }];
}

+ (void)share:(NSArray<NSURL *> *)urls from:(UIViewController *)vc sourceView:(UIView *)view barItem:(UIBarButtonItem *)item {
    if (urls.count == 0) return;
    UIActivityViewController *a = [[UIActivityViewController alloc] initWithActivityItems:urls applicationActivities:nil];
    UIPopoverPresentationController *pop = a.popoverPresentationController;
    if (item) pop.barButtonItem = item;
    else if (view) { pop.sourceView = view; pop.sourceRect = view.bounds; }
    else { pop.sourceView = vc.view; pop.sourceRect = CGRectMake(CGRectGetMidX(vc.view.bounds), CGRectGetMidY(vc.view.bounds), 1, 1); }
    [[self topPresenterFrom:vc] presentViewController:a animated:YES completion:nil];
}

+ (void)hapticSuccess {
    [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeSuccess];
}

+ (void)hapticError {
    [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeError];
}

+ (id)beginLongOperation {
    AMLongOperation *op = [AMLongOperation new];
    UIApplication *app = UIApplication.sharedApplication;
    __weak AMLongOperation *weakOp = op;
    op.task = [app beginBackgroundTaskWithName:@"ArchiveMaster" expirationHandler:^{
        [weakOp endTask];
    }];
    if (AMActiveOperations++ == 0) app.idleTimerDisabled = YES;
    return op;
}

+ (void)endLongOperation:(id)token {
    if (![token isKindOfClass:AMLongOperation.class]) return;
    AMLongOperation *op = token;
    if (op.finished) return;
    op.finished = YES;
    [op endTask];
    if (AMActiveOperations > 0 && --AMActiveOperations == 0) UIApplication.sharedApplication.idleTimerDisabled = NO;
}

+ (long long)niceBytes:(long long)bytes {
    const long long KB = 1024, MB = 1024 * 1024;
    if (bytes < MB) return MAX(10 * KB, (bytes + 5 * KB) / (10 * KB) * (10 * KB));
    long long tenth = MB / 10;
    return (bytes + tenth / 2) / tenth * tenth;
}

#pragma mark - Liquid Glass

+ (BOOL)hasLiquidGlass {
    static BOOL has;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ has = NSClassFromString(@"UIGlassEffect") != nil; });
    return has;
}

+ (UIVisualEffect *)glassEffectWithFallback:(UIBlurEffectStyle)fallback interactive:(BOOL)interactive {
    Class glass = NSClassFromString(@"UIGlassEffect");
    SEL make = NSSelectorFromString(@"effectWithStyle:");
    if (glass && [glass respondsToSelector:make]) {
        UIVisualEffect *(*send)(id, SEL, NSInteger) = (void *)objc_msgSend;
        UIVisualEffect *effect = send(glass, make, 0 /* UIGlassEffectStyleRegular */);
        if (interactive && [effect respondsToSelector:NSSelectorFromString(@"setInteractive:")]) [effect setValue:@YES forKey:@"interactive"];
        if (effect) return effect;
    }
    return [UIBlurEffect effectWithStyle:fallback];
}

static UIButtonConfiguration *AMButtonConfiguration(NSString *selectorName) {
    SEL sel = NSSelectorFromString(selectorName);
    if (![UIButtonConfiguration respondsToSelector:sel]) return nil;
    UIButtonConfiguration *(*send)(id, SEL) = (void *)objc_msgSend;
    return send(UIButtonConfiguration.class, sel);
}

+ (UIButtonConfiguration *)prominentButtonConfiguration {
    UIButtonConfiguration *c = AMButtonConfiguration(@"prominentGlassButtonConfiguration");
    if (!c) {
        c = [UIButtonConfiguration filledButtonConfiguration];
        c.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    }
    c.buttonSize = UIButtonConfigurationSizeLarge;
    return c;
}

+ (UIButtonConfiguration *)secondaryButtonConfiguration {
    UIButtonConfiguration *c = AMButtonConfiguration(@"glassButtonConfiguration");
    if (!c) {
        c = [UIButtonConfiguration grayButtonConfiguration];
        c.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    }
    c.buttonSize = UIButtonConfigurationSizeLarge;
    return c;
}

+ (void)configureTabBarController:(UITabBarController *)tabs {
    if ([tabs respondsToSelector:NSSelectorFromString(@"setTabBarMinimizeBehavior:")])
        [tabs setValue:@2 /* UITabBarMinimizeBehaviorOnScrollDown */ forKey:@"tabBarMinimizeBehavior"];
}

+ (BOOL)setSubtitle:(NSString *)subtitle forNavigationItem:(UINavigationItem *)item {
    if (![item respondsToSelector:NSSelectorFromString(@"setSubtitle:")]) return NO;
    [item setValue:subtitle forKey:@"subtitle"];
    return YES;
}

+ (void)applyReadableMarginsToTableView:(UITableView *)tableView {
    CGFloat width = tableView.bounds.size.width;
    if (width <= 0) return;
    const CGFloat maxContent = 700;
    CGFloat side = width >= maxContent + 80 ? floor((width - maxContent) / 2) : (width > 400 ? 20 : 16);
    NSDirectionalEdgeInsets m = tableView.directionalLayoutMargins;
    if (fabs(m.leading - side) < 0.5 && fabs(m.trailing - side) < 0.5) return;
    tableView.directionalLayoutMargins = NSDirectionalEdgeInsetsMake(m.top, side, m.bottom, side);
}

+ (UIImage *)symbol:(NSString *)name {
    return [UIImage systemImageNamed:name] ?: [UIImage systemImageNamed:@"doc"];
}

+ (UIImage *)symbol:(NSString *)name pointSize:(CGFloat)size {
    UIImageSymbolConfiguration *c = [UIImageSymbolConfiguration configurationWithPointSize:size weight:UIImageSymbolWeightRegular];
    return [UIImage systemImageNamed:name withConfiguration:c] ?: [UIImage systemImageNamed:@"doc" withConfiguration:c];
}

@end

#pragma mark - Form rows

@implementation AMForm

static UILabel *AMBodyLabel(NSString *text) {
    UILabel *l = [UILabel new];
    l.text = text;
    l.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    l.adjustsFontForContentSizeCategory = YES;
    l.numberOfLines = 0;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    return l;
}

static UITableViewCell *AMPlainCell(void) {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    NSLayoutConstraint *h = [cell.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:44];
    h.priority = UILayoutPriorityRequired - 1;
    h.active = YES;
    return cell;
}

+ (UITableViewCell *)popupCellWithTitle:(NSString *)title options:(NSArray<NSString *> *)options selected:(NSInteger)selected handler:(void (^)(NSInteger))handler {
    UITableViewCell *cell = AMPlainCell();
    UILabel *label = AMBodyLabel(title);
    UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
    if (@available(iOS 16.0, *)) {
        cfg.indicator = UIButtonConfigurationIndicatorPopup;
    } else {
        cfg.image = [UIImage systemImageNamed:@"chevron.up.chevron.down"
                            withConfiguration:[UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleFootnote]];
        cfg.imagePlacement = NSDirectionalRectEdgeTrailing;
        cfg.imagePadding = 4;
    }
    cfg.contentInsets = NSDirectionalEdgeInsetsMake(8, 8, 8, 0);
    UIButton *button = [UIButton buttonWithConfiguration:cfg primaryAction:nil];
    NSMutableArray<UIAction *> *actions = [NSMutableArray array];
    [options enumerateObjectsUsingBlock:^(NSString *opt, NSUInteger idx, BOOL *stop) {
        UIAction *a = [UIAction actionWithTitle:opt image:nil identifier:nil handler:^(__kindof UIAction *x) {
            handler((NSInteger)idx);
        }];
        if ((NSInteger)idx == selected) a.state = UIMenuElementStateOn;
        [actions addObject:a];
    }];
    button.menu = [UIMenu menuWithTitle:@"" children:actions];
    button.showsMenuAsPrimaryAction = YES;
    button.changesSelectionAsPrimaryAction = YES;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.accessibilityLabel = title;
    [button setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [button setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [label setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [cell.contentView addSubview:label];
    [cell.contentView addSubview:button];
    UILayoutGuide *m = cell.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [label.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [label.topAnchor constraintGreaterThanOrEqualToAnchor:m.topAnchor],
        [label.bottomAnchor constraintLessThanOrEqualToAnchor:m.bottomAnchor],
        [button.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
        [button.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [button.leadingAnchor constraintGreaterThanOrEqualToAnchor:label.trailingAnchor constant:8],
        [button.topAnchor constraintGreaterThanOrEqualToAnchor:cell.contentView.topAnchor],
        [button.bottomAnchor constraintLessThanOrEqualToAnchor:cell.contentView.bottomAnchor],
    ]];
    return cell;
}

+ (UITableViewCell *)switchCellWithTitle:(NSString *)title on:(BOOL)on handler:(void (^)(BOOL))handler outSwitch:(UISwitch **)outSwitch {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UIListContentConfiguration *c = [UIListContentConfiguration cellConfiguration];
    c.text = title;
    cell.contentConfiguration = c;
    UISwitch *sw = [UISwitch new];
    sw.on = on;
    __weak UISwitch *weakSw = sw;
    [sw addAction:[UIAction actionWithHandler:^(__kindof UIAction *a) {
            handler(weakSw.isOn);
        }]
        forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    if (outSwitch) *outSwitch = sw;
    return cell;
}

+ (UITableViewCell *)segmentedCellWithItems:(NSArray<NSString *> *)items selected:(NSInteger)selected handler:(void (^)(NSInteger))handler {
    UITableViewCell *cell = AMPlainCell();
    UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:items];
    seg.selectedSegmentIndex = selected;
    seg.translatesAutoresizingMaskIntoConstraints = NO;
    __weak UISegmentedControl *weakSeg = seg;
    [seg addAction:[UIAction actionWithHandler:^(__kindof UIAction *a) {
             handler(weakSeg.selectedSegmentIndex);
         }]
        forControlEvents:UIControlEventValueChanged];
    [cell.contentView addSubview:seg];
    UILayoutGuide *m = cell.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [seg.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [seg.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
        [seg.topAnchor constraintEqualToAnchor:m.topAnchor],
        [seg.bottomAnchor constraintEqualToAnchor:m.bottomAnchor],
    ]];
    return cell;
}

+ (UITableViewCell *)textFieldCellWithPlaceholder:(NSString *)placeholder text:(NSString *)text secure:(BOOL)secure outTextField:(UITextField **)outField {
    UITableViewCell *cell = AMPlainCell();
    UITextField *tf = [UITextField new];
    tf.placeholder = placeholder;
    tf.text = text;
    tf.secureTextEntry = secure;
    tf.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    tf.adjustsFontForContentSizeCategory = YES;
    tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tf.returnKeyType = UIReturnKeyDone;
    tf.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:tf];
    UILayoutGuide *m = cell.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [tf.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [tf.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
        [tf.topAnchor constraintEqualToAnchor:m.topAnchor],
        [tf.bottomAnchor constraintEqualToAnchor:m.bottomAnchor],
    ]];
    *outField = tf;
    return cell;
}

+ (UITableViewCell *)sliderCellWithTitle:(NSString *)title value:(float)value min:(float)min max:(float)max format:(NSString *(^)(float))format handler:(void (^)(float))handler outSlider:(UISlider **)outSlider {
    UITableViewCell *cell = AMPlainCell();
    UILabel *label = AMBodyLabel(title);
    UILabel *valueLabel = [UILabel new];
    valueLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody]
        scaledFontForFont:[UIFont monospacedDigitSystemFontOfSize:17 weight:UIFontWeightRegular]];
    valueLabel.adjustsFontForContentSizeCategory = YES;
    valueLabel.textColor = UIColor.secondaryLabelColor;
    valueLabel.text = format(value);
    valueLabel.textAlignment = NSTextAlignmentRight;
    valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [valueLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UISlider *slider = [UISlider new];
    slider.minimumValue = min;
    slider.maximumValue = max;
    slider.value = value;
    slider.translatesAutoresizingMaskIntoConstraints = NO;
    slider.accessibilityLabel = title;
    __weak UISlider *weakSlider = slider;
    __weak UILabel *weakValue = valueLabel;
    [slider addAction:[UIAction actionWithHandler:^(__kindof UIAction *a) {
                weakValue.text = format(weakSlider.value);
                handler(weakSlider.value);
            }]
        forControlEvents:UIControlEventValueChanged];
    [cell.contentView addSubview:label];
    [cell.contentView addSubview:valueLabel];
    [cell.contentView addSubview:slider];
    UILayoutGuide *m = cell.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [label.topAnchor constraintEqualToAnchor:m.topAnchor],
        [valueLabel.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
        [valueLabel.firstBaselineAnchor constraintEqualToAnchor:label.firstBaselineAnchor],
        [valueLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:label.trailingAnchor constant:8],
        [slider.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [slider.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
        [slider.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:10],
        [slider.bottomAnchor constraintEqualToAnchor:m.bottomAnchor],
    ]];
    if (outSlider) *outSlider = slider;
    return cell;
}

+ (UITableViewCell *)stepperCellWithTitle:(NSString *)title value:(NSInteger)value min:(NSInteger)min max:(NSInteger)max
                                   format:(NSString *(^)(NSInteger))format handler:(void (^)(NSInteger))handler {
    UITableViewCell *cell = AMPlainCell();
    UILabel *label = AMBodyLabel(title);
    UILabel *valueLabel = [UILabel new];
    valueLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledFontForFont:[UIFont monospacedDigitSystemFontOfSize:17 weight:UIFontWeightRegular]];
    valueLabel.adjustsFontForContentSizeCategory = YES;
    valueLabel.textColor = UIColor.secondaryLabelColor;
    valueLabel.text = format(value);
    valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    UIStepper *stepper = [UIStepper new];
    stepper.minimumValue = min;
    stepper.maximumValue = max;
    stepper.value = value;
    stepper.translatesAutoresizingMaskIntoConstraints = NO;
    stepper.accessibilityLabel = title;
    __weak UIStepper *weakStepper = stepper;
    __weak UILabel *weakValue = valueLabel;
    [stepper addAction:[UIAction actionWithHandler:^(__kindof UIAction *a) {
                 NSInteger v = (NSInteger)weakStepper.value;
                 weakValue.text = format(v);
                 handler(v);
             }]
        forControlEvents:UIControlEventValueChanged];
    [cell.contentView addSubview:label];
    [cell.contentView addSubview:valueLabel];
    [cell.contentView addSubview:stepper];
    UILayoutGuide *m = cell.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [label.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [label.topAnchor constraintGreaterThanOrEqualToAnchor:m.topAnchor],
        [label.bottomAnchor constraintLessThanOrEqualToAnchor:m.bottomAnchor],
        [stepper.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
        [stepper.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [valueLabel.trailingAnchor constraintEqualToAnchor:stepper.leadingAnchor constant:-12],
        [valueLabel.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [valueLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:label.trailingAnchor constant:8],
    ]];
    return cell;
}

+ (UITableViewCell *)menuCellWithTitle:(NSString *)title buttonTitle:(NSString *)buttonTitle menu:(UIMenu *)menu {
    UITableViewCell *cell = AMPlainCell();
    UILabel *label = AMBodyLabel(title);
    UIButtonConfiguration *cfg = [UIButtonConfiguration plainButtonConfiguration];
    cfg.title = buttonTitle;
    cfg.image = [UIImage systemImageNamed:@"chevron.down" withConfiguration:[UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleFootnote]];
    cfg.imagePlacement = NSDirectionalRectEdgeTrailing;
    cfg.imagePadding = 4;
    cfg.contentInsets = NSDirectionalEdgeInsetsMake(8, 8, 8, 0);
    UIButton *button = [UIButton buttonWithConfiguration:cfg primaryAction:nil];
    button.menu = menu;
    button.showsMenuAsPrimaryAction = YES;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [cell.contentView addSubview:label];
    [cell.contentView addSubview:button];
    UILayoutGuide *m = cell.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:m.leadingAnchor],
        [label.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [label.topAnchor constraintGreaterThanOrEqualToAnchor:m.topAnchor],
        [label.bottomAnchor constraintLessThanOrEqualToAnchor:m.bottomAnchor],
        [button.trailingAnchor constraintEqualToAnchor:m.trailingAnchor],
        [button.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
        [button.leadingAnchor constraintGreaterThanOrEqualToAnchor:label.trailingAnchor constant:8],
    ]];
    return cell;
}

+ (UITableViewCell *)actionCellWithTitle:(NSString *)title symbol:(NSString *)symbol destructive:(BOOL)destructive {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    UIListContentConfiguration *c = [UIListContentConfiguration cellConfiguration];
    c.text = title;
    UIColor *color = destructive ? UIColor.systemRedColor : UIColor.tintColor;
    c.textProperties.color = color;
    if (symbol) {
        c.image = [UIImage systemImageNamed:symbol];
        c.imageProperties.tintColor = color;
    }
    cell.contentConfiguration = c;
    cell.accessibilityTraits = UIAccessibilityTraitButton;
    return cell;
}

+ (UITableViewCell *)valueCellWithTitle:(NSString *)title detail:(NSString *)detail symbol:(NSString *)symbol tint:(UIColor *)tint accessory:(UITableViewCellAccessoryType)accessory {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    UIListContentConfiguration *c = [UIListContentConfiguration valueCellConfiguration];
    c.text = title;
    c.secondaryText = detail;
    if (symbol) {
        c.image = [UIImage systemImageNamed:symbol];
        c.imageProperties.tintColor = tint ?: UIColor.tintColor;
    }
    cell.contentConfiguration = c;
    cell.accessoryType = accessory;
    cell.selectionStyle = accessory == UITableViewCellAccessoryNone && !symbol ? UITableViewCellSelectionStyleNone
                                                                              : UITableViewCellSelectionStyleDefault;
    return cell;
}

@end

#import "AMProgressController.h"
#import "AMUI.h"

@interface AMProgressController ()
@property (nonatomic, copy) NSString *titleText;
@property (nonatomic, copy) NSString *symbolName;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UILabel *percentLabel;
@property (nonatomic, strong) UIProgressView *bar;
@property (nonatomic, strong) UIButton *cancelButton;
@end

@implementation AMProgressController

- (instancetype)initWithTitle:(NSString *)title symbol:(NSString *)symbol {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _titleText = [title copy];
        _symbolName = [symbol copy];
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
        self.modalInPresentation = YES;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    BOOL glass = AMUI.hasLiquidGlass;
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:glass ? 0.2 : 0.3];

    UIVisualEffectView *card = [[UIVisualEffectView alloc] initWithEffect:[AMUI glassEffectWithFallback:UIBlurEffectStyleSystemThickMaterial interactive:NO]];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = glass ? 34 : 14;  // iOS 26 alerts are rounder and concentric with the screen
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.clipsToBounds = !glass;
    [self.view addSubview:card];

    UIImageView *icon = [[UIImageView alloc] initWithImage:[AMUI symbol:self.symbolName pointSize:34]];
    icon.tintColor = UIColor.tintColor;
    icon.contentMode = UIViewContentModeCenter;

    UILabel *title = [UILabel new];
    title.text = self.titleText;
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    title.adjustsFontForContentSizeCategory = YES;
    title.textAlignment = NSTextAlignmentCenter;
    title.numberOfLines = 0;
    title.accessibilityTraits = UIAccessibilityTraitHeader;

    self.detailLabel = [UILabel new];
    self.detailLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.detailLabel.adjustsFontForContentSizeCategory = YES;
    self.detailLabel.textColor = UIColor.secondaryLabelColor;
    self.detailLabel.textAlignment = NSTextAlignmentCenter;
    self.detailLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.detailLabel.text = @" ";

    self.bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];

    self.percentLabel = [UILabel new];
    self.percentLabel.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption1]
        scaledFontForFont:[UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular]];
    self.percentLabel.adjustsFontForContentSizeCategory = YES;
    self.percentLabel.textColor = UIColor.secondaryLabelColor;
    self.percentLabel.textAlignment = NSTextAlignmentCenter;
    self.percentLabel.text = @"0%";

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ icon, title, self.detailLabel, self.bar, self.percentLabel ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    [stack setCustomSpacing:14 afterView:self.detailLabel];
    [stack setCustomSpacing:6 afterView:self.bar];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card.contentView addSubview:stack];

    if (glass) {
        // iOS 26 style: a capsule button inside the card.
        UIButtonConfiguration *cfg = AMUI.secondaryButtonConfiguration;
        cfg.title = L(@"取消");
        self.cancelButton = [UIButton buttonWithConfiguration:cfg primaryAction:nil];
        [self.cancelButton addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];
        [stack addArrangedSubview:self.cancelButton];
        [stack setCustomSpacing:20 afterView:self.percentLabel];
        [NSLayoutConstraint activateConstraints:@[
            [card.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
            [card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
            [card.widthAnchor constraintEqualToConstant:300],
            [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:24],
            [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:22],
            [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-22],
            [stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-22],
        ]];
    } else {
        UIView *separator = [UIView new];
        separator.backgroundColor = UIColor.separatorColor;
        separator.translatesAutoresizingMaskIntoConstraints = NO;
        [card.contentView addSubview:separator];
        self.cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [self.cancelButton setTitle:L(@"取消") forState:UIControlStateNormal];
        self.cancelButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        self.cancelButton.titleLabel.adjustsFontForContentSizeCategory = YES;
        self.cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
        [self.cancelButton addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];
        [card.contentView addSubview:self.cancelButton];
        CGFloat hairline = 1.0 / MAX(1.0, self.traitCollection.displayScale);
        [NSLayoutConstraint activateConstraints:@[
            [card.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
            [card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
            [card.widthAnchor constraintEqualToConstant:280],
            [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:20],
            [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:20],
            [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-20],
            [separator.topAnchor constraintEqualToAnchor:stack.bottomAnchor constant:16],
            [separator.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
            [separator.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
            [separator.heightAnchor constraintEqualToConstant:hairline],
            [self.cancelButton.topAnchor constraintEqualToAnchor:separator.bottomAnchor],
            [self.cancelButton.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor],
            [self.cancelButton.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor],
            [self.cancelButton.heightAnchor constraintGreaterThanOrEqualToConstant:44],
            [self.cancelButton.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor],
        ]];
    }
    self.view.accessibilityViewIsModal = YES;
}

- (void)setProgress:(double)fraction detail:(NSString *)detail {
    [self loadViewIfNeeded];
    if (detail.length) self.detailLabel.text = detail;
    [self.bar setProgress:(float)fraction animated:YES];
    NSString *pct = [NSString stringWithFormat:@"%ld%%", (long)lround(fraction * 100)];
    self.percentLabel.text = pct;
    self.bar.accessibilityValue = pct;
}

- (void)cancelTapped {
    self.cancelButton.enabled = NO;
    if (self.cancelButton.configuration) {
        UIButtonConfiguration *c = self.cancelButton.configuration;
        c.title = L(@"正在取消…");
        self.cancelButton.configuration = c;
    } else {
        [self.cancelButton setTitle:L(@"正在取消…") forState:UIControlStateDisabled];
    }
    if (self.cancelHandler) self.cancelHandler();
}

@end

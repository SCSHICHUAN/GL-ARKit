/*
  GameViewController.mm
  UI host: embeds SCRenderer full-screen; draws buttons / move pad.
*/

#import "GameViewController.h"
#import "SCRenderer.h"

@interface GameViewController ()
@property (nonatomic, strong) SCRenderer *glView;
@property (nonatomic, strong) UIStackView *animBar;
@property (nonatomic, strong) UIStackView *movePad;
@end

@implementation GameViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

    self.glView = [[SCRenderer alloc] initWithFrame:self.view.bounds];
    self.glView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.glView];
    [self.glView startRendering];

    [self setupControls];
}

#pragma mark - Controls (UI only)

- (UIButton *)makeButton:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightSemibold];
    b.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.45];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.layer.cornerRadius = 8;
    b.contentEdgeInsets = UIEdgeInsetsMake(8, 10, 8, 10);
    if (action) {
        [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    }
    return b;
}

- (UIButton *)makeHoldButton:(NSString *)title began:(SEL)began ended:(SEL)ended {
    UIButton *b = [self makeButton:title action:nil];
    [b addTarget:self action:began forControlEvents:UIControlEventTouchDown];
    [b addTarget:self action:ended forControlEvents:UIControlEventTouchUpInside];
    [b addTarget:self action:ended forControlEvents:UIControlEventTouchUpOutside];
    [b addTarget:self action:ended forControlEvents:UIControlEventTouchCancel];
    return b;
}

- (void)setupControls {
    self.animBar = [[UIStackView alloc] init];
    self.animBar.axis = UILayoutConstraintAxisHorizontal;
    self.animBar.spacing = 6;
    self.animBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.animBar addArrangedSubview:[self makeButton:@"Walk" action:@selector(playWalk)]];
    [self.animBar addArrangedSubview:[self makeButton:@"Run" action:@selector(playRun)]];
    [self.animBar addArrangedSubview:[self makeButton:@"Crawl" action:@selector(playCrawl)]];
    [self.animBar addArrangedSubview:[self makeButton:@"Idle" action:@selector(playIdle)]];
    [self.animBar addArrangedSubview:[self makeButton:@"<" action:@selector(browsePrev)]];
    [self.animBar addArrangedSubview:[self makeButton:@">" action:@selector(browseNext)]];
    [self.animBar addArrangedSubview:[self makeButton:@"Pause" action:@selector(togglePause)]];
    [self.view addSubview:self.animBar];

    self.movePad = [[UIStackView alloc] init];
    self.movePad.axis = UILayoutConstraintAxisVertical;
    self.movePad.spacing = 6;
    self.movePad.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *rowW = [[UIStackView alloc] init];
    rowW.axis = UILayoutConstraintAxisHorizontal;
    [rowW addArrangedSubview:[self makeHoldButton:@"W" began:@selector(fwdOn) ended:@selector(fwdOff)]];

    UIStackView *rowAD = [[UIStackView alloc] init];
    rowAD.axis = UILayoutConstraintAxisHorizontal;
    rowAD.spacing = 6;
    [rowAD addArrangedSubview:[self makeHoldButton:@"A" began:@selector(leftOn) ended:@selector(leftOff)]];
    [rowAD addArrangedSubview:[self makeHoldButton:@"S" began:@selector(backOn) ended:@selector(backOff)]];
    [rowAD addArrangedSubview:[self makeHoldButton:@"D" began:@selector(rightOn) ended:@selector(rightOff)]];

    UIStackView *rowUF = [[UIStackView alloc] init];
    rowUF.axis = UILayoutConstraintAxisHorizontal;
    rowUF.spacing = 6;
    [rowUF addArrangedSubview:[self makeHoldButton:@"Up" began:@selector(upOn) ended:@selector(upOff)]];
    [rowUF addArrangedSubview:[self makeHoldButton:@"Dn" began:@selector(downOn) ended:@selector(downOff)]];

    [self.movePad addArrangedSubview:rowW];
    [self.movePad addArrangedSubview:rowAD];
    [self.movePad addArrangedSubview:rowUF];
    [self.view addSubview:self.movePad];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.animBar.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:8],
        [self.animBar.trailingAnchor constraintLessThanOrEqualToAnchor:g.trailingAnchor constant:-8],
        [self.animBar.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
        [self.movePad.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:12],
        [self.movePad.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-12],
    ]];
}

#pragma mark - Button → SCRenderer

- (void)playWalk { [self.glView playWalk]; }
- (void)playRun { [self.glView playRun]; }
- (void)playCrawl { [self.glView playCrawl]; }
- (void)playIdle { [self.glView playIdle]; }
- (void)browsePrev { [self.glView browsePrevAnim]; }
- (void)browseNext { [self.glView browseNextAnim]; }
- (void)togglePause { [self.glView toggleAnimPause]; }

- (void)fwdOn { [self.glView setMoveForward:YES]; }
- (void)fwdOff { [self.glView setMoveForward:NO]; }
- (void)backOn { [self.glView setMoveBackward:YES]; }
- (void)backOff { [self.glView setMoveBackward:NO]; }
- (void)leftOn { [self.glView setMoveLeft:YES]; }
- (void)leftOff { [self.glView setMoveLeft:NO]; }
- (void)rightOn { [self.glView setMoveRight:YES]; }
- (void)rightOff { [self.glView setMoveRight:NO]; }
- (void)upOn { [self.glView setMoveUp:YES]; }
- (void)upOff { [self.glView setMoveUp:NO]; }
- (void)downOn { [self.glView setMoveDown:YES]; }
- (void)downOff { [self.glView setMoveDown:NO]; }

@end

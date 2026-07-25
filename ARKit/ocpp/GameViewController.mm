/*
  GameViewController.mm
  UI host: embeds SCRenderer; horizontal CollectionView of model animation clips.
  Also starts SCARKitSession to dump head/body/face (not linked to model yet).
*/

#import "GameViewController.h"
#import "SCRenderer.h"
#import "arkit/SCARKitSession.h"

static NSString * const kAnimCellId = @"AnimClipCell";

@interface AnimClipCell : UICollectionViewCell
@property (nonatomic, strong) UILabel *titleLabel;
@end

@implementation AnimClipCell
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.contentView.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.45];
        self.contentView.layer.cornerRadius = 8;
        self.titleLabel = [[UILabel alloc] init];
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightSemibold];
        self.titleLabel.textColor = UIColor.whiteColor;
        self.titleLabel.numberOfLines = 1;
        [self.contentView addSubview:self.titleLabel];
        [NSLayoutConstraint activateConstraints:@[
            [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:10],
            [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-10],
            [self.titleLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        ]];
    }
    return self;
}

@end

@interface GameViewController () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, SCARKitSessionDelegate>
@property (nonatomic, strong) SCRenderer *glView;
@property (nonatomic, strong) UICollectionView *animCollection;
@property (nonatomic, strong) UIButton *pauseButton;
@property (nonatomic, strong) UIButton *arModeButton;
@property (nonatomic, strong) UILabel *arDumpLabel;
@property (nonatomic, strong) UIStackView *movePad;
@property (nonatomic, copy) NSArray<NSString *> *animNames;
@property (nonatomic, strong) SCARKitSession *arSession;
@end

@implementation GameViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

    self.glView = [[SCRenderer alloc] initWithFrame:self.view.bounds];
    self.glView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.glView];
    [self.glView startRendering];

    self.animNames = [self.glView animationNames] ?: @[];
    [self setupControls];
    [self setupARKit];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.arSession stop];
}

#pragma mark - ARKit (dump only)

- (void)setupARKit {
    self.arSession = [[SCARKitSession alloc] init];
    self.arSession.delegate = self;
    self.arSession.logInterval = 0.5;

    BOOL faceOK = [SCARKitSession isFaceTrackingSupported];
    BOOL bodyOK = [SCARKitSession isBodyTrackingSupported];
    NSLog(@"[ARKit] device support: face=%d body=%d", (int)faceOK, (int)bodyOK);

    if (!faceOK && !bodyOK) {
        self.arDumpLabel.text = @"ARKit: 此设备不支持 Face/Body 追踪";
        return;
    }

    SCARKitTrackingMode mode = faceOK ? SCARKitTrackingModeFace : SCARKitTrackingModeBody;
    self.arDumpLabel.text = @"ARKit: 请求相机权限…";
    [self.arSession startWithMode:mode];
    [self refreshARModeButton];
}

- (void)toggleARMode {
    SCARKitTrackingMode next = (self.arSession.mode == SCARKitTrackingModeFace)
        ? SCARKitTrackingModeBody
        : SCARKitTrackingModeFace;
    [self.arSession switchToMode:next];
    [self refreshARModeButton];
}

- (void)refreshARModeButton {
    BOOL face = self.arSession.mode == SCARKitTrackingModeFace;
    NSString *title = face ? @"AR:Face" : @"AR:Body";
    [self.arModeButton setTitle:title forState:UIControlStateNormal];
}

- (void)arSession:(SCARKitSession *)session didUpdateFace:(SCARFaceData *)face {
    simd_float3 p = face.head.position;
    __block NSInteger active = 0;
    [face.blendShapes enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSNumber *val, BOOL *stop) {
        if (val.floatValue > 0.05f) active++;
    }];
    NSString *text = [NSString stringWithFormat:
                      @"FACE/HEAD  pos=(%.2f, %.2f, %.2f)\nblendShapes active=%ld / %lu  meshVerts=%ld",
                      p.x, p.y, p.z, (long)active,
                      (unsigned long)face.blendShapes.count, (long)face.geometryVertexCount];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.arDumpLabel.text = text;
    });
}

- (void)arSession:(SCARKitSession *)session didUpdateBody:(SCARBodyData *)body {
    NSInteger tracked = 0;
    for (SCARBodyJoint *j in body.joints) {
        if (j.tracked) tracked++;
    }
    NSString *headLine = @"HEAD  (n/a)";
    if (body.head) {
        simd_float3 p = body.head.position;
        headLine = [NSString stringWithFormat:@"HEAD  pos=(%.2f, %.2f, %.2f)", p.x, p.y, p.z];
    }
    NSString *text = [NSString stringWithFormat:@"BODY/%@\ntracked joints=%ld / %lu",
                      headLine, (long)tracked, (unsigned long)body.joints.count];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.arDumpLabel.text = text;
    });
}

- (void)arSession:(SCARKitSession *)session didFailWithMessage:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.arDumpLabel.text = [NSString stringWithFormat:@"ARKit: %@", message];
    });
}

- (void)arSession:(SCARKitSession *)session didChangeMode:(SCARKitTrackingMode)mode {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self refreshARModeButton];
        self.arDumpLabel.text = mode == SCARKitTrackingModeFace
            ? @"ARKit Face: waiting for face…"
            : @"ARKit Body: stand in rear camera view…";
    });
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
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    layout.minimumInteritemSpacing = 6;
    layout.minimumLineSpacing = 6;
    layout.sectionInset = UIEdgeInsetsMake(0, 0, 0, 0);
    // Fixed row height — avoids self-sizing layout thrash inside a 40pt-tall collection.

    self.animCollection = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    self.animCollection.translatesAutoresizingMaskIntoConstraints = NO;
    self.animCollection.backgroundColor = UIColor.clearColor;
    self.animCollection.showsHorizontalScrollIndicator = NO;
    self.animCollection.dataSource = self;
    self.animCollection.delegate = self;
    [self.animCollection registerClass:[AnimClipCell class] forCellWithReuseIdentifier:kAnimCellId];
    [self.view addSubview:self.animCollection];

    self.pauseButton = [self makeButton:@"Pause" action:@selector(togglePause)];
    self.pauseButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.pauseButton];

    self.arModeButton = [self makeButton:@"AR:Face" action:@selector(toggleARMode)];
    self.arModeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.arModeButton];

    self.arDumpLabel = [[UILabel alloc] init];
    self.arDumpLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.arDumpLabel.numberOfLines = 3;
    self.arDumpLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.arDumpLabel.textColor = UIColor.greenColor;
    self.arDumpLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
    self.arDumpLabel.layer.cornerRadius = 6;
    self.arDumpLabel.clipsToBounds = YES;
    self.arDumpLabel.text = @"ARKit: starting…";
    [self.view addSubview:self.arDumpLabel];

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
        [self.pauseButton.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-8],
        [self.pauseButton.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
        [self.pauseButton.heightAnchor constraintEqualToConstant:36],

        [self.arModeButton.trailingAnchor constraintEqualToAnchor:self.pauseButton.trailingAnchor],
        [self.arModeButton.topAnchor constraintEqualToAnchor:self.pauseButton.bottomAnchor constant:6],
        [self.arModeButton.heightAnchor constraintEqualToConstant:36],

        [self.animCollection.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:8],
        [self.animCollection.trailingAnchor constraintEqualToAnchor:self.pauseButton.leadingAnchor constant:-8],
        [self.animCollection.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
        [self.animCollection.heightAnchor constraintEqualToConstant:40],

        [self.arDumpLabel.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:8],
        [self.arDumpLabel.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-8],
        [self.arDumpLabel.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-8],

        [self.movePad.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:12],
        [self.movePad.bottomAnchor constraintEqualToAnchor:self.arDumpLabel.topAnchor constant:-8],
    ]];
}

#pragma mark - UICollectionView

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return (NSInteger)self.animNames.count;
}

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    AnimClipCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:kAnimCellId forIndexPath:indexPath];
    cell.titleLabel.text = self.animNames[(NSUInteger)indexPath.item];
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [self.glView playAnimationAtIndex:indexPath.item];
}

- (CGSize)collectionView:(UICollectionView *)collectionView
                  layout:(UICollectionViewLayout *)collectionViewLayout
  sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    NSString *name = self.animNames[(NSUInteger)indexPath.item];
    CGSize textSize = [name sizeWithAttributes:@{
        NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightSemibold]
    }];
    return CGSizeMake(ceil(textSize.width) + 20.0, 32.0);
}

#pragma mark - Button → SCRenderer

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

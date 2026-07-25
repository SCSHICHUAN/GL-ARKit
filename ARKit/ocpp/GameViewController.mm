/*
  GameViewController.mm
  UI host: embeds SCRenderer; model switch + animation clips; ARKit dump (not linked to model yet).
*/

#import "GameViewController.h"
#import "SCRenderer.h"
#import "SCARKitSession.h"
#import "SCARFaceProjector.h"
#import <math.h>

static NSString * const kAnimCellId = @"AnimClipCell";
static NSString * const kModelCellId = @"ModelCell";

@interface AnimClipCell : UICollectionViewCell
@property (nonatomic, strong) UILabel *titleLabel;
- (void)setHighlightedSelected:(BOOL)on;
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

- (void)setHighlightedSelected:(BOOL)on {
    self.contentView.backgroundColor = on
        ? [[UIColor systemBlueColor] colorWithAlphaComponent:0.75]
        : [[UIColor blackColor] colorWithAlphaComponent:0.45];
}
@end

@interface GameViewController () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, SCARKitSessionDelegate>
@property (nonatomic, strong) SCRenderer *glView;
@property (nonatomic, strong) UICollectionView *animCollection;
@property (nonatomic, strong) UICollectionView *modelCollection;
@property (nonatomic, strong) UIButton *pauseButton;
@property (nonatomic, strong) UIButton *arModeButton;
@property (nonatomic, strong) UILabel *arDumpLabel;
@property (nonatomic, strong) UIStackView *movePad;
@property (nonatomic, copy) NSArray<NSString *> *animNames;
@property (nonatomic, copy) NSArray<NSString *> *modelNames;
@property (nonatomic, assign) NSInteger selectedModelIndex;
@property (nonatomic, strong) SCARKitSession *arSession;
@property (nonatomic, strong) SCARFaceProjector *faceProjector;
/// 合并 AR 回调，避免主队列堆积造成眼球一跳一跳
@property (nonatomic, assign) BOOL faceDrivePending;
@property (nonatomic, assign) float pendingHeadYaw, pendingHeadPitch, pendingHeadRoll;
@property (nonatomic, assign) float pendingEyePitchL, pendingEyeYawL, pendingEyePitchR, pendingEyeYawR;
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *pendingEyeWeights;
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *pendingFaceWeights;
@property (nonatomic, copy) NSString *pendingDumpText;
@end

@implementation GameViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

    self.glView = [[SCRenderer alloc] initWithFrame:self.view.bounds];
    self.glView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.glView];
    [self.glView startRendering];

    self.modelNames = [self.glView modelNames] ?: @[];
    self.selectedModelIndex = [self.glView currentModelIndex];
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
    self.faceProjector = [[SCARFaceProjector alloc] init];

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
    [self.faceProjector reset];
    [self.arSession switchToMode:next];
    [self refreshARModeButton];
}

- (void)refreshARModeButton {
    BOOL face = self.arSession.mode == SCARKitTrackingModeFace;
    NSString *title = face ? @"AR:Face" : @"AR:Body";
    [self.arModeButton setTitle:title forState:UIControlStateNormal];
}

- (void)arSession:(SCARKitSession *)session didUpdateFace:(SCARFaceData *)face {
    SCARFaceProjection *proj = [self.faceProjector projectFace:face];

    // quat → 近似 yaw/pitch/roll（相对校准姿态）
    float yaw = 0, pitch = 0, roll = 0;
    if (proj.headValid) {
        simd_float4 q = proj.headOrientation.vector; // x,y,z,w
        const float x = q.x, y = q.y, z = q.z, w = q.w;
        float sinp = 2.f * (w * x + y * z);
        if (fabsf(sinp) >= 1.f) pitch = copysignf((float)M_PI / 2.f, sinp);
        else pitch = asinf(sinp);
        yaw = atan2f(2.f * (w * y - z * x), 1.f - 2.f * (x * x + y * y));
        roll = atan2f(2.f * (w * z + x * y), 1.f - 2.f * (y * y + z * z));
        const float lim = 0.85f;
        yaw = fmaxf(-lim, fminf(lim, yaw));
        pitch = fmaxf(-lim, fminf(lim, pitch));
        roll = fmaxf(-lim * 0.5f, fminf(lim * 0.5f, roll));
    }

    // 注视已是双眼共向；不再左右对调（对调会在共向时无意义，且易搞乱眨眼）
    float ePL = proj.eyePitchLeft, eYL = proj.eyeYawLeft;
    float ePR = proj.eyePitchRight, eYR = proj.eyeYawRight;

    NSString *text = [NSString stringWithFormat:
                      @"DRIVE HEAD ypr=(%.2f, %.2f, %.2f)\n"
                      @"EYE L py=(%.2f,%.2f) R=(%.2f,%.2f)",
                      yaw, pitch, roll, ePL, eYL, ePR, eYR];

    self.pendingHeadYaw = yaw;
    self.pendingHeadPitch = pitch;
    self.pendingHeadRoll = roll;
    self.pendingEyePitchL = ePL;
    self.pendingEyeYawL = eYL;
    self.pendingEyePitchR = ePR;
    self.pendingEyeYawR = eYR;
    self.pendingEyeWeights = proj.eyeWeights;
    self.pendingFaceWeights = proj.faceWeights;
    self.pendingDumpText = text;

    if (self.faceDrivePending) return;
    self.faceDrivePending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.faceDrivePending = NO;
        [self.glView applyFaceProjectionHeadYaw:self.pendingHeadYaw
                                          pitch:self.pendingHeadPitch
                                           roll:self.pendingHeadRoll
                                   eyePitchLeft:self.pendingEyePitchL
                                     eyeYawLeft:self.pendingEyeYawL
                                  eyePitchRight:self.pendingEyePitchR
                                    eyeYawRight:self.pendingEyeYawR
                                     eyeWeights:self.pendingEyeWeights
                                    faceWeights:self.pendingFaceWeights];
        self.arDumpLabel.text = self.pendingDumpText;
    });
}

- (void)arSession:(SCARKitSession *)session didUpdateBody:(SCARBodyData *)body {
    [self.glView clearFaceDrive];
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
    b.exclusiveTouch = YES;
    [b.widthAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [b.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [b addTarget:self action:began forControlEvents:UIControlEventTouchDown];
    [b addTarget:self action:began forControlEvents:UIControlEventTouchDragEnter];
    [b addTarget:self action:ended forControlEvents:UIControlEventTouchUpInside];
    [b addTarget:self action:ended forControlEvents:UIControlEventTouchUpOutside];
    [b addTarget:self action:ended forControlEvents:UIControlEventTouchCancel];
    [b addTarget:self action:ended forControlEvents:UIControlEventTouchDragExit];
    return b;
}

- (UICollectionView *)makeChipCollection:(NSString *)reuseId {
    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    layout.minimumInteritemSpacing = 6;
    layout.minimumLineSpacing = 6;
    layout.sectionInset = UIEdgeInsetsZero;

    UICollectionView *cv = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    cv.translatesAutoresizingMaskIntoConstraints = NO;
    cv.backgroundColor = UIColor.clearColor;
    cv.showsHorizontalScrollIndicator = NO;
    cv.dataSource = self;
    cv.delegate = self;
    [cv registerClass:[AnimClipCell class] forCellWithReuseIdentifier:reuseId];
    return cv;
}

- (void)setupControls {
    self.modelCollection = [self makeChipCollection:kModelCellId];
    [self.view addSubview:self.modelCollection];

    self.animCollection = [self makeChipCollection:kAnimCellId];
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
    [self.view bringSubviewToFront:self.movePad];

    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.pauseButton.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-8],
        [self.pauseButton.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
        [self.pauseButton.heightAnchor constraintEqualToConstant:36],

        [self.arModeButton.trailingAnchor constraintEqualToAnchor:self.pauseButton.trailingAnchor],
        [self.arModeButton.topAnchor constraintEqualToAnchor:self.pauseButton.bottomAnchor constant:6],
        [self.arModeButton.heightAnchor constraintEqualToConstant:36],

        [self.modelCollection.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:8],
        [self.modelCollection.trailingAnchor constraintEqualToAnchor:self.pauseButton.leadingAnchor constant:-8],
        [self.modelCollection.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
        [self.modelCollection.heightAnchor constraintEqualToConstant:36],

        [self.animCollection.leadingAnchor constraintEqualToAnchor:self.modelCollection.leadingAnchor],
        [self.animCollection.trailingAnchor constraintEqualToAnchor:self.modelCollection.trailingAnchor],
        [self.animCollection.topAnchor constraintEqualToAnchor:self.modelCollection.bottomAnchor constant:6],
        [self.animCollection.heightAnchor constraintEqualToConstant:36],

        [self.arDumpLabel.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:8],
        [self.arDumpLabel.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-8],
        [self.arDumpLabel.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-8],

        [self.movePad.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:12],
        [self.movePad.bottomAnchor constraintEqualToAnchor:self.arDumpLabel.topAnchor constant:-8],
    ]];
}

#pragma mark - UICollectionView

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    if (collectionView == self.modelCollection) return (NSInteger)self.modelNames.count;
    return (NSInteger)self.animNames.count;
}

- (__kindof UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    BOOL isModel = (collectionView == self.modelCollection);
    NSString *reuse = isModel ? kModelCellId : kAnimCellId;
    AnimClipCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:reuse forIndexPath:indexPath];
    if (isModel) {
        cell.titleLabel.text = self.modelNames[(NSUInteger)indexPath.item];
        [cell setHighlightedSelected:(indexPath.item == self.selectedModelIndex)];
    } else {
        cell.titleLabel.text = self.animNames[(NSUInteger)indexPath.item];
        [cell setHighlightedSelected:NO];
    }
    return cell;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    if (collectionView == self.modelCollection) {
        [self switchToModelAtIndex:indexPath.item];
        return;
    }
    [self.glView playAnimationAtIndex:indexPath.item];
}

- (CGSize)collectionView:(UICollectionView *)collectionView
                  layout:(UICollectionViewLayout *)collectionViewLayout
  sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    NSString *name = (collectionView == self.modelCollection)
        ? self.modelNames[(NSUInteger)indexPath.item]
        : self.animNames[(NSUInteger)indexPath.item];
    CGSize textSize = [name sizeWithAttributes:@{
        NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightSemibold]
    }];
    return CGSizeMake(ceil(textSize.width) + 20.0, 32.0);
}

- (void)switchToModelAtIndex:(NSInteger)index {
    if (index == self.selectedModelIndex) return;
    BOOL ok = [self.glView loadModelAtIndex:index];
    if (!ok) {
        self.arDumpLabel.text = [NSString stringWithFormat:@"模型加载失败: %@", self.modelNames[(NSUInteger)index]];
        return;
    }
    self.selectedModelIndex = index;
    self.animNames = [self.glView animationNames] ?: @[];
    [self.modelCollection reloadData];
    [self.animCollection reloadData];
    NSLog(@"[Model] switched to %@", self.modelNames[(NSUInteger)index]);
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

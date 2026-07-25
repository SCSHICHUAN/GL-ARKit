/*
  GameViewController.mm
  UI host: embeds SCRenderer; horizontal CollectionView of model animation clips.
*/

#import "GameViewController.h"
#import "SCRenderer.h"

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
            [self.titleLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:8],
            [self.titleLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-8],
        ]];
    }
    return self;
}

- (UICollectionViewLayoutAttributes *)preferredLayoutAttributesFittingAttributes:(UICollectionViewLayoutAttributes *)layoutAttributes {
    [self setNeedsLayout];
    [self layoutIfNeeded];
    CGSize size = [self.contentView systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
    UICollectionViewLayoutAttributes *attrs = [layoutAttributes copy];
    CGRect frame = attrs.frame;
    frame.size = CGSizeMake(ceil(size.width), MAX(36.0, ceil(size.height)));
    attrs.frame = frame;
    return attrs;
}
@end

@interface GameViewController () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>
@property (nonatomic, strong) SCRenderer *glView;
@property (nonatomic, strong) UICollectionView *animCollection;
@property (nonatomic, strong) UIButton *pauseButton;
@property (nonatomic, strong) UIStackView *movePad;
@property (nonatomic, copy) NSArray<NSString *> *animNames;
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
    layout.estimatedItemSize = UICollectionViewFlowLayoutAutomaticSize;
    layout.minimumInteritemSpacing = 6;
    layout.minimumLineSpacing = 6;
    layout.sectionInset = UIEdgeInsetsMake(0, 0, 0, 0);

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

        [self.animCollection.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:8],
        [self.animCollection.trailingAnchor constraintEqualToAnchor:self.pauseButton.leadingAnchor constant:-8],
        [self.animCollection.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
        [self.animCollection.heightAnchor constraintEqualToConstant:40],

        [self.movePad.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:12],
        [self.movePad.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-12],
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

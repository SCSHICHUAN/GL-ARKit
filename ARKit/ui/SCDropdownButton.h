/*
  SCDropdownButton.h
  与控件栏按钮同风格的下拉选择：点按钮后在下方展开选项列表。
*/

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SCDropdownButton : UIView

@property (nonatomic, copy) NSString *titlePrefix;
@property (nonatomic, copy) NSArray<NSString *> *options;
@property (nonatomic, assign) NSInteger selectedIndex;
@property (nonatomic, assign, getter=isEnabled) BOOL enabled;
@property (nonatomic, copy, nullable) void (^selectionHandler)(NSInteger index, NSString *title);

- (instancetype)initWithPrefix:(NSString *)prefix
                       options:(NSArray<NSString *> *)options
                 selectedIndex:(NSInteger)selectedIndex;

- (void)setSelectedIndex:(NSInteger)selectedIndex;
- (void)dismiss;

@end

NS_ASSUME_NONNULL_END

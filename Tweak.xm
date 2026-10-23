#import <UIKit/UIKit.h>
#import <objc/message.h>

// 海鸥 3.2.9 UI-only Tweak scaffold
// Adds a "群发助手" row to ZDAssistantController and opens a separate
// friend/group recipient-selection screen.
//
// Safety / integration notes:
// - This file intentionally does NOT scrape group members or rank lists.
// - It does NOT submit friend requests, monitor new members for auto-add,
//   or send messages. The final action is a local preview only.
// - authorizedItemsForMode: is intentionally empty until connected to an
//   authorized, in-app contact/group data source.

@interface SGRecipientPickerController : UIViewController <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property (nonatomic, strong) UISegmentedControl *modeControl;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) NSArray<NSDictionary *> *allItems;
@property (nonatomic, strong) NSArray<NSDictionary *> *visibleItems;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedFriendIDs;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedGroupIDs;
@property (nonatomic, assign) NSInteger mode; // 0 = existing friends, 1 = authorized groups
@end

static NSInteger SGSectionCount(id object, UITableView *tableView) {
    NSInteger sections = 1;
    SEL selector = @selector(numberOfSectionsInTableView:);
    if ([object respondsToSelector:selector]) {
        NSInteger (*send)(id, SEL, id) = (NSInteger (*)(id, SEL, id))objc_msgSend;
        sections = send(object, selector, tableView);
    }
    return MAX(sections, 1);
}

@implementation SGRecipientPickerController

- (instancetype)init {
    self = [super init];
    if (self) {
        _mode = 0;
        _selectedFriendIDs = [NSMutableSet set];
        _selectedGroupIDs = [NSMutableSet set];
        _allItems = @[];
        _visibleItems = @[];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"群发助手";
    self.view.backgroundColor = [UIColor whiteColor];

    self.modeControl = [[UISegmentedControl alloc] initWithItems:@[@"好友消息", @"群消息"]];
    self.modeControl.selectedSegmentIndex = 0;
    self.modeControl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.modeControl addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.modeControl];

    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectZero];
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchBar.placeholder = @"搜索名称";
    self.searchBar.delegate = self;
    [self.view addSubview:self.searchBar];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.allowsMultipleSelection = YES;
    [self.view addSubview:self.tableView];

    self.emptyLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.font = [UIFont systemFontOfSize:14.0];
    self.emptyLabel.textColor = [UIColor grayColor];
    self.emptyLabel.text = @"尚未接入已授权的通讯录/群组数据源。\n此模板不会抓取群成员或排行榜人员。";
    self.tableView.backgroundView = self.emptyLabel;

    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.modeControl.topAnchor constraintEqualToAnchor:guide.topAnchor constant:8.0],
        [self.modeControl.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:16.0],
        [self.modeControl.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-16.0],
        [self.modeControl.heightAnchor constraintEqualToConstant:34.0],

        [self.searchBar.topAnchor constraintEqualToAnchor:self.modeControl.bottomAnchor constant:6.0],
        [self.searchBar.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
        [self.searchBar.heightAnchor constraintEqualToConstant:44.0],

        [self.tableView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:guide.bottomAnchor]
    ]];

    UIBarButtonItem *selectAll = [[UIBarButtonItem alloc] initWithTitle:@"全选/取消" style:UIBarButtonItemStylePlain target:self action:@selector(toggleSelectAll)];
    UIBarButtonItem *space = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    UIBarButtonItem *preview = [[UIBarButtonItem alloc] initWithTitle:@"编辑/预览" style:UIBarButtonItemStyleDone target:self action:@selector(editAndPreview)];
    self.toolbarItems = @[selectAll, space, preview];
    [self.navigationController setToolbarHidden:NO animated:NO];

    [self reloadAuthorizedItems];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.navigationController setToolbarHidden:YES animated:animated];
}

// Replace this empty provider only with data exposed by an authorized,
// in-app contacts/group API. Expected item format: @{ @"id": uniqueID, @"name": displayName }.
- (NSArray<NSDictionary *> *)authorizedItemsForMode:(NSInteger)mode {
    (void)mode;
    return @[];
}

- (void)reloadAuthorizedItems {
    self.allItems = [self authorizedItemsForMode:self.mode] ?: @[];
    [self applySearchFilter];
}

- (NSSet<NSString *> *)selectedIDsForCurrentMode {
    return self.mode == 0 ? self.selectedFriendIDs : self.selectedGroupIDs;
}

- (void)modeChanged:(UISegmentedControl *)sender {
    self.mode = sender.selectedSegmentIndex;
    self.searchBar.text = @"";
    [self reloadAuthorizedItems];
}

- (void)applySearchFilter {
    NSString *query = [self.searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (query.length == 0) {
        self.visibleItems = self.allItems;
    } else {
        NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *item, NSDictionary *bindings) {
            NSString *name = [item[@"name"] description] ?: @"";
            NSString *identifier = [item[@"id"] description] ?: @"";
            return [name localizedCaseInsensitiveContainsString:query] || [identifier localizedCaseInsensitiveContainsString:query];
        }];
        self.visibleItems = [self.allItems filteredArrayUsingPredicate:predicate];
    }
    self.emptyLabel.text = self.allItems.count == 0
        ? @"尚未接入已授权的通讯录/群组数据源。\n此模板不会抓取群成员或排行榜人员。"
        : @"没有符合条件的对象。";
    self.tableView.backgroundView.hidden = (self.visibleItems.count > 0);
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.visibleItems.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuseID = @"SGAuthorizedRecipientCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseID];
    }
    NSDictionary *item = self.visibleItems[indexPath.row];
    NSString *identifier = [item[@"id"] description] ?: @"";
    cell.textLabel.text = [item[@"name"] description] ?: @"未命名对象";
    cell.detailTextLabel.text = identifier;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryType = [[self selectedIDsForCurrentMode] containsObject:identifier] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = self.visibleItems[indexPath.row];
    NSString *identifier = [item[@"id"] description] ?: @"";
    NSMutableSet<NSString *> *selected = self.mode == 0 ? self.selectedFriendIDs : self.selectedGroupIDs;
    if ([selected containsObject:identifier]) {
        [selected removeObject:identifier];
    } else if (identifier.length > 0) {
        [selected addObject:identifier];
    }
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
}

- (void)toggleSelectAll {
    NSMutableSet<NSString *> *selected = self.mode == 0 ? self.selectedFriendIDs : self.selectedGroupIDs;
    BOOL allVisibleSelected = self.visibleItems.count > 0;
    for (NSDictionary *item in self.visibleItems) {
        NSString *identifier = [item[@"id"] description] ?: @"";
        if (identifier.length == 0 || ![selected containsObject:identifier]) {
            allVisibleSelected = NO;
            break;
        }
    }
    for (NSDictionary *item in self.visibleItems) {
        NSString *identifier = [item[@"id"] description] ?: @"";
        if (identifier.length == 0) continue;
        if (allVisibleSelected) {
            [selected removeObject:identifier];
        } else {
            [selected addObject:identifier];
        }
    }
    [self.tableView reloadData];
}

- (void)editAndPreview {
    NSUInteger count = [self selectedIDsForCurrentMode].count;
    if (count == 0) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"尚未选择对象" message:@"请先从已授权的联系人或群组中选择对象。" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    UIAlertController *editor = [UIAlertController alertControllerWithTitle:@"消息内容（本地预览）" message:[NSString stringWithFormat:@"已选对象：%lu 个\n当前模式：%@\n此模板只预览，不会发送消息。", (unsigned long)count, self.mode == 0 ? @"好友消息" : @"群消息"] preferredStyle:UIAlertControllerStyleAlert];
    [editor addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"输入预览文本";
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [editor addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [editor addAction:[UIAlertAction actionWithTitle:@"生成预览" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *draft = editor.textFields.firstObject.text ?: @"";
        NSString *summary = [NSString stringWithFormat:@"模式：%@\n对象数量：%lu\n内容：%@\n\n未执行发送。", self.mode == 0 ? @"好友消息" : @"群消息", (unsigned long)count, draft.length ? draft : @"（空内容）"];
        UIAlertController *preview = [UIAlertController alertControllerWithTitle:@"预览结果" message:summary preferredStyle:UIAlertControllerStyleAlert];
        [preview addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:preview animated:YES completion:nil];
    }]];
    [self presentViewController:editor animated:YES completion:nil];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [self applySearchFilter];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

@end

%hook ZDAssistantController

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSInteger originalRows = %orig;
    NSInteger sections = SGSectionCount(self, tableView);
    // Insert the new entry at the end of the last section of the assistant list.
    if (sections > 0 && section == sections - 1) {
        return originalRows + 1;
    }
    return originalRows;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger sections = SGSectionCount(self, tableView);
    NSInteger hookedRows = [self tableView:tableView numberOfRowsInSection:indexPath.section];
    BOOL isInjectedRow = (sections > 0 && indexPath.section == sections - 1 && indexPath.row == hookedRows - 1);
    if (isInjectedRow) {
        static NSString *reuseID = @"SGGroupMassAssistantEntry";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseID];
        }
        cell.textLabel.text = @"群发助手";
        cell.detailTextLabel.text = @"好友消息与群消息分开管理";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }
    return %orig;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger sections = SGSectionCount(self, tableView);
    NSInteger hookedRows = [self tableView:tableView numberOfRowsInSection:indexPath.section];
    BOOL isInjectedRow = (sections > 0 && indexPath.section == sections - 1 && indexPath.row == hookedRows - 1);
    if (isInjectedRow) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        SGRecipientPickerController *picker = [[SGRecipientPickerController alloc] init];
        UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:picker];
        [self presentViewController:navigation animated:YES completion:nil];
        return;
    }
    %orig;
}

%end

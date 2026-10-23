#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ==========================================
// 1. 数据模型
// ==========================================
typedef NS_ENUM(NSInteger, HOMassTargetType) {
    HOMassTargetTypeFriend = 0,     // 好友
    HOMassTargetTypeGroup = 1,      // 群聊
    HOMassTargetTypeGroupMember = 2,// 群成员
    HOMassTargetTypeRankUser = 3    // 等级排行用户
};

@interface HOMassTargetItem : NSObject
@property (nonatomic, copy) NSString *targetId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic, assign) HOMassTargetType type;
@property (nonatomic, strong) id rawModel;
@end

@implementation HOMassTargetItem
@end

// ==========================================
// 2. 主动数据采集与发送引擎
// ==========================================
@interface HOMassDataManager : NSObject
@property (nonatomic, strong) NSMutableArray<HOMassTargetItem *> *friendsList;
@property (nonatomic, strong) NSMutableArray<HOMassTargetItem *> *groupsList;
@property (nonatomic, strong) NSMutableArray<HOMassTargetItem *> *groupMembersList;
@property (nonatomic, strong) NSMutableArray<HOMassTargetItem *> *rankUsersList;

+ (instancetype)shared;
- (void)manualRefreshAllData:(void(^)(NSString *summary))completion;
- (void)sendMassMessage:(NSString *)text toTargets:(NSArray<HOMassTargetItem *> *)targets interval:(NSTimeInterval)interval progress:(void(^)(NSInteger current, NSInteger total))progress completion:(void(^)(NSInteger sentCount))completion;
@end

@implementation HOMassDataManager

+ (instancetype)shared {
    static HOMassDataManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[HOMassDataManager alloc] init];
        instance.friendsList = [NSMutableArray array];
        instance.groupsList = [NSMutableArray array];
        instance.groupMembersList = [NSMutableArray array];
        instance.rankUsersList = [NSMutableArray array];
    });
    return instance;
}

- (id)safeValueForKey:(NSString *)key inObj:(id)obj {
    if (!obj || !key) return nil;
    @try {
        return [obj valueForKey:key];
    } @catch (NSException *e) {
        @try {
            return [obj valueForKey:[@"_" stringByAppendingString:key]];
        } @catch (NSException *ex) {
            return nil;
        }
    }
}

// 主动拉取当前所有数据 (不自动触发，仅在用户点击刷新时执行)
- (void)manualRefreshAllData:(void(^)(NSString *summary))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self.friendsList removeAllObjects];
        [self.groupsList removeAllObjects];
        [self.groupMembersList removeAllObjects];
        [self.rankUsersList removeAllObjects];
        
        NSMutableSet *addedFriendIds = [NSMutableSet set];
        NSMutableSet *addedGroupIds = [NSMutableSet set];
        NSMutableSet *addedMemberIds = [NSMutableSet set];
        NSMutableSet *addedRankUserIds = [NSMutableSet set];
        
        UIWindow *window = [UIApplication sharedApplication].keyWindow;
        UIViewController *rootVC = window.rootViewController;
        
        // 1. 获取会话列表与通讯录
        id msgListVC = [self safeValueForKey:@"zd_messageListVc" inObj:rootVC];
        id contactVC = [self safeValueForKey:@"zd_contactVc" inObj:rootVC];
        id findVC = [self safeValueForKey:@"zd_findVc" inObj:rootVC];
        
        // 1.1 从会话列表中提取好友和群聊
        NSArray *recents = [self safeValueForKey:@"newRecents" inObj:msgListVC];
        if ([recents isKindOfClass:[NSArray class]]) {
            for (id recent in recents) {
                NSString *chatId = [NSString stringWithFormat:@"%@", [self safeValueForKey:@"chatId" inObj:recent] ?: [self safeValueForKey:@"id" inObj:recent] ?: @""];
                NSString *name = [self safeValueForKey:@"name" inObj:recent] ?: [self safeValueForKey:@"nickName" inObj:recent] ?: @"未命名会话";
                NSNumber *isGroup = [self safeValueForKey:@"isGroup" inObj:recent] ?: [self safeValueForKey:@"chatType" inObj:recent];
                
                if (chatId.length == 0) continue;
                
                if ([isGroup intValue] == 1 || [isGroup intValue] == 2) {
                    if (![addedGroupIds containsObject:chatId]) {
                        [addedGroupIds addObject:chatId];
                        HOMassTargetItem *item = [HOMassTargetItem new];
                        item.targetId = chatId;
                        item.name = name;
                        item.detail = [NSString stringWithFormat:@"群ID: %@", chatId];
                        item.type = HOMassTargetTypeGroup;
                        item.rawModel = recent;
                        [self.groupsList addObject:item];
                    }
                } else {
                    if (![addedFriendIds containsObject:chatId]) {
                        [addedFriendIds addObject:chatId];
                        HOMassTargetItem *item = [HOMassTargetItem new];
                        item.targetId = chatId;
                        item.name = name;
                        item.detail = [NSString stringWithFormat:@"好友ID: %@", chatId];
                        item.type = HOMassTargetTypeFriend;
                        item.rawModel = recent;
                        [self.friendsList addObject:item];
                    }
                }
            }
        }
        
        // 1.2 从通讯录补充好友
        NSArray *contactDatas = [self safeValueForKey:@"zd_datas" inObj:contactVC] ?: [self safeValueForKey:@"dataArray" inObj:contactVC];
        if ([contactDatas isKindOfClass:[NSArray class]]) {
            for (id section in contactDatas) {
                NSArray *rows = [section isKindOfClass:[NSArray class]] ? section : [self safeValueForKey:@"list" inObj:section];
                if ([rows isKindOfClass:[NSArray class]]) {
                    for (id user in rows) {
                        NSString *uid = [NSString stringWithFormat:@"%@", [self safeValueForKey:@"userId" inObj:user] ?: [self safeValueForKey:@"id" inObj:user] ?: @""];
                        NSString *nick = [self safeValueForKey:@"nickName" inObj:user] ?: [self safeValueForKey:@"name" inObj:user] ?: @"好友";
                        if (uid.length > 0 && ![addedFriendIds containsObject:uid]) {
                            [addedFriendIds addObject:uid];
                            HOMassTargetItem *item = [HOMassTargetItem new];
                            item.targetId = uid;
                            item.name = nick;
                            item.detail = [NSString stringWithFormat:@"UID: %@", uid];
                            item.type = HOMassTargetTypeFriend;
                            item.rawModel = user;
                            [self.friendsList addObject:item];
                        }
                    }
                }
            }
        }
        
        // 2. 主动获取已缓存的群成员 (遍历群列表中所有群的 groupMemberList / members)
        for (HOMassTargetItem *groupItem in self.groupsList) {
            id groupObj = groupItem.rawModel;
            NSArray *members = [self safeValueForKey:@"groupMemberList" inObj:groupObj] ?: [self safeValueForKey:@"members" inObj:groupObj];
            if ([members isKindOfClass:[NSArray class]]) {
                for (id m in members) {
                    NSString *mUid = [NSString stringWithFormat:@"%@", [self safeValueForKey:@"userId" inObj:m] ?: [self safeValueForKey:@"id" inObj:m] ?: @""];
                    if (mUid.length > 0 && ![addedMemberIds containsObject:mUid]) {
                        [addedMemberIds addObject:mUid];
                        HOMassTargetItem *mItem = [HOMassTargetItem new];
                        mItem.targetId = mUid;
                        mItem.name = [self safeValueForKey:@"showName" inObj:m] ?: [self safeValueForKey:@"nickName" inObj:m] ?: @"群成员";
                        mItem.detail = [NSString stringWithFormat:@"所属群: %@", groupItem.name];
                        mItem.type = HOMassTargetTypeGroupMember;
                        mItem.rawModel = m;
                        [self.groupMembersList addObject:mItem];
                    }
                }
            }
        }
        
        // 3. 主动抓取发现页等级排行榜数据 (从全局单例/发现页提取上榜用户)
        for (NSString *key in @[@"zd_topVc", @"zd_globalTopVc", @"rankVC", @"zd_datas"]) {
            id rankObj = [self safeValueForKey:key inObj:findVC];
            NSArray *rankUsers = [self safeValueForKey:@"zd_datas" inObj:rankObj] ?: [self safeValueForKey:@"dataArray" inObj:rankObj];
            if ([rankUsers isKindOfClass:[NSArray class]]) {
                for (id u in rankUsers) {
                    NSString *rUid = [NSString stringWithFormat:@"%@", [self safeValueForKey:@"userId" inObj:u] ?: [self safeValueForKey:@"id" inObj:u] ?: @""];
                    if (rUid.length > 0 && ![addedRankUserIds containsObject:rUid]) {
                        [addedRankUserIds addObject:rUid];
                        HOMassTargetItem *rItem = [HOMassTargetItem new];
                        rItem.targetId = rUid;
                        rItem.name = [self safeValueForKey:@"nickName" inObj:u] ?: @"榜单用户";
                        id grade = [self safeValueForKey:@"grade" inObj:u] ?: @0;
                        id rank = [self safeValueForKey:@"ranking" inObj:u] ?: @0;
                        rItem.detail = [NSString stringWithFormat:@"Lv.%@ | 排名:%@", grade, rank];
                        rItem.type = HOMassTargetTypeRankUser;
                        rItem.rawModel = u;
                        [self.rankUsersList addObject:rItem];
                    }
                }
            }
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *sum = [NSString stringWithFormat:@"刷新完成：好友 %lu 人 | 群聊 %lu 个 | 群成员 %lu 人 | 排行榜 %lu 人",
                             (unsigned long)self.friendsList.count,
                             (unsigned long)self.groupsList.count,
                             (unsigned long)self.groupMembersList.count,
                             (unsigned long)self.rankUsersList.count];
            if (completion) completion(sum);
        });
    });
}

// 执行发送
- (void)sendMassMessage:(NSString *)text toTargets:(NSArray<HOMassTargetItem *> *)targets interval:(NSTimeInterval)interval progress:(void(^)(NSInteger current, NSInteger total))progress completion:(void(^)(NSInteger sentCount))completion {
    if (text.length == 0 || targets.count == 0) {
        if (completion) completion(0);
        return;
    }
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSInteger sent = 0;
        Class msgClass = objc_getClass("_TtC7ZhengDu9ZDMessage") ?: objc_getClass("ZhengDu.ZDMessage");
        Class msgMgrClass = objc_getClass("_TtC7ZhengDu16ZDMessageManager") ?: objc_getClass("ZhengDu.ZDMessageManager");
        
        for (HOMassTargetItem *t in targets) {
            @try {
                id msgObj = [[msgClass alloc] init];
                if (msgObj) {
                    [msgObj setValue:t.targetId forKey:@"chatId"];
                    [msgObj setValue:t.targetId forKey:@"toUserId"];
                    [msgObj setValue:text forKey:@"message"];
                    [msgObj setValue:@(1) forKey:@"contentType"]; // 1 文本
                    [msgObj setValue:@(t.type == HOMassTargetTypeGroup ? 2 : 1) forKey:@"messageType"];
                }
                
                SEL sharedSel = NSSelectorFromString(@"shared");
                if (![msgMgrClass respondsToSelector:sharedSel]) {
                    sharedSel = NSSelectorFromString(@"sharedInstance");
                }
                if ([msgMgrClass respondsToSelector:sharedSel]) {
                    id mgr = ((id (*)(id, SEL))objc_msgSend)(msgMgrClass, sharedSel);
                    [mgr setValue:@(YES) forKey:@"isGroupSend"];
                    
                    unsigned int count = 0;
                    Method *methods = class_copyMethodList([mgr class], &count);
                    for (unsigned int i = 0; i < count; i++) {
                        NSString *s = NSStringFromSelector(method_getName(methods[i]));
                        if ([s containsString:@"send"] && [s containsString:@"Message"]) {
                            SEL sendSel = method_getName(methods[i]);
                            NSMethodSignature *sig = [mgr methodSignatureForSelector:sendSel];
                            if (sig.numberOfArguments >= 3) {
                                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                                [inv setTarget:mgr];
                                [inv setSelector:sendSel];
                                [inv setArgument:&msgObj atIndex:2];
                                [inv invoke];
                                break;
                            }
                        }
                    }
                    free(methods);
                }
                sent++;
            } @catch (NSException *e) {}
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if (progress) progress(sent, targets.count);
            });
            [NSThread sleepForTimeInterval:MAX(interval, 0.4)];
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(sent);
        });
    });
}

@end

// ==========================================
// 3. 群发助手界面
// ==========================================
@interface HOMassAssistantController : UIViewController <UITableViewDelegate, UITableViewDataSource, UISearchBarDelegate>
@property (nonatomic, strong) UISegmentedControl *segment;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UITextField *inputField;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) NSMutableArray<HOMassTargetItem *> *currentShowList;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedIds;
@end

@implementation HOMassAssistantController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"群发助手";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.selectedIds = [NSMutableSet set];
    self.currentShowList = [NSMutableArray array];
    
    [self setupNavBar];
    [self setupViews];
    [self switchTab:0];
}

- (void)setupNavBar {
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStylePlain target:self action:@selector(dismissSelf)];
    
    UIBarButtonItem *refreshItem = [[UIBarButtonItem alloc] initWithTitle:@"🔄 刷新获取" style:UIBarButtonItemStyleDone target:self action:@selector(doRefreshData)];
    UIBarButtonItem *selectAllItem = [[UIBarButtonItem alloc] initWithTitle:@"全选" style:UIBarButtonItemStylePlain target:self action:@selector(selectAllTargets)];
    UIBarButtonItem *invertItem = [[UIBarButtonItem alloc] initWithTitle:@"反选" style:UIBarButtonItemStylePlain target:self action:@selector(invertTargets)];
    self.navigationItem.rightBarButtonItems = @[refreshItem, selectAllItem, invertItem];
}

- (void)setupViews {
    // 选项卡：好友与群单独分开
    self.segment = [[UISegmentedControl alloc] initWithItems:@[@"好友列表", @"群聊列表", @"群内全员", @"等级排行"]];
    self.segment.frame = CGRectMake(12, 100, self.view.bounds.size.width - 24, 36);
    self.segment.selectedSegmentIndex = 0;
    [self.segment addTarget:self action:@selector(tabChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.segment];
    
    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 142, self.view.bounds.size.width, 44)];
    self.searchBar.placeholder = @"搜索名称或ID...";
    self.searchBar.delegate = self;
    [self.view addSubview:self.searchBar];
    
    CGFloat bottomH = 110;
    self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 186, self.view.bounds.size.width, self.view.bounds.size.height - 186 - bottomH) style:UITableViewStylePlain];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    [self.view addSubview:self.tableView];
    
    UIView *bottomBar = [[UIView alloc] initWithFrame:CGRectMake(0, self.view.bounds.size.height - bottomH, self.view.bounds.size.width, bottomH)];
    bottomBar.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    [self.view addSubview:bottomBar];
    
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 6, self.view.bounds.size.width - 32, 20)];
    self.statusLabel.font = [UIFont systemFontOfSize:12];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.text = @"提示：请点击右上角【🔄 刷新获取】拉取最新列表";
    [bottomBar addSubview:self.statusLabel];
    
    self.inputField = [[UITextField alloc] initWithFrame:CGRectMake(16, 32, self.view.bounds.size.width - 116, 40)];
    self.inputField.borderStyle = UITextBorderStyleRoundedRect;
    self.inputField.placeholder = @"输入要群发的内容...";
    [bottomBar addSubview:self.inputField];
    
    UIButton *sendBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    sendBtn.frame = CGRectMake(self.view.bounds.size.width - 90, 32, 74, 40);
    sendBtn.backgroundColor = [UIColor systemBlueColor];
    [sendBtn setTitle:@"开始群发" forState:UIControlStateNormal];
    [sendBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    sendBtn.layer.cornerRadius = 6;
    [sendBtn addTarget:self action:@selector(startSending) forControlEvents:UIControlEventTouchUpInside];
    [bottomBar addSubview:sendBtn];
}

- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)doRefreshData {
    self.statusLabel.text = @"⏳ 正在刷新获取好友、群、成员及榜单数据...";
    [[HOMassDataManager shared] manualRefreshAllData:^(NSString *summary) {
        self.statusLabel.text = summary;
        [self switchTab:self.segment.selectedSegmentIndex];
    }];
}

- (void)tabChanged:(UISegmentedControl *)seg {
    [self switchTab:seg.selectedSegmentIndex];
}

- (void)switchTab:(NSInteger)index {
    [self.currentShowList removeAllObjects];
    HOMassDataManager *mgr = [HOMassDataManager shared];
    if (index == 0) [self.currentShowList addObjectsFromArray:mgr.friendsList];
    else if (index == 1) [self.currentShowList addObjectsFromArray:mgr.groupsList];
    else if (index == 2) [self.currentShowList addObjectsFromArray:mgr.groupMembersList];
    else if (index == 3) [self.currentShowList addObjectsFromArray:mgr.rankUsersList];
    [self.tableView reloadData];
}

- (void)selectAllTargets {
    for (HOMassTargetItem *item in self.currentShowList) {
        [self.selectedIds addObject:item.targetId];
    }
    [self.tableView reloadData];
    self.statusLabel.text = [NSString stringWithFormat:@"已选中 %lu 个目标", (unsigned long)self.selectedIds.count];
}

- (void)invertTargets {
    for (HOMassTargetItem *item in self.currentShowList) {
        if ([self.selectedIds containsObject:item.targetId]) {
            [self.selectedIds removeObject:item.targetId];
        } else {
            [self.selectedIds addObject:item.targetId];
        }
    }
    [self.tableView reloadData];
    self.statusLabel.text = [NSString stringWithFormat:@"已选中 %lu 个目标", (unsigned long)self.selectedIds.count];
}

- (void)startSending {
    [self.view endEditing:YES];
    NSString *text = self.inputField.text;
    if (text.length == 0) {
        self.statusLabel.text = @"⚠️ 请先输入群发文本内容！";
        return;
    }
    
    NSMutableArray *targets = [NSMutableArray array];
    HOMassDataManager *mgr = [HOMassDataManager shared];
    NSArray *pools = @[mgr.friendsList, mgr.groupsList, mgr.groupMembersList, mgr.rankUsersList];
    for (NSArray *pool in pools) {
        for (HOMassTargetItem *it in pool) {
            if ([self.selectedIds containsObject:it.targetId]) {
                [targets addObject:it];
            }
        }
    }
    
    if (targets.count == 0) {
        self.statusLabel.text = @"⚠️ 请至少选择一个好友或群！";
        return;
    }
    
    self.statusLabel.text = [NSString stringWithFormat:@"🚀 开始发送 (0/%lu)...", (unsigned long)targets.count];
    [[HOMassDataManager shared] sendMassMessage:text toTargets:targets interval:0.5 progress:^(NSInteger current, NSInteger total) {
        self.statusLabel.text = [NSString stringWithFormat:@"🚀 正在发送 (%ld/%ld)...", (long)current, (long)total];
    } completion:^(NSInteger sentCount) {
        self.statusLabel.text = [NSString stringWithFormat:@"✅ 群发完毕！成功投递 %ld 项", (long)sentCount];
    }];
}

#pragma mark - TableView
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.currentShowList.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"HOCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    HOMassTargetItem *item = self.currentShowList[indexPath.row];
    cell.textLabel.text = item.name;
    cell.detailTextLabel.text = item.detail;
    cell.accessoryType = [self.selectedIds containsObject:item.targetId] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    HOMassTargetItem *item = self.currentShowList[indexPath.row];
    if ([self.selectedIds containsObject:item.targetId]) {
        [self.selectedIds removeObject:item.targetId];
    } else {
        [self.selectedIds addObject:item.targetId];
    }
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    self.statusLabel.text = [NSString stringWithFormat:@"已选中 %lu 个目标", (unsigned long)self.selectedIds.count];
}

@end

// ==========================================
// 4. Hook “我的”页面并在【海鸥助手】下一行添加 Cell
// ==========================================
static NSInteger lastTargetSection = -1;

// 1. Hook numberOfRowsInSection: 找到有海鸥助手的 Section，行数 +1
static NSInteger (*orig_numberOfRows)(id self, SEL _cmd, UITableView *tableView, NSInteger section) = NULL;
static NSInteger hook_numberOfRows(id self, SEL _cmd, UITableView *tableView, NSInteger section) {
    NSInteger origCount = orig_numberOfRows(self, _cmd, tableView, section);
    NSInteger totalSections = [tableView numberOfSections];
    // “海鸥助手”在最后一个 Section 的末尾
    if (section == totalSections - 1) {
        lastTargetSection = section;
        return origCount + 1; // 增加一行“群发助手”
    }
    return origCount;
}

// 2. Hook cellForRowAtIndexPath: 如果是新增的最后一行，返回我们自定义的群发助手 Cell
static UITableViewCell* (*orig_cellForRow)(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) = NULL;
static UITableViewCell* hook_cellForRow(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    NSInteger totalSections = [tableView numberOfSections];
    if (indexPath.section == totalSections - 1) {
        NSInteger origRows = orig_numberOfRows(self, _cmd, tableView, indexPath.section);
        // 如果是最后额外增加的那一行
        if (indexPath.row == origRows) {
            static NSString *cellId = @"HOMassAssistantCellEntry";
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellId];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.textLabel.font = [UIFont systemFontOfSize:15];
            }
            cell.textLabel.text = @"群发助手";
            cell.imageView.image = [UIImage systemImageNamed:@"paperplane.fill"] ?: [UIImage systemImageNamed:@"message.fill"];
            cell.imageView.tintColor = [UIColor systemBlueColor];
            return cell;
        }
    }
    return orig_cellForRow(self, _cmd, tableView, indexPath);
}

// 3. Hook didSelectRowAtIndexPath: 点击这一行弹出群发助手
static void (*orig_didSelectRow)(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) = NULL;
static void hook_didSelectRow(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    NSInteger totalSections = [tableView numberOfSections];
    if (indexPath.section == totalSections - 1) {
        NSInteger origRows = orig_numberOfRows(self, _cmd, tableView, indexPath.section);
        if (indexPath.row == origRows) {
            [tableView deselectRowAtIndexPath:indexPath animated:YES];
            HOMassAssistantController *massVC = [[HOMassAssistantController alloc] init];
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:massVC];
            nav.modalPresentationStyle = UIModalPresentationFullScreen;
            [(UIViewController *)self presentViewController:nav animated:YES completion:nil];
            return;
        }
    }
    if (orig_didSelectRow) {
        orig_didSelectRow(self, _cmd, tableView, indexPath);
    }
}

// ==========================================
// 5. 构造函数初始化 (精准仅挂钩 ZDMineController)
// ==========================================
__attribute__((constructor)) static void InitHaiouMassHook() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // 精准获取“我的”页面控制器
        Class mineCls = objc_getClass("_TtC7ZhengDu16ZDMineController") ?: objc_getClass("ZhengDu.ZDMineController");
        if (mineCls) {
            Method mRows = class_getInstanceMethod(mineCls, @selector(tableView:numberOfRowsInSection:));
            if (mRows) {
                orig_numberOfRows = (void *)method_getImplementation(mRows);
                method_setImplementation(mRows, (IMP)hook_numberOfRows);
            }
            
            Method mCell = class_getInstanceMethod(mineCls, @selector(tableView:cellForRowAtIndexPath:));
            if (mCell) {
                orig_cellForRow = (void *)method_getImplementation(mCell);
                method_setImplementation(mCell, (IMP)hook_cellForRow);
            }
            
            Method mSelect = class_getInstanceMethod(mineCls, @selector(tableView:didSelectRowAtIndexPath:));
            if (mSelect) {
                orig_didSelectRow = (void *)method_getImplementation(mSelect);
                method_setImplementation(mSelect, (IMP)hook_didSelectRow);
            }
            NSLog(@"[HaiouMass] 成功仅在【我的】页面最下方注入【群发助手】行！");
        }
    });
}

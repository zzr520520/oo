#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ==========================================
// 1. 群发目标数据模型
// ==========================================
typedef NS_ENUM(NSInteger, HOMassTargetType) {
    HOMassTargetTypeFriend = 0,     // 好友
    HOMassTargetTypeGroup = 1,      // 群聊
    HOMassTargetTypeGroupMember = 2,// 群内所有成员
    HOMassTargetTypeRankUser = 3    // 等级排行榜人员
};

@interface HOMassTargetItem : NSObject
@property (nonatomic, copy) NSString *targetId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic, assign) HOMassTargetType type;
@property (nonatomic, strong) id rawModel; // 保存原生 ZDUser / ZDGroup / ZDGroupMember 对象
@end

@implementation HOMassTargetItem
@end

// ==========================================
// 2. 数据采集与群发引擎单例 (HOMassDataManager)
// ==========================================
@interface HOMassDataManager : NSObject
@property (nonatomic, strong) NSMutableArray<HOMassTargetItem *> *friendsList;
@property (nonatomic, strong) NSMutableArray<HOMassTargetItem *> *groupsList;
@property (nonatomic, strong) NSMutableArray<HOMassTargetItem *> *groupMembersList;
@property (nonatomic, strong) NSMutableArray<HOMassTargetItem *> *rankUsersList;

+ (instancetype)shared;
- (void)collectAllDataFromRuntime;
- (void)sendMassMessage:(NSString *)text toTargets:(NSArray<HOMassTargetItem *> *)targets interval:(NSTimeInterval)interval completion:(void(^)(NSInteger sentCount))completion;
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

// 安全获取 KVC 属性，防止 Swift 类未暴露 key 导致崩溃
- (id)safeValueForKey:(NSString *)key inObj:(id)obj {
    if (!obj || !key) return nil;
    @try {
        return [obj valueForKey:key];
    } @catch (NSException *exception) {
        // 尝试带下划线的成员变量
        @try {
            return [obj valueForKey:[@"_" stringByAppendingString:key]];
        } @catch (NSException *e) {
            return nil;
        }
    }
}

// 遍历当前内存中的控制器与数据源
- (void)collectAllDataFromRuntime {
    [self.friendsList removeAllObjects];
    [self.groupsList removeAllObjects];
    
    UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow;
    UIViewController *rootVC = keyWindow.rootViewController;
    if (!rootVC) return;
    
    // 1. 从 ZDRootController 获取会话列表和联系人控制器
    id msgListVC = [self safeValueForKey:@"zd_messageListVc" inObj:rootVC];
    id contactVC = [self safeValueForKey:@"zd_contactVc" inObj:rootVC];
    
    NSMutableSet *addedFriendIds = [NSMutableSet set];
    NSMutableSet *addedGroupIds = [NSMutableSet set];
    
    // 解析会话列表 (newRecents -> ZDRecentChat)
    NSArray *recents = [self safeValueForKey:@"newRecents" inObj:msgListVC];
    if ([recents isKindOfClass:[NSArray class]]) {
        for (id recent in recents) {
            NSString *chatId = [NSString stringWithFormat:@"%@", [self safeValueForKey:@"chatId" inObj:recent] ?: [self safeValueForKey:@"id" inObj:recent] ?: @""];
            NSString *name = [self safeValueForKey:@"name" inObj:recent] ?: [self safeValueForKey:@"nickName" inObj:recent] ?: @"未知会话";
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
    
    // 解析联系人控制器数据源 (兜底补充未在最近会话中的好友)
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
}

// 解析并保存群成员对象 (由 Hook 自动触发或手动扫描)
- (void)parseGroupMembersFromArray:(NSArray *)members groupId:(NSString *)groupId {
    if (![members isKindOfClass:[NSArray class]]) return;
    NSMutableSet *existingIds = [NSMutableSet set];
    for (HOMassTargetItem *item in self.groupMembersList) {
        [existingIds addObject:item.targetId];
    }
    
    for (id member in members) {
        NSString *uid = [NSString stringWithFormat:@"%@", [self safeValueForKey:@"userId" inObj:member] ?: [self safeValueForKey:@"id" inObj:member] ?: @""];
        if (uid.length == 0 || [existingIds containsObject:uid]) continue;
        
        NSString *name = [self safeValueForKey:@"showName" inObj:member] ?: [self safeValueForKey:@"nickName" inObj:member] ?: [self safeValueForKey:@"mark" inObj:member] ?: @"群成员";
        NSString *account = [NSString stringWithFormat:@"%@", [self safeValueForKey:@"account" inObj:member] ?: uid];
        
        [existingIds addObject:uid];
        HOMassTargetItem *item = [HOMassTargetItem new];
        item.targetId = uid;
        item.name = name;
        item.detail = [NSString stringWithFormat:@"账号:%@ (来自群:%@)", account, groupId ?: @"当前群"];
        item.type = HOMassTargetTypeGroupMember;
        item.rawModel = member;
        [self.groupMembersList addObject:item];
    }
}

// 解析并保存等级排行榜人员 (由 Hook 自动触发)
- (void)parseRankUsersFromArray:(NSArray *)users {
    if (![users isKindOfClass:[NSArray class]]) return;
    NSMutableSet *existingIds = [NSMutableSet set];
    for (HOMassTargetItem *item in self.rankUsersList) {
        [existingIds addObject:item.targetId];
    }
    
    for (id user in users) {
        NSString *uid = [NSString stringWithFormat:@"%@", [self safeValueForKey:@"userId" inObj:user] ?: [self safeValueForKey:@"id" inObj:user] ?: @""];
        if (uid.length == 0 || [existingIds containsObject:uid]) continue;
        
        NSString *name = [self safeValueForKey:@"nickName" inObj:user] ?: [self safeValueForKey:@"name" inObj:user] ?: @"榜单用户";
        id grade = [self safeValueForKey:@"grade" inObj:user] ?: @0;
        id ranking = [self safeValueForKey:@"ranking" inObj:user] ?: [self safeValueForKey:@"rankingDay" inObj:user] ?: @0;
        
        [existingIds addObject:uid];
        HOMassTargetItem *item = [HOMassTargetItem new];
        item.targetId = uid;
        item.name = name;
        item.detail = [NSString stringWithFormat:@"Lv.%@ | 排名:%@ | ID:%@", grade, ranking, uid];
        item.type = HOMassTargetTypeRankUser;
        item.rawModel = user;
        [self.rankUsersList addObject:item];
    }
}

// 核心群发逻辑：调用 ZDMessageManager / ZDChatManager
- (void)sendMassMessage:(NSString *)text toTargets:(NSArray<HOMassTargetItem *> *)targets interval:(NSTimeInterval)interval completion:(void(^)(NSInteger sentCount))completion {
    if (text.length == 0 || targets.count == 0) {
        if (completion) completion(0);
        return;
    }
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSInteger count = 0;
        Class msgClass = objc_getClass("_TtC7ZhengDu9ZDMessage") ?: objc_getClass("ZhengDu.ZDMessage");
        Class textInfoClass = objc_getClass("_TtC7ZhengDu17ZDMessageTextInfo") ?: objc_getClass("ZhengDu.ZDMessageTextInfo");
        Class msgMgrClass = objc_getClass("_TtC7ZhengDu16ZDMessageManager") ?: objc_getClass("ZhengDu.ZDMessageManager");
        
        for (HOMassTargetItem *target in targets) {
            @try {
                // 构造 ZDMessage 实体
                id msgObj = [[msgClass alloc] init];
                if (msgObj) {
                    [msgObj setValue:target.targetId forKey:@"chatId"];
                    [msgObj setValue:target.targetId forKey:@"toUserId"];
                    [msgObj setValue:text forKey:@"message"];
                    [msgObj setValue:@(1) forKey:@"contentType"]; // 1: 文本消息
                    [msgObj setValue:@(target.type == HOMassTargetTypeGroup ? 2 : 1) forKey:@"messageType"]; // 区分单聊/群聊
                }
                
                // 构造 ZDMessageTextInfo
                id textInfo = [[textInfoClass alloc] init];
                if (textInfo) {
                    [textInfo setValue:text forKey:@"zd_text"];
                }
                
                // 尝试通过 ZDMessageManager 单例发送
                SEL sharedSel = NSSelectorFromString(@"shared");
                if (![msgMgrClass respondsToSelector:sharedSel]) {
                    sharedSel = NSSelectorFromString(@"sharedInstance");
                }
                if ([msgMgrClass respondsToSelector:sharedSel]) {
                    id mgr = ((id (*)(id, SEL))objc_msgSend)(msgMgrClass, sharedSel);
                    [mgr setValue:@(YES) forKey:@"isGroupSend"]; // 标记为群发助手模式
                    
                    // 查找发送方法并调用
                    unsigned int methodCount = 0;
                    Method *methods = class_copyMethodList([mgr class], &methodCount);
                    for (unsigned int i = 0; i < methodCount; i++) {
                        NSString *selName = NSStringFromSelector(method_getName(methods[i]));
                        if ([selName containsString:@"send"] && [selName containsString:@"Message"]) {
                            // 动态投递消息至发送队列
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
                count++;
            } @catch (NSException *exception) {
                NSLog(@"[HaiouMass] Send error: %@", exception);
            }
            
            // 发送间隔防风控限制
            [NSThread sleepForTimeInterval:MAX(interval, 0.3)];
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(count);
        });
    });
}
@end

// ==========================================
// 3. 群发助手独立 UI 面板 (HOMassAssistantController)
// ==========================================
@interface HOMassAssistantController : UIViewController <UITableViewDelegate, UITableViewDataSource, UISearchBarDelegate>
@property (nonatomic, strong) UISegmentedControl *segmentControl;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UITextField *msgInputField;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) NSMutableArray<HOMassTargetItem *> *currentList;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedIds;
@end

@implementation HOMassAssistantController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"海鸥群发助手";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.selectedIds = [NSMutableSet set];
    self.currentList = [NSMutableArray array];
    
    // 采集最新内存数据
    [[HOMassDataManager shared] collectAllDataFromRuntime];
    
    [self setupUI];
    [self switchTab:0];
}

- (void)setupUI {
    // 顶部关闭与全选/反选按钮
    UIBarButtonItem *closeItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStylePlain target:self action:@selector(closeVC)];
    UIBarButtonItem * nativeGroupSendItem = [[UIBarButtonItem alloc] initWithTitle:@"原生群发" style:UIBarButtonItemStylePlain target:self action:@selector(triggerNativeGroupSend)];
    self.navigationItem.leftBarButtonItems = @[closeItem, nativeGroupSendItem];
    
    UIBarButtonItem *selectAllItem = [[UIBarButtonItem alloc] initWithTitle:@"全选" style:UIBarButtonItemStylePlain target:self action:@selector(selectAllClicked)];
    UIBarButtonItem *invertItem = [[UIBarButtonItem alloc] initWithTitle:@"反选" style:UIBarButtonItemStylePlain target:self action:@selector(invertSelectClicked)];
    self.navigationItem.rightBarButtonItems = @[selectAllItem, invertItem];
    
    // 1. 分栏控制器：好友 | 群聊 | 群全员 | 等级排行
    self.segmentControl = [[UISegmentedControl alloc] initWithItems:@[@"好友列表", @"群聊列表", @"群内全员", @"等级排行"]];
    self.segmentControl.frame = CGRectMake(12, 100, self.view.bounds.size.width - 24, 36);
    self.segmentControl.selectedSegmentIndex = 0;
    [self.segmentControl addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.segmentControl];
    
    // 2. 搜索框
    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 142, self.view.bounds.size.width, 44)];
    self.searchBar.placeholder = @"搜索昵称 / ID / 群名...";
    self.searchBar.delegate = self;
    [self.view addSubview:self.searchBar];
    
    // 3. 多选列表 TableView
    CGFloat bottomHeight = 110;
    self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 186, self.view.bounds.size.width, self.view.bounds.size.height - 186 - bottomHeight) style:UITableViewStylePlain];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.allowsMultipleSelection = YES;
    [self.view addSubview:self.tableView];
    
    // 4. 底部发送控制台
    UIView *bottomBar = [[UIView alloc] initWithFrame:CGRectMake(0, self.view.bounds.size.height - bottomHeight, self.view.bounds.size.width, bottomHeight)];
    bottomBar.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    [self.view addSubview:bottomBar];
    
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, 8, self.view.bounds.size.width - 30, 20)];
    self.statusLabel.font = [UIFont systemFontOfSize:13];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.text = @"已选择 0 个目标 (进入过群聊/排行榜后自动无限制抓取全员)";
    [bottomBar addSubview:self.statusLabel];
    
    self.msgInputField = [[UITextField alloc] initWithFrame:CGRectMake(15, 34, self.view.bounds.size.width - 115, 42)];
    self.msgInputField.borderStyle = UITextBorderStyleRoundedRect;
    self.msgInputField.placeholder = @"输入要群发的消息内容...";
    [bottomBar addSubview:self.msgInputField];
    
    UIButton *sendBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    sendBtn.frame = CGRectMake(self.view.bounds.size.width - 90, 34, 75, 42);
    sendBtn.backgroundColor = [UIColor systemBlueColor];
    [sendBtn setTitle:@"一键群发" forState:UIControlStateNormal];
    [sendBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    sendBtn.layer.cornerRadius = 6;
    [sendBtn addTarget:self action:@selector(startMassSend) forControlEvents:UIControlEventTouchUpInside];
    [bottomBar addSubview:sendBtn];
}

- (void)closeVC {
    [self dismissViewControllerAnimated:YES completion:nil];
}

// 联动调用原生自带群发页面 (ZDMessageListController1.zd_clickGroupSendMessage)
- (void)triggerNativeGroupSend {
    [self dismissViewControllerAnimated:YES completion:^{
        UIViewController *rootVC = [UIApplication sharedApplication].keyWindow.rootViewController;
        id msgListVC = [[HOMassDataManager shared] safeValueForKey:@"zd_messageListVc" inObj:rootVC];
        SEL nativeSel = NSSelectorFromString(@"zd_clickGroupSendMessage");
        if (msgListVC && [msgListVC respondsToSelector:nativeSel]) {
            ((void (*)(id, SEL))objc_msgSend)(msgListVC, nativeSel);
        }
    }];
}

- (void)segmentChanged:(UISegmentedControl *)seg {
    [self switchTab:seg.selectedSegmentIndex];
}

- (void)switchTab:(NSInteger)index {
    [self.currentList removeAllObjects];
    HOMassDataManager *mgr = [HOMassDataManager shared];
    if (index == 0) {
        [self.currentList addObjectsFromArray:mgr.friendsList];
    } else if (index == 1) {
        [self.currentList addObjectsFromArray:mgr.groupsList];
    } else if (index == 2) {
        [self.currentList addObjectsFromArray:mgr.groupMembersList];
    } else if (index == 3) {
        [self.currentList addObjectsFromArray:mgr.rankUsersList];
    }
    [self.tableView reloadData];
    [self updateStatusLabel];
}

- (void)selectAllClicked {
    for (HOMassTargetItem *item in self.currentList) {
        [self.selectedIds addObject:item.targetId];
    }
    [self.tableView reloadData];
    [self updateStatusLabel];
}

- (void)invertSelectClicked {
    for (HOMassTargetItem *item in self.currentList) {
        if ([self.selectedIds containsObject:item.targetId]) {
            [self.selectedIds removeObject:item.targetId];
        } else {
            [self.selectedIds addObject:item.targetId];
        }
    }
    [self.tableView reloadData];
    [self updateStatusLabel];
}

- (void)updateStatusLabel {
    self.statusLabel.text = [NSString stringWithFormat:@"当前列表共 %lu 项 | 已跨分类选中 %lu 个发送目标", (unsigned long)self.currentList.count, (unsigned long)self.selectedIds.count];
}

- (void)startMassSend {
    [self.view endEditing:YES];
    NSString *text = self.msgInputField.text;
    if (text.length == 0) {
        self.statusLabel.text = @"⚠️ 请先输入要群发的消息内容！";
        return;
    }
    
    // 汇总所有选中的目标
    NSMutableArray *targets = [NSMutableArray array];
    NSMutableSet *added = [NSMutableSet set];
    HOMassDataManager *mgr = [HOMassDataManager shared];
    NSArray *allPools = @[mgr.friendsList, mgr.groupsList, mgr.groupMembersList, mgr.rankUsersList];
    
    for (NSArray *pool in allPools) {
        for (HOMassTargetItem *item in pool) {
            if ([self.selectedIds containsObject:item.targetId] && ![added containsObject:item.targetId]) {
                [added addObject:item.targetId];
                [targets addObject:item];
            }
        }
    }
    
    if (targets.count == 0) {
        self.statusLabel.text = @"⚠️ 请至少勾选一个发送对象！";
        return;
    }
    
    self.statusLabel.text = [NSString stringWithFormat:@"🚀 正在群发中 (0/%lu)...", (unsigned long)targets.count];
    [[HOMassDataManager shared] sendMassMessage:text toTargets:targets interval:0.5 completion:^(NSInteger sentCount) {
        self.statusLabel.text = [NSString stringWithFormat:@"✅ 群发完成！成功投递 %ld 个目标", (long)sentCount];
    }];
}

#pragma mark - TableView DataSource & Delegate
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.currentList.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"HOMassCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    HOMassTargetItem *item = self.currentList[indexPath.row];
    cell.textLabel.text = item.name;
    cell.detailTextLabel.text = item.detail;
    cell.accessoryType = [self.selectedIds containsObject:item.targetId] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    HOMassTargetItem *item = self.currentList[indexPath.row];
    if ([self.selectedIds containsObject:item.targetId]) {
        [self.selectedIds removeObject:item.targetId];
    } else {
        [self.selectedIds addObject:item.targetId];
    }
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    [self updateStatusLabel];
}

@end

// ==========================================
// 4. Runtime Swizzling 注入与无限制数据拦截
// ==========================================
static void (*orig_RankVC_viewDidLoad)(id self, SEL _cmd) = NULL;
static void hook_RankVC_viewDidLoad(id self, SEL _cmd) {
    if (orig_RankVC_viewDidLoad) orig_RankVC_viewDidLoad(self, _cmd);
    // 突破发现页等级排行榜人数限制：将分页拉取数量 zd_size 设为 9999
    @try {
        [self setValue:@(9999) forKey:@"zd_size"];
    } @catch (NSException *e) {}
}

// 拦截排行榜 Cell 渲染，自动无限制收集所有上榜人员信息
static UITableViewCell* (*orig_RankVC_cellForRow)(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) = NULL;
static UITableViewCell* hook_RankVC_cellForRow(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    // 尝试提取排行榜控制器内的数据源数组
    for (NSString *key in @[@"zd_datas", @"dataArray", @"list", @"users", @"rankList"]) {
        id arr = [[HOMassDataManager shared] safeValueForKey:key inObj:self];
        if ([arr isKindOfClass:[NSArray class]] && [arr count] > 0) {
            [[HOMassDataManager shared] parseRankUsersFromArray:arr];
            break;
        }
    }
    return orig_RankVC_cellForRow(self, _cmd, tableView, indexPath);
}

// 拦截群成员列表与群详情，无限制提取群内所有成员
static void (*orig_GroupMemberVC_viewDidAppear)(id self, SEL _cmd, BOOL animated) = NULL;
static void hook_GroupMemberVC_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (orig_GroupMemberVC_viewDidAppear) orig_GroupMemberVC_viewDidAppear(self, _cmd, animated);
    
    // 强制修改分页限制并提取成员列表
    @try { [self setValue:@(9999) forKey:@"zd_size"]; } @catch (NSException *e) {}
    NSString *groupId = [[HOMassDataManager shared] safeValueForKey:@"groupId" inObj:self] ?: [[HOMassDataManager shared] safeValueForKey:@"zd_groupId" inObj:self];
    
    for (NSString *key in @[@"members", @"groupMemberList", @"zd_datas", @"dataArray", @"memberList"]) {
        id arr = [[HOMassDataManager shared] safeValueForKey:key inObj:self];
        if ([arr isKindOfClass:[NSArray class]] && [arr count] > 0) {
            [[HOMassDataManager shared] parseGroupMembersFromArray:arr groupId:groupId];
        }
    }
}

// 在“我的”页面 (ZDMineController) 或“海鸥助手”下一行注入【群发助手】入口
static void addMassAssistantButtonToMineVC(UIViewController *vc) {
    if (!vc || [vc.view viewWithTag:202699]) return;
    
    // 方案 A：如果页面存在 UITableView，挂载一个悬浮/内嵌栏在“海鸥助手”下方
    UIButton *entryBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    entryBtn.tag = 202699;
    entryBtn.frame = CGRectMake(16, 260, vc.view.bounds.size.width - 32, 46);
    entryBtn.backgroundColor = [UIColor colorWithRed:0.10 green:0.47 blue:0.90 alpha:0.95];
    [entryBtn setTitle:@"📨 群发助手 (好友/群/群全员/排行榜)" forState:UIControlStateNormal];
    [entryBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    entryBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    entryBtn.layer.cornerRadius = 10;
    entryBtn.layer.shadowColor = [UIColor blackColor].CGColor;
    entryBtn.layer.shadowOpacity = 0.2;
    entryBtn.layer.shadowOffset = CGSizeMake(0, 2);
    
    // 自动寻找页面中“海鸥助手”所在的 Cell 或 View，紧贴在其下一行显示
    for (UIView *sub in vc.view.subviews) {
        if ([sub isKindOfClass:[UITableView class]]) {
            UITableView *tv = (UITableView *)sub;
            for (UITableViewCell *cell in tv.visibleCells) {
                if ([cell.textLabel.text containsString:@"海鸥助手"]) {
                    CGRect cellRect = [cell convertRect:cell.bounds toView:tv];
                    entryBtn.frame = CGRectMake(16, CGRectGetMaxY(cellRect) + 4, tv.bounds.size.width - 32, 44);
                    [tv addSubview:entryBtn];
                    break;
                }
            }
            if (!entryBtn.superview) {
                // 默认插入在 TableView 头部下方
                UIView *header = tv.tableHeaderView;
                CGFloat yPos = header ? CGRectGetMaxY(header.frame) + 8 : 120;
                entryBtn.frame = CGRectMake(16, yPos, tv.bounds.size.width - 32, 44);
                [tv addSubview:entryBtn];
            }
            break;
        }
    }
    
    if (!entryBtn.superview) {
        [vc.view addSubview:entryBtn];
    }
    
    [entryBtn addTarget:vc action:@selector(ho_openMassAssistant) forControlEvents:UIControlEventTouchUpInside];
}

static void (*orig_MineVC_viewDidAppear)(id self, SEL _cmd, BOOL animated) = NULL;
static void hook_MineVC_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (orig_MineVC_viewDidAppear) orig_MineVC_viewDidAppear(self, _cmd, animated);
    addMassAssistantButtonToMineVC((UIViewController *)self);
}

// 给 UIViewController 动态添加跳转方法
static void ho_openMassAssistant_IMP(id self, SEL _cmd) {
    HOMassAssistantController *massVC = [[HOMassAssistantController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:massVC];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [(UIViewController *)self presentViewController:nav animated:YES completion:nil];
}

// ==========================================
// 5. Dylib 构造函数入口
// ==========================================
__attribute__((constructor)) static void HaiouMassHelperInit() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // 1. 为所有 UIViewController 注入打开群发助手的 Selector
        class_addMethod([UIViewController class], @selector(ho_openMassAssistant), (IMP)ho_openMassAssistant_IMP, "v@:");
        
        // 2. Hook “我的”页面 (ZDMineController)
        Class mineCls = objc_getClass("_TtC7ZhengDu16ZDMineController") ?: objc_getClass("ZhengDu.ZDMineController");
        if (mineCls) {
            Method m = class_getInstanceMethod(mineCls, @selector(viewDidAppear:));
            if (m) {
                orig_MineVC_viewDidAppear = (__typeof__(orig_MineVC_viewDidAppear))method_getImplementation(m);
                method_setImplementation(m, (IMP)hook_MineVC_viewDidAppear);
            }
        }
        
        // 3. Hook 等级排行榜页面 (ZDGlobalTopItemController) 突破条数限制
        Class rankCls = objc_getClass("_TtC7ZhengDu25ZDGlobalTopItemController") ?: objc_getClass("ZhengDu.ZDGlobalTopItemController");
        if (rankCls) {
            Method mLoad = class_getInstanceMethod(rankCls, @selector(viewDidLoad));
            if (mLoad) {
                orig_RankVC_viewDidLoad = (__typeof__(orig_RankVC_viewDidLoad))method_getImplementation(mLoad);
                method_setImplementation(mLoad, (IMP)hook_RankVC_viewDidLoad);
            }
            Method mCell = class_getInstanceMethod(rankCls, @selector(tableView:cellForRowAtIndexPath:));
            if (mCell) {
                orig_RankVC_cellForRow = (__typeof__(orig_RankVC_cellForRow))method_getImplementation(mCell);
                method_setImplementation(mCell, (IMP)hook_RankVC_cellForRow);
            }
        }
        
        // 4. Hook 群成员列表页面 (ZDConversationGroupMemberListController) 无限制获取群成员
        Class groupMemberCls = objc_getClass("_TtC7ZhengDu39ZDConversationGroupMemberListController") ?: objc_getClass("ZhengDu.ZDConversationGroupMemberListController");
        if (groupMemberCls) {
            Method mAppear = class_getInstanceMethod(groupMemberCls, @selector(viewDidAppear:));
            if (mAppear) {
                orig_GroupMemberVC_viewDidAppear = (__typeof__(orig_GroupMemberVC_viewDidAppear))method_getImplementation(mAppear);
                method_setImplementation(mAppear, (IMP)hook_GroupMemberVC_viewDidAppear);
            }
        }
        
        NSLog(@"[HaiouMassHelper] Dylib 注入成功！");
    });
}

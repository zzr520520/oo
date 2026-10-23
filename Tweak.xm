#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sqlite3.h>

// ==========================================
// 1. 数据模型定义
// ==========================================
typedef NS_ENUM(NSInteger, HOMassTargetType) {
    HOMassTargetTypeFriend = 0,     // 好友
    HOMassTargetTypeGroup = 1,      // 群聊
    HOMassTargetTypeGroupMember = 2,// 群成员
    HOMassTargetTypeRankUser = 3    // 排行榜用户
};

@interface HOMassTargetItem : NSObject
@property (nonatomic, copy) NSString *targetId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic, assign) HOMassTargetType type;
@property (nonatomic, assign) BOOL isFriend; // 是否为已通过的好友
@property (nonatomic, strong) id rawModel;
@end

@implementation HOMassTargetItem
@end

// ==========================================
// 2. 数据与操作引擎
// ==========================================
@interface HOMassDataManager : NSObject
@property (nonatomic, strong) NSMutableArray<HOMassTargetItem *> *friendsList;
@property (nonatomic, strong) NSMutableArray<HOMassTargetItem *> *groupsList;
@property (nonatomic, strong) NSMutableArray<HOMassTargetItem *> *groupMembersList;
@property (nonatomic, strong) NSMutableArray<HOMassTargetItem *> *rankUsersList;

+ (instancetype)shared;
- (void)manualRefreshAllData:(void(^)(NSString *summary))completion;
- (void)sendFriendRequestsToTargets:(NSArray<HOMassTargetItem *> *)targets reason:(NSString *)reason progress:(void(^)(NSInteger current, NSInteger total))progress completion:(void(^)(NSInteger successCount))completion;
- (void)sendMassMessage:(NSString *)text toTargets:(NSArray<HOMassTargetItem *> *)targets onlyFriends:(BOOL)onlyFriends interval:(NSTimeInterval)interval progress:(void(^)(NSInteger current, NSInteger total))progress completion:(void(^)(NSInteger sentCount))completion;
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

- (void)manualRefreshAllData:(void(^)(NSString *summary))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self.friendsList removeAllObjects];
        [self.groupsList removeAllObjects];
        [self.groupMembersList removeAllObjects];
        [self.rankUsersList removeAllObjects];
        
        NSMutableSet *addedIds = [NSMutableSet set];
        
        // 扫描沙盒 SQLite 数据库
        NSString *docDir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *libDir = [docDir stringByDeletingLastPathComponent];
        NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtPath:libDir];
        for (NSString *subPath in enumerator) {
            if ([subPath.pathExtension isEqualToString:@"db"] || [subPath.pathExtension isEqualToString:@"sqlite"]) {
                NSString *dbPath = [libDir stringByAppendingPathComponent:subPath];
                sqlite3 *db = NULL;
                if (sqlite3_open([dbPath UTF8String], &db) == SQLITE_OK) {
                    const char *sql = "SELECT name FROM sqlite_master WHERE type='table';";
                    sqlite3_stmt *stmt = NULL;
                    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK) {
                        while (sqlite3_step(stmt) == SQLITE_ROW) {
                            const char *tNameC = (const char *)sqlite3_column_text(stmt, 0);
                            if (!tNameC) continue;
                            NSString *tName = [NSString stringWithUTF8String:tNameC];
                            
                            NSString *query = [NSString stringWithFormat:@"SELECT * %@ LIMIT 1500;", tName];
                            // 优化 SQL 容错
                            NSString *safeQuery = [NSString stringWithFormat:@"SELECT * FROM %@ LIMIT 1000;", tName];
                            sqlite3_stmt *qStmt = NULL;
                            if (sqlite3_prepare_v2(db, [safeQuery UTF8String], -1, &qStmt, NULL) == SQLITE_OK) {
                                int colCount = sqlite3_column_count(qStmt);
                                while (sqlite3_step(qStmt) == SQLITE_ROW) {
                                    NSString *uId = @"";
                                    NSString *uName = @"";
                                    BOOL isFriendFlag = YES; // 默认数据库里的多为好友或会话
                                    
                                    for (int c = 0; c < colCount; c++) {
                                        const char *cnC = sqlite3_column_name(qStmt, c);
                                        const char *cvC = (const char *)sqlite3_column_text(qStmt, c);
                                        if (!cnC || !cvC) continue;
                                        NSString *cn = [[NSString stringWithUTF8String:cnC] lowercaseString];
                                        NSString *cv = [NSString stringWithUTF8String:cvC];
                                        
                                        if (([cn containsString:@"id"] || [cn isEqualToString:@"uid"]) && uId.length == 0) uId = cv;
                                        if (([cn containsString:@"name"] || [cn containsString:@"nick"] || [cn containsString:@"title"]) && uName.length == 0) uName = cv;
                                        if ([cn containsString:@"relation"] || [cn containsString:@"status"]) {
                                            if ([cv intValue] == 0) isFriendFlag = NO;
                                        }
                                    }
                                    
                                    if (uId.length > 0 && ![addedIds containsObject:uId]) {
                                        [addedIds addObject:uId];
                                        HOMassTargetItem *item = [HOMassTargetItem new];
                                        item.targetId = uId;
                                        item.name = (uName.length > 0 && ![uName isEqualToString:uId]) ? uName : [NSString stringWithFormat:@"用户_%@", [uId substringFromIndex:MAX(0, (int)uId.length - 6)]];
                                        item.detail = [NSString stringWithFormat:@"好友ID: %@", uId];
                                        item.type = HOMassTargetTypeFriend;
                                        item.isFriend = isFriendFlag;
                                        [self.friendsList addObject:item];
                                    }
                                }
                                sqlite3_finalize(qStmt);
                            }
                        }
                        sqlite3_finalize(stmt);
                    }
                    sqlite3_close(db);
                }
            }
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *summary = [NSString stringWithFormat:@"获取成功：好友 %lu | 群聊 %lu | 成员 %lu | 排行 %lu",
                             (unsigned long)self.friendsList.count,
                             (unsigned long)self.groupsList.count,
                             (unsigned long)self.groupMembersList.count,
                             (unsigned long)self.rankUsersList.count];
            if (completion) completion(summary);
        });
    });
}

// 批量发送好友申请
- (void)sendFriendRequestsToTargets:(NSArray<HOMassTargetItem *> *)targets reason:(NSString *)reason progress:(void(^)(NSInteger current, NSInteger total))progress completion:(void(^)(NSInteger successCount))completion {
    if (targets.count == 0) {
        if (completion) completion(0);
        return;
    }
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSInteger success = 0;
        Class contactMgrClass = objc_getClass("_TtC7ZhengDu17ZDContactManager") ?: objc_getClass("ZhengDu.ZDContactManager");
        
        for (HOMassTargetItem *t in targets) {
            @try {
                // 尝试通过系统反射调用添加好友接口
                SEL sharedSel = NSSelectorFromString(@"shared") ?: NSSelectorFromString(@"sharedInstance");
                if ([contactMgrClass respondsToSelector:sharedSel]) {
                    id mgr = ((id (*)(id, SEL))objc_msgSend)(contactMgrClass, sharedSel);
                    unsigned int count = 0;
                    Method *methods = class_copyMethodList([mgr class], &count);
                    for (unsigned int i = 0; i < count; i++) {
                        NSString *s = NSStringFromSelector(method_getName(methods[i]));
                        if ([s containsString:@"add"] && ([s containsString:@"Friend"] || [s containsString:@"Contact"] || [s containsString:@"User"])) {
                            SEL addSel = method_getName(methods[i]);
                            NSMethodSignature *sig = [mgr methodSignatureForSelector:addSel];
                            if (sig.numberOfArguments >= 3) {
                                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                                [inv setTarget:mgr];
                                [inv setSelector:addSel];
                                NSString *tidArg = t.targetId;
                                [inv setArgument:&tidArg atIndex:2];
                                [inv invoke];
                                break;
                            }
                        }
                    }
                    free(methods);
                }
                success++;
            } @catch (NSException *e) {}
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if (progress) progress(success, targets.count);
            });
            [NSThread sleepForTimeInterval:0.6];
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(success);
        });
    });
}

// 带好友白名单过滤的群发
- (void)sendMassMessage:(NSString *)text toTargets:(NSArray<HOMassTargetItem *> *)targets onlyFriends:(BOOL)onlyFriends interval:(NSTimeInterval)interval progress:(void(^)(NSInteger current, NSInteger total))progress completion:(void(^)(NSInteger sentCount))completion {
    if (text.length == 0 || targets.count == 0) {
        if (completion) completion(0);
        return;
    }
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSInteger sent = 0;
        Class msgClass = objc_getClass("_TtC7ZhengDu9ZDMessage") ?: objc_getClass("ZhengDu.ZDMessage");
        Class msgMgrClass = objc_getClass("_TtC7ZhengDu16ZDMessageManager") ?: objc_getClass("ZhengDu.ZDMessageManager");
        
        for (HOMassTargetItem *t in targets) {
            // 如果开启了“仅限通讯录好友”，且该目标标记为非好友，则跳过
            if (onlyFriends && t.type == HOMassTargetTypeFriend && !t.isFriend) {
                continue;
            }
            
            @try {
                id msgObj = [[msgClass alloc] init];
                if (msgObj) {
                    [msgObj setValue:t.targetId forKey:@"chatId"];
                    [msgObj setValue:t.targetId forKey:@"toUserId"];
                    [msgObj setValue:text forKey:@"message"];
                    [msgObj setValue:@(1) forKey:@"contentType"];
                    [msgObj setValue:@(t.type == HOMassTargetTypeGroup ? 2 : 1) forKey:@"messageType"];
                }
                
                SEL sharedSel = NSSelectorFromString(@"shared") ?: NSSelectorFromString(@"sharedInstance");
                if ([msgMgrClass respondsToSelector:sharedSel]) {
                    id mgr = ((id (*)(id, SEL))objc_msgSend)(msgMgrClass, sharedSel);
                    [mgr setValue:@(YES) forKey:@"isGroupSend"];
                    
                    unsigned int count = 0;
                    Method *methods = class_copyMethodList([mgr class], &count);
                    for (unsigned int i = 0; i < count; i++) {
                        NSString *s = NSStringFromSelector(method_getName(methods[i]));
                        if ([s containsString:@"send"] && ([s containsString:@"Msg"] || [s containsString:@"Message"])) {
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
            [NSThread sleepForTimeInterval:MAX(interval, 0.5)];
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(sent);
        });
    });
}
@end

// ==========================================
// 3. UI 控制面板
// ==========================================
@interface HOMassAssistantController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UISegmentedControl *segment;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UITextField *inputField;
@property (nonatomic, strong) UISwitch *friendSwitch; // 仅向通讯录好友群发开关
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) NSMutableArray<HOMassTargetItem *> *currentShowList;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedIds;
@end

@implementation HOMassAssistantController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"群发与好友助手";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.selectedIds = [NSMutableSet set];
    self.currentShowList = [NSMutableArray array];
    
    [self setupNavBar];
    [self setupViews];
    [self doRefreshData];
}

- (void)setupNavBar {
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStylePlain target:self action:@selector(dismissSelf)];
    
    UIBarButtonItem *refreshItem = [[UIBarButtonItem alloc] initWithTitle:@"🔄 刷新" style:UIBarButtonItemStyleDone target:self action:@selector(doRefreshData)];
    UIBarButtonItem *selectAllItem = [[UIBarButtonItem alloc] initWithTitle:@"全选" style:UIBarButtonItemStylePlain target:self action:@selector(selectAllTargets)];
    UIBarButtonItem *invertItem = [[UIBarButtonItem alloc] initWithTitle:@"反选" style:UIBarButtonItemStylePlain target:self action:@selector(invertTargets)];
    self.navigationItem.rightBarButtonItems = @[refreshItem, selectAllItem, invertItem];
}

- (void)setupViews {
    self.segment = [[UISegmentedControl alloc] initWithItems:@[@"好友列表", @"群聊列表", @"群内全员", @"等级排行"]];
    self.segment.frame = CGRectMake(12, 100, self.view.bounds.size.width - 24, 36);
    self.segment.selectedSegmentIndex = 0;
    [self.segment addTarget:self action:@selector(tabChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.segment];
    
    CGFloat bottomH = 150;
    self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 146, self.view.bounds.size.width, self.view.bounds.size.height - 146 - bottomH) style:UITableViewStylePlain];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    [self.view addSubview:self.tableView];
    
    UIView *bottomBar = [[UIView alloc] initWithFrame:CGRectMake(0, self.view.bounds.size.height - bottomH, self.view.bounds.size.width, bottomH)];
    bottomBar.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    [self.view addSubview:bottomBar];
    
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 6, self.view.bounds.size.width - 32, 20)];
    self.statusLabel.font = [UIFont systemFontOfSize:12];
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    self.statusLabel.text = @"就绪：请勾选目标并选择操作";
    [bottomBar addSubview:self.statusLabel];
    
    // 仅通讯录好友白名单开关
    UILabel *switchLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 32, 160, 24)];
    switchLabel.font = [UIFont systemFontOfSize:13];
    switchLabel.text = @"仅向通讯录好友群发:";
    [bottomBar addSubview:switchLabel];
    
    self.friendSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(176, 30, 50, 24)];
    self.friendSwitch.on = YES;
    [bottomBar addSubview:self.friendSwitch];
    
    // 批量添加好友申请按钮
    UIButton *addBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    addBtn.frame = CGRectMake(self.view.bounds.size.width - 170, 30, 74, 30);
    addBtn.backgroundColor = [UIColor systemOrangeColor];
    [addBtn setTitle:@"加好友" forState:UIControlStateNormal];
    [addBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    addBtn.layer.cornerRadius = 6;
    [addBtn addTarget:self action:@selector(startAddFriends) forControlEvents:UIControlEventTouchUpInside];
    [bottomBar addSubview:addBtn];
    
    // 群发输入框
    self.inputField = [[UITextField alloc] initWithFrame:CGRectMake(16, 70, self.view.bounds.size.width - 116, 40)];
    self.inputField.borderStyle = UITextBorderStyleRoundedRect;
    self.inputField.placeholder = @"输入要群发的内容...";
    [bottomBar addSubview:self.inputField];
    
    // 群发按钮
    UIButton *sendBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    sendBtn.frame = CGRectMake(self.view.bounds.size.width - 90, 70, 74, 40);
    sendBtn.backgroundColor = [UIColor systemBlueColor];
    [sendBtn setTitle:@"发消息" forState:UIControlStateNormal];
    [sendBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    sendBtn.layer.cornerRadius = 6;
    [sendBtn addTarget:self action:@selector(startSending) forControlEvents:UIControlEventTouchUpInside];
    [bottomBar addSubview:sendBtn];
}

- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)doRefreshData {
    self.statusLabel.text = @"⏳ 正在刷新本地缓存...";
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

- (void)startAddFriends {
    [self.view endEditing:YES];
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
        self.statusLabel.text = @"⚠️ 请先勾选要发送好友申请的目标！";
        return;
    }
    
    self.statusLabel.text = [NSString stringWithFormat:@"📤 正在发送申请 (0/%lu)...", (unsigned long)targets.count];
    [[HOMassDataManager shared] sendFriendRequestsToTargets:targets reason:@"你好" progress:^(NSInteger current, NSInteger total) {
        self.statusLabel.text = [NSString stringWithFormat:@"📤 正在发送申请 (%ld/%ld)...", (long)current, (long)total];
    } completion:^(NSInteger successCount) {
        self.statusLabel.text = [NSString stringWithFormat:@"✅ 申请发送完毕！成功 %ld 项", (long)successCount];
    }];
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
        self.statusLabel.text = @"⚠️ 请至少勾选一个发送对象！";
        return;
    }
    
    BOOL onlyFriends = self.friendSwitch.isOn;
    self.statusLabel.text = [NSString stringWithFormat:@"🚀 开始群发 (0/%lu)...", (unsigned long)targets.count];
    [[HOMassDataManager shared] sendMassMessage:text toTargets:targets onlyFriends:onlyFriends interval:0.6 progress:^(NSInteger current, NSInteger total) {
        self.statusLabel.text = [NSString stringWithFormat:@"🚀 正在群发 (%ld/%ld)...", (long)current, (long)total];
    } completion:^(NSInteger sentCount) {
        self.statusLabel.text = [NSString stringWithFormat:@"✅ 群发完成！有效送达 %ld 项", (long)sentCount];
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
// 4. Hook 注入入口
// ==========================================
static NSInteger (*orig_numberOfRows)(id self, SEL _cmd, UITableView *tableView, NSInteger section) = NULL;
static NSInteger hook_numberOfRows(id self, SEL _cmd, UITableView *tableView, NSInteger section) {
    NSInteger origCount = orig_numberOfRows(self, _cmd, tableView, section);
    NSInteger totalSections = [tableView numberOfSections];
    if (section == totalSections - 1) {
        return origCount + 1;
    }
    return origCount;
}

static UITableViewCell* (*orig_cellForRow)(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) = NULL;
static UITableViewCell* hook_cellForRow(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    NSInteger totalSections = [tableView numberOfSections];
    if (indexPath.section == totalSections - 1) {
        NSInteger origRows = orig_numberOfRows(self, _cmd, tableView, indexPath.section);
        if (indexPath.row == origRows) {
            static NSString *cellId = @"HOMassAssistantCellEntry";
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellId];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.textLabel.font = [UIFont systemFontOfSize:15];
            }
            cell.textLabel.text = @"群发与好友助手";
            cell.imageView.image = [UIImage systemImageNamed:@"paperplane.fill"] ?: [UIImage systemImageNamed:@"message.fill"];
            cell.imageView.tintColor = [UIColor systemBlueColor];
            return cell;
        }
    }
    return orig_cellForRow(self, _cmd, tableView, indexPath);
}

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

__attribute__((constructor)) static void InitHaiouMassHook() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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
        }
    });
}

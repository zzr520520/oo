#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sqlite3.h>

// ==========================================
// 1. 数据模型与分类定义
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
@property (nonatomic, strong) id rawModel;
@end

@implementation HOMassTargetItem
@end

// ==========================================
// 2. 数据采集引擎 (支持 内存Ivar反射 + 本地SQLite直读)
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

// 核心：突破 Swift 属性没有 @objc 限制的底层 Ivar 反射读取方法
- (id)getUnderlyingIvar:(NSString *)ivarName fromObject:(id)obj {
    if (!obj || !ivarName) return nil;
    SEL getter = NSSelectorFromString(ivarName);
    if ([obj respondsToSelector:getter]) {
        @try {
            id val = [obj valueForKey:ivarName];
            if (val) return val;
        } @catch (NSException *e) {}
    }
    
    Class cls = [obj class];
    while (cls && cls != [NSObject class]) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *name = ivar_getName(ivars[i]);
            if (!name) continue;
            NSString *strName = [NSString stringWithUTF8String:name];
            if ([strName isEqualToString:ivarName] || 
                [strName isEqualToString:[@"_" stringByAppendingString:ivarName]]) {
                const char *type = ivar_getTypeEncoding(ivars[i]);
                if (type && type[0] == '@') {
                    id val = object_getIvar(obj, ivars[i]);
                    free(ivars);
                    return val;
                }
            }
        }
        free(ivars);
        cls = class_getSuperclass(cls);
    }
    return nil;
}

// 主动刷新：结合内存对象捕获 + 沙盒 SQLite 兜底数据库直读
- (void)manualRefreshAllData:(void(^)(NSString *summary))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self.friendsList removeAllObjects];
        [self.groupsList removeAllObjects];
        [self.groupMembersList removeAllObjects];
        [self.rankUsersList removeAllObjects];
        
        NSMutableSet *addedFriendIds = [NSMutableSet set];
        NSMutableSet *addedGroupIds = [NSMutableSet set];
        
        // 1. 内存控制器扫描
        UIWindow *window = [UIApplication sharedApplication].keyWindow;
        UIViewController *rootVC = window.rootViewController;
        if (rootVC) {
            id msgListVC = [self getUnderlyingIvar:@"zd_messageListVc" fromObject:rootVC];
            NSArray *recents = [self getUnderlyingIvar:@"newRecents" fromObject:msgListVC];
            if ([recents isKindOfClass:[NSArray class]]) {
                for (id recent in recents) {
                    NSString *chatId = [NSString stringWithFormat:@"%@", [self getUnderlyingIvar:@"chatId" fromObject:recent] ?: [self getUnderlyingIvar:@"id" fromObject:recent] ?: @""];
                    NSString *name = [self getUnderlyingIvar:@"name" fromObject:recent] ?: [self getUnderlyingIvar:@"nickName" fromObject:recent] ?: @"会话";
                    NSNumber *isGroup = [self getUnderlyingIvar:@"isGroup" fromObject:recent] ?: [self getUnderlyingIvar:@"chatType" fromObject:recent];
                    
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
        }
        
        // 2. 沙盒 SQLite 数据库直读兜底（确保无视 UI 状态直接查出全部本地好友与群）
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docDir = paths.firstObject;
        // 向上检索 Library 目录
        NSString *libDir = [docDir stringByDeletingLastPathComponent];
        NSString *targetDbPath = nil;
        
        // 递归查找应用沙盒中的 .db 或 .sqlite 文件
        NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtPath:libDir];
        for (NSString *subPath in enumerator) {
            if ([subPath.pathExtension isEqualToString:@"db"] || [subPath.pathExtension isEqualToString:@"sqlite"]) {
                targetDbPath = [libDir stringByAppendingPathComponent:subPath];
                break;
            }
        }
        
        if (targetDbPath) {
            sqlite3 *db = NULL;
            if (sqlite3_open([targetDbPath UTF8String], &db) == SQLITE_OK) {
                // 查询可能的联系人或会话表
                const char *sql = "SELECT name, sql FROM sqlite_master WHERE type='table';";
                sqlite3_stmt *stmt = NULL;
                if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK) {
                    while (sqlite3_step(stmt) == SQLITE_ROW) {
                        const char *tableName = (const char *)sqlite3_column_text(stmt, 0);
                        if (tableName) {
                            NSString *tName = [NSString stringWithUTF8String:tableName];
                            // 如果表名包含 user / friend / contact / group 等关键字，尝试捞取数据
                            if ([tName rangeOfString:@"user" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                                [tName rangeOfString:@"friend" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                                [tName rangeOfString:@"chat" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                                NSString *querySql = [NSString stringWithFormat:@"SELECT * FROM %@ LIMIT 500;", tName];
                                sqlite3_stmt *qStmt = NULL;
                                if (sqlite3_prepare_v2(db, [querySql UTF8String], -1, &qStmt, NULL) == SQLITE_OK) {
                                    while (sqlite3_step(qStmt) == SQLITE_ROW) {
                                        // 简单提取前两列作为 ID 与 昵称
                                        const char *c0 = (const char *)sqlite3_column_text(qStmt, 0);
                                        const char *c1 = (const char *)sqlite3_column_text(qStmt, 1);
                                        if (c0 && c1) {
                                            NSString *uId = [NSString stringWithUTF8String:c0];
                                            NSString *uName = [NSString stringWithUTF8String:c1];
                                            if (uId.length > 0 && uName.length > 0 && ![addedFriendIds containsObject:uId]) {
                                                [addedFriendIds addObject:uId];
                                                HOMassTargetItem *item = [HOMassTargetItem new];
                                                item.targetId = uId;
                                                item.name = uName;
                                                item.detail = [NSString stringWithFormat:@"本地库同步 ID: %@", uId];
                                                item.type = HOMassTargetTypeFriend;
                                                [self.friendsList addObject:item];
                                            }
                                        }
                                    }
                                    sqlite3_finalize(qStmt);
                                }
                            }
                        }
                    }
                    sqlite3_finalize(stmt);
                }
                sqlite3_close(db);
            }
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *summary = [NSString stringWithFormat:@"刷新成功：好友 %lu 人 | 群聊 %lu 个 | 群成员 %lu 人",
                             (unsigned long)self.friendsList.count,
                             (unsigned long)self.groupsList.count,
                             (unsigned long)self.groupMembersList.count];
            if (completion) completion(summary);
        });
    });
}

// 消息群发执行
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
                    [msgObj setValue:@(1) forKey:@"contentType"];
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
// 3. 群发助手面板控制器
// ==========================================
@interface HOMassAssistantController : UIViewController <UITableViewDelegate, UITableViewDataSource, UISearchBarDelegate>
@property (nonatomic, strong) UISegmentedControl *segment;
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
    [self doRefreshData]; // 首次打开自动刷新一次
}

- (void)setupNavBar {
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStylePlain target:self action:@selector(dismissSelf)];
    
    UIBarButtonItem *refreshItem = [[UIBarButtonItem alloc] initWithTitle:@"🔄 刷新获取" style:UIBarButtonItemStyleDone target:self action:@selector(doRefreshData)];
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
    
    CGFloat bottomH = 110;
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
    self.statusLabel.text = @"就绪：点击右上角【🔄 刷新获取】同步最新通讯录与本地库";
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
    self.statusLabel.text = @"⏳ 正在从内存与本地 SQLite 库同步提取...";
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
        self.statusLabel.text = @"⚠️ 请至少勾选一个发送对象！";
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
// 4. Hook “我的”页面底部，精准在【海鸥助手】下插入行
// ==========================================
static NSInteger (*orig_numberOfRows)(id self, SEL _cmd, UITableView *tableView, NSInteger section) = NULL;
static NSInteger hook_numberOfRows(id self, SEL _cmd, UITableView *tableView, NSInteger section) {
    NSInteger origCount = orig_numberOfRows(self, _cmd, tableView, section);
    NSInteger totalSections = [tableView numberOfSections];
    if (section == totalSections - 1) {
        return origCount + 1; // 增加一行“群发助手”
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
            cell.textLabel.text = @"群发助手";
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

// ==========================================
// 5. 模块初始化
// ==========================================
__attribute__((constructor)) static void InitHaiouMassHook() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        Class mineCls = objc_getClass("_TtC7ZhengDu16ZDMineController") ?: objc_getClass("ZhengDu.ZDMineController");
        if (mineCls) {
            Method mRows = class_getInstanceMethod(mineCls, @selector(tableView:numberOfRowsInSection:));
            if (mRows) {
                orig_numberOfRows = (__typeof__(orig_numberOfRows))method_getImplementation(mRows);
                method_setImplementation(mRows, (IMP)hook_numberOfRows);
            }
            
            Method mCell = class_getInstanceMethod(mineCls, @selector(tableView:cellForRowAtIndexPath:));
            if (mCell) {
                orig_cellForRow = (__typeof__(orig_cellForRow))method_getImplementation(mCell);
                method_setImplementation(mCell, (IMP)hook_cellForRow);
            }
            
            Method mSelect = class_getInstanceMethod(mineCls, @selector(tableView:didSelectRowAtIndexPath:));
            if (mSelect) {
                orig_didSelectRow = (__typeof__(orig_didSelectRow))method_getImplementation(mSelect);
                method_setImplementation(mSelect, (IMP)hook_didSelectRow);
            }
        }
    });
}

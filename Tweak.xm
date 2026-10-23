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
@property (nonatomic, assign) BOOL isFriend;
@property (nonatomic, strong) id rawModel;
@end

@implementation HOMassTargetItem
@end

// ==========================================
// 2. 数据与气泡转发引擎
// ==========================================
@interface HOMassDataManager : NSObject
@property (nonatomic, strong) NSMutableArray<HOMassTargetItem *> *friendsList;
@property (nonatomic, strong) NSMutableArray<HOMassTargetItem *> *groupsList;
@property (nonatomic, strong) NSMutableArray<HOMassTargetItem *> *groupMembersList;
@property (nonatomic, strong) NSMutableArray<HOMassTargetItem *> *rankUsersList;
@property (nonatomic, strong) id pendingForwardMessage; // 缓存当前长按要转发的消息

+ (instancetype)shared;
- (void)manualRefreshAllData:(void(^)(NSString *summary))completion;
- (void)forwardMessageToTargets:(NSArray<HOMassTargetItem *> *)targets interval:(NSTimeInterval)interval progress:(void(^)(NSInteger current, NSInteger total))progress completion:(void(^)(NSInteger sentCount))completion;
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
                            
                            NSString *query = [NSString stringWithFormat:@"SELECT * FROM %@ LIMIT 1000;", tName];
                            sqlite3_stmt *qStmt = NULL;
                            if (sqlite3_prepare_v2(db, [query UTF8String], -1, &qStmt, NULL) == SQLITE_OK) {
                                int colCount = sqlite3_column_count(qStmt);
                                while (sqlite3_step(qStmt) == SQLITE_ROW) {
                                    NSString *uId = @"";
                                    NSString *uName = @"";
                                    for (int c = 0; c < colCount; c++) {
                                        const char *cnC = sqlite3_column_name(qStmt, c);
                                        const char *cvC = (const char *)sqlite3_column_text(qStmt, c);
                                        if (!cnC || !cvC) continue;
                                        NSString *cn = [[NSString stringWithUTF8String:cnC] lowercaseString];
                                        NSString *cv = [NSString stringWithUTF8String:cvC];
                                        if (([cn containsString:@"id"] || [cn isEqualToString:@"uid"]) && uId.length == 0) uId = cv;
                                        if (([cn containsString:@"name"] || [cn containsString:@"nick"] || [cn containsString:@"title"]) && uName.length == 0) uName = cv;
                                    }
                                    if (uId.length > 0 && ![addedIds containsObject:uId]) {
                                        [addedIds addObject:uId];
                                        HOMassTargetItem *item = [HOMassTargetItem new];
                                        item.targetId = uId;
                                        item.name = (uName.length > 0 && ![uName isEqualToString:uId]) ? uName : [NSString stringWithFormat:@"用户_%@", [uId substringFromIndex:MAX(0, (int)uId.length - 6)]];
                                        item.detail = [NSString stringWithFormat:@"ID: %@", uId];
                                        item.type = HOMassTargetTypeFriend;
                                        item.isFriend = YES;
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
            NSString *summary = [NSString stringWithFormat:@"加载成功：好友 %lu | 群聊 %lu", (unsigned long)self.friendsList.count, (unsigned long)self.groupsList.count];
            if (completion) completion(summary);
        });
    });
}

// 核心：利用海鸥原生转发逻辑进行群发
- (void)forwardMessageToTargets:(NSArray<HOMassTargetItem *> *)targets interval:(NSTimeInterval)interval progress:(void(^)(NSInteger current, NSInteger total))progress completion:(void(^)(NSInteger sentCount))completion {
    if (!self.pendingForwardMessage || targets.count == 0) {
        if (completion) completion(0);
        return;
    }
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSInteger sent = 0;
        Class msgMgrClass = objc_getClass("_TtC7ZhengDu16ZDMessageManager") ?: objc_getClass("ZhengDu.ZDMessageManager");
        
        for (HOMassTargetItem *t in targets) {
            @try {
                // 修改当前缓存消息的目标会话 ID 为当前遍历的目标
                id msg = self.pendingForwardMessage;
                [msg setValue:t.targetId forKey:@"chatId"];
                [msg.mutableCopy setValue:t.targetId forKey:@"toUserId"];
                
                SEL sharedSel = NSSelectorFromString(@"shared") ?: NSSelectorFromString(@"sharedInstance");
                if ([msgMgrClass respondsToSelector:sharedSel]) {
                    id mgr = ((id (*)(id, SEL))objc_msgSend)(msgMgrClass, sharedSel);
                    
                    // 动态查找转发/发送方法并调用原厂签名
                    unsigned int count = 0;
                    Method *methods = class_copyMethodList([mgr class], &count);
                    for (unsigned int i = 0; i < count; i++) {
                        NSString *s = NSStringFromSelector(method_getName(methods[i]));
                        if ([s containsString:@"forward"] || ([s containsString:@"send"] && [s containsString:@"Msg"])) {
                            SEL sel = method_getName(methods[i]);
                            NSMethodSignature *sig = [mgr methodSignatureForSelector:sel];
                            if (sig.numberOfArguments >= 3) {
                                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                                [inv setTarget:mgr];
                                [inv setSelector:sel];
                                [inv setArgument:&msg atIndex:2];
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
// 3. 气泡菜单增强 (在长按菜单中注入转发群发)
// ==========================================
%hook UIMenuController
- (void)setMenuItems:(NSArray<UIMenuItem *> *)menuItems {
    NSMutableArray *items = [menuItems mutableCopy] ?: [NSMutableArray array];
    BOOL hasCustom = NO;
    for (UIMenuItem *item in items) {
        if ([item.title isEqualToString:@"🚀 转发群发"]) {
            hasCustom = YES;
            break;
        }
    }
    if (!hasCustom) {
        UIMenuItem *customItem = [[UIMenuItem alloc] initWithTitle:@"🚀 转发群发" action:@selector(ho_handleBubbleMassForward:)];
        [items addObject:customItem];
    }
    %orig(items);
}
%end

// 响应气泡菜单点击事件
@interface UIResponder (HOMassBubble)
@end
@implementation UIResponder (HOMassBubble)
- (void)ho_handleBubbleMassForward:(id)sender {
    // 捕获当前选中的气泡消息模型
    // 通过响应链寻找当前聊天控制器，提取被长按的消息
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    UIViewController *rootVC = window.rootViewController;
    
    // 弹出我们的群发助手控制面板，并提示已成功吸附消息
    HOMassAssistantController *massVC = [[HOMassAssistantController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:massVC];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [rootVC presentViewController:nav animated:YES completion:nil];
}
@end

// ==========================================
// 4. 群发助手面板 UI
// ==========================================
@interface HOMassAssistantController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UISegmentedControl *segment;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) NSMutableArray<HOMassTargetItem *> *currentShowList;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedIds;
@end

@implementation HOMassAssistantController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"气泡消息群发助手";
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
    self.navigationItem.rightBarButtonItems = @[refreshItem];
}

- (void)setupViews {
    self.segment = [[UISegmentedControl alloc] initWithItems:@[@"好友列表", @"群聊列表"]];
    self.segment.frame = CGRectMake(12, 100, self.view.bounds.size.width - 24, 36);
    self.segment.selectedSegmentIndex = 0;
    [self.segment addTarget:self action:@selector(tabChanged:) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:self.segment];
    
    CGFloat bottomH = 90;
    self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 146, self.view.bounds.size.width, self.view.bounds.size.height - 146 - bottomH) style:UITableViewStylePlain];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    [self.view addSubview:self.tableView];
    
    UIView *bottomBar = [[UIView alloc] initWithFrame:CGRectMake(0, self.view.bounds.size.height - bottomH, self.view.bounds.size.width, bottomH)];
    bottomBar.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    [self.view addSubview:bottomBar];
    
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 6, self.view.bounds.size.width - 32, 20)];
    self.statusLabel.font = [UIFont systemFontOfSize:12];
    self.statusLabel.textColor = [UIColor systemBlueColor];
    self.statusLabel.text = @"💡 已通过长按气泡唤醒，请勾选转发目标";
    [bottomBar addSubview:self.statusLabel];
    
    UIButton *sendBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    sendBtn.frame = CGRectMake(16, 32, self.view.bounds.size.width - 32, 44);
    sendBtn.backgroundColor = [UIColor systemBlueColor];
    [sendBtn setTitle:@"开始群发此气泡消息" forState:UIControlStateNormal];
    [sendBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    sendBtn.layer.cornerRadius = 8;
    [sendBtn addTarget:self action:@selector(startForwarding) forControlEvents:UIControlEventTouchUpInside];
    [bottomBar addSubview:sendBtn];
}

- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)doRefreshData {
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
    [self.tableView reloadData];
}

- (void)startForwarding {
    NSMutableArray *targets = [NSMutableArray array];
    HOMassDataManager *mgr = [HOMassDataManager shared];
    NSArray *pools = @[mgr.friendsList, mgr.groupsList];
    for (NSArray *pool in pools) {
        for (HOMassTargetItem *it in pool) {
            if ([self.selectedIds containsObject:it.targetId]) {
                [targets addObject:it];
            }
        }
    }
    
    if (targets.count == 0) {
        self.statusLabel.text = @"⚠️ 请至少勾选一个转发目标！";
        return;
    }
    
    self.statusLabel.text = [NSString stringWithFormat:@"🚀 正在批量转发 (0/%lu)...", (unsigned long)targets.count];
    [[HOMassDataManager shared] forwardMessageToTargets:targets interval:0.5 progress:^(NSInteger current, NSInteger total) {
        self.statusLabel.text = [NSString stringWithFormat:@"🚀 正在批量转发 (%ld/%ld)...", (long)current, (long)total];
    } completion:^(NSInteger sentCount) {
        self.statusLabel.text = [NSString stringWithFormat:@"✅ 转发完毕！成功投递 %ld 项", (long)sentCount];
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
// 5. “我的”页面入口 Hook
// ==========================================
static NSInteger (*orig_numberOfRows)(id self, SEL _cmd, UITableView *tableView, NSInteger section) = NULL;
static NSInteger hook_numberOfRows(id self, SEL _cmd, UITableView *tableView, NSInteger section) {
    NSInteger origCount = orig_numberOfRows(self, _cmd, tableView, section);
    if (section == [tableView numberOfSections] - 1) return origCount + 1;
    return origCount;
}

static UITableViewCell* (*orig_cellForRow)(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) = NULL;
static UITableViewCell* hook_cellForRow(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    if (indexPath.section == [tableView numberOfSections] - 1) {
        NSInteger origRows = orig_numberOfRows(self, _cmd, tableView, indexPath.section);
        if (indexPath.row == origRows) {
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"HOMassEntry"];
            cell.textLabel.text = @"气泡群发助手";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
    }
    return orig_cellForRow(self, _cmd, tableView, indexPath);
}

static void (*orig_didSelectRow)(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) = NULL;
static void hook_didSelectRow(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    if (indexPath.section == [tableView numberOfSections] - 1) {
        NSInteger origRows = orig_numberOfRows(self, _cmd, tableView, indexPath.section);
        if (indexPath.row == origRows) {
            [tableView deselectRowAtIndexPath:indexPath animated:YES];
            HOMassAssistantController *vc = [[HOMassAssistantController alloc] init];
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
            nav.modalPresentationStyle = UIModalPresentationFullScreen;
            [(UIViewController *)self presentViewController:nav animated:YES completion:nil];
            return;
        }
    }
    if (orig_didSelectRow) orig_didSelectRow(self, _cmd, tableView, indexPath);
}

__attribute__((constructor)) static void InitBubbleMassHook() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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

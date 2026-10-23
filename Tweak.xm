//
//  HaiouMassHelper.m
//  海鸥 3.2.9 (Build 20261022) 群发与全自动拓客助手 Dylib (防闪退 & 真无限翻页修复版)
//  架构: arm64 | 依赖: UIKit, Foundation, Objective-C Runtime, sqlite3
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sqlite3.h>

#pragma mark - ==================== 安全反射与内存读写工具 ====================

static NSInteger SafeReadSwiftInt(id obj, ptrdiff_t offset) {
    if (!obj) return 0;
    uint8_t *base = (__bridge void *)obj;
    return *(NSInteger *)(base + offset);
}

static void SafeWriteSwiftInt(id obj, ptrdiff_t offset, NSInteger val) {
    if (!obj) return;
    uint8_t *base = (__bridge void *)obj;
    *(NSInteger *)(base + offset) = val;
}

// 递归提取任意 View 内部所有 UILabel 的文本
static void CollectLabelsTextInView(UIView *view, NSMutableArray<NSString *> *outTexts) {
    if (!view || view.hidden || view.alpha < 0.01) return;
    if ([view isKindOfClass:[UILabel class]]) {
        NSString *t = [(UILabel *)view text];
        if (t && t.length > 0) {
            [outTexts addObject:[t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
        }
    }
    for (UIView *sub in view.subviews) {
        CollectLabelsTextInView(sub, outTexts);
    }
}

// 在视图树中查找 UICollectionView 或 UITableView
static UICollectionView *FindCollectionViewInView(UIView *root) {
    if (!root) return nil;
    if ([root isKindOfClass:[UICollectionView class]]) return (UICollectionView *)root;
    for (UIView *sub in root.subviews) {
        UICollectionView *found = FindCollectionViewInView(sub);
        if (found) return found;
    }
    return nil;
}

static NSString *SafeKVCString(id obj, NSString *key) {
    if (!obj || !key) return nil;
    @try {
        id val = [obj valueForKey:key];
        if ([val isKindOfClass:[NSString class]]) return val;
        if ([val isKindOfClass:[UILabel class]]) return [(UILabel *)val text];
        if (val) return [val description];
    } @catch (NSException *e) {}
    return nil;
}

#pragma mark - ==================== 数据模型与全局引擎 ====================

@interface HOModelItem : NSObject
@property (nonatomic, copy) NSString *itemId;     // userId / 海鸥号 / groupId
@property (nonatomic, copy) NSString *account;    // 海鸥号 / 群号
@property (nonatomic, copy) NSString *name;       // 昵称 / 群名称
@property (nonatomic, copy) NSString *source;     // 来源标识
@property (nonatomic, assign) BOOL isGroup;
@property (nonatomic, assign) BOOL isSelected;
@end

@implementation HOModelItem
@end

@interface HOMassEngine : NSObject
@property (nonatomic, strong) NSMutableDictionary<NSString *, HOModelItem *> *contactFriendsMap; // 通讯录已添加好友
@property (nonatomic, strong) NSMutableDictionary<NSString *, HOModelItem *> *joinedGroupsMap;   // 独立群聊
@property (nonatomic, strong) NSMutableDictionary<NSString *, HOModelItem *> *collectedUsersMap; // 采集池(排行榜+群成员)
@property (nonatomic, strong) NSMutableSet<NSString *> *addedRequestHistory;

@property (nonatomic, assign) BOOL autoAddNewGroupMember;
@property (nonatomic, assign) BOOL unlockRankPagination;
@property (nonatomic, copy) NSString *defaultVerifyMsg;
@property (nonatomic, assign) NSTimeInterval batchDelay;

// 排行榜自动翻页控制
@property (nonatomic, strong) NSTimer *rankPageTimer;
@property (nonatomic, assign) BOOL isAutoPagingRank;
@property (nonatomic, weak) UIViewController *activeRankVC;
@property (nonatomic, weak) UIButton *rankFloatingBtn;

// 记录「我的」页面“海鸥助手”所在的真实 Section 与 Row
@property (nonatomic, assign) NSInteger haiouAssistantSection;
@property (nonatomic, assign) NSInteger haiouAssistantRow;

+ (instancetype)shared;
- (void)saveSettings;
- (void)syncFromLocalDatabase;
- (void)harvestFromCellView:(UIView *)cell defaultSource:(NSString *)source;
- (void)harvestGroupMemberObject:(id)memberObj source:(NSString *)source;
- (void)enqueueAutoAddFriendWithUserId:(NSString *)uid name:(NSString *)name source:(NSString *)source;
- (void)batchAddFriends:(NSArray<HOModelItem *> *)users verifyMsg:(NSString *)verifyMsg progress:(void(^)(NSInteger current, NSInteger total, NSString *log))progressBlock;
- (void)batchSendMessage:(NSString *)text toItems:(NSArray<HOModelItem *> *)items progress:(void(^)(NSInteger current, NSInteger total, NSString *log))progressBlock;
- (void)toggleRankUnlimitedAutoPageOnVC:(UIViewController *)vc;
@end

@implementation HOMassEngine

+ (instancetype)shared {
    static HOMassEngine *ins = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ins = [[HOMassEngine alloc] init];
    });
    return ins;
}

- (instancetype)init {
    if (self = [super init]) {
        _contactFriendsMap = [NSMutableDictionary dictionary];
        _joinedGroupsMap = [NSMutableDictionary dictionary];
        _collectedUsersMap = [NSMutableDictionary dictionary];
        
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        _addedRequestHistory = [NSMutableSet setWithArray:[ud arrayForKey:@"HO_AddedHistory"] ?: @[]];
        _autoAddNewGroupMember = [ud objectForKey:@"HO_AutoAddJoin"] ? [ud boolForKey:@"HO_AutoAddJoin"] : YES;
        _unlockRankPagination  = [ud objectForKey:@"HO_UnlockRank"] ? [ud boolForKey:@"HO_UnlockRank"] : YES;
        _defaultVerifyMsg      = [ud stringForKey:@"HO_VerifyMsg"] ?: @"你好，交个朋友~";
        _batchDelay            = [ud doubleForKey:@"HO_BatchDelay"] > 0 ? [ud doubleForKey:@"HO_BatchDelay"] : 2.0;
        
        // 默认在 Section 1 的第 1 行（即第 0 行“海鸥助手”的下一行），渲染时还会动态校准
        _haiouAssistantSection = 1;
        _haiouAssistantRow = 0;
    }
    return self;
}

- (void)saveSettings {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:_autoAddNewGroupMember forKey:@"HO_AutoAddJoin"];
    [ud setBool:_unlockRankPagination forKey:@"HO_UnlockRank"];
    [ud setObject:_defaultVerifyMsg forKey:@"HO_VerifyMsg"];
    [ud setDouble:_batchDelay forKey:@"HO_BatchDelay"];
    [ud setObject:[_addedRequestHistory allObjects] forKey:@"HO_AddedHistory"];
    [ud synchronize];
}

#pragma mark - 1. 扫描本地 SQLite 数据库 (提取通讯录好友 & 群聊)
- (void)syncFromLocalDatabase {
    NSArray *dirs = @[
        [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject],
        [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject]
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *rootPath in dirs) {
        NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:rootPath];
        NSString *relPath;
        while ((relPath = [enumerator nextObject])) {
            NSString *ext = relPath.pathExtension.lowercaseString;
            if ([ext isEqualToString:@"db"] || [ext isEqualToString:@"sqlite"] || [ext isEqualToString:@"sqlite3"]) {
                [self inspectSQLiteFile:[rootPath stringByAppendingPathComponent:relPath]];
            }
        }
    }
}

- (void)inspectSQLiteFile:(NSString *)dbPath {
    sqlite3 *db = NULL;
    if (sqlite3_open_v2([dbPath UTF8String], &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return;
    }
    sqlite3_stmt *tableStmt = NULL;
    NSMutableArray<NSString *> *tables = [NSMutableArray array];
    if (sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table';", -1, &tableStmt, NULL) == SQLITE_OK) {
        while (sqlite3_step(tableStmt) == SQLITE_ROW) {
            const char *tName = (const char *)sqlite3_column_text(tableStmt, 0);
            if (tName) [tables addObject:[NSString stringWithUTF8String:tName]];
        }
        sqlite3_finalize(tableStmt);
    }
    
    for (NSString *tName in tables) {
        NSString *lower = tName.lowercaseString;
        if ([lower containsString:@"user"] || [lower containsString:@"friend"] || [lower containsString:@"contact"]) {
            NSString *sql = [NSString stringWithFormat:@"SELECT * FROM \"%@\";", tName];
            sqlite3_stmt *stmt = NULL;
            if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &stmt, NULL) == SQLITE_OK) {
                int colCount = sqlite3_column_count(stmt);
                while (sqlite3_step(stmt) == SQLITE_ROW) {
                    NSString *uid = nil, *nick = nil, *acc = nil, *mark = nil;
                    BOOL isFriendFlag = YES;
                    for (int i = 0; i < colCount; i++) {
                        const char *cName = sqlite3_column_name(stmt, i);
                        const char *cVal  = (const char *)sqlite3_column_text(stmt, i);
                        if (!cName || !cVal) continue;
                        NSString *col = [NSString stringWithUTF8String:cName];
                        NSString *val = [NSString stringWithUTF8String:cVal];
                        if ([col isEqualToString:@"userId"] || [col isEqualToString:@"id"]) {
                            if (val.length >= 4 && !uid) uid = val;
                        } else if ([col isEqualToString:@"nickName"] || [col isEqualToString:@"name"] || [col isEqualToString:@"showName"]) {
                            if (val.length > 0) nick = val;
                        } else if ([col isEqualToString:@"mark"] && val.length > 0) {
                            mark = val;
                        } else if ([col isEqualToString:@"account"] && val.length > 0) {
                            acc = val;
                        } else if ([col isEqualToString:@"whetherFriends"] || [col isEqualToString:@"isFriend"]) {
                            isFriendFlag = ([val intValue] == 1 || [val.lowercaseString isEqualToString:@"true"]);
                        }
                    }
                    if (uid.length > 0 && isFriendFlag && ![uid isEqualToString:@"1483263478134476800"]) {
                        HOModelItem *item = _contactFriendsMap[uid] ?: [[HOModelItem alloc] init];
                        item.itemId = uid;
                        item.name = mark.length > 0 ? [NSString stringWithFormat:@"%@ (%@)", mark, nick ?: @""] : (nick ?: uid);
                        item.account = acc ?: uid;
                        item.source = @"通讯录好友";
                        item.isGroup = NO;
                        _contactFriendsMap[uid] = item;
                    }
                }
                sqlite3_finalize(stmt);
            }
        } else if ([lower containsString:@"group"] && ![lower containsString:@"member"] && ![lower containsString:@"notice"]) {
            NSString *sql = [NSString stringWithFormat:@"SELECT * FROM \"%@\";", tName];
            sqlite3_stmt *stmt = NULL;
            if (sqlite3_prepare_v2(db, [sql UTF8String], -1, &stmt, NULL) == SQLITE_OK) {
                int colCount = sqlite3_column_count(stmt);
                while (sqlite3_step(stmt) == SQLITE_ROW) {
                    NSString *gid = nil, *gName = nil, *gNo = nil;
                    for (int i = 0; i < colCount; i++) {
                        const char *cName = sqlite3_column_name(stmt, i);
                        const char *cVal  = (const char *)sqlite3_column_text(stmt, i);
                        if (!cName || !cVal) continue;
                        NSString *col = [NSString stringWithUTF8String:cName];
                        NSString *val = [NSString stringWithUTF8String:cVal];
                        if ([col isEqualToString:@"id"] || [col isEqualToString:@"groupId"] || [col isEqualToString:@"chatId"]) {
                            if (val.length >= 4) gid = val;
                        } else if ([col isEqualToString:@"name"] || [col isEqualToString:@"groupName"]) {
                            if (val.length > 0) gName = val;
                        } else if ([col isEqualToString:@"groupNo"] && val.length > 0) {
                            gNo = val;
                        }
                    }
                    if (gid.length > 0 && gName.length > 0) {
                        HOModelItem *item = _joinedGroupsMap[gid] ?: [[HOModelItem alloc] init];
                        item.itemId = gid;
                        item.name = gName;
                        item.account = gNo ?: gid;
                        item.source = @"我的群聊";
                        item.isGroup = YES;
                        _joinedGroupsMap[gid] = item;
                    }
                }
                sqlite3_finalize(stmt);
            }
        }
    }
    sqlite3_close(db);
}

#pragma mark - 2. 排行榜 Cell 与群成员采集引擎
- (void)harvestFromCellView:(UIView *)cell defaultSource:(NSString *)source {
    if (!cell) return;
    // 1. 先尝试通过 ZDGlobalRankItemCell / ZDGlobalAllRankItemCell 的公开 getter 方法提取
    // 逆向报告 5.3 节实锤: -[ZDGlobalRankItemCell zd_account], -[ZDGlobalAllRankItemCell zd_name]
    NSString *accText = nil;
    NSString *nameText = nil;
    
    if ([cell respondsToSelector:NSSelectorFromString(@"zd_account")]) {
        UILabel *accLab = ((id (*)(id, SEL))objc_msgSend)(cell, NSSelectorFromString(@"zd_account"));
        if ([accLab isKindOfClass:[UILabel class]]) accText = accLab.text;
    }
    if ([cell respondsToSelector:NSSelectorFromString(@"zd_name")]) {
        UILabel *nameLab = ((id (*)(id, SEL))objc_msgSend)(cell, NSSelectorFromString(@"zd_name"));
        if ([nameLab isKindOfClass:[UILabel class]]) nameText = nameLab.text;
    }
    
    // 2. 若 IBOutlet 为空，则深度扫描 Cell 内所有 UILabel 文本
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    CollectLabelsTextInView(cell, texts);
    for (NSString *t in texts) {
        if ([t containsString:@"海鸥号"] || [t containsString:@"ID"] || [t containsString:@"账号"]) {
            NSString *cleaned = [[t componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]] componentsJoinedByString:@""];
            if (cleaned.length >= 4) accText = cleaned;
        } else if (!nameText && t.length >= 1 && t.length <= 20 && ![t hasPrefix:@"Lv"] && ![t hasPrefix:@"LV"] && ![t containsString:@"经验"] && ![t containsString:@"榜"]) {
            // 排除纯数字排名序号 (如 "1", "2", "3")
            NSScanner *sc = [NSScanner scannerWithString:t];
            NSInteger tmp;
            if (!([sc scanInteger:&tmp] && [sc isAtEnd] && t.length <= 3)) {
                nameText = t;
            }
        }
    }
    
    NSString *finalKey = accText.length > 0 ? accText : nameText;
    if (finalKey.length >= 2 && !_contactFriendsMap[finalKey]) {
        HOModelItem *item = _collectedUsersMap[finalKey] ?: [[HOModelItem alloc] init];
        item.itemId = finalKey;
        item.account = accText ?: finalKey;
        item.name = nameText ?: finalKey;
        item.source = source ?: @"等级排行榜";
        item.isGroup = NO;
        _collectedUsersMap[finalKey] = item;
    }
}

- (void)harvestGroupMemberObject:(id)memberObj source:(NSString *)source {
    if (!memberObj) return;
    NSString *uid  = SafeKVCString(memberObj, @"userId") ?: SafeKVCString(memberObj, @"id");
    NSString *acc  = SafeKVCString(memberObj, @"account");
    NSString *nick = SafeKVCString(memberObj, @"showName") ?: (SafeKVCString(memberObj, @"nickName") ?: SafeKVCString(memberObj, @"mark"));
    
    NSString *key = uid.length > 0 ? uid : acc;
    if (key.length >= 2 && !_contactFriendsMap[key]) {
        HOModelItem *item = _collectedUsersMap[key] ?: [[HOModelItem alloc] init];
        item.itemId = key;
        item.account = acc ?: key;
        item.name = nick ?: key;
        item.source = source ?: @"群成员全量采集";
        item.isGroup = NO;
        _collectedUsersMap[key] = item;
    }
}

#pragma mark - 3. 等级排行榜【真·无限翻页与全自动采集】引擎
- (void)toggleRankUnlimitedAutoPageOnVC:(UIViewController *)vc {
    if (_isAutoPagingRank) {
        _isAutoPagingRank = NO;
        [_rankPageTimer invalidate];
        _rankPageTimer = nil;
        if (_rankFloatingBtn) {
            [_rankFloatingBtn setTitle:[NSString stringWithFormat:@"⚡无限翻页(已采%lu人)", (unsigned long)_collectedUsersMap.count] forState:UIControlStateNormal];
            _rankFloatingBtn.backgroundColor = [UIColor systemOrangeColor];
        }
        return;
    }
    
    _isAutoPagingRank = YES;
    _activeRankVC = vc;
    if (_rankFloatingBtn) {
        [_rankFloatingBtn setTitle:@"🛑停止翻页(采集中...)" forState:UIControlStateNormal];
        _rankFloatingBtn.backgroundColor = [UIColor systemRedColor];
    }
    
    // 立即执行第一次翻页，并开启每 1.5 秒自动翻下一页的循环定时器
    [self stepNextRankPage];
    _rankPageTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 target:self selector:@selector(stepNextRankPage) userInfo:nil repeats:YES];
}

- (void)stepNextRankPage {
    UIViewController *vc = _activeRankVC;
    if (!vc || !vc.view.window) {
        // 页面已离开，自动停止
        if (_isAutoPagingRank) [self toggleRankUnlimitedAutoPageOnVC:nil];
        return;
    }
    
    // 1. 强制将 ZDGlobalTopItemController 的 zd_size (offset 0x78) 设为 100
    SafeWriteSwiftInt(vc, 0x78, 100);
    
    // 2. 找到页面内的 UICollectionView
    UICollectionView *cv = FindCollectionViewInView(vc.view);
    if (cv) {
        // 先把当前可见的所有 Cell 采集一遍
        for (UICollectionViewCell *cell in cv.visibleCells) {
            [self harvestFromCellView:cell defaultSource:@"发现-等级排行榜"];
        }
        
        // 3. 触发 MJRefreshFooter 上拉加载更多网络请求
        id mjFooter = nil;
        @try { mjFooter = [cv valueForKey:@"mj_footer"]; } @catch (NSException *e) {}
        if (mjFooter) {
            // 重置 NoMoreData 状态，强制允许无限翻页！
            if ([mjFooter respondsToSelector:NSSelectorFromString(@"resetNoMoreData")]) {
                ((void (*)(id, SEL))objc_msgSend)(mjFooter, NSSelectorFromString(@"resetNoMoreData"));
            }
            if ([mjFooter respondsToSelector:NSSelectorFromString(@"beginRefreshing")]) {
                ((void (*)(id, SEL))objc_msgSend)(mjFooter, NSSelectorFromString(@"beginRefreshing"));
            } else if ([mjFooter respondsToSelector:NSSelectorFromString(@"executeRefreshingCallback")]) {
                ((void (*)(id, SEL))objc_msgSend)(mjFooter, NSSelectorFromString(@"executeRefreshingCallback"));
            }
        }
        
        // 4. 同时将列表向下滚动一屏，触发系统级 willDisplayCell / scrollViewDidScroll 加载逻辑
        CGFloat maxOffset = MAX(0, cv.contentSize.height - cv.bounds.size.height);
        CGFloat nextY = MIN(maxOffset + 120, cv.contentOffset.y + cv.bounds.size.height * 0.85);
        if (cv.contentSize.height > cv.bounds.size.height) {
            [cv setContentOffset:CGPointMake(0, nextY) animated:YES];
        }
    }
    
    if (_rankFloatingBtn) {
        [_rankFloatingBtn setTitle:[NSString stringWithFormat:@"🛑采集中(%lu人)点此停", (unsigned long)_collectedUsersMap.count] forState:UIControlStateNormal];
    }
}

#pragma mark - 4. 批量加好友与群发通道
- (void)enqueueAutoAddFriendWithUserId:(NSString *)uid name:(NSString *)name source:(NSString *)source {
    if (!uid || uid.length == 0) return;
    if ([_addedRequestHistory containsObject:uid] || _contactFriendsMap[uid]) return;
    
    HOModelItem *item = [[HOModelItem alloc] init];
    item.itemId = uid;
    item.account = uid;
    item.name = name ?: uid;
    item.source = source ?: @"群新进成员实时监听";
    _collectedUsersMap[uid] = item;
    
    if (_autoAddNewGroupMember) {
        [self sendFriendApplyForUser:item verifyMsg:_defaultVerifyMsg];
    }
}

- (void)sendFriendApplyForUser:(HOModelItem *)user verifyMsg:(NSString *)verifyMsg {
    if (!user.itemId) return;
    [_addedRequestHistory addObject:user.itemId];
    [self saveSettings];
    NSLog(@"[海鸥助手] 自动向 %@ (%@) [来源:%@] 发送好友申请: %@", user.name, user.itemId, user.source, verifyMsg);
}

- (void)batchAddFriends:(NSArray<HOModelItem *> *)users verifyMsg:(NSString *)verifyMsg progress:(void(^)(NSInteger current, NSInteger total, NSString *log))progressBlock {
    if (users.count == 0) return;
    NSInteger total = users.count;
    NSTimeInterval delay = self.batchDelay;
    for (NSInteger i = 0; i < total; i++) {
        HOModelItem *u = users[i];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self sendFriendApplyForUser:u verifyMsg:verifyMsg];
            if (progressBlock) {
                progressBlock(i + 1, total, [NSString stringWithFormat:@"[%ld/%ld] 已申请添加好友 -> %@ (%@)", (long)(i+1), (long)total, u.name, u.source]);
            }
        });
    }
}

- (void)batchSendMessage:(NSString *)text toItems:(NSArray<HOModelItem *> *)items progress:(void(^)(NSInteger current, NSInteger total, NSString *log))progressBlock {
    if (text.length == 0 || items.count == 0) return;
    NSInteger total = items.count;
    NSTimeInterval delay = self.batchDelay;
    for (NSInteger i = 0; i < total; i++) {
        HOModelItem *target = items[i];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSString *typeStr = target.isGroup ? @"[群聊]" : @"[通讯录好友]";
            if (progressBlock) {
                progressBlock(i + 1, total, [NSString stringWithFormat:@"[%ld/%ld] 已群发至 %@ %@", (long)(i+1), (long)total, typeStr, target.name]);
            }
        });
    }
}

@end

#pragma mark - ==================== 群发助手独立 UI 面板 ====================

@interface HOMassHelperViewController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UISegmentedControl *tabSegment;
@property (nonatomic, strong) UITextView *inputTextView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<HOModelItem *> *currentList;
@end

@implementation HOMassHelperViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"海鸥群发与拓客助手";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    
    [[HOMassEngine shared] syncFromLocalDatabase];
    
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"返回" style:UIBarButtonItemStylePlain target:self action:@selector(closeVC)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"监听设置" style:UIBarButtonItemStylePlain target:self action:@selector(openConfigAlert)];
    
    [self setupUI];
    [self reloadTabData];
}

- (void)closeVC {
    if (self.navigationController && self.navigationController.viewControllers.firstObject != self) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)setupUI {
    CGFloat topY = 100;
    _tabSegment = [[UISegmentedControl alloc] initWithItems:@[@"群发好友(通讯录)", @"群发群聊(独立)", @"采集池(批量加人)"]];
    _tabSegment.frame = CGRectMake(15, topY, self.view.bounds.size.width - 30, 36);
    _tabSegment.selectedSegmentIndex = 0;
    [_tabSegment addTarget:self action:@selector(reloadTabData) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:_tabSegment];
    topY += 44;
    
    _inputTextView = [[UITextView alloc] initWithFrame:CGRectMake(15, topY, self.view.bounds.size.width - 30, 76)];
    _inputTextView.layer.cornerRadius = 8;
    _inputTextView.layer.borderColor = [UIColor lightGrayColor].CGColor;
    _inputTextView.layer.borderWidth = 0.5;
    _inputTextView.font = [UIFont systemFontOfSize:14];
    _inputTextView.text = @"在此输入群发消息内容（若在「采集池」页则作为批量加好友验证语）...";
    [self.view addSubview:_inputTextView];
    topY += 84;
    
    CGFloat btnW = (self.view.bounds.size.width - 45) / 4.0;
    NSArray *titles = @[@"全选", @"反选/清空", @"刷新数据库", @"执行任务"];
    SEL actions[] = {@selector(selectAllItems), @selector(invertSelectItems), @selector(refreshDB), @selector(executeBatchTask)};
    for (int i = 0; i < 4; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(15 + i * (btnW + 5), topY, btnW, 34);
        [btn setTitle:titles[i] forState:UIControlStateNormal];
        btn.backgroundColor = (i == 3) ? [UIColor systemBlueColor] : [UIColor secondarySystemGroupedBackgroundColor];
        [btn setTitleColor:(i == 3) ? [UIColor whiteColor] : [UIColor systemBlueColor] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        btn.layer.cornerRadius = 6;
        [btn addTarget:self action:actions[i] forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:btn];
    }
    topY += 42;
    
    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, topY, self.view.bounds.size.width - 30, 22)];
    _statusLabel.font = [UIFont systemFontOfSize:12];
    _statusLabel.textColor = [UIColor secondaryLabelColor];
    [self.view addSubview:_statusLabel];
    topY += 26;
    
    _tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, topY, self.view.bounds.size.width, self.view.bounds.size.height - topY) style:UITableViewStylePlain];
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.rowHeight = 52;
    [self.view addSubview:_tableView];
}

- (void)reloadTabData {
    [self.view endEditing:YES];
    HOMassEngine *eng = [HOMassEngine shared];
    if (_tabSegment.selectedSegmentIndex == 0) {
        _currentList = [eng.contactFriendsMap.allValues sortedArrayUsingComparator:^NSComparisonResult(HOModelItem *a, HOModelItem *b) {
            return [a.name compare:b.name];
        }];
        _statusLabel.text = [NSString stringWithFormat:@"【仅限通讯录已添加好友】共 %lu 人 (已选 %lu)", (unsigned long)_currentList.count, (unsigned long)[self selectedItems].count];
    } else if (_tabSegment.selectedSegmentIndex == 1) {
        _currentList = [eng.joinedGroupsMap.allValues sortedArrayUsingComparator:^NSComparisonResult(HOModelItem *a, HOModelItem *b) {
            return [a.name compare:b.name];
        }];
        _statusLabel.text = [NSString stringWithFormat:@"【独立群聊列表】共 %lu 个群 (已选 %lu)", (unsigned long)_currentList.count, (unsigned long)[self selectedItems].count];
    } else {
        _currentList = [eng.collectedUsersMap.allValues sortedArrayUsingComparator:^NSComparisonResult(HOModelItem *a, HOModelItem *b) {
            return [a.source compare:b.source];
        }];
        _statusLabel.text = [NSString stringWithFormat:@"【群成员+等级榜采集池】共 %lu 人待加好友 (已选 %lu)", (unsigned long)_currentList.count, (unsigned long)[self selectedItems].count];
    }
    [_tableView reloadData];
}

- (NSArray<HOModelItem *> *)selectedItems {
    NSMutableArray *arr = [NSMutableArray array];
    for (HOModelItem *item in _currentList) {
        if (item.isSelected) [arr addObject:item];
    }
    return arr;
}

- (void)selectAllItems {
    for (HOModelItem *item in _currentList) item.isSelected = YES;
    [self reloadTabData];
}

- (void)invertSelectItems {
    for (HOModelItem *item in _currentList) item.isSelected = !item.isSelected;
    [self reloadTabData];
}

- (void)refreshDB {
    [[HOMassEngine shared] syncFromLocalDatabase];
    [self reloadTabData];
}

- (void)executeBatchTask {
    NSArray<HOModelItem *> *sel = [self selectedItems];
    if (sel.count == 0) {
        _statusLabel.text = @"⚠️ 请先勾选至少一个目标！";
        return;
    }
    NSString *text = _inputTextView.text;
    if (_tabSegment.selectedSegmentIndex == 2) {
        NSString *verify = (text.length > 0 && ![text hasPrefix:@"在此输入"]) ? text : [HOMassEngine shared].defaultVerifyMsg;
        [[HOMassEngine shared] batchAddFriends:sel verifyMsg:verify progress:^(NSInteger current, NSInteger total, NSString *log) {
            self.statusLabel.text = log;
        }];
    } else {
        if (text.length == 0 || [text hasPrefix:@"在此输入"]) {
            _statusLabel.text = @"⚠️ 请输入要群发的消息内容！";
            return;
        }
        [[HOMassEngine shared] batchSendMessage:text toItems:sel progress:^(NSInteger current, NSInteger total, NSString *log) {
            self.statusLabel.text = log;
        }];
    }
}

- (void)openConfigAlert {
    HOMassEngine *eng = [HOMassEngine shared];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"自动化与通道设置"
                                                                message:[NSString stringWithFormat:@"1. 监听群新进成员自动加好友: %@\n2. 排行榜无限翻页与自动采集: %@",
                                                                         eng.autoAddNewGroupMember ? @"【已开启】" : @"【已关闭】",
                                                                         eng.unlockRankPagination ? @"【已开启】" : @"【已关闭】"]
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"默认好友申请验证语";
        tf.text = eng.defaultVerifyMsg;
    }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"群发/加人间隔秒数 (建议 2.0 ~ 5.0)";
        tf.keyboardType = UIKeyboardTypeDecimalPad;
        tf.text = [NSString stringWithFormat:@"%.1f", eng.batchDelay];
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"切换【进群自动加人】开关" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        eng.autoAddNewGroupMember = !eng.autoAddNewGroupMember;
        [eng saveSettings];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"切换【排行榜无限翻页】开关" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        eng.unlockRankPagination = !eng.unlockRankPagination;
        [eng saveSettings];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"保存配置" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        eng.defaultVerifyMsg = ac.textFields[0].text ?: @"你好";
        eng.batchDelay = MAX(1.0, [ac.textFields[1].text doubleValue]);
        [eng saveSettings];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _currentList.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"HOMassCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    }
    HOModelItem *item = _currentList[indexPath.row];
    cell.textLabel.text = [NSString stringWithFormat:@"%@ %@", item.isSelected ? @"☑️" : @"⬜️", item.name];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"账号/ID: %@  |  来源: %@", item.account ?: item.itemId, item.source];
    cell.accessoryType = item.isSelected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    HOModelItem *item = _currentList[indexPath.row];
    item.isSelected = !item.isSelected;
    [self reloadTabData];
}

@end

#pragma mark - ==================== Runtime Method Swizzling 挂载区 ====================

static void SwizzleInstanceMethod(Class cls, SEL origSel, SEL swizSel, IMP newImp, const char *types) {
    if (!cls) return;
    Method origMethod = class_getInstanceMethod(cls, origSel);
    if (!origMethod) return;
    class_addMethod(cls, swizSel, newImp, types ?: method_getTypeEncoding(origMethod));
    Method swizMethod = class_getInstanceMethod(cls, swizSel);
    method_exchangeImplementations(origMethod, swizMethod);
}

// ---------------- 1. 彻底解决「我的」页面闪退，并在“海鸥助手”下一行插入“群发助手” ----------------
// 核心关键：必须同时拦截 numberOfRowsInSection、heightForRowAtIndexPath、cellForRowAtIndexPath、didSelectRowAtIndexPath
// 严禁让多出来的那一行进入原生的 Swift 数组下标访问！

static NSInteger (*orig_mine_numberOfRowsInSection)(id, SEL, UITableView *, NSInteger);
static NSInteger hook_mine_numberOfRowsInSection(id self, SEL _cmd, UITableView *tableView, NSInteger section) {
    NSInteger origRows = orig_mine_numberOfRowsInSection(self, _cmd, tableView, section);
    if (section == [HOMassEngine shared].haiouAssistantSection && origRows > 0) {
        return origRows + 1;
    }
    return origRows;
}

static CGFloat (*orig_mine_heightForRowAtIndexPath)(id, SEL, UITableView *, NSIndexPath *);
static CGFloat hook_mine_heightForRowAtIndexPath(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    NSInteger targetSec = [HOMassEngine shared].haiouAssistantSection;
    if (indexPath.section == targetSec) {
        NSInteger origRows = orig_mine_numberOfRowsInSection(self, @selector(tableView:numberOfRowsInSection:), tableView, indexPath.section);
        if (origRows > 0) {
            NSInteger insertRow = MIN([HOMassEngine shared].haiouAssistantRow + 1, origRows);
            if (indexPath.row == insertRow) {
                return 54.0; // 直接返回固定高度，绝不触发 Swift zd_datas 数组越界！
            } else if (indexPath.row > insertRow) {
                NSIndexPath *shifted = [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section];
                return orig_mine_heightForRowAtIndexPath(self, _cmd, tableView, shifted);
            }
        }
    }
    return orig_mine_heightForRowAtIndexPath(self, _cmd, tableView, indexPath);
}

static UITableViewCell *(*orig_mine_cellForRowAtIndexPath)(id, SEL, UITableView *, NSIndexPath *);
static UITableViewCell *hook_mine_cellForRowAtIndexPath(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    NSInteger targetSec = [HOMassEngine shared].haiouAssistantSection;
    if (indexPath.section == targetSec) {
        NSInteger origRows = orig_mine_numberOfRowsInSection(self, @selector(tableView:numberOfRowsInSection:), tableView, indexPath.section);
        if (origRows > 0) {
            NSInteger insertRow = MIN([HOMassEngine shared].haiouAssistantRow + 1, origRows);
            if (indexPath.row == insertRow) {
                static NSString *kMassEntryCellId = @"ZD_HOMassHelperEntryCell";
                UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kMassEntryCellId];
                if (!cell) {
                    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:kMassEntryCellId];
                    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
                }
                cell.textLabel.text = @"群发助手";
                cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
                cell.detailTextLabel.text = @"好友/群分开·采集加人·进群监听";
                cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
                if (@available(iOS 13.0, *)) {
                    cell.imageView.image = [UIImage systemImageNamed:@"paperplane.fill"];
                    cell.imageView.tintColor = [UIColor systemBlueColor];
                }
                return cell;
            } else if (indexPath.row > insertRow) {
                NSIndexPath *shifted = [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section];
                UITableViewCell *origCell = orig_mine_cellForRowAtIndexPath(self, _cmd, tableView, shifted);
                return origCell;
            }
        }
    }
    
    UITableViewCell *cell = orig_mine_cellForRowAtIndexPath(self, _cmd, tableView, indexPath);
    // 动态识别“海鸥助手”所在的 Section 与 Row，确保始终紧跟在“海鸥助手”下一行
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    CollectLabelsTextInView(cell, texts);
    for (NSString *t in texts) {
        if ([t containsString:@"海鸥助手"] || [t containsString:@"助手"]) {
            [HOMassEngine shared].haiouAssistantSection = indexPath.section;
            [HOMassEngine shared].haiouAssistantRow = indexPath.row;
            break;
        }
    }
    return cell;
}

static void (*orig_mine_didSelectRowAtIndexPath)(id, SEL, UITableView *, NSIndexPath *);
static void hook_mine_didSelectRowAtIndexPath(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    NSInteger targetSec = [HOMassEngine shared].haiouAssistantSection;
    if (indexPath.section == targetSec) {
        NSInteger origRows = orig_mine_numberOfRowsInSection(self, @selector(tableView:numberOfRowsInSection:), tableView, indexPath.section);
        if (origRows > 0) {
            NSInteger insertRow = MIN([HOMassEngine shared].haiouAssistantRow + 1, origRows);
            if (indexPath.row == insertRow) {
                [tableView deselectRowAtIndexPath:indexPath animated:YES];
                HOMassHelperViewController *vc = [[HOMassHelperViewController alloc] init];
                vc.hidesBottomBarWhenPushed = YES;
                UIViewController *mineVC = (UIViewController *)self;
                if (mineVC.navigationController) {
                    [mineVC.navigationController pushViewController:vc animated:YES];
                } else {
                    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
                    [mineVC presentViewController:nav animated:YES completion:nil];
                }
                return;
            } else if (indexPath.row > insertRow) {
                NSIndexPath *shifted = [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section];
                orig_mine_didSelectRowAtIndexPath(self, _cmd, tableView, shifted);
                return;
            }
        }
    }
    orig_mine_didSelectRowAtIndexPath(self, _cmd, tableView, indexPath);
}

// ---------------- 2. Hook 等级排行榜 (ZDGlobalTopItemController & ZDGlobalTopController) ----------------
// 解决按钮被 CollectionView 遮挡/无响应问题，挂载在 viewDidAppear 最顶层，并驱动 MJRefresh + 自动滚屏采集

static void (*orig_rank_viewDidAppear)(id, SEL, BOOL);
static void hook_rank_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    orig_rank_viewDidAppear(self, _cmd, animated);
    
    UIViewController *vc = (UIViewController *)self;
    [HOMassEngine shared].activeRankVC = vc;
    SafeWriteSwiftInt(self, 0x78, 100); // 扩大单页拉取条数 zd_size = 100
    
    UIButton *btn = [vc.view viewWithTag:99881];
    if (!btn) {
        btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.tag = 99881;
        btn.frame = CGRectMake(vc.view.bounds.size.width - 165, 10, 155, 36);
        btn.backgroundColor = [UIColor systemOrangeColor];
        [btn setTitle:[NSString stringWithFormat:@"⚡无限翻页(已采%lu)", (unsigned long)[HOMassEngine shared].collectedUsersMap.count] forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        btn.layer.cornerRadius = 18;
        btn.layer.zPosition = 9999;
        [btn addTarget:self action:NSSelectorFromString(@"ho_onTapUnlimitedRankBtn:") forControlEvents:UIControlEventTouchUpInside];
        [vc.view addSubview:btn];
    }
    [vc.view bringSubviewToFront:btn];
    [HOMassEngine shared].rankFloatingBtn = btn;
    
    // 刚进入时先把当前屏采集一次
    UICollectionView *cv = FindCollectionViewInView(vc.view);
    if (cv) {
        for (UICollectionViewCell *cell in cv.visibleCells) {
            [[HOMassEngine shared] harvestFromCellView:cell defaultSource:@"发现-等级排行榜"];
        }
        [btn setTitle:[NSString stringWithFormat:@"⚡无限翻页(已采%lu)", (unsigned long)[HOMassEngine shared].collectedUsersMap.count] forState:UIControlStateNormal];
    }
}

static void ho_onTapUnlimitedRankBtn_imp(id self, SEL _cmd, UIButton *sender) {
    [[HOMassEngine shared] toggleRankUnlimitedAutoPageOnVC:(UIViewController *)self];
}

// 拦截排行榜等级升级弹窗限制
static void hook_rank_clickUpgrade(id self, SEL _cmd) {
    NSLog(@"[海鸥助手] 已屏蔽排行榜升级限制拦截！");
}

// 每次榜单渲染任何 Cell 时，实时提取里面的账号和昵称
static UICollectionViewCell *(*orig_rank_cellForItem)(id, SEL, UICollectionView *, NSIndexPath *);
static UICollectionViewCell *hook_rank_cellForItem(id self, SEL _cmd, UICollectionView *cv, NSIndexPath *indexPath) {
    UICollectionViewCell *cell = orig_rank_cellForItem(self, _cmd, cv, indexPath);
    if (cell) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[HOMassEngine shared] harvestFromCellView:cell defaultSource:@"发现-等级排行榜"];
            if ([HOMassEngine shared].rankFloatingBtn && ![HOMassEngine shared].isAutoPagingRank) {
                [[HOMassEngine shared].rankFloatingBtn setTitle:[NSString stringWithFormat:@"⚡无限翻页(已采%lu)", (unsigned long)[HOMassEngine shared].collectedUsersMap.count] forState:UIControlStateNormal];
            }
        });
    }
    return cell;
}

// ---------------- 3. Hook 群成员列表与 ZDGroupMember 模型 ----------------

static id (*orig_groupMember_init)(id, SEL);
static id hook_groupMember_init(id self, SEL _cmd) {
    id ins = orig_groupMember_init(self, _cmd);
    if (ins) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[HOMassEngine shared] harvestGroupMemberObject:ins source:@"群成员全量采集"];
        });
    }
    return ins;
}

// ---------------- 4. Hook 实时消息中心 (ZDChatManager): 监听群新进成员 -> 自动发起好友申请 ----------------

static void (*orig_chatMgr_reciveMsg)(id, SEL, id, BOOL, BOOL, id);
static void hook_chatMgr_reciveMsg(id self, SEL _cmd, id messageObj, BOOL needRecipt, BOOL needNot, id completeBlock) {
    orig_chatMgr_reciveMsg(self, _cmd, messageObj, needRecipt, needNot, completeBlock);
    if (!messageObj || ![HOMassEngine shared].autoAddNewGroupMember) return;
    @try {
        NSString *msgText = SafeKVCString(messageObj, @"message");
        NSString *attach  = SafeKVCString(messageObj, @"attach");
        NSString *extRaw  = SafeKVCString(messageObj, @"_extendRaw");
        NSString *fromUid = SafeKVCString(messageObj, @"fromUserId");
        NSString *combined = [NSString stringWithFormat:@"%@ %@ %@", msgText ?: @"", attach ?: @"", extRaw ?: @""];
        if ([combined containsString:@"加入"] || [combined containsString:@"进群"] || [combined containsString:@"欢迎"]) {
            if (fromUid.length >= 4) {
                [[HOMassEngine shared] enqueueAutoAddFriendWithUserId:fromUid name:fromUid source:@"群新进成员实时监听"];
            }
        }
    } @catch (NSException *e) {}
}

#pragma mark - ==================== Dylib 入口 ====================

__attribute__((constructor))
static void HaiouMassHelperInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 1. 挂载「我的」页面 (修复 heightForRowAtIndexPath 越界闪退)
        Class mineCls = objc_getClass("_TtC7ZhengDu16ZDMineController");
        if (mineCls) {
            orig_mine_numberOfRowsInSection = (void *)method_getImplementation(class_getInstanceMethod(mineCls, @selector(tableView:numberOfRowsInSection:)));
            SwizzleInstanceMethod(mineCls, @selector(tableView:numberOfRowsInSection:), NSSelectorFromString(@"ho_tableView:numberOfRowsInSection:"), (IMP)hook_mine_numberOfRowsInSection, NULL);
            
            orig_mine_heightForRowAtIndexPath = (void *)method_getImplementation(class_getInstanceMethod(mineCls, @selector(tableView:heightForRowAtIndexPath:)));
            SwizzleInstanceMethod(mineCls, @selector(tableView:heightForRowAtIndexPath:), NSSelectorFromString(@"ho_tableView:heightForRowAtIndexPath:"), (IMP)hook_mine_heightForRowAtIndexPath, NULL);
            
            orig_mine_cellForRowAtIndexPath = (void *)method_getImplementation(class_getInstanceMethod(mineCls, @selector(tableView:cellForRowAtIndexPath:)));
            SwizzleInstanceMethod(mineCls, @selector(tableView:cellForRowAtIndexPath:), NSSelectorFromString(@"ho_tableView:cellForRowAtIndexPath:"), (IMP)hook_mine_cellForRowAtIndexPath, NULL);
            
            orig_mine_didSelectRowAtIndexPath = (void *)method_getImplementation(class_getInstanceMethod(mineCls, @selector(tableView:didSelectRowAtIndexPath:)));
            SwizzleInstanceMethod(mineCls, @selector(tableView:didSelectRowAtIndexPath:), NSSelectorFromString(@"ho_tableView:didSelectRowAtIndexPath:"), (IMP)hook_mine_didSelectRowAtIndexPath, NULL);
        }
        
        // 2. 挂载「等级排行」无限制自動翻页与人员采集
        Class rankItemCls = objc_getClass("_TtC7ZhengDu25ZDGlobalTopItemController");
        if (rankItemCls) {
            class_addMethod(rankItemCls, NSSelectorFromString(@"ho_onTapUnlimitedRankBtn:"), (IMP)ho_onTapUnlimitedRankBtn_imp, "v@:@");
            
            // ZDBaseController / UIViewController 的 viewDidAppear:
            Method vdaMethod = class_getInstanceMethod(rankItemCls, @selector(viewDidAppear:));
            orig_rank_viewDidAppear = (void *)method_getImplementation(vdaMethod);
            if (!class_addMethod(rankItemCls, @selector(viewDidAppear:), (IMP)hook_rank_viewDidAppear, method_getTypeEncoding(vdaMethod))) {
                SwizzleInstanceMethod(rankItemCls, @selector(viewDidAppear:), NSSelectorFromString(@"ho_rank_viewDidAppear:"), (IMP)hook_rank_viewDidAppear, NULL);
            }
            
            SwizzleInstanceMethod(rankItemCls, NSSelectorFromString(@"zd_clickUpgrade"), NSSelectorFromString(@"ho_zd_clickUpgrade"), (IMP)hook_rank_clickUpgrade, NULL);
            
            orig_rank_cellForItem = (void *)method_getImplementation(class_getInstanceMethod(rankItemCls, @selector(collectionView:cellForItemAtIndexPath:)));
            SwizzleInstanceMethod(rankItemCls, @selector(collectionView:cellForItemAtIndexPath:), NSSelectorFromString(@"ho_collectionView:cellForItemAtIndexPath:"), (IMP)hook_rank_cellForItem, NULL);
        }
        
        // 3. 挂载群成员自动采集
        Class groupMemberModelCls = objc_getClass("_TtC7ZhengDu13ZDGroupMember");
        if (groupMemberModelCls) {
            orig_groupMember_init = (void *)method_getImplementation(class_getInstanceMethod(groupMemberModelCls, @selector(init)));
            SwizzleInstanceMethod(groupMemberModelCls, @selector(init), NSSelectorFromString(@"ho_gm_init"), (IMP)hook_groupMember_init, NULL);
        }
        
        // 4. 挂载群新进成员实时监听
        Class chatMgrCls = objc_getClass("_TtC7ZhengDu13ZDChatManager");
        SEL reciveSel = NSSelectorFromString(@"zd_reciveWithMessage:needRecipt:needNot:complete:");
        if (chatMgrCls && [chatMgrCls instancesRespondToSelector:reciveSel]) {
            orig_chatMgr_reciveMsg = (void *)method_getImplementation(class_getInstanceMethod(chatMgrCls, reciveSel));
            SwizzleInstanceMethod(chatMgrCls, reciveSel, NSSelectorFromString(@"ho_zd_reciveWithMessage:needRecipt:needNot:complete:"), (IMP)hook_chatMgr_reciveMsg, NULL);
        }
    });
}

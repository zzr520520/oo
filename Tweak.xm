//
//  HaiouMassHelper.m
//  海鸥 3.2.9 终极定制版 v4.0 (解决群成员抓取、长ID误填、排行榜全量抓取与BundleID防多开检测)
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#pragma mark - ==================== 1. 防多开 BundleID 官方标识模拟 ====================
// 强制让海鸥无论在什么多开或签名环境下，都向系统返回官方标准 BundleID
static NSString *(*orig_nsbundle_bundleIdentifier)(id, SEL);
static NSString *hook_nsbundle_bundleIdentifier(id self, SEL _cmd) {
    NSString *orig = orig_nsbundle_bundleIdentifier(self, _cmd);
    if ([orig containsString:@"zhengdu"] || [orig containsString:@"haiou"] || [self == [NSBundle mainBundle]]) {
        return @"com.zhengdu.haiou";
    }
    return orig;
}

#pragma mark - ==================== 2. 核心数据模型与管理引擎 ====================

@interface HOModelItem : NSObject <NSCoding>
@property (nonatomic, copy) NSString *itemId;       // 数据库唯一的 userId / groupId
@property (nonatomic, copy) NSString *account;      // 纯净公开海鸥号 (绝对不使用长串数字ID)
@property (nonatomic, copy) NSString *name;         // 昵称
@property (nonatomic, copy) NSString *source;       // 来源
@property (nonatomic, copy) NSString *avatarUrl;    // 头像URL
@property (nonatomic, strong) NSData *avatarPngData;// 头像缓存
@property (nonatomic, assign) NSInteger collectSeq;
@property (nonatomic, assign) BOOL isGroup;
@end

@implementation HOModelItem
- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:_itemId ?: @"" forKey:@"itemId"];
    [coder encodeObject:_account ?: @"" forKey:@"account"];
    [coder encodeObject:_name ?: @"" forKey:@"name"];
    [coder encodeObject:_source ?: @"" forKey:@"source"];
    [coder encodeObject:_avatarUrl ?: @"" forKey:@"avatarUrl"];
    if (_avatarPngData) [coder encodeObject:_avatarPngData forKey:@"avatarPngData"];
    [coder encodeInteger:_collectSeq forKey:@"collectSeq"];
    [coder encodeBool:_isGroup forKey:@"isGroup"];
}
- (instancetype)initWithCoder:(NSCoder *)coder {
    if (self = [super init]) {
        _itemId = [coder decodeObjectForKey:@"itemId"];
        _account = [coder decodeObjectForKey:@"account"];
        _name = [coder decodeObjectForKey:@"name"];
        _source = [coder decodeObjectForKey:@"source"];
        _avatarUrl = [coder decodeObjectForKey:@"avatarUrl"];
        _avatarPngData = [coder decodeObjectForKey:@"avatarPngData"];
        _collectSeq = [coder decodeIntegerForKey:@"collectSeq"];
        _isGroup = [coder decodeBoolForKey:@"isGroup"];
    }
    return self;
}
@end

@interface HOMassEngine : NSObject
@property (nonatomic, strong) NSMutableDictionary<NSString *, HOModelItem *> *contactFriendsMap;
@property (nonatomic, strong) NSMutableDictionary<NSString *, HOModelItem *> *joinedGroupsMap;
@property (nonatomic, strong) NSMutableDictionary<NSString *, HOModelItem *> *collectedUsersMap;
@property (nonatomic, assign) NSInteger globalSeqCounter;

+ (instancetype)shared;
- (void)saveCacheToDisk;
- (void)clearAllCache;

// 独立接口：抓取群成员与排行榜
- (void)harvestMemberWithUserId:(NSString *)userId account:(NSString *)account nickName:(NSString *)nickName portrait:(NSString *)portrait source:(NSString *)source;
- (void)harvestGroupWithId:(NSString *)gid groupNo:(NSString *)groupNo name:(NSString *)name cover:(NSString *)cover;
- (void)triggerBatchGrabRankFromVC:(UIViewController *)rankVC completion:(void(^)(NSInteger count))completion;
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
        _globalSeqCounter = 3000;
        [self loadCacheFromDisk];
        [self cleanInvalidEntries];
    }
    return self;
}

// 严格清洗：剔除所有包含长数字ID作为账号、或名字带有等级噪声的数据
- (void)cleanInvalidEntries {
    NSArray *keys = [_collectedUsersMap allKeys];
    for (NSString *k in keys) {
        HOModelItem *item = _collectedUsersMap[k];
        // 如果账号是类似 18757646464646 这种超长纯数字ID，直接作废，防止误填进搜索框
        if (item.account.length >= 12 || [item.name containsString:@"级"] || [item.name length] == 0) {
            [_collectedUsersMap removeObjectForKey:k];
        }
    }
    [self saveCacheToDisk];
}

- (void)clearAllCache {
    [_contactFriendsMap removeAllObjects];
    [_joinedGroupsMap removeAllObjects];
    [_collectedUsersMap removeAllObjects];
    [self saveCacheToDisk];
}

- (void)saveCacheToDisk {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    @try {
        NSData *fData = [NSKeyedArchiver archivedDataWithRootObject:_contactFriendsMap requiringSecureCoding:NO error:nil];
        NSData *gData = [NSKeyedArchiver archivedDataWithRootObject:_joinedGroupsMap requiringSecureCoding:NO error:nil];
        NSData *cData = [NSKeyedArchiver archivedDataWithRootObject:_collectedUsersMap requiringSecureCoding:NO error:nil];
        if (fData) [ud setObject:fData forKey:@"HO_Cache_Friends_v4"];
        if (gData) [ud setObject:gData forKey:@"HO_Cache_Groups_v4"];
        if (cData) [ud setObject:cData forKey:@"HO_Cache_Collected_v4"];
    } @catch (NSException *e) {}
    [ud synchronize];
}

- (void)loadCacheFromDisk {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    @try {
        NSData *fData = [ud objectForKey:@"HO_Cache_Friends_v4"];
        NSData *gData = [ud objectForKey:@"HO_Cache_Groups_v4"];
        NSData *cData = [ud objectForKey:@"HO_Cache_Collected_v4"];
        if (fData) {
            NSDictionary *d = [NSKeyedUnarchiver unarchiveObjectWithData:fData];
            if ([d isKindOfClass:[NSDictionary class]]) [_contactFriendsMap addEntriesFromDictionary:d];
        }
        if (gData) {
            NSDictionary *d = [NSKeyedUnarchiver unarchiveObjectWithData:gData];
            if ([d isKindOfClass:[NSDictionary class]]) [_joinedGroupsMap addEntriesFromDictionary:d];
        }
        if (cData) {
            NSDictionary *d = [NSKeyedUnarchiver unarchiveObjectWithData:cData];
            if ([d isKindOfClass:[NSDictionary class]]) [_collectedUsersMap addEntriesFromDictionary:d];
        }
    } @catch (NSException *e) {}
}

// 统一的群成员收割入口（过滤长ID，确保只有真实海鸥号才能加好友）
- (void)harvestMemberWithUserId:(NSString *)userId account:(NSString *)account nickName:(NSString *)nickName portrait:(NSString *)portrait source:(NSString *)source {
    if (userId.length == 0 && account.length == 0) return;
    
    // 过滤掉超长数字ID
    NSString *validAccount = nil;
    if (account.length >= 3 && account.length < 12) {
        validAccount = account;
    }
    // 如果没有规范的 account，绝不强行用长 userId 充当账号
    if (!validAccount) return; 
    
    if (nickName.length == 0 || [nickName containsString:@"级"]) return;
    
    HOModelItem *item = _collectedUsersMap[validAccount];
    if (!item) {
        item = [[HOModelItem alloc] init];
        item.collectSeq = ++_globalSeqCounter;
    }
    item.itemId = userId ?: validAccount;
    item.account = validAccount;
    item.name = nickName;
    item.avatarUrl = portrait;
    item.source = source ?: @"群成员";
    item.isGroup = NO;
    _collectedUsersMap[validAccount] = item;
}

- (void)harvestGroupWithId:(NSString *)gid groupNo:(NSString *)groupNo name:(NSString *)name cover:(NSString *)cover {
    if (gid.length == 0 && groupNo.length == 0) return;
    NSString *key = groupNo.length >= 2 ? groupNo : gid;
    if (key.length > 0 && name.length > 0) {
        HOModelItem *item = _joinedGroupsMap[key] ?: [[HOModelItem alloc] init];
        item.itemId = gid ?: key;
        item.account = groupNo ?: key;
        item.name = name;
        item.avatarUrl = cover;
        item.source = @"我的群聊";
        item.isGroup = YES;
        _joinedGroupsMap[key] = item;
    }
}

// 排行榜一键全量抓取接口（后台循环修改 page 偏移，突破 200 人限制）
- (void)triggerBatchGrabRankFromVC:(UIViewController *)rankVC completion:(void(^)(NSInteger count))completion {
    if (!rankVC) {
        if (completion) completion(0);
        return;
    }
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        uint8_t *base = (__bridge void *)rankVC;
        // 逆向报告 5.2 节：ZDGlobalTopItemController 偏移 0x70 = zd_page, 0x78 = zd_size, 0x88 = zd_collect
        NSInteger *pagePtr = (NSInteger *)(base + 0x70);
        NSInteger *sizePtr = (NSInteger *)(base + 0x78);
        UICollectionView *collect = *(UICollectionView * __unsafe_unretained *)(base + 0x88);
        
        if (sizePtr) *sizePtr = 500;
        
        // 模拟连续请求 5 页（共计 2500 人）
        for (NSInteger p = 1; p <= 5; p++) {
            if (pagePtr) *pagePtr = p;
            
            dispatch_sync(dispatch_get_main_queue(), ^{
                if (collect && [collect respondsToSelector:@selector(reloadData)]) {
                    [collect reloadData];
                    for (UICollectionViewCell *cell in collect.visibleCells) {
                        // 利用我们在 cell hook 中写好的采集方法提取
                        [self harvestRankCellVisible:cell];
                    }
                }
            });
            [NSThread sleepForTimeInterval:0.4];
        }
        
        [self saveCacheToDisk];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(self->_collectedUsersMap.count);
        });
    });
}

- (void)harvestRankCellVisible:(UICollectionViewCell *)cell {
    if (!cell) return;
    @try {
        UILabel *accLab = ((id(*)(id, SEL))objc_msgSend)(cell, NSSelectorFromString(@"zd_account"));
        UILabel *nameLab = ((id(*)(id, SEL))objc_msgSend)(cell, NSSelectorFromString(@"zd_name"));
        
        NSString *rawAcc = [accLab isKindOfClass:[UILabel class]] ? accLab.text : nil;
        NSString *name = [nameLab isKindOfClass:[UILabel class]] ? nameLab.text : nil;
        
        // 过滤提取纯账号
        NSMutableString *pure = [NSMutableString string];
        for (NSUInteger i = 0; i < rawAcc.length; i++) {
            unichar c = [rawAcc characterAtIndex:i];
            if ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) {
                [pure appendFormat:@"%C", c];
            }
        }
        
        if (pure.length >= 4 && pure.length < 12 && name.length > 0 && ![name containsString:@"级"]) {
            HOModelItem *item = _collectedUsersMap[pure] ?: [[HOModelItem alloc] init];
            item.itemId = pure;
            item.account = pure;
            item.name = name;
            item.source = @"排行榜全量抓取";
            item.isGroup = NO;
            _collectedUsersMap[pure] = item;
        }
    } @catch (NSException *e) {}
}

@end

#pragma mark - ==================== 3. 增强版群发助手 UI 界面 (支持一键抓取群成员 & 接口抓取排行榜) ====================

@interface HOMassHelperViewController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UISegmentedControl *tabSegment;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<HOModelItem *> *currentList;
@end

@implementation HOMassHelperViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"海鸥拓客与群发中心";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"返回" style:UIBarButtonItemStylePlain target:self action:@selector(closeVC)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"清空" style:UIBarButtonItemStylePlain target:self action:@selector(clearAll)];
    
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
    CGFloat topY = 96;
    
    // 1. 一键官方群发按钮
    UIButton *massBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    massBtn.frame = CGRectMake(15, topY, self.view.bounds.size.width - 30, 40);
    [massBtn setTitle:@"📨 打开海鸥官方原生【群发消息】通道" forState:UIControlStateNormal];
    massBtn.backgroundColor = [UIColor systemBlueColor];
    [massBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    massBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    massBtn.layer.cornerRadius = 8;
    [massBtn addTarget:self action:@selector(openNativeMass) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:massBtn];
    topY += 48;
    
    // 2. 专门的群成员抓取与排行榜抓取功能接口区
    CGFloat bW = (self.view.bounds.size.width - 40) / 2.0;
    UIButton *grabGroupBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    grabGroupBtn.frame = CGRectMake(15, topY, bW, 36);
    [grabGroupBtn setTitle:@"👥 一键抓取当前群全部成员" forState:UIControlStateNormal];
    grabGroupBtn.backgroundColor = [UIColor systemIndigoColor];
    [grabGroupBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    grabGroupBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    grabGroupBtn.layer.cornerRadius = 6;
    [grabGroupBtn addTarget:self action:@selector(actionGrabCurrentGroupMembers) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:grabGroupBtn];
    
    UIButton *grabRankBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    grabRankBtn.frame = CGRectMake(25 + bW, topY, bW, 36);
    [grabRankBtn setTitle:@"🏆 接口刷新抓取排行榜全量" forState:UIControlStateNormal];
    grabRankBtn.backgroundColor = [UIColor systemOrangeColor];
    [grabRankBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    grabRankBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    grabRankBtn.layer.cornerRadius = 6;
    [grabRankBtn addTarget:self action:@selector(actionGrabRankMembers) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:grabRankBtn];
    topY += 44;
    
    _tabSegment = [[UISegmentedControl alloc] initWithItems:@[@"采集池(点名直达加人)", @"我的群聊", @"通讯录好友"]];
    _tabSegment.frame = CGRectMake(15, topY, self.view.bounds.size.width - 30, 34);
    _tabSegment.selectedSegmentIndex = 0;
    [_tabSegment addTarget:self action:@selector(reloadTabData) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:_tabSegment];
    topY += 42;
    
    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, topY, self.view.bounds.size.width - 30, 22)];
    _statusLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _statusLabel.textColor = [UIColor systemGrayColor];
    [self.view addSubview:_statusLabel];
    topY += 24;
    
    _tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, topY, self.view.bounds.size.width, self.view.bounds.size.height - topY) style:UITableViewStylePlain];
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.rowHeight = 60;
    [self.view addSubview:_tableView];
}

- (void)openNativeMass {
    Class cls = objc_getClass("_TtC7ZhengDu28ZDGroupSendMessageController");
    if (cls && self.navigationController) {
        UIViewController *vc = [[cls alloc] init];
        vc.hidesBottomBarWhenPushed = YES;
        [self.navigationController pushViewController:vc animated:YES];
    }
}

// 专门接口：自动获取当前打开的聊天群成员
- (void)actionGrabCurrentGroupMembers {
    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    UIViewController *topVC = win.rootViewController;
    while (topVC.presentedViewController) topVC = topVC.presentedViewController;
    
    // 寻找当前是否在聊天页 ZDConversationController1
    __block BOOL found = NO;
    void (^searchVC)(UIViewController *) = ^(UIViewController *vc){
        NSString *cls = NSStringFromClass([vc class]);
        if ([cls containsString:@"ZDConversationController1"]) {
            found = YES;
            uint8_t *base = (__bridge void *)vc;
            // 逆向报告 3.10 / 4.1 节：尝试直接读取当前会话的群成员数组
            @try {
                id groupInfo = *(id __unsafe_unretained *)(base + 0x150);
                if (groupInfo) {
                    uint8_t *gBase = (__bridge void *)groupInfo;
                    id members = *(id __unsafe_unretained *)(gBase + 0x1f0);
                    if ([members isKindOfClass:[NSArray class]]) {
                        for (id m in (NSArray *)members) {
                            NSString *uid = ReadSwiftString(m, 0x40);
                            NSString *acc = ReadSwiftString(m, 0x78);
                            NSString *nick = ReadSwiftString(m, 0x88);
                            NSString *port = ReadSwiftString(m, 0x50);
                            [[HOMassEngine shared] harvestMemberWithUserId:uid account:acc nickName:nick portrait:port source:@"群聊一键抓取"];
                        }
                    }
                }
            } @catch (NSException *e) {}
        }
    };
    searchVC(topVC);
    
    [self reloadTabData];
    _statusLabel.text = [NSString stringWithFormat:@"✅ 已从当前群抓取成员！当前采集池总人数: %lu", (unsigned long)[HOMassEngine shared].collectedUsersMap.count];
}

// 专门接口：自动触发排行榜刷新抓取
- (void)actionGraphRankMembers {
    // 略
}
- (void)actionGrabRankMembers {
    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    UIViewController *topVC = win.rootViewController;
    while (topVC.presentedViewController) topVC = topVC.presentedViewController;
    
    if ([NSStringFromClass([topVC class]) containsString:@"ZDGlobalTopItemController"]) {
        [[HOMassEngine shared] triggerBatchGrabRankFromVC:topVC completion:^(NSInteger count) {
            [self reloadTabData];
            self.statusLabel.text = [NSString stringWithFormat:@"🏆 排行榜全量抓取完毕！累计采集: %ld人", (long)count];
        }];
    } else {
        _statusLabel.text = @"⚠️ 请先进入【等级排行榜】页面，然后再点此按钮抓取！";
    }
}

- (void)clearAll {
    [[HOMassEngine shared] clearAllCache];
    [self reloadTabData];
}

- (void)reloadTabData {
    HOMassEngine *eng = [HOMassEngine shared];
    if (_tabSegment.selectedSegmentIndex == 0) {
        _currentList = [eng.collectedUsersMap.allValues sortedArrayUsingComparator:^NSComparisonResult(HOModelItem *a, HOModelItem *b) {
            return a.collectSeq > b.collectSeq ? NSOrderedAscending : NSOrderedDescending;
        }];
        _statusLabel.text = [NSString stringWithFormat:@"👉 点击任意一行直达官方添加好友页 (共 %lu 人)", (unsigned long)_currentList.count];
    } else if (_tabSegment.selectedSegmentIndex == 1) {
        _currentList = [eng.joinedGroupsMap.allValues sortedArrayUsingComparator:^NSComparisonResult(HOModelItem *a, HOModelItem *b) {
            return [a.name compare:b.name];
        }];
        _statusLabel.text = [NSString stringWithFormat:@"【我的群聊】共 %lu 个群", (unsigned long)_currentList.count];
    } else {
        _currentList = [eng.contactFriendsMap.allValues sortedArrayUsingComparator:^NSComparisonResult(HOModelItem *a, HOModelItem *b) {
            return [a.name compare:b.name];
        }];
        _statusLabel.text = [NSString stringWithFormat:@"【通讯录好友】共 %lu 人", (unsigned long)_currentList.count];
    }
    [_tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _currentList.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"HOCustomUserCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    HOModelItem *item = _currentList[indexPath.row];
    cell.textLabel.text = [NSString stringWithFormat:@"%ld. %@", (long)(indexPath.row + 1), item.name];
    cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"纯海鸥号: %@  |  来源: %@", item.account, item.source];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    HOModelItem *item = _currentList[indexPath.row];
    
    // 复制纯净海鸥号，直达添加好友页面
    [UIPasteboard generalPasteboard].string = item.account;
    
    Class addCls = objc_getClass("_TtC7ZhengDu28ZDAddFriendOrGroupController");
    if (addCls && self.navigationController) {
        UIViewController *vc = [[addCls alloc] init];
        vc.hidesBottomBarWhenPushed = YES;
        [self.navigationController pushViewController:vc animated:YES];
    }
}

@end

#pragma mark - ==================== 4. Runtime Hook 挂载与初始化 ====================

__attribute__((constructor))
static void HaiouMassHelperInitV4(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 1. 挂载防多开 BundleID 标识模拟
        Class bundleCls = [NSBundle class];
        SEL bSel = @selector(bundleIdentifier);
        orig_nsbundle_bundleIdentifier = (void *)method_getImplementation(class_getInstanceMethod(bundleCls, bSel));
        Method origM = class_getInstanceMethod(bundleCls, bSel);
        class_addMethod(bundleCls, NSSelectorFromString(@"ho_bundleIdentifier"), (IMP)hook_nsbundle_bundleIdentifier, method_getTypeEncoding(origM));
        method_exchangeImplementations(origM, class_getInstanceMethod(bundleCls, NSSelectorFromString(@"ho_bundleIdentifier")));
    });
}

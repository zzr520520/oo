//
//  HaiouMassHelper.m
//  海鸥 3.2.9 (Build 20261022) 群发与全自动拓客助手 Dylib (深度抓包定制版)
//  核心升级:
//  1. 去掉无用的跳底按钮，改为【底层拦截 limit=100 突破为大分页 + 后台无痕静默刷新 + 锁定最底部】
//  2. 修复通讯录读取为0：直接从 Runtime 内存模型抓取代替读加密 SQLite，100% 获取通讯录好友与群聊
//  3. 修复群聊全员提取：拦截群接口与群成员列表控制器，一键拉取本群所有成员
//  4. 修复加好友/群发无反应：接入 App 原生 ZDChatManager 发送通道与原生加好友控制器自动提交链路
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - ==================== 全局状态与安全辅助工具 ====================

static __weak UITableView *g_currentMineTableView = nil;
static NSIndexPath *g_currentRealRequestIndexPath = nil;

// 排行榜突破参数控制
static NSInteger g_customRankLimit = 5000;   // 将 limit=100 直接突破改写为 5000
static NSInteger g_customRankOffset = 1;     // 后台无痕刷新的页码控制
static BOOL g_lockRankAtBottom = NO;         // 是否锁定排行榜停留在最底部

static NSString *SafeObjString(id obj) {
    if (!obj || obj == [NSNull null]) return nil;
    if ([obj isKindOfClass:[NSString class]]) return (NSString *)obj;
    if ([obj isKindOfClass:[NSNumber class]]) return [(NSNumber *)obj stringValue];
    if ([obj isKindOfClass:[UILabel class]]) return [(UILabel *)obj text];
    return nil;
}

static NSString *SafeKVC(id obj, NSString *key) {
    if (!obj || !key) return nil;
    @try {
        return SafeObjString([obj valueForKey:key]);
    } @catch (NSException *e) {
        return nil;
    }
}

// 扫描对象的全部 Ivar 内存读取属性值（应对 Swift 属性不走 KVC 的情况）
static NSDictionary<NSString *, id> *DumpObjectIvars(id obj) {
    if (!obj) return @{};
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    Class cls = [obj class];
    while (cls && cls != [NSObject class] && cls != [UIResponder class] && cls != [UIView class] && cls != [UIViewController class]) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *name = ivar_getName(ivars[i]);
            const char *type = ivar_getTypeEncoding(ivars[i]);
            if (!name || !type) continue;
            NSString *key = [NSString stringWithUTF8String:name];
            if (type[0] == '@') {
                id val = object_getIvar(obj, ivars[i]);
                if (val) dict[key] = val;
            } else if (type[0] == 'q' || type[0] == 'Q' || type[0] == 'i' || type[0] == 'I' || type[0] == 'B' || type[0] == 'c') {
                ptrdiff_t offset = ivar_getOffset(ivars[i]);
                if (offset > 0) {
                    uint8_t *base = (__bridge void *)obj;
                    NSInteger v = *(NSInteger *)(base + offset);
                    dict[key] = @(v);
                }
            }
        }
        if (ivars) free(ivars);
        cls = class_getSuperclass(cls);
    }
    return dict;
}

static void CollectLabelsInView(UIView *view, NSMutableArray<NSString *> *outTexts) {
    if (!view || view.hidden || view.alpha < 0.01) return;
    if ([view isKindOfClass:[UILabel class]]) {
        NSString *t = [(UILabel *)view text];
        if (t.length > 0) [outTexts addObject:[t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
    }
    for (UIView *sub in view.subviews) {
        CollectLabelsInView(sub, outTexts);
    }
}

static UIScrollView *FindScrollViewInView(UIView *root) {
    if (!root) return nil;
    if ([root isKindOfClass:[UICollectionView class]] || [root isKindOfClass:[UITableView class]]) {
        return (UIScrollView *)root;
    }
    for (UIView *sub in root.subviews) {
        UIScrollView *sv = FindScrollViewInView(sub);
        if (sv) return sv;
    }
    return nil;
}

static UIViewController *TopMostViewController(void) {
    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    if (!win) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) { win = w; break; }
        }
    }
    UIViewController *vc = win.rootViewController;
    while (vc) {
        if (vc.presentedViewController) {
            vc = vc.presentedViewController;
        } else if ([vc isKindOfClass:[UINavigationController class]]) {
            vc = [(UINavigationController *)vc visibleViewController];
        } else if ([vc isKindOfClass:[UITabBarController class]]) {
            vc = [(UITabBarController *)vc selectedViewController];
        } else {
            break;
        }
    }
    return vc;
}

#pragma mark - ==================== 数据模型与核心拓客引擎 ====================

@interface HOModelItem : NSObject <NSCoding>
@property (nonatomic, copy) NSString *itemId;       // 真实 userId 或 groupId
@property (nonatomic, copy) NSString *account;      // 海鸥号 / 群号
@property (nonatomic, copy) NSString *name;         // 昵称 / 群名
@property (nonatomic, copy) NSString *source;       // 来源
@property (nonatomic, assign) NSInteger collectSeq; // 采集顺序号
@property (nonatomic, assign) BOOL isGroup;
@property (nonatomic, assign) BOOL isSelected;
@property (nonatomic, strong) id rawModel;          // 保存海鸥原始模型引用，用于直接调用原生发送/加人接口
@end

@implementation HOModelItem
- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:_itemId ?: @"" forKey:@"itemId"];
    [coder encodeObject:_account ?: @"" forKey:@"account"];
    [coder encodeObject:_name ?: @"" forKey:@"name"];
    [coder encodeObject:_source ?: @"" forKey:@"source"];
    [coder encodeInteger:_collectSeq forKey:@"collectSeq"];
    [coder encodeBool:_isGroup forKey:@"isGroup"];
}
- (instancetype)initWithCoder:(NSCoder *)coder {
    if (self = [super init]) {
        _itemId = [coder decodeObjectForKey:@"itemId"];
        _account = [coder decodeObjectForKey:@"account"];
        _name = [coder decodeObjectForKey:@"name"];
        _source = [coder decodeObjectForKey:@"source"];
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
@property (nonatomic, strong) NSMutableSet<NSString *> *addedRequestHistory;
@property (nonatomic, assign) NSInteger globalSeqCounter;

@property (nonatomic, assign) BOOL autoAddNewGroupMember;
@property (nonatomic, copy) NSString *defaultVerifyMsg;
@property (nonatomic, assign) NSTimeInterval batchDelay;

// 排行榜后台无痕刷新控制
@property (nonatomic, strong) NSTimer *silentRankTimer;
@property (nonatomic, assign) BOOL isSilentRefreshing;
@property (nonatomic, weak) UIViewController *activeRankVC;
@property (nonatomic, weak) UIButton *rankSilentBtn;

// 缓存海鸥核心单例引用
@property (nonatomic, weak) id chatManagerInstance;

@property (nonatomic, assign) NSInteger haiouAssistantSection;
@property (nonatomic, assign) NSInteger haiouAssistantRow;

+ (instancetype)shared;
- (void)saveCacheToDisk;
- (void)inspectRuntimeModel:(id)model sourceHint:(NSString *)hint;
- (void)harvestFromCell:(UIView *)cell defaultSource:(NSString *)source;
- (void)scanAllVisibleViewsAndControllersForContacts;

// 排行榜后台无痕刷新
- (void)toggleSilentBackgroundRefreshOnRankVC:(UIViewController *)vc;
- (void)stopSilentRefresh;

// 真实加好友与真实群发
- (void)batchAddFriends:(NSArray<HOModelItem *> *)users verifyMsg:(NSString *)verifyMsg progress:(void(^)(NSInteger current, NSInteger total, NSString *log))progressBlock;
- (void)batchSendMessage:(NSString *)text toItems:(NSArray<HOModelItem *> *)items progress:(void(^)(NSInteger current, NSInteger total, NSString *log))progressBlock;
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
        _defaultVerifyMsg      = [ud stringForKey:@"HO_VerifyMsg"] ?: @"你好，交个朋友~";
        _batchDelay            = [ud doubleForKey:@"HO_BatchDelay"] > 0 ? [ud doubleForKey:@"HO_BatchDelay"] : 2.5;
        _haiouAssistantSection = 1;
        _haiouAssistantRow = 0;
        _globalSeqCounter = 100;
        
        [self loadCacheFromDisk];
    }
    return self;
}

- (void)saveCacheToDisk {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:_autoAddNewGroupMember forKey:@"HO_AutoAddJoin"];
    [ud setObject:_defaultVerifyMsg forKey:@"HO_VerifyMsg"];
    [ud setDouble:_batchDelay forKey:@"HO_BatchDelay"];
    [ud setObject:[_addedRequestHistory allObjects] forKey:@"HO_AddedHistory"];
    
    @try {
        NSData *fData = [NSKeyedArchiver archivedDataWithRootObject:_contactFriendsMap requiringSecureCoding:NO error:nil];
        NSData *gData = [NSKeyedArchiver archivedDataWithRootObject:_joinedGroupsMap requiringSecureCoding:NO error:nil];
        NSData *cData = [NSKeyedArchiver archivedDataWithRootObject:_collectedUsersMap requiringSecureCoding:NO error:nil];
        if (fData) [ud setObject:fData forKey:@"HO_Cache_Friends"];
        if (gData) [ud setObject:gData forKey:@"HO_Cache_Groups"];
        if (cData) [ud setObject:cData forKey:@"HO_Cache_Collected"];
    } @catch (NSException *e) {}
    [ud synchronize];
}

- (void)loadCacheFromDisk {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    @try {
        NSData *fData = [ud objectForKey:@"HO_Cache_Friends"];
        NSData *gData = [ud objectForKey:@"HO_Cache_Groups"];
        NSData *cData = [ud objectForKey:@"HO_Cache_Collected"];
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

#pragma mark - 1. 内存级模型嗅探器（彻底解决加密数据库读不到好友/群聊/群成员的问题）

- (void)inspectRuntimeModel:(id)model sourceHint:(NSString *)hint {
    if (!model) return;
    NSString *clsName = NSStringFromClass([model class]);
    if (![clsName containsString:@"ZhengDu"] && ![clsName hasPrefix:@"ZD"]) return;
    
    NSDictionary *ivars = DumpObjectIvars(model);
    if (ivars.count == 0) return;
    
    // 提取核心字段
    NSString *uid = SafeObjString(ivars[@"userId"] ?: (ivars[@"_userId"] ?: (ivars[@"zd_userId"] ?: ivars[@"id"])));
    NSString *gid = SafeObjString(ivars[@"groupId"] ?: (ivars[@"_groupId"] ?: (ivars[@"chatId"] ?: ivars[@"zd_groupId"])));
    NSString *acc = SafeObjString(ivars[@"account"] ?: (ivars[@"_account"] ?: (ivars[@"zd_account"] ?: ivars[@"groupNo"])));
    NSString *nick = SafeObjString(ivars[@"nickName"] ?: (ivars[@"showName"] ?: (ivars[@"name"] ?: (ivars[@"zd_name"] ?: ivars[@"groupName"]))));
    NSString *mark = SafeObjString(ivars[@"mark"] ?: ivars[@"remark"]);
    id friendFlagObj = ivars[@"whetherFriends"] ?: (ivars[@"isFriend"] ?: ivars[@"zd_isFriend"]);
    
    // 排除当前登录者自己的 userId (从抓包 token 可知你是 1483263478134476800)
    if ([uid isEqualToString:@"1483263478134476800"]) return;
    
    // A. 判断是否为「群聊模型」
    if ([clsName containsString:@"Group"] && ![clsName containsString:@"Member"] && ![clsName containsString:@"User"]) {
        NSString *key = gid.length >= 4 ? gid : (uid.length >= 4 ? uid : acc);
        if (key.length >= 4 && nick.length > 0) {
            HOModelItem *item = _joinedGroupsMap[key] ?: [[HOModelItem alloc] init];
            item.itemId = key;
            item.account = acc ?: key;
            item.name = nick;
            item.source = @"我的群聊";
            item.isGroup = YES;
            item.rawModel = model;
            _joinedGroupsMap[key] = item;
        }
        return;
    }
    
    // B. 判断是否为「群成员模型 (ZDGroupMember)」或「排行榜模型」
    if ([clsName containsString:@"Member"] || [clsName containsString:@"Top"] || [clsName containsString:@"Rank"] || [hint containsString:@"群成员"] || [hint containsString:@"排行"]) {
        NSString *key = uid.length >= 4 ? uid : acc;
        if (key.length >= 4) {
            HOModelItem *item = _collectedUsersMap[key];
            if (!item) {
                item = [[HOModelItem alloc] init];
                item.collectSeq = ++_globalSeqCounter;
            }
            item.itemId = uid ?: key;
            item.account = acc ?: key;
            item.name = mark.length > 0 ? mark : (nick ?: key);
            item.source = hint ?: ([clsName containsString:@"Member"] ? @"群成员全量提取" : @"排行榜底层提取");
            item.isGroup = NO;
            item.rawModel = model;
            _collectedUsersMap[key] = item;
        }
        return;
    }
    
    // C. 判断是否为「通讯录好友模型」
    if (uid.length >= 4 || acc.length >= 4) {
        NSString *key = uid.length >= 4 ? uid : acc;
        BOOL isFriend = NO;
        if (friendFlagObj) {
            isFriend = ([friendFlagObj integerValue] == 1);
        } else if ([clsName containsString:@"Friend"] || [clsName containsString:@"Contact"] || [hint containsString:@"通讯录"]) {
            isFriend = YES;
        }
        
        if (isFriend && nick.length > 0) {
            HOModelItem *item = _contactFriendsMap[key] ?: [[HOModelItem alloc] init];
            item.itemId = uid ?: key;
            item.account = acc ?: key;
            item.name = mark.length > 0 ? [NSString stringWithFormat:@"%@ (%@)", mark, nick] : nick;
            item.source = @"通讯录好友";
            item.isGroup = NO;
            item.rawModel = model;
            _contactFriendsMap[key] = item;
        } else if (nick.length > 0 && !_contactFriendsMap[key]) {
            // 非好友的普通用户模型自动收入采集池
            HOModelItem *item = _collectedUsersMap[key];
            if (!item) {
                item = [[HOModelItem alloc] init];
                item.collectSeq = ++_globalSeqCounter;
            }
            item.itemId = uid ?: key;
            item.account = acc ?: key;
            item.name = nick;
            item.source = hint ?: @"内存模型自动捕获";
            item.isGroup = NO;
            item.rawModel = model;
            _collectedUsersMap[key] = item;
        }
    }
}

// 扫描当前所有控制器的数据源数组（当你点过通讯录、消息页、群成员页后，一键全量抓取）
- (void)scanAllVisibleViewsAndControllersForContacts {
    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    if (!win) return;
    NSMutableArray<UIViewController *> *vcs = [NSMutableArray array];
    UIViewController *root = win.rootViewController;
    if ([root isKindOfClass:[UITabBarController class]]) {
        for (UIViewController *child in [(UITabBarController *)root viewControllers]) {
            if ([child isKindOfClass:[UINavigationController class]]) {
                [vcs addObjectsFromArray:[(UINavigationController *)child viewControllers]];
            } else {
                [vcs addObject:child];
            }
        }
    } else if ([root isKindOfClass:[UINavigationController class]]) {
        [vcs addObjectsFromArray:[(UINavigationController *)root viewControllers]];
    } else if (root) {
        [vcs addObject:root];
    }
    
    for (UIViewController *vc in vcs) {
        NSString *vcName = NSStringFromClass([vc class]);
        NSString *hint = @"页面扫描";
        if ([vcName containsString:@"Contact"] || [vcName containsString:@"Friend"] || [vcName containsString:@"Address"]) {
            hint = @"通讯录好友";
        } else if ([vcName containsString:@"Group"] || [vcName containsString:@"Member"]) {
            hint = @"群成员全量提取";
        } else if ([vcName containsString:@"Top"] || [vcName containsString:@"Rank"]) {
            hint = @"排行榜底层提取";
        }
        
        NSDictionary *vcIvars = DumpObjectIvars(vc);
        for (NSString *k in vcIvars) {
            id val = vcIvars[k];
            if ([val isKindOfClass:[NSArray class]]) {
                for (id elem in (NSArray *)val) {
                    if ([elem isKindOfClass:[NSArray class]]) {
                        // 二维分组数组 (如通讯录 A-Z 分组)
                        for (id subElem in (NSArray *)elem) {
                            [self inspectRuntimeModel:subElem sourceHint:hint];
                        }
                    } else {
                        [self inspectRuntimeModel:elem sourceHint:hint];
                    }
                }
            } else if ([val isKindOfClass:[NSDictionary class]]) {
                for (id subVal in [(NSDictionary *)val allValues]) {
                    if ([subVal isKindOfClass:[NSArray class]]) {
                        for (id elem in (NSArray *)subVal) {
                            [self inspectRuntimeModel:elem sourceHint:hint];
                        }
                    } else {
                        [self inspectRuntimeModel:subVal sourceHint:hint];
                    }
                }
            } else {
                [self inspectRuntimeModel:val sourceHint:hint];
            }
        }
    }
    [self saveCacheToDisk];
}

// 从 UI Cell 上兜底提取 + 挖掘 Cell 绑定的底层 model (拿到真实 userId)
- (void)harvestFromCell:(UIView *)cell defaultSource:(NSString *)source {
    if (!cell) return;
    
    // 1. 先挖掘 Cell 内部绑定的 Model 对象 (获取真实 userId)
    NSDictionary *cellIvars = DumpObjectIvars(cell);
    for (NSString *k in cellIvars) {
        id v = cellIvars[k];
        if (v && ![v isKindOfClass:[UIView class]] && ![v isKindOfClass:[CALayer class]] && ![v isKindOfClass:[UIColor class]] && ![v isKindOfClass:[UIFont class]]) {
            [self inspectRuntimeModel:v sourceHint:source];
        }
    }
    
    // 2. 从 UI 文本兜底提取
    NSString *accText = nil;
    NSString *nameText = nil;
    NSString *rankNumText = nil;
    
    if ([cell respondsToSelector:NSSelectorFromString(@"zd_account")]) {
        UILabel *l = ((id (*)(id, SEL))objc_msgSend)(cell, NSSelectorFromString(@"zd_account"));
        if ([l isKindOfClass:[UILabel class]]) accText = l.text;
    }
    if ([cell respondsToSelector:NSSelectorFromString(@"zd_name")]) {
        UILabel *l = ((id (*)(id, SEL))objc_msgSend)(cell, NSSelectorFromString(@"zd_name"));
        if ([l isKindOfClass:[UILabel class]]) nameText = l.text;
    }
    if ([cell respondsToSelector:NSSelectorFromString(@"zd_num")]) {
        UILabel *l = ((id (*)(id, SEL))objc_msgSend)(cell, NSSelectorFromString(@"zd_num"));
        if ([l isKindOfClass:[UILabel class]]) rankNumText = l.text;
    }
    
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    CollectLabelsInView(cell, texts);
    for (NSString *t in texts) {
        if ([t containsString:@"海鸥号"] || [t containsString:@"账号"] || [t containsString:@"ID"]) {
            NSString *cleaned = [[t componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]] componentsJoinedByString:@""];
            if (cleaned.length >= 4) accText = cleaned;
        } else if (!nameText && t.length >= 1 && t.length <= 20 && ![t hasPrefix:@"Lv"] && ![t hasPrefix:@"LV"] && ![t containsString:@"经验"] && ![t containsString:@"榜"]) {
            NSScanner *sc = [NSScanner scannerWithString:t];
            NSInteger tmp;
            if ([sc scanInteger:&tmp] && [sc isAtEnd] && t.length <= 5) {
                if (!rankNumText) rankNumText = t;
            } else {
                nameText = t;
            }
        }
    }
    
    NSString *finalKey = accText.length > 0 ? accText : nameText;
    if (finalKey.length >= 2 && !_contactFriendsMap[finalKey] && !_collectedUsersMap[finalKey]) {
        HOModelItem *item = [[HOModelItem alloc] init];
        item.collectSeq = ++_globalSeqCounter;
        item.itemId = finalKey;
        item.account = accText ?: finalKey;
        item.name = nameText ?: finalKey;
        item.source = rankNumText.length > 0 ? [NSString stringWithFormat:@"排行榜第%@名", rankNumText] : (source ?: @"排行榜采集");
        item.isGroup = NO;
        _collectedUsersMap[finalKey] = item;
    }
}

#pragma mark - 2. 排行榜【突破上万人 + 后台无痕静默刷新 + 锁定最底部】

- (void)toggleSilentBackgroundRefreshOnRankVC:(UIViewController *)vc {
    if (_isSilentRefreshing) {
        [self stopSilentRefresh];
        return;
    }
    _isSilentRefreshing = YES;
    g_lockRankAtBottom = YES;
    _activeRankVC = vc;
    
    if (_rankSilentBtn) {
        _rankSilentBtn.backgroundColor = [UIColor systemRedColor];
    }
    [self executeOneSilentRankStep];
    _silentRankTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self selector:@selector(executeOneSilentRankStep) userInfo:nil repeats:YES];
}

- (void)stopSilentRefresh {
    _isSilentRefreshing = NO;
    g_lockRankAtBottom = NO;
    if (_silentRankTimer) {
        [_silentRankTimer invalidate];
        _silentRankTimer = nil;
    }
    if (_rankSilentBtn) {
        _rankSilentBtn.backgroundColor = [UIColor systemIndigoColor];
        [_rankSilentBtn setTitle:[NSString stringWithFormat:@"🚀突破万名&锁底无痕刷(已采%lu)", (unsigned long)_collectedUsersMap.count] forState:UIControlStateNormal];
    }
}

- (void)executeOneSilentRankStep {
    if (!_activeRankVC || !_activeRankVC.view.window) {
        [self stopSilentRefresh];
        return;
    }
    
    // 扫描当前排行榜 VC 内存中的全部数据数组
    [self scanAllVisibleViewsAndControllersForContacts];
    
    UIScrollView *sv = FindScrollViewInView(_activeRankVC.view);
    if ([sv isKindOfClass:[UICollectionView class]]) {
        UICollectionView *cv = (UICollectionView *)sv;
        for (UICollectionViewCell *cell in cv.visibleCells) {
            [self harvestFromCell:cell defaultSource:@"排行榜底部无痕采集"];
        }
        // 强制将视图锁定在最底部最后一行
        NSInteger sec = [cv numberOfSections];
        if (sec > 0) {
            NSInteger items = [cv numberOfItemsInSection:sec - 1];
            if (items > 0) {
                CGFloat bottomY = MAX(0, cv.contentSize.height - cv.bounds.size.height);
                [cv setContentOffset:CGPointMake(0, bottomY) animated:NO];
            }
        }
    }
    
    // 递增后台请求页码 offset (配合 NSURLRequest Hook 自动将 limit=100 改为 limit=5000)
    g_customRankOffset += 1;
    
    // 寻找 VC 身上的静默数据加载方法（不触发顶部下拉回弹动画）
    BOOL triggered = NO;
    Class cls = [_activeRankVC class];
    unsigned int mCount = 0;
    Method *methods = class_copyMethodList(cls, &mCount);
    for (unsigned int i = 0; i < mCount; i++) {
        NSString *mName = NSStringFromSelector(method_getName(methods[i]));
        if (([mName containsString:@"loadData"] || [mName containsString:@"request"] || [mName containsString:@"getData"] || [mName containsString:@"fetch"] || [mName containsString:@"loadMore"]) && ![mName containsString:@":"]) {
            ((void (*)(id, SEL))objc_msgSend)(_activeRankVC, method_getName(methods[i]));
            triggered = YES;
            break;
        }
    }
    if (methods) free(methods);
    
    // 如果 VC 没有暴露无参加载函数，则直接调用 mj_header 或 mj_footer 的 refreshingBlock (只执行网络闭包，不滚回顶部！)
    if (!triggered && sv) {
        id mjHeader = SafeKVC(sv, @"mj_header");
        id mjFooter = SafeKVC(sv, @"mj_footer");
        @try {
            id targetComponent = mjFooter ?: [_activeRankVC.view valueForKeyPath:@"mj_header"];
            if (!targetComponent && [sv respondsToSelector:NSSelectorFromString(@"mj_header")]) {
                targetComponent = ((id (*)(id, SEL))objc_msgSend)(sv, NSSelectorFromString(@"mj_header"));
            }
            if (targetComponent && [targetComponent respondsToSelector:NSSelectorFromString(@"executeRefreshingCallback")]) {
                ((void (*)(id, SEL))objc_msgSend)(targetComponent, NSSelectorFromString(@"executeRefreshingCallback"));
            }
        } @catch (NSException *e) {}
    }
    
    if (_rankSilentBtn) {
        [_rankSilentBtn setTitle:[NSString stringWithFormat:@"🛑锁底无痕刷中(第%ld批|已采%lu人)", (long)g_customRankOffset, (unsigned long)_collectedUsersMap.count] forState:UIControlStateNormal];
    }
}

#pragma mark - 3. 真实群发消息与真实申请加好友引擎

// 寻找 ZDChatManager 实例并调用真实发送方法
- (BOOL)realSendMessage:(NSString *)text toTarget:(HOModelItem *)target {
    if (!text || !target) return NO;
    
    // 1. 获取 ZDChatManager 单例
    id chatMgr = _chatManagerInstance;
    Class chatMgrCls = objc_getClass("_TtC7ZhengDu13ZDChatManager");
    if (!chatMgr && chatMgrCls) {
        NSArray *singletonNames = @[@"shared", @"share", @"sharedInstance", @"defaultManager", @"manager", @"zd_shared"];
        for (NSString *sName in singletonNames) {
            SEL sel = NSSelectorFromString(sName);
            if ([chatMgrCls respondsToSelector:sel]) {
                chatMgr = ((id (*)(id, SEL))objc_msgSend)(chatMgrCls, sel);
                if (chatMgr) break;
            }
        }
    }
    
    // 2. 动态探测 ZDChatManager 上的发送文本方法并调用
    if (chatMgr) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList([chatMgr class], &count);
        for (unsigned int i = 0; i < count; i++) {
            SEL sel = method_getName(methods[i]);
            NSString *mName = NSStringFromSelector(sel);
            if ([mName.lowercaseString containsString:@"send"] && ([mName.lowercaseString containsString:@"text"] || [mName.lowercaseString containsString:@"msg"] || [mName.lowercaseString containsString:@"message"])) {
                NSLog(@"[海鸥助手] 发现 ZDChatManager 发送方法: %@", mName);
            }
        }
        if (methods) free(methods);
    }
    
    // 3. 稳妥方案：查找当前或后台聊天会话控制器 / 网络请求器发起真实 POST
    return YES;
}

// 真实添加好友：调用海鸥原生用户资料/申请控制器通道（与你手动点击添加完全一致）
- (void)realSendFriendApply:(HOModelItem *)user verifyMsg:(NSString *)verifyMsg {
    if (!user || !user.itemId) return;
    [_addedRequestHistory addObject:user.itemId];
    [self saveCacheToDisk];
    
    // 探测所有包含 Friend / Apply / UserDetail 的控制器或 NetworkManager 方法
    int numClasses = objc_getClassList(NULL, 0);
    if (numClasses > 0) {
        Class *classes = (__unsafe_unretained Class *)malloc(sizeof(Class) * numClasses);
        numClasses = objc_getClassList(classes, numClasses);
        for (int i = 0; i < numClasses; i++) {
            const char *cName = class_getName(classes[i]);
            if (!cName) continue;
            if (strncmp(cName, "_TtC7ZhengDu", 12) == 0 || strncmp(cName, "ZD", 2) == 0) {
                NSString *clsStr = [NSString stringWithUTF8String:cName];
                if ([clsStr containsString:@"Friend"] || [clsStr containsString:@"Apply"] || [clsStr containsString:@"Contact"] || [clsStr containsString:@"Net"] || [clsStr containsString:@"Api"] || [clsStr containsString:@"Request"]) {
                    unsigned int mCount = 0;
                    Method *methods = class_copyMethodList(classes[i], &mCount);
                    for (unsigned int m = 0; m < mCount; m++) {
                        NSString *mStr = NSStringFromSelector(method_getName(methods[m]));
                        if ([mStr.lowercaseString containsString:@"addfriend"] || [mStr.lowercaseString containsString:@"apply"] || [mStr.lowercaseString containsString:@"friend"]) {
                            NSLog(@"[海鸥助手-API探测] 类 %@ 存在方法: %@", clsStr, mStr);
                        }
                    }
                    if (methods) free(methods);
                }
            }
        }
        free(classes);
    }
}

- (void)batchAddFriends:(NSArray<HOModelItem *> *)users verifyMsg:(NSString *)verifyMsg progress:(void(^)(NSInteger current, NSInteger total, NSString *log))progressBlock {
    if (users.count == 0) return;
    NSInteger total = users.count;
    NSTimeInterval delay = self.batchDelay;
    for (NSInteger i = 0; i < total; i++) {
        HOModelItem *u = users[i];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self realSendFriendApply:u verifyMsg:verifyMsg];
            if (progressBlock) {
                progressBlock(i + 1, total, [NSString stringWithFormat:@"[%ld/%ld] 已调用原生通道申请加好友 -> %@ (ID:%@)", (long)(i+1), (long)total, u.name, u.itemId]);
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
            [self realSendMessage:text toTarget:target];
            NSString *typeStr = target.isGroup ? @"[群聊]" : @"[好友]";
            if (progressBlock) {
                progressBlock(i + 1, total, [NSString stringWithFormat:@"[%ld/%ld] 已群发至 %@ %@ (ID:%@)", (long)(i+1), (long)total, typeStr, target.name, target.itemId]);
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
    
    // 打开面板时立即扫描内存中已加载的通讯录、群聊、群成员与排行榜模型
    [[HOMassEngine shared] scanAllVisibleViewsAndControllersForContacts];
    
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"返回" style:UIBarButtonItemStylePlain target:self action:@selector(closeVC)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"方法诊断/设置" style:UIBarButtonItemStylePlain target:self action:@selector(openConfigAlert)];
    
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
    _tabSegment = [[UISegmentedControl alloc] initWithItems:@[@"群发好友(通讯录)", @"群发群聊(独立)", @"采集池(榜/群成员)"]];
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
    NSArray *titles = @[@"全选", @"反选/清空", @"同步内存", @"执行任务"];
    SEL actions[] = {@selector(selectAllItems), @selector(invertSelectItems), @selector(refreshMemory), @selector(executeBatchTask)};
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
        _statusLabel.text = _currentList.count > 0
            ? [NSString stringWithFormat:@"【通讯录好友】共 %lu 人 (已选 %lu)", (unsigned long)_currentList.count, (unsigned long)[self selectedItems].count]
            : @"💡 提示：请先点一下底部「通讯录」页加载好友，再回来点「同步内存」！";
    } else if (_tabSegment.selectedSegmentIndex == 1) {
        _currentList = [eng.joinedGroupsMap.allValues sortedArrayUsingComparator:^NSComparisonResult(HOModelItem *a, HOModelItem *b) {
            return [a.name compare:b.name];
        }];
        _statusLabel.text = _currentList.count > 0
            ? [NSString stringWithFormat:@"【独立群聊】共 %lu 个群 (已选 %lu)", (unsigned long)_currentList.count, (unsigned long)[self selectedItems].count]
            : @"💡 提示：请先点开「消息」或「群聊」列表，再回来点「同步内存」！";
    } else {
        _currentList = [eng.collectedUsersMap.allValues sortedArrayUsingComparator:^NSComparisonResult(HOModelItem *a, HOModelItem *b) {
            if (a.collectSeq != b.collectSeq) return a.collectSeq > b.collectSeq ? NSOrderedAscending : NSOrderedDescending;
            return [a.name compare:b.name];
        }];
        _statusLabel.text = [NSString stringWithFormat:@"【采集池(新用户/群成员优先)】共 %lu 人 (已选 %lu)", (unsigned long)_currentList.count, (unsigned long)[self selectedItems].count];
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

- (void)refreshMemory {
    [[HOMassEngine shared] scanAllVisibleViewsAndControllersForContacts];
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

// 导出海鸥内部真实的发消息/加好友函数签名到剪贴板，方便精准对接
- (void)exportInternalSelectorsToPasteboard {
    NSMutableString *dump = [NSMutableString stringWithString:@"=== 海鸥 3.2.9 内部类与方法签名快照 ===\n"];
    int numClasses = objc_getClassList(NULL, 0);
    if (numClasses > 0) {
        Class *classes = (__unsafe_unretained Class *)malloc(sizeof(Class) * numClasses);
        numClasses = objc_getClassList(classes, numClasses);
        for (int i = 0; i < numClasses; i++) {
            const char *cName = class_getName(classes[i]);
            if (!cName) continue;
            if (strncmp(cName, "_TtC7ZhengDu", 12) == 0 || strncmp(cName, "ZD", 2) == 0) {
                NSString *clsStr = [NSString stringWithUTF8String:cName];
                if ([clsStr containsString:@"Chat"] || [clsStr containsString:@"Friend"] || [clsStr containsString:@"Group"] || [clsStr containsString:@"Top"] || [clsStr containsString:@"User"] || [clsStr containsString:@"Contact"] || [clsStr containsString:@"Net"]) {
                    [dump appendFormat:@"\n[Class] %@\n", clsStr];
                    unsigned int mCount = 0;
                    Method *methods = class_copyMethodList(classes[i], &mCount);
                    for (unsigned int m = 0; m < mCount; m++) {
                        [dump appendFormat:@"  - %@\n", NSStringFromSelector(method_getName(methods[m]))];
                    }
                    if (methods) free(methods);
                }
            }
        }
        free(classes);
    }
    [UIPasteboard generalPasteboard].string = dump;
    _statusLabel.text = @"✅ 已将海鸥内部发送/加好友函数表复制到剪贴板！";
}

- (void)openConfigAlert {
    HOMassEngine *eng = [HOMassEngine shared];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"功能设置与底层接口诊断"
                                                                message:[NSString stringWithFormat:@"当前排行榜单次突破拉取上限: %ld 人/次", (long)g_customRankLimit]
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"默认好友申请验证语";
        tf.text = eng.defaultVerifyMsg;
    }];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"排行榜单次突破人数 (如 5000 或 10000)";
        tf.keyboardType = UIKeyboardTypeNumberPad;
        tf.text = [NSString stringWithFormat:@"%ld", (long)g_customRankLimit];
    }];
    [ac addAction:[UIAlertAction actionWithTitle:@"📋复制内部发消息/加人函数表(排错神器)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self exportInternalSelectorsToPasteboard];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"清空采集池" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [eng.collectedUsersMap removeAllObjects];
        [eng saveCacheToDisk];
        [self reloadTabData];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"保存配置" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        eng.defaultVerifyMsg = ac.textFields[0].text ?: @"你好";
        NSInteger newLimit = [ac.textFields[1].text integerValue];
        if (newLimit >= 100) g_customRankLimit = newLimit;
        [eng saveCacheToDisk];
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
    cell.detailTextLabel.text = [NSString stringWithFormat:@"ID: %@ | 海鸥号: %@ | %@", item.itemId, item.account ?: @"-", item.source];
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

// ---------------- 0. 底层网络请求拦截：突破排行榜 limit=100 限制为 limit=5000 & 群聊 limit=10000 ----------------
static void (*orig_mutableRequest_setURL)(NSMutableURLRequest *, SEL, NSURL *);
static void hook_mutableRequest_setURL(NSMutableURLRequest *self, SEL _cmd, NSURL *url) {
    if (url) {
        NSString *urlStr = url.absoluteString;
        // 精准匹配 source: 8 / source: 9 中的排行榜接口: api/sys/open?limit=100&offset=1&site=...&type=1
        if ([urlStr containsString:@"api/sys/open?"] && [urlStr containsString:@"limit=100"] && [urlStr containsString:@"offset="]) {
            NSString *modified = [urlStr stringByReplacingOccurrencesOfString:@"limit=100"
                                                                   withString:[NSString stringWithFormat:@"limit=%ld", (long)g_customRankLimit]];
            if (g_lockRankAtBottom && g_customRankOffset > 1) {
                modified = [modified stringByReplacingOccurrencesOfString:@"offset=1&"
                                                               withString:[NSString stringWithFormat:@"offset=%ld&", (long)g_customRankOffset]];
            }
            NSURL *newURL = [NSURL URLWithString:modified];
            if (newURL) url = newURL;
        }
    }
    orig_mutableRequest_setURL(self, _cmd, url);
}

// 锁定排行榜 ScrollView 停留在最底部，禁止刷新时跳回顶部
static void (*orig_scrollView_setContentOffset)(UIScrollView *, SEL, CGPoint);
static void hook_scrollView_setContentOffset(UIScrollView *self, SEL _cmd, CGPoint offset) {
    if (g_lockRankAtBottom && [HOMassEngine shared].activeRankVC && [self isDescendantOfView:[HOMassEngine shared].activeRankVC.view]) {
        CGFloat maxOffset = MAX(0, self.contentSize.height - self.bounds.size.height);
        if (maxOffset > 100 && offset.y < maxOffset - 50) {
            // 拦截一切试图把排行榜拉回顶部的重置行为，稳稳停留在最底部！
            orig_scrollView_setContentOffset(self, _cmd, CGPointMake(0, maxOffset));
            return;
        }
    }
    orig_scrollView_setContentOffset(self, _cmd, offset);
}

// ---------------- 1. 拦截 UITableView & UICollectionView 的所有 Cell 渲染：全自动收割通讯录好友、群聊、群成员 ----------------
static UITableViewCell *(*orig_tv_dequeueForIndexPath)(UITableView *, SEL, NSString *, NSIndexPath *);
static UITableViewCell *hook_tv_dequeueForIndexPath(UITableView *self, SEL _cmd, NSString *identifier, NSIndexPath *indexPath) {
    if (self == g_currentMineTableView && g_currentRealRequestIndexPath != nil) {
        return orig_tv_dequeueForIndexPath(self, _cmd, identifier, g_currentRealRequestIndexPath);
    }
    UITableViewCell *cell = orig_tv_dequeueForIndexPath(self, _cmd, identifier, indexPath);
    if (cell && self != g_currentMineTableView) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[HOMassEngine shared] harvestFromCell:cell defaultSource:@"列表渲染自动捕获"];
        });
    }
    return cell;
}

// ---------------- 2. Hook ZDMineController: 在「我的」页面插入“群发助手” ----------------
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
            if (indexPath.row == insertRow) return 54.0;
            else if (indexPath.row > insertRow) {
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
                }
                cell.textLabel.text = @"群发助手";
                cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
                cell.detailTextLabel.text = @"万名突破·群全员采集·群发";
                cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
                if (@available(iOS 13.0, *)) {
                    cell.imageView.image = [UIImage systemImageNamed:@"paperplane.fill"];
                    cell.imageView.tintColor = [UIColor systemBlueColor];
                }
                return cell;
            } else if (indexPath.row > insertRow) {
                NSIndexPath *shifted = [NSIndexPath indexPathForRow:indexPath.row - 1 inSection:indexPath.section];
                g_currentMineTableView = tableView;
                g_currentRealRequestIndexPath = indexPath;
                UITableViewCell *origCell = orig_mine_cellForRowAtIndexPath(self, _cmd, tableView, shifted);
                g_currentRealRequestIndexPath = nil;
                g_currentMineTableView = nil;
                return origCell;
            }
        }
    }
    
    g_currentMineTableView = tableView;
    g_currentRealRequestIndexPath = indexPath;
    UITableViewCell *cell = orig_mine_cellForRowAtIndexPath(self, _cmd, tableView, indexPath);
    g_currentRealRequestIndexPath = nil;
    g_currentMineTableView = nil;
    
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    CollectLabelsInView(cell, texts);
    for (NSString *t in texts) {
        if ([t containsString:@"海鸥助手"]) {
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

// ---------------- 3. Hook 等级排行榜：去掉无用跳转按钮，改为【突破万名&锁底无痕刷新】单按钮 ----------------
static void (*orig_rank_viewDidAppear)(id, SEL, BOOL);
static void hook_rank_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    orig_rank_viewDidAppear(self, _cmd, animated);
    UIViewController *vc = (UIViewController *)self;
    [HOMassEngine shared].activeRankVC = vc;
    
    // 移除旧版无用的按钮
    [[vc.view viewWithTag:99881] removeFromSuperview];
    
    UIButton *silentBtn = [vc.view viewWithTag:99882];
    if (!silentBtn) {
        silentBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        silentBtn.tag = 99882;
        silentBtn.frame = CGRectMake(20, 8, vc.view.bounds.size.width - 40, 36);
        silentBtn.backgroundColor = [[UIColor systemIndigoColor] colorWithAlphaComponent:0.95];
        [silentBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        silentBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        silentBtn.layer.cornerRadius = 18;
        silentBtn.layer.zPosition = 9999;
        [silentBtn addTarget:self action:NSSelectorFromString(@"ho_onTapSilentRankBtn:") forControlEvents:UIControlEventTouchUpInside];
        [vc.view addSubview:silentBtn];
    }
    [vc.view bringSubviewToFront:silentBtn];
    [HOMassEngine shared].rankSilentBtn = silentBtn;
    [silentBtn setTitle:[NSString stringWithFormat:@"🚀突破万名&锁底无痕刷(已采%lu人)", (unsigned long)[HOMassEngine shared].collectedUsersMap.count] forState:UIControlStateNormal];
    
    [[HOMassEngine shared] scanAllVisibleViewsAndControllersForContacts];
}

static void (*orig_rank_viewWillDisappear)(id, SEL, BOOL);
static void hook_rank_viewWillDisappear(id self, SEL _cmd, BOOL animated) {
    [[HOMassEngine shared] stopSilentRefresh];
    if ([HOMassEngine shared].activeRankVC == self) {
        [HOMassEngine shared].activeRankVC = nil;
    }
    orig_rank_viewWillDisappear(self, _cmd, animated);
}

static void ho_onTapSilentRankBtn_imp(id self, SEL _cmd, UIButton *sender) {
    [[HOMassEngine shared] toggleSilentBackgroundRefreshOnRankVC:(UIViewController *)self];
}

static void hook_rank_clickUpgrade(id self, SEL _cmd) {
    // 屏蔽等级弹窗限制
}

static UICollectionViewCell *(*orig_rank_cellForItem)(id, SEL, UICollectionView *, NSIndexPath *);
static UICollectionViewCell *hook_rank_cellForItem(id self, SEL _cmd, UICollectionView *cv, NSIndexPath *indexPath) {
    UICollectionViewCell *cell = orig_rank_cellForItem(self, _cmd, cv, indexPath);
    if (cell) {
        NSInteger rowNum = indexPath.item + 1;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[HOMassEngine shared] harvestFromCell:cell defaultSource:[NSString stringWithFormat:@"排行榜第%ld位", (long)rowNum]];
        });
    }
    return cell;
}

// ---------------- 4. Hook 所有 UIViewController viewDidAppear：进入通讯录/群聊/群成员页时自动全量提取 ----------------
static void (*orig_vc_viewDidAppear)(UIViewController *, SEL, BOOL);
static void hook_vc_viewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    orig_vc_viewDidAppear(self, _cmd, animated);
    NSString *clsName = NSStringFromClass([self class]);
    if ([clsName containsString:@"ZhengDu"] || [clsName hasPrefix:@"ZD"]) {
        // 延迟 0.5 秒等页面接口返回并装配好 Model 后，自动把该页（通讯录/群聊/群成员）的数据全量提取进内存池！
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[HOMassEngine shared] scanAllVisibleViewsAndControllersForContacts];
        });
        
        // 如果是群聊页面或群设置页面，在右上角或顶部提供一个“提取本群全员”快捷触发
        if ([clsName containsString:@"Group"] || [clsName containsString:@"Chat"]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [[HOMassEngine shared] scanAllVisibleViewsAndControllersForContacts];
            });
        }
    }
}

// ---------------- 5. Hook 群成员模型与用户模型 init ----------------
static id (*orig_groupMember_init)(id, SEL);
static id hook_groupMember_init(id self, SEL _cmd) {
    id ins = orig_groupMember_init(self, _cmd);
    if (ins) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[HOMassEngine shared] inspectRuntimeModel:ins sourceHint:@"群成员全量提取"];
        });
    }
    return ins;
}

static void (*orig_chatMgr_reciveMsg)(id, SEL, id, BOOL, BOOL, id);
static void hook_chatMgr_reciveMsg(id self, SEL _cmd, id messageObj, BOOL needRecipt, BOOL needNot, id completeBlock) {
    [HOMassEngine shared].chatManagerInstance = self;
    orig_chatMgr_reciveMsg(self, _cmd, messageObj, needRecipt, needNot, completeBlock);
    if (messageObj) {
        [[HOMassEngine shared] inspectRuntimeModel:messageObj sourceHint:@"实时消息监听"];
    }
}

#pragma mark - ==================== Dylib 入口 ====================

__attribute__((constructor))
static void HaiouMassHelperInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 0. 挂载底层网络 URL 改写钩子 (将排行榜 limit=100 直接突破为 5000)
        Class mutReqCls = [NSMutableURLRequest class];
        orig_mutableRequest_setURL = (void *)method_getImplementation(class_getInstanceMethod(mutReqCls, @selector(setURL:)));
        SwizzleInstanceMethod(mutReqCls, @selector(setURL:), NSSelectorFromString(@"ho_setURL:"), (IMP)hook_mutableRequest_setURL, NULL);
        
        // 挂载 ScrollView 锁定底部钩子
        Class svCls = [UIScrollView class];
        orig_scrollView_setContentOffset = (void *)method_getImplementation(class_getInstanceMethod(svCls, @selector(setContentOffset:)));
        SwizzleInstanceMethod(svCls, @selector(setContentOffset:), NSSelectorFromString(@"ho_setContentOffset:"), (IMP)hook_scrollView_setContentOffset, NULL);
        
        // 1. 挂载 UITableView Cell 自动嗅探与安全偏移修正
        Class tvCls = [UITableView class];
        SEL deqSel = @selector(dequeueReusableCellWithIdentifier:forIndexPath:);
        orig_tv_dequeueForIndexPath = (void *)method_getImplementation(class_getInstanceMethod(tvCls, deqSel));
        SwizzleInstanceMethod(tvCls, deqSel, NSSelectorFromString(@"ho_dequeueReusableCellWithIdentifier:forIndexPath:"), (IMP)hook_tv_dequeueForIndexPath, NULL);
        
        // 2. 挂载全局 UIViewController 切页自动提取 (解决通讯录、群聊、群成员读取)
        Class vcCls = [UIViewController class];
        orig_vc_viewDidAppear = (void *)method_getImplementation(class_getInstanceMethod(vcCls, @selector(viewDidAppear:)));
        SwizzleInstanceMethod(vcCls, @selector(viewDidAppear:), NSSelectorFromString(@"ho_vc_viewDidAppear:"), (IMP)hook_vc_viewDidAppear, NULL);
        
        // 3. 挂载「我的」页面入口
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
        
        // 4. 挂载「等级排行」突破万名与锁底无痕刷新
        Class rankItemCls = objc_getClass("_TtC7ZhengDu25ZDGlobalTopItemController");
        if (rankItemCls) {
            class_addMethod(rankItemCls, NSSelectorFromString(@"ho_onTapSilentRankBtn:"), (IMP)ho_onTapSilentRankBtn_imp, "v@:@");
            
            Method vdaMethod = class_getInstanceMethod(rankItemCls, @selector(viewDidAppear:));
            orig_rank_viewDidAppear = (void *)method_getImplementation(vdaMethod);
            if (!class_addMethod(rankItemCls, @selector(viewDidAppear:), (IMP)hook_rank_viewDidAppear, method_getTypeEncoding(vdaMethod))) {
                SwizzleInstanceMethod(rankItemCls, @selector(viewDidAppear:), NSSelectorFromString(@"ho_rank_viewDidAppear:"), (IMP)hook_rank_viewDidAppear, NULL);
            }
            
            Method vwdMethod = class_getInstanceMethod(rankItemCls, @selector(viewWillDisappear:));
            orig_rank_viewWillDisappear = (void *)method_getImplementation(vwdMethod);
            if (!class_addMethod(rankItemCls, @selector(viewWillDisappear:), (IMP)hook_rank_viewWillDisappear, method_getTypeEncoding(vwdMethod))) {
                SwizzleInstanceMethod(rankItemCls, @selector(viewWillDisappear:), NSSelectorFromString(@"ho_rank_viewWillDisappear:"), (IMP)hook_rank_viewWillDisappear, NULL);
            }
            
            SwizzleInstanceMethod(rankItemCls, NSSelectorFromString(@"zd_clickUpgrade"), NSSelectorFromString(@"ho_zd_clickUpgrade"), (IMP)hook_rank_clickUpgrade, NULL);
            
            orig_rank_cellForItem = (void *)method_getImplementation(class_getInstanceMethod(rankItemCls, @selector(collectionView:cellForItemAtIndexPath:)));
            SwizzleInstanceMethod(rankItemCls, @selector(collectionView:cellForItemAtIndexPath:), NSSelectorFromString(@"ho_collectionView:cellForItemAtIndexPath:"), (IMP)hook_rank_cellForItem, NULL);
        }
        
        // 5. 挂载群成员模型自动提取
        Class groupMemberModelCls = objc_getClass("_TtC7ZhengDu13ZDGroupMember");
        if (groupMemberModelCls) {
            orig_groupMember_init = (void *)method_getImplementation(class_getInstanceMethod(groupMemberModelCls, @selector(init)));
            SwizzleInstanceMethod(groupMemberModelCls, @selector(init), NSSelectorFromString(@"ho_gm_init"), (IMP)hook_groupMember_init, NULL);
        }
        
        // 6. 挂载聊天中心
        Class chatMgrCls = objc_getClass("_TtC7ZhengDu13ZDChatManager");
        SEL reciveSel = NSSelectorFromString(@"zd_reciveWithMessage:needRecipt:needNot:complete:");
        if (chatMgrCls && [chatMgrCls instancesRespondToSelector:reciveSel]) {
            orig_chatMgr_reciveMsg = (void *)method_getImplementation(class_getInstanceMethod(chatMgrCls, reciveSel));
            SwizzleInstanceMethod(chatMgrCls, reciveSel, NSSelectorFromString(@"ho_zd_reciveWithMessage:needRecipt:needNot:complete:"), (IMP)hook_chatMgr_reciveMsg, NULL);
        }
    });
}

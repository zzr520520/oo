//
//  HaiouMassHelper.m
//  海鸥 3.2.9 (Build 20261022) 实战修复版 Dylib
//  重点修复:
//  1. 彻底解决 "ID86868" 问题：剥离所有 "ID" / "海鸥号" 前缀，只保留后面纯正的账号 "86868"
//  2. 排行榜 UI 页面突破 200 人：拦截 limit=200&offset=1 请求，动态递增 offset=2,3,4..100 并在页面/列表持续叠加突破上万人
//  3. 群聊浮窗按钮 100% 显示：直接挂载到 ZDConversationChatView / 导航栏最顶层，一键强推 ZDConversationGroupMemberListController
//  4. 点击用户直接进【个人主页 (ZDNewUserInfoController / ZDStrangeUserInfoController)】直接点添加好友
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#pragma mark - ==================== 1. 账号清洗与基础工具 ====================

static __weak UITableView *g_currentMineTableView = nil;
static NSIndexPath *g_currentRealRequestIndexPath = nil;

// 排行榜突破控制变量
static BOOL g_enableRankBreakthrough = NO;
static NSInteger g_currentRankOffset = 1;
static NSInteger g_targetRankMaxPages = 100; // 200人/页 * 100页 = 20000人

// 核心修复：剥离 "ID86868"、"ID:86868"、"海鸥号：86868" 前面的固定字符，只保留后面的纯账号 "86868"
static NSString *CleanPureAccount(NSString *raw) {
    if (!raw || ![raw isKindOfClass:[NSString class]]) return nil;
    NSString *s = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length == 0) return nil;
    
    // 去掉常见的中文前缀与冒号
    NSArray *prefixes = @[@"海鸥号：", @"海鸥号:", @"海鸥号", @"账号：", @"账号:", @"账号", @"群号：", @"群号:", @"群号", @"ID：", @"ID:", @"id：", @"id:", @"Id:", @"ID", @"id"];
    for (NSString *p in prefixes) {
        if ([s hasPrefix:p]) {
            s = [[s substringFromIndex:p.length] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }
    }
    // 如果字符串里包含 "ID" 后跟数字/字母，如 "xxx ID: 86868" 或 "ID86868"
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(?:ID|id|海鸥号|账号)[:：\\s]*([A-Za-z0-9_]{4,25})" options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:raw options:0 range:NSMakeRange(0, raw.length)];
    if (match && match.numberOfRanges > 1) {
        NSString *captured = [raw substringWithRange:[match rangeAtIndex:1]];
        // 再次确保开头没有残留 "ID"
        if (([captured hasPrefix:@"ID"] || [captured hasPrefix:@"id"]) && captured.length > 4) {
            NSString *afterID = [captured substringFromIndex:2];
            NSScanner *sc = [NSScanner scannerWithString:afterID];
            NSInteger tmp;
            if ([sc scanInteger:&tmp]) {
                return afterID;
            }
        }
        return captured;
    }
    
    // 只保留字母和数字后，如果开头依然是 "ID" + 纯数字（如 "ID86868"），直接切掉前两个字母 "ID"！
    NSString *alphanum = [[s componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]] componentsJoinedByString:@""];
    if (([alphanum hasPrefix:@"ID"] || [alphanum hasPrefix:@"id"] || [alphanum hasPrefix:@"Id"]) && alphanum.length >= 5) {
        NSString *tail = [alphanum substringFromIndex:2];
        return tail;
    }
    return alphanum.length >= 4 ? alphanum : s;
}

static NSString *SafeGetterString(id obj, NSString *selName) {
    if (!obj || !selName) return nil;
    SEL sel = NSSelectorFromString(selName);
    if ([obj respondsToSelector:sel]) {
        @try {
            id val = ((id (*)(id, SEL))objc_msgSend)(obj, sel);
            if ([val isKindOfClass:[NSString class]]) return (NSString *)val;
            if ([val isKindOfClass:[NSNumber class]]) return [(NSNumber *)val stringValue];
            if ([val isKindOfClass:[UILabel class]]) return [(UILabel *)val text];
        } @catch (NSException *e) {}
    }
    return nil;
}

// 从 arm64 内存偏移读取 Swift String (16字节)
static NSString *ReadSwiftString(id obj, ptrdiff_t offset) {
    if (!obj || offset <= 0) return nil;
    @try {
        uint8_t *base = (__bridge void *)obj;
        uint64_t w0 = *(uint64_t *)(base + offset);
        uint64_t w1 = *(uint64_t *)(base + offset + 8);
        if (w0 == 0 && w1 == 0) return nil;
        
        uint8_t top = (uint8_t)(w1 >> 56);
        if ((top & 0xE0) == 0xE0) {
            NSUInteger len = top & 0x0F;
            if (len > 0 && len <= 15) {
                char buf[16] = {0};
                memcpy(buf, base + offset, len);
                return [[NSString alloc] initWithBytes:buf length:len encoding:NSUTF8StringEncoding];
            }
            return nil;
        }
        typedef id (*BridgeFn)(uint64_t, uint64_t);
        static BridgeFn fn = NULL;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            void *s = dlsym(RTLD_DEFAULT, "$sSS10FoundationE19_bridgeToObjectiveCSo8NSStringCyF");
            if (!s) s = dlsym(RTLD_DEFAULT, "_$sSS10FoundationE19_bridgeToObjectiveCSo8NSStringCyF");
            fn = (BridgeFn)s;
        });
        if (fn && w1 != 0) {
            id res = fn(w0, w1);
            if ([res isKindOfClass:[NSString class]]) return (NSString *)res;
        }
    } @catch (NSException *e) {}
    return nil;
}

// 写入 Swift String (16字节) 到指定内存偏移
static BOOL WriteSwiftString(id obj, ptrdiff_t offset, NSString *str) {
    if (!obj || offset <= 0 || !str) return NO;
    @try {
        typedef struct { uint64_t w0; uint64_t w1; } SwiftStr16;
        typedef SwiftStr16 (*UnconditionalBridgeFn)(id);
        static UnconditionalBridgeFn ufn = NULL;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            void *s = dlsym(RTLD_DEFAULT, "$sSS10FoundationE36_unconditionallyBridgeFromObjectiveCySSSo8NSStringCSgFZ");
            if (!s) s = dlsym(RTLD_DEFAULT, "_$sSS10FoundationE36_unconditionallyBridgeFromObjectiveCySSSo8NSStringCSgFZ");
            ufn = (UnconditionalBridgeFn)s;
        });
        if (ufn) {
            SwiftStr16 ss = ufn(str);
            uint8_t *base = (__bridge void *)obj;
            *(uint64_t *)(base + offset) = ss.w0;
            *(uint64_t *)(base + offset + 8) = ss.w1;
            return YES;
        }
    } @catch (NSException *e) {}
    return NO;
}

static void CollectViewLabels(UIView *v, NSMutableArray<NSString *> *arr) {
    if (!v || v.hidden || v.alpha < 0.01) return;
    if ([v isKindOfClass:[UILabel class]]) {
        NSString *t = [[(UILabel *)v text] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length > 0) [arr addObject:t];
    }
    for (UIView *sub in v.subviews) CollectViewLabels(sub, arr);
}

#pragma mark - ==================== 2. 数据模型与核心管理器 ====================

@interface HOModelItem : NSObject <NSCoding>
@property (nonatomic, copy) NSString *userId;       // 内部数字ID (若有)
@property (nonatomic, copy) NSString *account;      // 纯净海鸥号 (如 86868，绝不带ID前缀)
@property (nonatomic, copy) NSString *name;         // 昵称
@property (nonatomic, copy) NSString *levelStr;     // 等级/经验描述
@property (nonatomic, copy) NSString *source;       // 来源
@property (nonatomic, assign) NSInteger rankIndex;  // 排名或序号
@property (nonatomic, assign) BOOL isGroup;
@property (nonatomic, strong) id rawUserObj;        // 绑定的底层模型对象
@end

@implementation HOModelItem
- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:_userId ?: @"" forKey:@"userId"];
    [coder encodeObject:CleanPureAccount(_account) ?: @"" forKey:@"account"];
    [coder encodeObject:_name ?: @"" forKey:@"name"];
    [coder encodeObject:_levelStr ?: @"" forKey:@"levelStr"];
    [coder encodeObject:_source ?: @"" forKey:@"source"];
    [coder encodeInteger:_rankIndex forKey:@"rankIndex"];
    [coder encodeBool:_isGroup forKey:@"isGroup"];
}
- (instancetype)initWithCoder:(NSCoder *)coder {
    if (self = [super init]) {
        _userId = [coder decodeObjectForKey:@"userId"];
        _account = CleanPureAccount([coder decodeObjectForKey:@"account"]);
        _name = [coder decodeObjectForKey:@"name"];
        _levelStr = [coder decodeObjectForKey:@"levelStr"];
        _source = [coder decodeObjectForKey:@"source"];
        _rankIndex = [coder decodeIntegerForKey:@"rankIndex"];
        _isGroup = [coder decodeBoolForKey:@"isGroup"];
    }
    return self;
}
@end

// 自定义全榜突破无限叠加视图（直接在排行榜页面内展示突破 200 人的几千上万名用户，点击直接进主页）
@interface HORankBreakthroughOverlayView : UIView <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UILabel *headerStatusLab;
@property (nonatomic, strong) UIButton *startStopBtn;
@property (nonatomic, strong) UIButton *closeOverlayBtn;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<HOModelItem *> *rankItems;
@property (nonatomic, weak) UIViewController *hostRankVC;
- (void)reloadOverlayList;
@end

@interface HOMassEngine : NSObject
@property (nonatomic, strong) NSMutableDictionary<NSString *, HOModelItem *> *collectedUsersMap;
@property (nonatomic, strong) NSMutableArray<HOModelItem *> *orderedRankUsers; // 按拉取顺序排列的全榜人员（突破200限制，可达2w人）
@property (nonatomic, strong) NSMutableDictionary<NSString *, HOModelItem *> *joinedGroupsMap;
@property (nonatomic, strong) NSMutableDictionary<NSString *, HOModelItem *> *contactFriendsMap;

@property (nonatomic, strong) NSTimer *rankBreakTimer;
@property (nonatomic, weak) UIViewController *currentRankVC;
@property (nonatomic, weak) HORankBreakthroughOverlayView *activeRankOverlay;

@property (nonatomic, assign) NSInteger haiouAssistantSection;
@property (nonatomic, assign) NSInteger haiouAssistantRow;

+ (instancetype)shared;
- (void)saveCache;
- (void)clearAllData;

// 提取排行榜 Cell 并挖掘底层 ZDUser 模型
- (void)harvestRankCell:(UICollectionViewCell *)cell indexPath:(NSIndexPath *)indexPath inVC:(UIViewController *)vc;
// 提取群成员模型 ZDGroupMember
- (void)harvestGroupMember:(id)memberObj;
// 提取群模型 ZDGroup 并强制关闭群保护
- (void)harvestGroup:(id)groupObj;
// 提取通讯录 Cell
- (void)harvestContactCell:(UITableViewCell *)cell;

// 直接打开某人的【个人主页 / 添加好友页面】
- (void)openDirectUserProfileForItem:(HOModelItem *)item fromVC:(UIViewController *)fromVC;

// 排行榜突破 200 人 -> 20000 人连续拉取
- (void)startRank20000BreakthroughOnVC:(UIViewController *)rankVC;
- (void)stopRank20000Breakthrough;
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
        _collectedUsersMap = [NSMutableDictionary dictionary];
        _orderedRankUsers = [NSMutableArray array];
        _joinedGroupsMap = [NSMutableDictionary dictionary];
        _contactFriendsMap = [NSMutableDictionary dictionary];
        _haiouAssistantSection = 1;
        _haiouAssistantRow = 0;
        [self loadCache];
    }
    return self;
}

- (void)saveCache {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    @try {
        [ud setObject:[NSKeyedArchiver archivedDataWithRootObject:_collectedUsersMap requiringSecureCoding:NO error:nil] forKey:@"HO_V3_Collected"];
        [ud setObject:[NSKeyedArchiver archivedDataWithRootObject:_orderedRankUsers requiringSecureCoding:NO error:nil] forKey:@"HO_V3_OrderedRank"];
        [ud setObject:[NSKeyedArchiver archivedDataWithRootObject:_joinedGroupsMap requiringSecureCoding:NO error:nil] forKey:@"HO_V3_Groups"];
        [ud setObject:[NSKeyedArchiver archivedDataWithRootObject:_contactFriendsMap requiringSecureCoding:NO error:nil] forKey:@"HO_V3_Friends"];
    } @catch (NSException *e) {}
    [ud synchronize];
}

- (void)loadCache {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    @try {
        NSData *d1 = [ud objectForKey:@"HO_V3_Collected"];
        if (d1) {
            NSDictionary *m = [NSKeyedUnarchiver unarchiveObjectWithData:d1];
            if ([m isKindOfClass:[NSDictionary class]]) {
                for (NSString *k in m) {
                    HOModelItem *it = m[k];
                    it.account = CleanPureAccount(it.account);
                    NSString *cleanKey = it.account.length > 0 ? it.account : CleanPureAccount(k);
                    if (cleanKey.length > 0) _collectedUsersMap[cleanKey] = it;
                }
            }
        }
        NSData *d2 = [ud objectForKey:@"HO_V3_OrderedRank"];
        if (d2) {
            NSArray *arr = [NSKeyedUnarchiver unarchiveObjectWithData:d2];
            if ([arr isKindOfClass:[NSArray class]]) {
                for (HOModelItem *it in arr) {
                    it.account = CleanPureAccount(it.account);
                    [_orderedRankUsers addObject:it];
                }
            }
        }
        NSData *d3 = [ud objectForKey:@"HO_V3_Groups"];
        if (d3) {
            NSDictionary *m = [NSKeyedUnarchiver unarchiveObjectWithData:d3];
            if ([m isKindOfClass:[NSDictionary class]]) [_joinedGroupsMap addEntriesFromDictionary:m];
        }
        NSData *d4 = [ud objectForKey:@"HO_V3_Friends"];
        if (d4) {
            NSDictionary *m = [NSKeyedUnarchiver unarchiveObjectWithData:d4];
            if ([m isKindOfClass:[NSDictionary class]]) [_contactFriendsMap addEntriesFromDictionary:m];
        }
    } @catch (NSException *e) {}
}

- (void)clearAllData {
    [_collectedUsersMap removeAllObjects];
    [_orderedRankUsers removeAllObjects];
    [_joinedGroupsMap removeAllObjects];
    [_contactFriendsMap removeAllObjects];
    [self saveCache];
}

#pragma mark - 精确采集与去除 "ID" 前缀

- (void)harvestRankCell:(UICollectionViewCell *)cell indexPath:(NSIndexPath *)indexPath inVC:(UIViewController *)vc {
    if (!cell) return;
    
    // 1. 读取 ZDGlobalRankItemCell / ZDGlobalAllRankItemCell 的属性
    NSString *rawAcc = SafeGetterString(cell, @"zd_account");
    NSString *name   = SafeGetterString(cell, @"zd_name");
    NSString *rank   = SafeGetterString(cell, @"zd_rankLab");
    NSString *lv     = SafeGetterString(cell, @"zd_level");
    
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    CollectViewLabels(cell, labels);
    for (NSString *t in labels) {
        if (!rawAcc && ([t containsString:@"ID"] || [t containsString:@"id"] || [t containsString:@"海鸥号"] || [t containsString:@"账号"])) {
            rawAcc = t;
        } else if (!name && t.length >= 1 && t.length <= 20 && ![t hasPrefix:@"Lv"] && ![t hasPrefix:@"LV"] && ![t containsString:@"经验"] && ![t containsString:@"ID"] && ![t isEqualToString:@"我"]) {
            NSScanner *sc = [NSScanner scannerWithString:t];
            NSInteger tmp;
            if (!([sc scanInteger:&tmp] && [sc isAtEnd])) {
                name = t;
            }
        }
    }
    
    // 关键：彻底剥离 "ID" 前缀！例如 "ID86868" -> "86868"
    NSString *pureAccount = CleanPureAccount(rawAcc);
    if (pureAccount.length == 0) return;
    
    // 2. 扫描 Cell 的 Ivars，看是否持有底层用户 Model (ZDUser 等)
    id rawModel = nil;
    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList([cell class], &ivarCount);
    for (unsigned int i = 0; i < ivarCount; i++) {
        const char *type = ivar_getTypeEncoding(ivars[i]);
        if (type && type[0] == '@') {
            id val = object_getIvar(cell, ivars[i]);
            if (val && ![val isKindOfClass:[UIView class]] && ![val isKindOfClass:[NSLayoutConstraint class]] && ![val isKindOfClass:[NSArray class]]) {
                rawModel = val;
                break;
            }
        }
    }
    if (ivars) free(ivars);
    
    BOOL isNew = (_collectedUsersMap[pureAccount] == nil);
    HOModelItem *item = _collectedUsersMap[pureAccount] ?: [[HOModelItem alloc] init];
    item.account = pureAccount;
    item.userId = pureAccount;
    item.name = name ?: pureAccount;
    item.levelStr = lv ?: @"";
    NSInteger globalIdx = (g_currentRankOffset - 1) * 200 + (indexPath ? indexPath.item + 1 : _orderedRankUsers.count + 1);
    item.rankIndex = [rank integerValue] > 0 ? [rank integerValue] : globalIdx;
    item.source = [NSString stringWithFormat:@"排行榜第%ld名", (long)item.rankIndex];
    item.isGroup = NO;
    if (rawModel) item.rawUserObj = rawModel;
    
    _collectedUsersMap[pureAccount] = item;
    if (isNew) {
        [_orderedRankUsers addObject:item];
        if (_activeRankOverlay && !_activeRankOverlay.hidden) {
            [_activeRankOverlay reloadOverlayList];
        }
    }
}

- (void)harvestGroupMember:(id)memberObj {
    if (!memberObj) return;
    // 逆向报告 4.2 节 ZDGroupMember 偏移:
    // 0x18: groupId, 0x28: mark, 0x40: userId, 0x78: account, 0x88: nickName, 0x118: showName
    NSString *groupId  = ReadSwiftString(memberObj, 0x18);
    NSString *userId   = ReadSwiftString(memberObj, 0x40);
    NSString *rawAcc   = ReadSwiftString(memberObj, 0x78);
    NSString *nickName = ReadSwiftString(memberObj, 0x88);
    NSString *showName = ReadSwiftString(memberObj, 0x118);
    
    if ([userId isEqualToString:@"1483263478134476800"]) return;
    
    NSString *pureAcc = CleanPureAccount(rawAcc);
    if (pureAcc.length == 0) pureAcc = CleanPureAccount(userId);
    if (pureAcc.length == 0) return;
    
    NSString *finalName = showName.length > 0 ? showName : (nickName.length > 0 ? nickName : pureAcc);
    
    BOOL isNew = (_collectedUsersMap[pureAcc] == nil);
    HOModelItem *item = _collectedUsersMap[pureAcc] ?: [[HOModelItem alloc] init];
    item.userId = userId.length > 0 ? userId : pureAcc;
    item.account = pureAcc;
    item.name = finalName;
    item.source = groupId.length > 0 ? [NSString stringWithFormat:@"群成员(群:%@)", [groupId substringToIndex:MIN(6, groupId.length)]] : @"群成员提取";
    item.isGroup = NO;
    item.rawUserObj = memberObj;
    _collectedUsersMap[pureAcc] = item;
    if (isNew) {
        [_orderedRankUsers insertObject:item atIndex:0];
    }
}

- (void)harvestGroup:(id)groupObj {
    if (!groupObj) return;
    @try {
        uint8_t *base = (__bridge void *)groupObj;
        // 逆向报告 4.1 节：强制解除群保护和群成员列表查看限制！
        // 0xc9: allowJoin, 0xca: allowInvite, 0x118: protect (群成员保护), 0x119: groupMemberList (查看群成员列表权限), 0x148: myRole
        base[0x118] = 0; // 关闭群保护(允许点群成员头像加好友)
        base[0x119] = 1; // 开启群成员列表查看权限
        
        NSString *gid   = ReadSwiftString(groupObj, 0x20);
        NSString *gNo   = CleanPureAccount(ReadSwiftString(groupObj, 0x30));
        NSString *gName = ReadSwiftString(groupObj, 0x50);
        NSInteger gCnt  = *(NSInteger *)(base + 0xe8);
        
        NSString *key = gid.length >= 4 ? gid : gNo;
        if (key.length >= 4 && gName.length > 0) {
            HOModelItem *item = _joinedGroupsMap[key] ?: [[HOModelItem alloc] init];
            item.userId = gid ?: key;
            item.account = gNo ?: key;
            item.name = gName;
            item.source = gCnt > 0 ? [NSString stringWithFormat:@"我的群聊(%ld人)", (long)gCnt] : @"我的群聊";
            item.isGroup = YES;
            item.rawUserObj = groupObj;
            _joinedGroupsMap[key] = item;
        }
    } @catch (NSException *e) {}
}

- (void)harvestContactCell:(UITableViewCell *)cell {
    if (!cell || ![NSStringFromClass([cell class]) containsString:@"ZDContactCell"]) return;
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    CollectViewLabels(cell, labels);
    NSString *fName = nil;
    NSString *fAcc = nil;
    for (NSString *t in labels) {
        if ([t isEqualToString:@"新的朋友"] || [t isEqualToString:@"群聊"] || [t isEqualToString:@"分组"] || [t containsString:@"助手"] || [t containsString:@"客服"]) return;
        if ([t containsString:@"ID"] || [t containsString:@"海鸥号"] || [t containsString:@"账号"]) {
            fAcc = CleanPureAccount(t);
        } else if (!fName && ![t containsString:@"在线"] && ![t containsString:@"离线"]) {
            fName = t;
        }
    }
    if (fName.length > 0) {
        NSString *key = fAcc.length > 0 ? fAcc : fName;
        HOModelItem *item = _contactFriendsMap[key] ?: [[HOModelItem alloc] init];
        item.userId = key;
        item.account = fAcc ?: key;
        item.name = fName;
        item.source = @"通讯录好友";
        item.isGroup = NO;
        _contactFriendsMap[key] = item;
    }
}

#pragma mark - 3. 核心功能：点击任意用户 -> 直接进入他的【个人主页 / 添加好友页面】(问题3彻底解决)

- (void)openDirectUserProfileForItem:(HOModelItem *)item fromVC:(UIViewController *)fromVC {
    if (!item || !fromVC) return;
    
    // 先把纯净的账号 (例如 86868，绝无 ID 前缀) 复制到剪贴板备用
    NSString *pureAccount = CleanPureAccount(item.account ?: item.userId);
    if (pureAccount.length > 0) {
        [UIPasteboard generalPasteboard].string = pureAccount;
    }
    
    UINavigationController *nav = fromVC.navigationController;
    if (!nav && [fromVC isKindOfClass:[UINavigationController class]]) {
        nav = (UINavigationController *)fromVC;
    }
    if (!nav) {
        UIViewController *root = [UIApplication sharedApplication].keyWindow.rootViewController;
        if ([root isKindOfClass:[UITabBarController class]]) {
            UIViewController *sel = [(UITabBarController *)root selectedViewController];
            if ([sel isKindOfClass:[UINavigationController class]]) nav = (UINavigationController *)sel;
        } else if ([root isKindOfClass:[UINavigationController class]]) {
            nav = (UINavigationController *)root;
        }
    }
    if (!nav) return;
    
    // 方案 1：直接构造海鸥原生的个人主页控制器 ZDNewUserInfoController 或 ZDStrangeUserInfoController
    // 逆向报告 2.5.1 节：
    // _TtC7ZhengDu23ZDNewUserInfoController (用户主页，含添加好友按钮)
    // _TtC7ZhengDu27ZDStrangeUserInfoController (陌生人添加好友页)
    // _TtC7ZhengDu20ZDUserInfoController (用户资料页)
    Class newUserInfoCls = objc_getClass("_TtC7ZhengDu23ZDNewUserInfoController");
    Class userModelCls   = objc_getClass("_TtC7ZhengDu6ZDUser");
    
    if (newUserInfoCls && userModelCls) {
        UIViewController *profileVC = [[newUserInfoCls alloc] init];
        if (profileVC) {
            // 构造或复用 ZDUser 模型并注入到 ZDNewUserInfoController 中
            id userObj = nil;
            if (item.rawUserObj && [NSStringFromClass([item.rawUserObj class]) containsString:@"ZDUser"]) {
                userObj = item.rawUserObj;
            } else {
                userObj = [[userModelCls alloc] init];
                // 扫描 ZDUser 的 ivars，将 userId / account / nickName 写入
                unsigned int uCount = 0;
                Ivar *uIvars = class_copyIvarList(userModelCls, &uCount);
                for (unsigned int i = 0; i < uCount; i++) {
                    const char *iName = ivar_getName(uIvars[i]);
                    if (!iName) continue;
                    NSString *k = [NSString stringWithUTF8String:iName];
                    ptrdiff_t off = ivar_getOffset(uIvars[i]);
                    if ([k isEqualToString:@"id"] || [k isEqualToString:@"userId"]) {
                        WriteSwiftString(userObj, off, item.userId.length > 0 ? item.userId : pureAccount);
                    } else if ([k isEqualToString:@"account"]) {
                        WriteSwiftString(userObj, off, pureAccount);
                    } else if ([k isEqualToString:@"nickName"] || [k isEqualToString:@"name"]) {
                        WriteSwiftString(userObj, off, item.name ?: pureAccount);
                    }
                }
                if (uIvars) free(uIvars);
            }
            
            // 查找 ZDNewUserInfoController 中接收 ZDUser 或 userId 的 ivar 并注入
            unsigned int vcCount = 0;
            Ivar *vcIvars = class_copyIvarList(newUserInfoCls, &vcCount);
            BOOL injectedUser = NO;
            for (unsigned int i = 0; i < vcCount; i++) {
                const char *iName = ivar_getName(vcIvars[i]);
                const char *iType = ivar_getTypeEncoding(vcIvars[i]);
                if (!iName) continue;
                NSString *k = [NSString stringWithUTF8String:iName];
                ptrdiff_t off = ivar_getOffset(vcIvars[i]);
                if ([k containsString:@"user"] && iType && iType[0] == '@') {
                    object_setIvar(profileVC, vcIvars[i], userObj);
                    injectedUser = YES;
                } else if ([k containsString:@"userId"] || [k containsString:@"uid"] || [k containsString:@"account"]) {
                    WriteSwiftString(profileVC, off, item.userId.length > 0 ? item.userId : pureAccount);
                    injectedUser = YES;
                }
            }
            if (vcIvars) free(vcIvars);
            
            if (injectedUser) {
                profileVC.hidesBottomBarWhenPushed = YES;
                [nav pushViewController:profileVC animated:YES];
                return;
            }
        }
    }
}

#pragma mark - 4. 排行榜突破 200 人限制：连续递增 offset 拉取 2 万人并直接显示在排行榜页面上

- (void)startRank20000BreakthroughOnVC:(UIViewController *)rankVC {
    if (_rankBreakTimer) {
        [self stopRank20000Breakthrough];
        return;
    }
    _currentRankVC = rankVC;
    g_enableRankBreakthrough = YES;
    if (g_currentRankOffset < 1) g_currentRankOffset = 1;
    
    // 立即拉取当前页可见项
    [self fetchNextRankBatch];
    // 每 2.0 秒自动请求下一批 200 人（避开海鸥 "手速太快" 限流），叠加到 20000 人！
    _rankBreakTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(fetchNextRankBatch) userInfo:nil repeats:YES];
}

- (void)stopRank20000Breakthrough {
    g_enableRankBreakthrough = NO;
    if (_rankBreakTimer) {
        [_rankBreakTimer invalidate];
        _rankBreakTimer = nil;
    }
    [self saveCache];
    if (_activeRankOverlay) {
        [_activeRankOverlay reloadOverlayList];
    }
}

- (void)fetchNextRankBatch {
    UIViewController *vc = _currentRankVC;
    if (!vc) {
        [self stopRank20000Breakthrough];
        return;
    }
    
    uint8_t *base = (__bridge void *)vc;
    // 逆向报告 5.2 节 ZDGlobalTopItemController:
    // 0x70: zd_page (Int), 0x78: zd_size (Int), 0x88: zd_collect (UICollectionView)
    NSInteger *pagePtr = (NSInteger *)(base + 0x70);
    NSInteger *sizePtr = (NSInteger *)(base + 0x78);
    UICollectionView *cv = *(UICollectionView * __unsafe_unretained *)(base + 0x88);
    
    // 先把当前原列表所有 Cell 抓进叠加池
    if ([cv isKindOfClass:[UICollectionView class]]) {
        for (UICollectionViewCell *cell in cv.visibleCells) {
            NSIndexPath *ip = [cv indexPathForCell:cell];
            [self harvestRankCell:cell indexPath:ip inVC:vc];
        }
    }
    
    // 递增页码（突破第一页的 200 人，请求第 2、3、4...100 页，每页 200 人，总计 20000 人）
    g_currentRankOffset += 1;
    *pagePtr = g_currentRankOffset;
    *sizePtr = 200;
    
    // 调用 ZDGlobalTopItemController 的数据请求函数
    if ([vc respondsToSelector:NSSelectorFromString(@"zd_willShowVC")]) {
        ((void (*)(id, SEL))objc_msgSend)(vc, NSSelectorFromString(@"zd_willShowVC"));
    }
    
    if (_activeRankOverlay) {
        [_activeRankOverlay reloadOverlayList];
    }
    
    if (g_currentRankOffset >= g_targetRankMaxPages) {
        [self stopRank20000Breakthrough];
    }
}

@end

#pragma mark - ==================== 3. 排行榜页面内嵌【2万人全榜直显面板】 ====================

@implementation HORankBreakthroughOverlayView

- (instancetype)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        self.backgroundColor = [UIColor systemBackgroundColor];
        self.layer.cornerRadius = 12;
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [UIColor systemIndigoColor].CGColor;
        
        UIView *topBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, frame.size.width, 46)];
        topBar.backgroundColor = [UIColor secondarySystemBackgroundColor];
        [self addSubview:topBar];
        
        _headerStatusLab = [[UILabel alloc] initWithFrame:CGRectMake(12, 4, frame.size.width - 190, 38)];
        _headerStatusLab.font = [UIFont boldSystemFontOfSize:12];
        _headerStatusLab.numberOfLines = 2;
        _headerStatusLab.textColor = [UIColor labelColor];
        [topBar addSubview:_headerStatusLab];
        
        _startStopBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        _startStopBtn.frame = CGRectMake(frame.size.width - 175, 8, 105, 30);
        _startStopBtn.layer.cornerRadius = 15;
        _startStopBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        [_startStopBtn addTarget:self action:@selector(onTapStartStop) forControlEvents:UIControlEventTouchUpInside];
        [topBar addSubview:_startStopBtn];
        
        _closeOverlayBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        _closeOverlayBtn.frame = CGRectMake(frame.size.width - 64, 8, 56, 30);
        [_closeOverlayBtn setTitle:@"原视图" forState:UIControlStateNormal];
        _closeOverlayBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        [_closeOverlayBtn addTarget:self action:@selector(onTapClose) forControlEvents:UIControlEventTouchUpInside];
        [topBar addSubview:_closeOverlayBtn];
        
        _tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 46, frame.size.width, frame.size.height - 46) style:UITableViewStylePlain];
        _tableView.delegate = self;
        _tableView.dataSource = self;
        _tableView.rowHeight = 54;
        [self addSubview:_tableView];
        
        [self reloadOverlayList];
    }
    return self;
}

- (void)onTapStartStop {
    if (g_enableRankBreakthrough) {
        [[HOMassEngine shared] stopRank20000Breakthrough];
    } else if (_hostRankVC) {
        [[HOMassEngine shared] startRank20000BreakthroughOnVC:_hostRankVC];
    }
    [self reloadOverlayList];
}

- (void)onTapClose {
    self.hidden = YES;
}

- (void)reloadOverlayList {
    _rankItems = [[HOMassEngine shared].orderedRankUsers copy];
    if (g_enableRankBreakthrough) {
        _startStopBtn.backgroundColor = [UIColor systemRedColor];
        [_startStopBtn setTitle:@"🛑停止拉取" forState:UIControlStateNormal];
        _headerStatusLab.text = [NSString stringWithFormat:@"⚡正在突破200限制拉取第 %ld 页...\n当前页面已叠加显示: %lu 人 (点名字直接进主页)", (long)g_currentRankOffset, (unsigned long)_rankItems.count];
    } else {
        _startStopBtn.backgroundColor = [UIColor systemIndigoColor];
        [_startStopBtn setTitle:@"🚀继续叠加2w人" forState:UIControlStateNormal];
        _headerStatusLab.text = [NSString stringWithFormat:@"✅ 排行榜突破列表：已叠加显示 %lu 人\n👇 直接点击任意一行进入【他个人主页】点添加好友", (unsigned long)_rankItems.count];
    }
    [_tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _rankItems.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"HORankBreakCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    HOModelItem *item = _rankItems[indexPath.row];
    cell.textLabel.text = [NSString stringWithFormat:@"第%ld名  %@   %@", (long)(indexPath.row + 1), item.name, item.levelStr ?: @""];
    cell.textLabel.font = [UIFont boldSystemFontOfSize:14];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"纯账号: %@   👉 点击直接进入他主页添加好友", item.account];
    cell.detailTextLabel.textColor = [UIColor systemBlueColor];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    HOModelItem *item = _rankItems[indexPath.row];
    [[HOMassEngine shared] openDirectUserProfileForItem:item fromVC:_hostRankVC];
}

@end

#pragma mark - ==================== 4. 群发与拓客中心面板 ====================

@interface HOMassHelperViewController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UISegmentedControl *tabSegment;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<HOModelItem *> *currentList;
@end

@implementation HOMassHelperViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"海鸥拓客与群发助手";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"返回" style:UIBarButtonItemStylePlain target:self action:@selector(closeVC)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"清空重采" style:UIBarButtonItemStylePlain target:self action:@selector(onClearAll)];
    [self setupUI];
    [self reloadTabData];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadTabData];
}

- (void)closeVC {
    if (self.navigationController && self.navigationController.viewControllers.firstObject != self) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)onClearAll {
    [[HOMassEngine shared] clearAllData];
    [self reloadTabData];
}

- (void)setupUI {
    CGFloat topY = 96;
    
    UIButton *nativeMassBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    nativeMassBtn.frame = CGRectMake(15, topY, self.view.bounds.size.width - 30, 40);
    [nativeMassBtn setTitle:@"📨 打开海鸥官方原生【群发消息】页面" forState:UIControlStateNormal];
    nativeMassBtn.backgroundColor = [UIColor systemBlueColor];
    [nativeMassBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    nativeMassBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    nativeMassBtn.layer.cornerRadius = 8;
    [nativeMassBtn addTarget:self action:@selector(openNativeMassSend) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:nativeMassBtn];
    topY += 48;
    
    _tabSegment = [[UISegmentedControl alloc] initWithItems:@[@"全榜/群成员(点名进主页)", @"我的群聊", @"通讯录好友"]];
    _tabSegment.frame = CGRectMake(15, topY, self.view.bounds.size.width - 30, 34);
    _tabSegment.selectedSegmentIndex = 0;
    [_tabSegment addTarget:self action:@selector(reloadTabData) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:_tabSegment];
    topY += 42;
    
    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, topY, self.view.bounds.size.width - 30, 22)];
    _statusLabel.font = [UIFont boldSystemFontOfSize:12];
    _statusLabel.textColor = [UIColor systemOrangeColor];
    [self.view addSubview:_statusLabel];
    topY += 26;
    
    _tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, topY, self.view.bounds.size.width, self.view.bounds.size.height - topY) style:UITableViewStylePlain];
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.rowHeight = 56;
    [self.view addSubview:_tableView];
}

- (void)openNativeMassSend {
    Class cls = objc_getClass("_TtC7ZhengDu28ZDGroupSendMessageController");
    if (cls && self.navigationController) {
        UIViewController *vc = [[cls alloc] init];
        vc.hidesBottomBarWhenPushed = YES;
        [self.navigationController pushViewController:vc animated:YES];
    }
}

- (void)reloadTabData {
    HOMassEngine *eng = [HOMassEngine shared];
    if (_tabSegment.selectedSegmentIndex == 0) {
        _currentList = [eng.orderedRankUsers copy];
        _statusLabel.text = [NSString stringWithFormat:@"👇 共 %lu 人 (已去ID前缀) | 点任意一行直接进他个人主页加好友", (unsigned long)_currentList.count];
    } else if (_tabSegment.selectedSegmentIndex == 1) {
        _currentList = [eng.joinedGroupsMap.allValues copy];
        _statusLabel.text = [NSString stringWithFormat:@"【我的群聊】共 %lu 个群", (unsigned long)_currentList.count];
    } else {
        _currentList = [eng.contactFriendsMap.allValues copy];
        _statusLabel.text = [NSString stringWithFormat:@"【通讯录好友】共 %lu 人", (unsigned long)_currentList.count];
    }
    [_tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _currentList.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"HOMassV3Cell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    HOModelItem *item = _currentList[indexPath.row];
    cell.textLabel.text = [NSString stringWithFormat:@"%ld. %@", (long)(indexPath.row + 1), item.name];
    cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"账号: %@  |  %@  👉点击直接进主页", item.account, item.source];
    cell.detailTextLabel.textColor = [UIColor systemBlueColor];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    HOModelItem *item = _currentList[indexPath.row];
    [[HOMassEngine shared] openDirectUserProfileForItem:item fromVC:self];
}

@end

#pragma mark - ==================== 5. Runtime Hook 底层挂载区 ====================

static void SwizzleMethod(Class cls, SEL origSel, SEL swizSel, IMP newImp) {
    if (!cls) return;
    Method origMethod = class_getInstanceMethod(cls, origSel);
    if (!origMethod) return;
    class_addMethod(cls, swizSel, newImp, method_getTypeEncoding(origMethod));
    Method swizMethod = class_getInstanceMethod(cls, swizSel);
    method_exchangeImplementations(origMethod, swizMethod);
}

// ---------------- A. 底层拦截排行榜网络请求 URL：把 limit=200&offset=1 自动改写为递增页码 offset=2,3,4... ----------------
static void (*orig_urlReq_setURL)(NSMutableURLRequest *, SEL, NSURL *);
static void hook_urlReq_setURL(NSMutableURLRequest *self, SEL _cmd, NSURL *url) {
    if (url && g_enableRankBreakthrough && g_currentRankOffset > 1) {
        NSString *u = url.absoluteString;
        // 精准匹配 source: 12 抓包中的排行榜 URL: api/sys/open?limit=200&offset=1&scene=1&site=...&type=2
        if ([u containsString:@"api/sys/open?"] && [u containsString:@"offset=1&"] && ([u containsString:@"limit=200"] || [u containsString:@"limit=100"])) {
            NSString *replaced = [u stringByReplacingOccurrencesOfString:@"offset=1&"
                                                              withString:[NSString stringWithFormat:@"offset=%ld&", (long)g_currentRankOffset]];
            NSURL *newURL = [NSURL URLWithString:replaced];
            if (newURL) url = newURL;
        }
    }
    orig_urlReq_setURL(self, _cmd, url);
}

// ---------------- B. 排行榜控制器 Hook：直接在当前排行榜页面内叠加显示 2 万人列表 ----------------
static void (*orig_rank_viewDidLayoutSubviews)(id, SEL);
static void hook_rank_viewDidLayoutSubviews(id self, SEL _cmd) {
    if (orig_rank_viewDidLayoutSubviews) orig_rank_viewDidLayoutSubviews(self, _cmd);
    UIViewController *vc = (UIViewController *)self;
    [HOMassEngine shared].currentRankVC = vc;
    
    // 顶部悬浮【⚡突破200限制·在当前页面显示2万人】切换按钮
    UIButton *toggleBtn = [vc.view viewWithTag:99771];
    if (!toggleBtn) {
        toggleBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        toggleBtn.tag = 99771;
        toggleBtn.frame = CGRectMake(16, 6, vc.view.bounds.size.width - 32, 36);
        toggleBtn.backgroundColor = [UIColor systemIndigoColor];
        [toggleBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        toggleBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        toggleBtn.layer.cornerRadius = 18;
        toggleBtn.layer.zPosition = 10000;
        [toggleBtn addTarget:self action:NSSelectorFromString(@"ho_onTapOpenRankOverlay:") forControlEvents:UIControlEventTouchUpInside];
        [vc.view addSubview:toggleBtn];
    }
    [vc.view bringSubviewToFront:toggleBtn];
    [toggleBtn setTitle:[NSString stringWithFormat:@"⚡突破200限制·当前页直显2万人 (已叠加%lu人)", (unsigned long)[HOMassEngine shared].orderedRankUsers.count] forState:UIControlStateNormal];
}

static void ho_onTapOpenRankOverlay_imp(id self, SEL _cmd, UIButton *sender) {
    UIViewController *vc = (UIViewController *)self;
    HORankBreakthroughOverlayView *overlay = [vc.view viewWithTag:99772];
    if (!overlay) {
        overlay = [[HORankBreakthroughOverlayView alloc] initWithFrame:CGRectMake(0, 46, vc.view.bounds.size.width, vc.view.bounds.size.height - 46)];
        overlay.tag = 99772;
        overlay.hostRankVC = vc;
        overlay.layer.zPosition = 10001;
        [vc.view addSubview:overlay];
    }
    overlay.hidden = NO;
    [vc.view bringSubviewToFront:overlay];
    [HOMassEngine shared].activeRankOverlay = overlay;
    
    // 打开面板同时自动启动连续分页叠加拉取
    if (!g_enableRankBreakthrough) {
        [[HOMassEngine shared] startRank20000BreakthroughOnVC:vc];
    }
    [overlay reloadOverlayList];
}

static UICollectionViewCell *(*orig_rank_cellForItem)(id, SEL, UICollectionView *, NSIndexPath *);
static UICollectionViewCell *hook_rank_cellForItem(id self, SEL _cmd, UICollectionView *cv, NSIndexPath *indexPath) {
    UICollectionViewCell *cell = orig_rank_cellForItem(self, _cmd, cv, indexPath);
    if (cell) {
        UIViewController *vc = (UIViewController *)self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[HOMassEngine shared] harvestRankCell:cell indexPath:indexPath inVC:vc];
            UIButton *toggleBtn = [vc.view viewWithTag:99771];
            if (toggleBtn) {
                [toggleBtn setTitle:[NSString stringWithFormat:@"⚡突破200限制·当前页直显2万人 (已叠加%lu人)", (unsigned long)[HOMassEngine shared].orderedRankUsers.count] forState:UIControlStateNormal];
            }
        });
    }
    return cell;
}

static void hook_rank_clickUpgrade(id self, SEL _cmd) {
    // 彻底屏蔽排行榜等级不足弹窗，允许直接点击榜单任意人进入其个人主页！
}

// ---------------- C. 群聊页面浮窗按钮 100% 必显修复：挂载在 viewWillLayoutSubviews 与 ZDConversationChatView 上 ----------------
static void (*orig_chat1_viewWillLayoutSubviews)(id, SEL);
static void hook_chat1_viewWillLayoutSubviews(id self, SEL _cmd) {
    orig_chat1_viewWillLayoutSubviews(self, _cmd);
    UIViewController *vc = (UIViewController *)self;
    
    // 在聊天页最顶层挂载「🔓强开群成员列表」浮窗按钮，确保不被 ZDConversationChatView 遮挡！
    UIButton *floatBtn = [vc.view viewWithTag:99888];
    if (!floatBtn) {
        floatBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        floatBtn.tag = 99888;
        floatBtn.frame = CGRectMake(vc.view.bounds.size.width - 158, 105, 148, 34);
        floatBtn.backgroundColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.95];
        [floatBtn setTitle:@"🔓强开本群成员列表" forState:UIControlStateNormal];
        [floatBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        floatBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        floatBtn.layer.cornerRadius = 17;
        floatBtn.layer.shadowColor = [UIColor blackColor].CGColor;
        floatBtn.layer.shadowOpacity = 0.3;
        floatBtn.layer.shadowOffset = CGSizeMake(0, 2);
        floatBtn.layer.zPosition = 99999;
        [floatBtn addTarget:self action:NSSelectorFromString(@"ho_onTapForceGroupMembers:") forControlEvents:UIControlEventTouchUpInside];
        [vc.view addSubview:floatBtn];
    }
    [vc.view bringSubviewToFront:floatBtn];
    
    // 同时解锁当前群的 protect 保护位与 groupMemberList 权限位
    @try {
        uint8_t *base = (__bridge void *)vc;
        id groupInfo = *(id __unsafe_unretained *)(base + 0x150);
        if (groupInfo) {
            [[HOMassEngine shared] harvestGroup:groupInfo];
        }
    } @catch (NSException *e) {}
}

static void ho_onTapForceGroupMembers_imp(id self, SEL _cmd, UIButton *sender) {
    UIViewController *vc = (UIViewController *)self;
    uint8_t *base = (__bridge void *)vc;
    
    // 1. 先把 ZDConversationController1 里的 zd_groupInfo (0x150) 和 session (0x180) 拿出来解锁权限
    id groupInfo = *(id __unsafe_unretained *)(base + 0x150);
    id sessionObj = *(id __unsafe_unretained *)(base + 0x180);
    if (groupInfo) {
        [[HOMassEngine shared] harvestGroup:groupInfo];
    }
    
    // 2. 直接初始化并 Push 海鸥原生的群成员列表控制器 ZDConversationGroupMemberListController (逆向报告 2.5.1 节)
    Class memberListCls = objc_getClass("_TtC7ZhengDu37ZDConversationGroupMemberListController");
    if (memberListCls && vc.navigationController) {
        UIViewController *memberVC = [[memberListCls alloc] init];
        if (memberVC) {
            // 将群信息和会话注入给 ZDConversationGroupMemberListController
            unsigned int count = 0;
            Ivar *ivars = class_copyIvarList(memberListCls, &count);
            for (unsigned int i = 0; i < count; i++) {
                const char *name = ivar_getName(ivars[i]);
                const char *type = ivar_getTypeEncoding(ivars[i]);
                if (!name || !type || type[0] != '@') continue;
                NSString *k = [NSString stringWithUTF8String:name];
                if ([k containsString:@"group"] && groupInfo) {
                    object_setIvar(memberVC, ivars[i], groupInfo);
                } else if ([k containsString:@"session"] && sessionObj) {
                    object_setIvar(memberVC, ivars[i], sessionObj);
                }
            }
            if (ivars) free(ivars);
            
            memberVC.hidesBottomBarWhenPushed = YES;
            [vc.navigationController pushViewController:memberVC animated:YES];
            return;
        }
    }
}

// ---------------- D. Hook「我的」页面入口 (ZDMineController) ----------------
static UITableViewCell *(*orig_tv_dequeueForIndexPath)(UITableView *, SEL, NSString *, NSIndexPath *);
static UITableViewCell *hook_tv_dequeueForIndexPath(UITableView *self, SEL _cmd, NSString *identifier, NSIndexPath *indexPath) {
    if (self == g_currentMineTableView && g_currentRealRequestIndexPath != nil) {
        return orig_tv_dequeueForIndexPath(self, _cmd, identifier, g_currentRealRequestIndexPath);
    }
    UITableViewCell *cell = orig_tv_dequeueForIndexPath(self, _cmd, identifier, indexPath);
    if (cell && [NSStringFromClass([cell class]) containsString:@"ZDContactCell"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[HOMassEngine shared] harvestContactCell:cell];
        });
    }
    return cell;
}

static NSInteger (*orig_mine_numberOfRowsInSection)(id, SEL, UITableView *, NSInteger);
static NSInteger hook_mine_numberOfRowsInSection(id self, SEL _cmd, UITableView *tableView, NSInteger section) {
    NSInteger origRows = orig_mine_numberOfRowsInSection(self, _cmd, tableView, section);
    if (section == [HOMassEngine shared].haiouAssistantSection && origRows > 0) return origRows + 1;
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
                static NSString *kEntryId = @"ZD_HOMassEntryCell_V3";
                UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kEntryId];
                if (!cell) {
                    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:kEntryId];
                    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                }
                cell.textLabel.text = @"群发助手";
                cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
                cell.detailTextLabel.text = [NSString stringWithFormat:@"已采%lu人(点名直进主页)", (unsigned long)[HOMassEngine shared].orderedRankUsers.count];
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
    CollectViewLabels(cell, texts);
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

// ---------------- E. Hook ZDGroup 与 ZDGroupMember init ----------------
static id (*orig_group_init)(id, SEL);
static id hook_group_init(id self, SEL _cmd) {
    id ins = orig_group_init(self, _cmd);
    if (ins) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[HOMassEngine shared] harvestGroup:ins];
        });
    }
    return ins;
}

static id (*orig_groupMember_init)(id, SEL);
static id hook_groupMember_init(id self, SEL _cmd) {
    id ins = orig_groupMember_init(self, _cmd);
    if (ins) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[HOMassEngine shared] harvestGroupMember:ins];
        });
    }
    return ins;
}

#pragma mark - ==================== 6. Dylib 构造函数 ====================

__attribute__((constructor))
static void HaiouMassHelperInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 1. 挂载网络请求 URL 拦截 (突破排行榜 offset=1 限制)
        Class reqCls = [NSMutableURLRequest class];
        orig_urlReq_setURL = (void *)method_getImplementation(class_getInstanceMethod(reqCls, @selector(setURL:)));
        SwizzleMethod(reqCls, @selector(setURL:), NSSelectorFromString(@"ho3_setURL:"), (IMP)hook_urlReq_setURL);
        
        // 2. 挂载 UITableView 安全修正
        Class tvCls = [UITableView class];
        SEL deqSel = @selector(dequeueReusableCellWithIdentifier:forIndexPath:);
        orig_tv_dequeueForIndexPath = (void *)method_getImplementation(class_getInstanceMethod(tvCls, deqSel));
        SwizzleMethod(tvCls, deqSel, NSSelectorFromString(@"ho3_dequeueReusableCellWithIdentifier:forIndexPath:"), (IMP)hook_tv_dequeueForIndexPath);
        
        // 3. 挂载「我的」页面 (ZDMineController)
        Class mineCls = objc_getClass("_TtC7ZhengDu16ZDMineController");
        if (mineCls) {
            orig_mine_numberOfRowsInSection = (void *)method_getImplementation(class_getInstanceMethod(mineCls, @selector(tableView:numberOfRowsInSection:)));
            SwizzleMethod(mineCls, @selector(tableView:numberOfRowsInSection:), NSSelectorFromString(@"ho3_tableView:numberOfRowsInSection:"), (IMP)hook_mine_numberOfRowsInSection);
            
            orig_mine_heightForRowAtIndexPath = (void *)method_getImplementation(class_getInstanceMethod(mineCls, @selector(tableView:heightForRowAtIndexPath:)));
            SwizzleMethod(mineCls, @selector(tableView:heightForRowAtIndexPath:), NSSelectorFromString(@"ho3_tableView:heightForRowAtIndexPath:"), (IMP)hook_mine_heightForRowAtIndexPath);
            
            orig_mine_cellForRowAtIndexPath = (void *)method_getImplementation(class_getInstanceMethod(mineCls, @selector(tableView:cellForRowAtIndexPath:)));
            SwizzleMethod(mineCls, @selector(tableView:cellForRowAtIndexPath:), NSSelectorFromString(@"ho3_tableView:cellForRowAtIndexPath:"), (IMP)hook_mine_cellForRowAtIndexPath);
            
            orig_mine_didSelectRowAtIndexPath = (void *)method_getImplementation(class_getInstanceMethod(mineCls, @selector(tableView:didSelectRowAtIndexPath:)));
            SwizzleMethod(mineCls, @selector(tableView:didSelectRowAtIndexPath:), NSSelectorFromString(@"ho3_tableView:didSelectRowAtIndexPath:"), (IMP)hook_mine_didSelectRowAtIndexPath);
        }
        
        // 4. 挂载「排行榜」分页控制器 (ZDGlobalTopItemController)
        Class rankItemCls = objc_getClass("_TtC7ZhengDu25ZDGlobalTopItemController");
        if (rankItemCls) {
            class_addMethod(rankItemCls, NSSelectorFromString(@"ho_onTapOpenRankOverlay:"), (IMP)ho_onTapOpenRankOverlay_imp, "v@:@");
            
            SEL layoutSel = @selector(viewWillLayoutSubviews);
            orig_rank_viewDidLayoutSubviews = (void *)method_getImplementation(class_getInstanceMethod(rankItemCls, layoutSel));
            SwizzleMethod(rankItemCls, layoutSel, NSSelectorFromString(@"ho3_rank_viewWillLayoutSubviews"), (IMP)hook_rank_viewDidLayoutSubviews);
            
            SwizzleMethod(rankItemCls, NSSelectorFromString(@"zd_clickUpgrade"), NSSelectorFromString(@"ho3_zd_clickUpgrade"), (IMP)hook_rank_clickUpgrade);
            
            orig_rank_cellForItem = (void *)method_getImplementation(class_getInstanceMethod(rankItemCls, @selector(collectionView:cellForItemAtIndexPath:)));
            SwizzleMethod(rankItemCls, @selector(collectionView:cellForItemAtIndexPath:), NSSelectorFromString(@"ho3_collectionView:cellForItemAtIndexPath:"), (IMP)hook_rank_cellForItem);
        }
        
        // 5. 挂载「群聊会话页」(ZDConversationController1) 100% 显示强开群成员按钮
        Class chat1Cls = objc_getClass("_TtC7ZhengDu25ZDConversationController1");
        if (chat1Cls) {
            class_addMethod(chat1Cls, NSSelectorFromString(@"ho_onTapForceGroupMembers:"), (IMP)ho_onTapForceGroupMembers_imp, "v@:@");
            orig_chat1_viewWillLayoutSubviews = (void *)method_getImplementation(class_getInstanceMethod(chat1Cls, @selector(viewWillLayoutSubviews)));
            SwizzleMethod(chat1Cls, @selector(viewWillLayoutSubviews), NSSelectorFromString(@"ho3_chat_viewWillLayoutSubviews"), (IMP)hook_chat1_viewWillLayoutSubviews);
        }
        
        // 6. 挂载群模型与群成员模型
        Class groupCls = objc_getClass("_TtC7ZhengDu7ZDGroup");
        if (groupCls) {
            orig_group_init = (void *)method_getImplementation(class_getInstanceMethod(groupCls, @selector(init)));
            SwizzleMethod(groupCls, @selector(init), NSSelectorFromString(@"ho3_group_init"), (IMP)hook_group_init);
        }
        Class gmCls = objc_getClass("_TtC7ZhengDu13ZDGroupMember");
        if (gmCls) {
            orig_groupMember_init = (void *)method_getImplementation(class_getInstanceMethod(gmCls, @selector(init)));
            SwizzleMethod(gmCls, @selector(init), NSSelectorFromString(@"ho3_gm_init"), (IMP)hook_groupMember_init);
        }
    });
}

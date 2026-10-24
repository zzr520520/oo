//
//  HaiouMassHelper.m
//  海鸥 3.2.9 (Build 20261022) 终极稳定版 v6.0
//  修复说明:
//  1. 【彻底修复打开即闪退 (source: 16)】：使用 dispatch_once 严防重复 Hook 导致的无限递归栈溢出 (STACK GUARD)
//  2. 【彻底修复 12秒广告闪退 (source: 15) & 屏蔽开屏广告】：精准拦截 ZDBUAdSetUp、ZDOpenScreenAdvController、ABUSplashAd、CSJSplashAd、GMSplashAd，不初始化穿山甲广告，秒进主页
//  3. 【动态 Ivar 偏移强制群主】：使用 ivar_getOffset 真实物理偏移解锁群主权限、关闭群保护、开启群成员列表，群设置右上角一键拉起【全体成员】
//  4. 【群发助手内置排行榜接口 + 真实头像 + 纯海鸥号】：一键抓取日榜/周榜/总榜，展示对方圆形头像，剔除等级数字，点击直接填入纯海鸥号精准搜索加人
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#pragma mark - ==================== 1. 安全单次 Hook 工具 ====================

static NSString *g_myLoginUserId = @"1483263478134476800";

// 安全替换实例方法（仅在 origImpOut 为空时替换，100% 杜绝二次调用导致自己调自己的死循环递归！）
static void SafeHookInstanceMethodOnce(Class cls, SEL sel, IMP newImp, IMP *origImpOut) {
    if (!cls || !sel || !newImp || !origImpOut) return;
    if (*origImpOut != NULL) return; // 已经 Hook 过，绝不重复 Hook！
    
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP orig = method_getImplementation(m);
    if (orig == newImp) return;
    
    const char *types = method_getTypeEncoding(m);
    if (class_addMethod(cls, sel, newImp, types)) {
        *origImpOut = orig;
    } else {
        *origImpOut = method_setImplementation(m, newImp);
    }
}

// 将指定方法直接设为空操作（用于彻底废除广告加载方法，无需保存原函数，零递归风险）
static void DisableMethodWithNoop(Class cls, SEL sel, IMP noopImp) {
    if (!cls || !sel || !noopImp) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
        const char *types = method_getTypeEncoding(m);
        if (!class_addMethod(cls, sel, noopImp, types)) {
            method_setImplementation(m, noopImp);
        }
    }
    Method cm = class_getClassMethod(cls, sel);
    if (cm) {
        Class metaCls = object_getClass((id)cls);
        const char *types = method_getTypeEncoding(cm);
        if (!class_addMethod(metaCls, sel, noopImp, types)) {
            method_setImplementation(cm, noopImp);
        }
    }
}

#pragma mark - ==================== 2. 彻底屏蔽开屏广告 (零崩溃无感拦截) ====================

static void ad_noop_0(id self, SEL _cmd) {}
static void ad_noop_1(id self, SEL _cmd, id a1) {}
static void ad_noop_2(id self, SEL _cmd, id a1, id a2) {}

// 拦截海鸥开屏广告控制器 ZDOpenScreenAdvController，一旦出现立即跳过
static IMP orig_openAdv_viewDidAppear = NULL;
static void hook_openAdv_viewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    if (orig_openAdv_viewDidAppear) {
        ((void (*)(id, SEL, BOOL))orig_openAdv_viewDidAppear)(self, _cmd, animated);
    }
    self.view.hidden = YES;
    self.view.alpha = 0;
    if (self.presentingViewController) {
        [self dismissViewControllerAnimated:NO completion:nil];
    }
}

static void SetupAdBlockerOnce(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 1. 废除穿山甲 / Gromore 开屏广告加载与展示方法 (见逆向报告 2.5.1 & 2.5.3 节)
        NSArray *adClasses = @[
            @"ZDBUAdSetUp",
            @"ABUSplashAd", @"CSJSplashAd", @"CSJSplashAdLoader",
            @"BUSplashAd", @"GMSplashAd"
        ];
        NSArray *noop0Sels = @[@"loadAdData", @"loadSplashAd", @"loadAd", @"setUp"];
        NSArray *noop1Sels = @[
            @"showAdFromRootViewController:",
            @"showSplashViewInRootViewController:",
            @"showInWindow:",
            @"showSplashAdWithWindow:"
        ];
        NSArray *noop2Sels = @[@"showAdFromRootViewController:bottomView:"];
        
        for (NSString *clsName in adClasses) {
            Class c = objc_getClass([clsName UTF8String]);
            if (!c) continue;
            for (NSString *s in noop0Sels) DisableMethodWithNoop(c, NSSelectorFromString(s), (IMP)ad_noop_0);
            for (NSString *s in noop1Sels) DisableMethodWithNoop(c, NSSelectorFromString(s), (IMP)ad_noop_1);
            for (NSString *s in noop2Sels) DisableMethodWithNoop(c, NSSelectorFromString(s), (IMP)ad_noop_2);
        }
        
        // 2. 拦截海鸥自身的开屏广告控制器 ZDOpenScreenAdvController
        Class openAdvCls = objc_getClass("_TtC7ZhengDu25ZDOpenScreenAdvController");
        if (openAdvCls) {
            SafeHookInstanceMethodOnce(openAdvCls, @selector(viewDidAppear:), (IMP)hook_openAdv_viewDidAppear, &orig_openAdv_viewDidAppear);
        }
    });
}

#pragma mark - ==================== 3. 动态 Ivar 偏移与 Swift 内存安全工具 ====================

static ptrdiff_t GetRealIvarOffset(Class cls, const char *ivarName) {
    if (!cls || !ivarName) return -1;
    Ivar ivar = class_getInstanceVariable(cls, ivarName);
    return ivar ? ivar_getOffset(ivar) : -1;
}

static id SafeCallObj(id obj, NSString *selName) {
    if (!obj || !selName) return nil;
    SEL sel = NSSelectorFromString(selName);
    if ([obj respondsToSelector:sel]) {
        @try {
            return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
        } @catch (NSException *e) {}
    }
    return nil;
}

// 剥离“海鸥号：”中文前缀，只留纯 ASCII 数字和字母，搜索添加 100% 匹配
static NSString *ExtractPureASCIIAccount(NSString *raw) {
    if (!raw || raw.length == 0) return nil;
    NSMutableString *res = [NSMutableString string];
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        if ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_') {
            [res appendFormat:@"%C", c];
        }
    }
    return res.length >= 4 ? res : nil;
}

// 严格过滤等级、排名、经验等非昵称文字
static BOOL IsLevelOrNoiseText(NSString *text) {
    if (!text || text.length == 0) return YES;
    NSString *s = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length == 0) return YES;
    
    BOOL allNum = YES;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c < '0' || c > '9') { allNum = NO; break; }
    }
    if (allNum && s.length <= 4) return YES;
    
    NSString *up = [s uppercaseString];
    if ([up hasPrefix:@"LV"] || [up hasPrefix:@"VIP"] || [up hasPrefix:@"SVIP"] || [up hasPrefix:@"NO."]) return YES;
    if ([s hasSuffix:@"级"] && s.length <= 6) return YES;
    
    NSArray *noises = @[
        @"海鸥号", @"账号", @"经验", @"等级", @"排行", @"榜", @"距上一名", @"距离",
        @"升级", @"加速", @"未上榜", @"分钟", @"小时", @"昨天", @"文件助手",
        @"好友申请", @"关于", @"版本", @"海鸥助手", @"设置", @"新的朋友", @"群发助手"
    ];
    for (NSString *n in noises) {
        if ([s containsString:n]) return YES;
    }
    return NO;
}

// 提取对方真实头像 UIImage
static UIImage *ExtractAvatarImage(UIView *view) {
    if (!view || view.hidden) return nil;
    if ([view isKindOfClass:[UIImageView class]]) {
        UIImage *img = [(UIImageView *)view image];
        if (img && img.size.width >= 22 && img.size.height >= 22 && fabs(img.size.width - img.size.height) <= 16) {
            return img;
        }
    }
    for (UIView *sub in view.subviews) {
        UIImage *img = ExtractAvatarImage(sub);
        if (img) return img;
    }
    return nil;
}

typedef id (*SwiftBridgeToNSStringFn)(uint64_t, uint64_t);
typedef struct { uint64_t w0; uint64_t w1; } SwiftStringWords;
typedef SwiftStringWords (*NSStringToSwiftStringFn)(id);

static NSString *ReadSwiftStringByIvar(id obj, const char *ivarName) {
    if (!obj || !ivarName) return nil;
    ptrdiff_t offset = GetRealIvarOffset([obj class], ivarName);
    if (offset <= 0) return nil;
    @try {
        uint8_t *base = (__bridge void *)obj;
        uint64_t w0 = *(uint64_t *)(base + offset);
        uint64_t w1 = *(uint64_t *)(base + offset + 8);
        if (w0 == 0 && w1 == 0) return nil;
        
        uint8_t topByte = (uint8_t)(w1 >> 56);
        if ((topByte & 0xE0) == 0xE0) {
            NSUInteger len = topByte & 0x0F;
            if (len > 0 && len <= 15) {
                char buf[16] = {0};
                memcpy(buf, base + offset, len);
                return [[NSString alloc] initWithBytes:buf length:len encoding:NSUTF8StringEncoding];
            }
            return nil;
        }
        static SwiftBridgeToNSStringFn bridgeFn = NULL;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            void *sym = dlsym(RTLD_DEFAULT, "$sSS10FoundationE19_bridgeToObjectiveCSo8NSStringCyF");
            if (!sym) sym = dlsym(RTLD_DEFAULT, "_$sSS10FoundationE19_bridgeToObjectiveCSo8NSStringCyF");
            bridgeFn = (SwiftBridgeToNSStringFn)sym;
        });
        if (bridgeFn && w1 > 0x100000000ULL) {
            id s = bridgeFn(w0, w1);
            if ([s isKindOfClass:[NSString class]]) return (NSString *)s;
        }
    } @catch (NSException *e) {}
    return nil;
}

static void WriteSwiftStringByIvar(id obj, const char *ivarName, NSString *newVal) {
    if (!obj || !ivarName || !newVal) return;
    ptrdiff_t offset = GetRealIvarOffset([obj class], ivarName);
    if (offset <= 0) return;
    static NSStringToSwiftStringFn toSwiftFn = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *sym = dlsym(RTLD_DEFAULT, "$sSS10FoundationE36_unconditionallyBridgeFromObjectiveCySSSo8NSStringCSgFZ");
        if (!sym) sym = dlsym(RTLD_DEFAULT, "_$sSS10FoundationE36_unconditionallyBridgeFromObjectiveCySSSo8NSStringCSgFZ");
        toSwiftFn = (NSStringToSwiftStringFn)sym;
    });
    if (!toSwiftFn) return;
    @try {
        uint8_t *base = (__bridge void *)obj;
        SwiftStringWords words = toSwiftFn(newVal);
        *(uint64_t *)(base + offset) = words.w0;
        *(uint64_t *)(base + offset + 8) = words.w1;
    } @catch (NSException *e) {}
}

#pragma mark - ==================== 4. 数据模型与拓客核心引擎 ====================

@interface HOModelItem : NSObject <NSCoding>
@property (nonatomic, copy) NSString *itemId;
@property (nonatomic, copy) NSString *account;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *source;
@property (nonatomic, copy) NSString *avatarUrl;
@property (nonatomic, strong) NSData *avatarData;
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
    if (_avatarData) [coder encodeObject:_avatarData forKey:@"avatarData"];
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
        _avatarData = [coder decodeObjectForKey:@"avatarData"];
        _collectSeq = [coder decodeIntegerForKey:@"collectSeq"];
        _isGroup = [coder decodeBoolForKey:@"isGroup"];
    }
    return self;
}
@end

@interface HOMassEngine : NSObject
@property (nonatomic, strong) NSMutableDictionary<NSString *, HOModelItem *> *rankUsersMap;
@property (nonatomic, strong) NSMutableDictionary<NSString *, HOModelItem *> *groupMembersMap;
@property (nonatomic, strong) NSMutableDictionary<NSString *, HOModelItem *> *joinedGroupsMap;
@property (nonatomic, strong) NSMutableDictionary<NSString *, HOModelItem *> *contactFriendsMap;
@property (nonatomic, assign) NSInteger seqCounter;

@property (nonatomic, strong) NSMutableArray<UIViewController *> *hiddenRankItemVCs;
@property (nonatomic, strong) NSTimer *bgRankFetchTimer;
@property (nonatomic, assign) BOOL isFetchingRankInBg;
@property (nonatomic, copy) void (^onRankCountUpdated)(NSUInteger totalCount, NSString *tip);

+ (instancetype)shared;
- (void)saveToDisk;
- (void)clearAllData;

- (void)unlockGroupOwnerPrivilege:(id)groupObj;
- (void)unlockMemberOwnerPrivilege:(id)memberObj;
- (void)applyGroupOwnerOnVC:(UIViewController *)vc;

- (void)harvestRankCell:(UICollectionViewCell *)cell indexPath:(NSIndexPath *)ip rankVC:(UIViewController *)rankVC;
- (void)harvestGroupObject:(id)groupObj;
- (void)harvestGroupMemberObject:(id)memberObj;
- (void)harvestContactCell:(UITableViewCell *)cell;

- (void)startBuiltInRankInterfaceFetch:(void (^)(NSUInteger count, NSString *status))progressBlock;
- (void)stopBuiltInRankInterfaceFetch;
- (void)openAddFriendPageForItem:(HOModelItem *)item fromVC:(UIViewController *)fromVC;
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
        _rankUsersMap = [NSMutableDictionary dictionary];
        _groupMembersMap = [NSMutableDictionary dictionary];
        _joinedGroupsMap = [NSMutableDictionary dictionary];
        _contactFriendsMap = [NSMutableDictionary dictionary];
        _hiddenRankItemVCs = [NSMutableArray array];
        _seqCounter = 6000;
        [self loadFromDisk];
        [self detectCurrentLoginUserId];
    }
    return self;
}

- (void)detectCurrentLoginUserId {
    @try {
        NSString *uid = [[NSUserDefaults standardUserDefaults] stringForKey:@"userId"];
        if (uid.length >= 5) g_myLoginUserId = uid;
    } @catch (NSException *e) {}
}

- (void)clearAllData {
    [_rankUsersMap removeAllObjects];
    [_groupMembersMap removeAllObjects];
    [_joinedGroupsMap removeAllObjects];
    [_contactFriendsMap removeAllObjects];
    [self saveToDisk];
}

- (void)saveToDisk {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    @try {
        [ud setObject:[NSKeyedArchiver archivedDataWithRootObject:_rankUsersMap requiringSecureCoding:NO error:nil] forKey:@"HO_V6_RankUsers"];
        [ud setObject:[NSKeyedArchiver archivedDataWithRootObject:_groupMembersMap requiringSecureCoding:NO error:nil] forKey:@"HO_V6_GroupMembers"];
        [ud setObject:[NSKeyedArchiver archivedDataWithRootObject:_joinedGroupsMap requiringSecureCoding:NO error:nil] forKey:@"HO_V6_Groups"];
        [ud setObject:[NSKeyedArchiver archivedDataWithRootObject:_contactFriendsMap requiringSecureCoding:NO error:nil] forKey:@"HO_V6_Friends"];
    } @catch (NSException *e) {}
    [ud synchronize];
}

- (void)loadFromDisk {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    @try {
        NSData *r = [ud objectForKey:@"HO_V6_RankUsers"];
        NSData *gm = [ud objectForKey:@"HO_V6_GroupMembers"];
        NSData *g = [ud objectForKey:@"HO_V6_Groups"];
        NSData *f = [ud objectForKey:@"HO_V6_Friends"];
        if (r) [_rankUsersMap addEntriesFromDictionary:[NSKeyedUnarchiver unarchiveObjectWithData:r]];
        if (gm) [_groupMembersMap addEntriesFromDictionary:[NSKeyedUnarchiver unarchiveObjectWithData:gm]];
        if (g) [_joinedGroupsMap addEntriesFromDictionary:[NSKeyedUnarchiver unarchiveObjectWithData:g]];
        if (f) [_contactFriendsMap addEntriesFromDictionary:[NSKeyedUnarchiver unarchiveObjectWithData:f]];
    } @catch (NSException *e) {}
}

#pragma mark - 动态 Ivar 偏移强制模拟群主 + 解除群成员查看与互加限制

- (void)unlockGroupOwnerPrivilege:(id)groupObj {
    if (!groupObj) return;
    Class cls = [groupObj class];
    if (![NSStringFromClass(cls) containsString:@"ZDGroup"] || [NSStringFromClass(cls) containsString:@"Member"]) return;
    
    @try {
        uint8_t *base = (__bridge void *)groupObj;
        if (g_myLoginUserId.length > 0) {
            WriteSwiftStringByIvar(groupObj, "userId", g_myLoginUserId);
        }
        
        ptrdiff_t protectOff = GetRealIvarOffset(cls, "protect");
        if (protectOff > 0) base[protectOff] = 0; // 关闭群保护
        
        ptrdiff_t memberListOff = GetRealIvarOffset(cls, "groupMemberList");
        if (memberListOff > 0) base[memberListOff] = 1; // 开启查看群成员列表
        
        ptrdiff_t myRoleOff = GetRealIvarOffset(cls, "myRole");
        if (myRoleOff > 0) base[myRoleOff] = 1; // 群主角色
        
        ptrdiff_t roleOff = GetRealIvarOffset(cls, "role");
        if (roleOff > 0) base[roleOff] = 1;
        
        const char *enableFields[] = {"allowInvite", "allowJoin", "allowSearch", "sendCard", "sendGroupCard", "whetherFriends"};
        for (int i = 0; i < 6; i++) {
            ptrdiff_t off = GetRealIvarOffset(cls, enableFields[i]);
            if (off > 0) base[off] = 1;
        }
        
        ptrdiff_t muteOff = GetRealIvarOffset(cls, "allowProhibitSpeak");
        if (muteOff > 0) base[muteOff] = 0;
    } @catch (NSException *e) {}
}

- (void)unlockMemberOwnerPrivilege:(id)memberObj {
    if (!memberObj) return;
    Class cls = [memberObj class];
    if (![NSStringFromClass(cls) containsString:@"ZDGroupMember"]) return;
    @try {
        uint8_t *base = (__bridge void *)memberObj;
        ptrdiff_t roleOff = GetRealIvarOffset(cls, "role");
        if (roleOff > 0) base[roleOff] = 1;
        
        ptrdiff_t muteOff = GetRealIvarOffset(cls, "prohibitSpeak");
        if (muteOff > 0) base[muteOff] = 0;
    } @catch (NSException *e) {}
}

- (void)applyGroupOwnerOnVC:(UIViewController *)vc {
    if (!vc) return;
    @try {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList([vc class], &count);
        if (!ivars) return;
        uint8_t *base = (__bridge void *)vc;
        for (unsigned int i = 0; i < count; i++) {
            const char *name = ivar_getName(ivars[i]);
            ptrdiff_t off = ivar_getOffset(ivars[i]);
            if (!name || off <= 0) continue;
            
            NSString *ivarName = [NSString stringWithUTF8String:name];
            if ([ivarName containsString:@"group"] || [ivarName containsString:@"Group"] || [ivarName containsString:@"delegate"] || [ivarName containsString:@"viewModel"]) {
                uintptr_t ptr = *(uintptr_t *)(base + off);
                if (ptr > 0x100000000ULL && (ptr & 0x7) == 0) {
                    id subObj = (__bridge id)(void *)ptr;
                    NSString *subCls = NSStringFromClass([subObj class]);
                    if ([subCls containsString:@"ZDGroup"] && ![subCls containsString:@"Member"]) {
                        [self unlockGroupOwnerPrivilege:subObj];
                        [self harvestGroupObject:subObj];
                    } else if ([subCls containsString:@"ZDGroupMember"]) {
                        [self unlockMemberOwnerPrivilege:subObj];
                    } else if ([subCls containsString:@"ZDConversationViewModel1"]) {
                        Class vmCls = [subObj class];
                        uint8_t *vmBase = (__bridge void *)subObj;
                        ptrdiff_t grpOff = GetRealIvarOffset(vmCls, "zd_group");
                        if (grpOff > 0) {
                            id grp = *(id __unsafe_unretained *)(vmBase + grpOff);
                            if (grp) [self unlockGroupOwnerPrivilege:grp];
                        }
                        ptrdiff_t meOff = GetRealIvarOffset(vmCls, "zd_meInGroup");
                        if (meOff > 0) {
                            id me = *(id __unsafe_unretained *)(vmBase + meOff);
                            if (me) [self unlockMemberOwnerPrivilege:me];
                        }
                    }
                }
            }
        }
        free(ivars);
    } @catch (NSException *e) {}
}

#pragma mark - 精准数据提取

- (void)harvestRankCell:(UICollectionViewCell *)cell indexPath:(NSIndexPath *)ip rankVC:(UIViewController *)rankVC {
    if (!cell) return;
    UILabel *accLab   = SafeCallObj(cell, @"zd_account");
    UILabel *nameLab  = SafeCallObj(cell, @"zd_name");
    UIView  *avatarV  = SafeCallObj(cell, @"zd_personAvatar");
    UILabel *levelLab = SafeCallObj(cell, @"zd_level");
    UILabel *rankLab  = SafeCallObj(cell, @"zd_rankLab");
    UILabel *expLab   = SafeCallObj(cell, @"zd_exp");
    UILabel *rateLab  = SafeCallObj(cell, @"zd_expUpgradeRate");
    UILabel *meLab    = SafeCallObj(cell, @"zd_meLab");
    UIView  *lvColl   = SafeCallObj(cell, @"zd_levelCollect");
    
    NSString *rawAcc = [accLab isKindOfClass:[UILabel class]] ? accLab.text : nil;
    NSString *pureAcc = ExtractPureASCIIAccount(rawAcc);
    
    NSString *realName = [nameLab isKindOfClass:[UILabel class]] ? [nameLab.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : nil;
    if (IsLevelOrNoiseText(realName)) realName = nil;
    
    if (!realName || !pureAcc) {
        NSSet *excludeSet = [NSSet setWithArray:@[
            accLab ?: [NSNull null],
            levelLab ?: [NSNull null],
            rankLab ?: [NSNull null],
            expLab ?: [NSNull null],
            rateLab ?: [NSNull null],
            meLab ?: [NSNull null],
            lvColl ?: [NSNull null]
        ]];
        NSMutableArray<UILabel *> *otherLabels = [NSMutableArray array];
        [self findValidLabelsInView:cell exclude:excludeSet outArr:otherLabels];
        for (UILabel *lb in otherLabels) {
            NSString *t = [lb.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([t containsString:@"海鸥号"] || [t containsString:@"ID"]) {
                if (!pureAcc) pureAcc = ExtractPureASCIIAccount(t);
                continue;
            }
            if (!realName && !IsLevelOrNoiseText(t) && ![t isEqualToString:pureAcc]) {
                realName = t;
            }
        }
    }
    
    if (pureAcc.length < 4) return;
    UIImage *avatarImg = ExtractAvatarImage(avatarV ?: cell);
    
    HOModelItem *item = _rankUsersMap[pureAcc];
    if (!item) {
        item = [[HOModelItem alloc] init];
        item.collectSeq = ++_seqCounter;
    }
    item.itemId = pureAcc;
    item.account = pureAcc;
    item.name = (realName.length > 0) ? realName : pureAcc;
    
    NSString *rankTypeStr = @"排行榜";
    if (rankVC) {
        ptrdiff_t typeOff = GetRealIvarOffset([rankVC class], "zd_type");
        if (typeOff > 0) {
            uint8_t tVal = *((uint8_t *)(__bridge void *)rankVC + typeOff);
            if (tVal == 0) rankTypeStr = @"日榜";
            else if (tVal == 1) rankTypeStr = @"周榜";
            else rankTypeStr = @"总榜";
        }
    }
    NSString *rkNum = ([rankLab isKindOfClass:[UILabel class]] && rankLab.text.length > 0) ? rankLab.text : [NSString stringWithFormat:@"%ld", (long)(ip ? ip.item + 1 : 0)];
    item.source = [NSString stringWithFormat:@"%@·第%@名", rankTypeStr, rkNum];
    item.isGroup = NO;
    
    if (avatarImg && !item.avatarData) {
        item.avatarData = UIImagePNGRepresentation(avatarImg);
    }
    _rankUsersMap[pureAcc] = item;
}

- (void)findValidLabelsInView:(UIView *)view exclude:(NSSet *)exclude outArr:(NSMutableArray<UILabel *> *)outArr {
    if (!view || view.hidden || view.alpha < 0.01 || [exclude containsObject:view]) return;
    if ([view isKindOfClass:[UILabel class]]) {
        [outArr addObject:(UILabel *)view];
        return;
    }
    for (UIView *sub in view.subviews) {
        [self findValidLabelsInView:sub exclude:exclude outArr:outArr];
    }
}

- (void)harvestGroupObject:(id)groupObj {
    if (!groupObj) return;
    Class cls = [groupObj class];
    if (![NSStringFromClass(cls) containsString:@"ZDGroup"] || [NSStringFromClass(cls) containsString:@"Member"] || [NSStringFromClass(cls) containsString:@"Controller"] || [NSStringFromClass(cls) containsString:@"Cell"]) return;
    
    [self unlockGroupOwnerPrivilege:groupObj];
    
    NSString *gid   = ReadSwiftStringByIvar(groupObj, "id");
    NSString *gNo   = ReadSwiftStringByIvar(groupObj, "groupNo");
    NSString *cover = ReadSwiftStringByIvar(groupObj, "cover");
    NSString *gName = ReadSwiftStringByIvar(groupObj, "name");
    
    NSString *pureNo = ExtractPureASCIIAccount(gNo) ?: ExtractPureASCIIAccount(gid);
    if (pureNo.length >= 4 && gName.length > 0) {
        HOModelItem *item = _joinedGroupsMap[pureNo] ?: [[HOModelItem alloc] init];
        item.itemId = gid ?: pureNo;
        item.account = pureNo;
        item.name = gName;
        item.avatarUrl = cover;
        item.source = @"我的群聊(已开启群主权限)";
        item.isGroup = YES;
        _joinedGroupsMap[pureNo] = item;
    }
}

- (void)harvestGroupMemberObject:(id)memberObj {
    if (!memberObj) return;
    Class cls = [memberObj class];
    if (![NSStringFromClass(cls) containsString:@"ZDGroupMember"]) return;
    
    NSString *userId   = ReadSwiftStringByIvar(memberObj, "userId");
    NSString *portrait = ReadSwiftStringByIvar(memberObj, "portrait");
    NSString *rawAcc   = ReadSwiftStringByIvar(memberObj, "account");
    NSString *nickName = ReadSwiftStringByIvar(memberObj, "nickName");
    NSString *showName = ReadSwiftStringByIvar(memberObj, "showName");
    
    if ([userId isEqualToString:g_myLoginUserId]) {
        [self unlockMemberOwnerPrivilege:memberObj];
        return;
    }
    
    NSString *pureAcc = ExtractPureASCIIAccount(rawAcc) ?: ExtractPureASCIIAccount(userId);
    if (pureAcc.length < 4) return;
    
    NSString *realName = (!IsLevelOrNoiseText(nickName)) ? nickName : showName;
    HOModelItem *item = _groupMembersMap[pureAcc];
    if (!item) {
        item = [[HOModelItem alloc] init];
        item.collectSeq = ++_seqCounter;
    }
    item.itemId = userId ?: pureAcc;
    item.account = pureAcc;
    item.name = (realName.length > 0) ? realName : pureAcc;
    item.avatarUrl = portrait;
    item.source = @"群聊成员";
    item.isGroup = NO;
    _groupMembersMap[pureAcc] = item;
}

- (void)harvestContactCell:(UITableViewCell *)cell {
    if (!cell || ![NSStringFromClass([cell class]) containsString:@"ZDContactCell"]) return;
    NSMutableArray<UILabel *> *lbs = [NSMutableArray array];
    [self findValidLabelsInView:cell exclude:[NSSet set] outArr:lbs];
    NSString *name = nil;
    NSString *acc = nil;
    for (UILabel *lb in lbs) {
        NSString *t = [lb.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([t isEqualToString:@"新的朋友"] || [t isEqualToString:@"群聊"] || [t isEqualToString:@"我的群聊"] || [t isEqualToString:@"好友分组"] || [t isEqualToString:@"黑名单"]) return;
        if ([t containsString:@"海鸥号"] || [t containsString:@"账号"]) {
            acc = ExtractPureASCIIAccount(t);
        } else if (!name && !IsLevelOrNoiseText(t) && ![t containsString:@"在线"] && ![t containsString:@"离线"]) {
            name = t;
        }
    }
    if (name.length > 0) {
        NSString *key = acc.length >= 4 ? acc : name;
        HOModelItem *item = _contactFriendsMap[key] ?: [[HOModelItem alloc] init];
        item.itemId = key;
        item.account = acc ?: key;
        item.name = name;
        item.source = @"通讯录好友";
        item.isGroup = NO;
        UIImage *img = ExtractAvatarImage(cell);
        if (img && !item.avatarData) item.avatarData = UIImagePNGRepresentation(img);
        _contactFriendsMap[key] = item;
    }
}

#pragma mark - 内置排行榜接口批量抓取

- (void)startBuiltInRankInterfaceFetch:(void (^)(NSUInteger, NSString *))progressBlock {
    _onRankCountUpdated = progressBlock;
    if (_isFetchingRankInBg) {
        [self stopBuiltInRankInterfaceFetch];
        return;
    }
    _isFetchingRankInBg = YES;
    [_hiddenRankItemVCs removeAllObjects];
    
    Class rankItemCls = objc_getClass("_TtC7ZhengDu25ZDGlobalTopItemController");
    if (rankItemCls) {
        UIWindow *keyWin = [UIApplication sharedApplication].keyWindow;
        for (uint8_t t = 0; t <= 2; t++) {
            UIViewController *vc = [[rankItemCls alloc] init];
            if (vc) {
                ptrdiff_t typeOff = GetRealIvarOffset(rankItemCls, "zd_type");
                if (typeOff > 0) *((uint8_t *)(__bridge void *)vc + typeOff) = t;
                
                ptrdiff_t sizeOff = GetRealIvarOffset(rankItemCls, "zd_size");
                if (sizeOff > 0) *(NSInteger *)((uint8_t *)(__bridge void *)vc + sizeOff) = 500;
                
                vc.view.frame = CGRectMake(-2000, -2000, 390, 844);
                [keyWin addSubview:vc.view];
                if ([vc respondsToSelector:NSSelectorFromString(@"zd_willShowVC")]) {
                    ((void (*)(id, SEL))objc_msgSend)(vc, NSSelectorFromString(@"zd_willShowVC"));
                }
                [_hiddenRankItemVCs addObject:vc];
            }
        }
    }
    
    if (_onRankCountUpdated) {
        _onRankCountUpdated(_rankUsersMap.count, @"🔄 正在后台同时请求【日榜+周榜+总榜】接口数据...");
    }
    _bgRankFetchTimer = [NSTimer scheduledTimerWithTimeInterval:1.8 target:self selector:@selector(stepBgRankFetch) userInfo:nil repeats:YES];
}

- (void)stopBuiltInRankInterfaceFetch {
    _isFetchingRankInBg = NO;
    if (_bgRankFetchTimer) {
        [_bgRankFetchTimer invalidate];
        _bgRankFetchTimer = nil;
    }
    for (UIViewController *vc in _hiddenRankItemVCs) {
        [vc.view removeFromSuperview];
    }
    [_hiddenRankItemVCs removeAllObjects];
    [self saveToDisk];
    if (_onRankCountUpdated) {
        _onRankCountUpdated(_rankUsersMap.count, [NSString stringWithFormat:@"✅ 排行榜接口抓取完成！共获取 %lu 名真实用户", (unsigned long)_rankUsersMap.count]);
    }
}

- (void)stepBgRankFetch {
    if (!_isFetchingRankInBg || _hiddenRankItemVCs.count == 0) {
        [self stopBuiltInRankInterfaceFetch];
        return;
    }
    Class rankItemCls = objc_getClass("_TtC7ZhengDu25ZDGlobalTopItemController");
    ptrdiff_t collectOff = GetRealIvarOffset(rankItemCls, "$__lazy_storage_$_zd_collect");
    
    for (UIViewController *vc in _hiddenRankItemVCs) {
        UICollectionView *cv = nil;
        if (collectOff > 0) {
            cv = *(UICollectionView * __unsafe_unretained *)((uint8_t *)(__bridge void *)vc + collectOff);
        }
        if (![cv isKindOfClass:[UICollectionView class]]) {
            for (UIView *sub in vc.view.subviews) {
                if ([sub isKindOfClass:[UICollectionView class]]) { cv = (UICollectionView *)sub; break; }
            }
        }
        if ([cv isKindOfClass:[UICollectionView class]]) {
            for (UICollectionViewCell *cell in cv.visibleCells) {
                NSIndexPath *ip = [cv indexPathForCell:cell];
                [self harvestRankCell:cell indexPath:ip rankVC:vc];
            }
            CGFloat nextY = cv.contentOffset.y + cv.bounds.size.height * 0.9;
            CGFloat maxY  = MAX(0, cv.contentSize.height - cv.bounds.size.height);
            if (nextY < maxY) {
                [cv setContentOffset:CGPointMake(0, nextY) animated:NO];
                [cv layoutIfNeeded];
            } else {
                [cv setContentOffset:CGPointMake(0, 0) animated:NO];
                @try {
                    id footer = [cv valueForKey:@"mj_footer"];
                    if (footer && [footer respondsToSelector:NSSelectorFromString(@"beginRefreshing")]) {
                        ((void (*)(id, SEL))objc_msgSend)(footer, NSSelectorFromString(@"beginRefreshing"));
                    }
                } @catch (NSException *e) {}
            }
        }
    }
    if (_onRankCountUpdated) {
        _onRankCountUpdated(_rankUsersMap.count, [NSString stringWithFormat:@"🚀 正在从日榜/周榜/总榜接口抓取中... (已抓 %lu 人)", (unsigned long)_rankUsersMap.count]);
    }
}

- (void)openAddFriendPageForItem:(HOModelItem *)item fromVC:(UIViewController *)fromVC {
    if (!item || !fromVC) return;
    NSString *pureAcc = ExtractPureASCIIAccount(item.account) ?: ExtractPureASCIIAccount(item.itemId);
    if (!pureAcc) return;
    [UIPasteboard generalPasteboard].string = pureAcc;
    
    UINavigationController *nav = fromVC.navigationController;
    if (!nav && [fromVC isKindOfClass:[UINavigationController class]]) nav = (UINavigationController *)fromVC;
    
    Class addVCCls = objc_getClass("_TtC7ZhengDu28ZDAddFriendOrGroupController");
    if (addVCCls && nav) {
        UIViewController *addVC = [[addVCCls alloc] init];
        if (addVC) {
            addVC.hidesBottomBarWhenPushed = YES;
            [nav pushViewController:addVC animated:YES];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                UITextField *tf = [self findTextFieldInView:addVC.view];
                if (tf) {
                    tf.text = pureAcc;
                    [tf becomeFirstResponder];
                    [tf sendActionsForControlEvents:UIControlEventEditingChanged];
                    if (tf.delegate && [tf.delegate respondsToSelector:@selector(textFieldShouldReturn:)]) {
                        [tf.delegate textFieldShouldReturn:tf];
                    }
                }
            });
        }
    }
}

- (UITextField *)findTextFieldInView:(UIView *)view {
    if (!view) return nil;
    if ([view isKindOfClass:[UITextField class]]) return (UITextField *)view;
    for (UIView *sub in view.subviews) {
        UITextField *tf = [self findTextFieldInView:sub];
        if (tf) return tf;
    }
    return nil;
}

@end

#pragma mark - ==================== 5. 群发助手 UI 面板 ====================

@interface HOMassHelperViewController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UISegmentedControl *tabSegment;
@property (nonatomic, strong) UIButton *rankFetchBtn;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<HOModelItem *> *currentList;
@end

@implementation HOMassHelperViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"群发助手 (com.zhengdu.haiou)";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"返回" style:UIBarButtonItemStylePlain target:self action:@selector(closeSelf)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"清空重采" style:UIBarButtonItemStylePlain target:self action:@selector(clearAllConfirm)];
    
    [self buildUI];
    [self refreshTableList];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [[HOMassEngine shared] stopBuiltInRankInterfaceFetch];
}

- (void)closeSelf {
    if (self.navigationController && self.navigationController.viewControllers.firstObject != self) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)buildUI {
    CGFloat y = 94;
    CGFloat w = self.view.bounds.size.width;
    
    UIButton *nativeSendBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    nativeSendBtn.frame = CGRectMake(12, y, (w - 32) * 0.48, 40);
    [nativeSendBtn setTitle:@"📨 官方原生群发通道" forState:UIControlStateNormal];
    nativeSendBtn.backgroundColor = [UIColor systemBlueColor];
    [nativeSendBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    nativeSendBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    nativeSendBtn.layer.cornerRadius = 8;
    [nativeSendBtn addTarget:self action:@selector(onTapNativeSend) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:nativeSendBtn];
    
    _rankFetchBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _rankFetchBtn.frame = CGRectMake(12 + (w - 32) * 0.48 + 8, y, (w - 32) * 0.52, 40);
    [_rankFetchBtn setTitle:@"🏆 接口抓取排行榜人员" forState:UIControlStateNormal];
    _rankFetchBtn.backgroundColor = [UIColor systemIndigoColor];
    [_rankFetchBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _rankFetchBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    _rankFetchBtn.layer.cornerRadius = 8;
    [_rankFetchBtn addTarget:self action:@selector(onTapBuiltInRankFetch) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_rankFetchBtn];
    y += 48;
    
    _tabSegment = [[UISegmentedControl alloc] initWithItems:@[@"🏆排行榜人员", @"👥提取的群成员", @"🏠我的群聊", @"📒通讯录好友"]];
    _tabSegment.frame = CGRectMake(12, y, w - 24, 34);
    _tabSegment.selectedSegmentIndex = 0;
    [_tabSegment addTarget:self action:@selector(refreshTableList) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:_tabSegment];
    y += 42;
    
    CGFloat bw = (w - 34) / 3.0;
    NSArray *bTitles = @[@"🔓去群聊提取全员", @"🔄去排行榜页面", @"📋复制当前海鸥号"];
    SEL bSels[] = {@selector(goMyGroupsPage), @selector(goNativeRankPage), @selector(copyCurrentAccounts)};
    for (int i = 0; i < 3; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(12 + i * (bw + 5), y, bw, 30);
        [b setTitle:bTitles[i] forState:UIControlStateNormal];
        b.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        [b setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        b.layer.cornerRadius = 6;
        [b addTarget:self action:bSels[i] forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:b];
    }
    y += 36;
    
    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, y, w - 28, 20)];
    _statusLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    _statusLabel.textColor = [UIColor systemOrangeColor];
    [self.view addSubview:_statusLabel];
    y += 22;
    
    _tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, y, w, self.view.bounds.size.height - y) style:UITableViewStylePlain];
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.rowHeight = 62;
    [self.view addSubview:_tableView];
}

- (void)onTapBuiltInRankFetch {
    _tabSegment.selectedSegmentIndex = 0;
    __weak typeof(self) weakSelf = self;
    [[HOMassEngine shared] startBuiltInRankInterfaceFetch:^(NSUInteger count, NSString *status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.statusLabel.text = status;
            BOOL running = [HOMassEngine shared].isFetchingRankInBg;
            weakSelf.rankFetchBtn.backgroundColor = running ? [UIColor systemRedColor] : [UIColor systemIndigoColor];
            [weakSelf.rankFetchBtn setTitle:running ? @"🛑 停止抓取(实时入库中)" : @"🏆 接口抓取排行榜人员" forState:UIControlStateNormal];
            [weakSelf refreshTableList];
        });
    }];
}

- (void)onTapNativeSend {
    Class cls = objc_getClass("_TtC7ZhengDu28ZDGroupSendMessageController");
    if (cls && self.navigationController) {
        UIViewController *vc = [[cls alloc] init];
        vc.hidesBottomBarWhenPushed = YES;
        [self.navigationController pushViewController:vc animated:YES];
    }
}

- (void)goMyGroupsPage {
    Class cls = objc_getClass("_TtC7ZhengDu19ZDMyGroupController");
    if (cls && self.navigationController) {
        UIViewController *vc = [[cls alloc] init];
        vc.hidesBottomBarWhenPushed = YES;
        [self.navigationController pushViewController:vc animated:YES];
    }
}

- (void)goNativeRankPage {
    Class cls = objc_getClass("_TtC7ZhengDu21ZDGlobalTopController");
    if (cls && self.navigationController) {
        UIViewController *vc = [[cls alloc] init];
        vc.hidesBottomBarWhenPushed = YES;
        [self.navigationController pushViewController:vc animated:YES];
    }
}

- (void)copyCurrentAccounts {
    if (_currentList.count == 0) return;
    NSMutableString *s = [NSMutableString string];
    for (HOModelItem *item in _currentList) {
        [s appendFormat:@"%@\n", item.account ?: item.itemId];
    }
    [UIPasteboard generalPasteboard].string = s;
    _statusLabel.text = [NSString stringWithFormat:@"✅ 已复制 %lu 个纯海鸥号到剪贴板！", (unsigned long)_currentList.count];
}

- (void)clearAllConfirm {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"清空全部采集数据" message:@"确定清空并重新采集吗？" preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"确定清空" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [[HOMassEngine shared] clearAllData];
        [self refreshTableList];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)refreshTableList {
    HOMassEngine *eng = [HOMassEngine shared];
    NSInteger idx = _tabSegment.selectedSegmentIndex;
    if (idx == 0) {
        _currentList = [eng.rankUsersMap.allValues sortedArrayUsingComparator:^NSComparisonResult(HOModelItem *a, HOModelItem *b) {
            return a.collectSeq > b.collectSeq ? NSOrderedAscending : NSOrderedDescending;
        }];
        if (!eng.isFetchingRankInBg) {
            _statusLabel.text = [NSString stringWithFormat:@"🏆【排行榜人员】共 %lu 人 (点右上紫色按钮自动抓日榜+周榜+总榜，点人名直接加他)", (unsigned long)_currentList.count];
        }
    } else if (idx == 1) {
        _currentList = [eng.groupMembersMap.allValues sortedArrayUsingComparator:^NSComparisonResult(HOModelItem *a, HOModelItem *b) {
            return a.collectSeq > b.collectSeq ? NSOrderedAscending : NSOrderedDescending;
        }];
        _statusLabel.text = [NSString stringWithFormat:@"👥【群聊成员】共 %lu 人 (进任何群点右上角...进群设置即可自动以群主权限提取全员)", (unsigned long)_currentList.count];
    } else if (idx == 2) {
        _currentList = [eng.joinedGroupsMap.allValues sortedArrayUsingComparator:^NSComparisonResult(HOModelItem *a, HOModelItem *b) {
            return [a.name compare:b.name];
        }];
        _statusLabel.text = [NSString stringWithFormat:@"🏠【我的群聊】共 %lu 个群 (已全部自动解锁群主权限)", (unsigned long)_currentList.count];
    } else {
        _currentList = [eng.contactFriendsMap.allValues sortedArrayUsingComparator:^NSComparisonResult(HOModelItem *a, HOModelItem *b) {
            return [a.name compare:b.name];
        }];
        _statusLabel.text = [NSString stringWithFormat:@"📒【通讯录好友】共 %lu 人", (unsigned long)_currentList.count];
    }
    [_tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _currentList.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"HOAvatarCellV6";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.imageView.layer.cornerRadius = 22;
        cell.imageView.layer.masksToBounds = YES;
    }
    HOModelItem *item = _currentList[indexPath.row];
    cell.textLabel.text = [NSString stringWithFormat:@"%ld. %@", (long)(indexPath.row + 1), item.name];
    cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"纯海鸥号: %@   |   %@   👉点击搜索添加", item.account ?: item.itemId, item.source];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    
    UIImage *avatarImg = item.avatarData ? [UIImage imageWithData:item.avatarData] : nil;
    if (!avatarImg) {
        if (@available(iOS 13.0, *)) {
            avatarImg = [UIImage systemImageNamed:item.isGroup ? @"person.3.fill" : @"person.crop.circle.fill"];
        }
        if (item.avatarUrl.length > 8 && [item.avatarUrl hasPrefix:@"http"]) {
            NSURL *u = [NSURL URLWithString:item.avatarUrl];
            if (u) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    NSData *d = [NSData dataWithContentsOfURL:u];
                    if (d) {
                        item.avatarData = d;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
                        });
                    }
                });
            }
        }
    }
    
    CGSize sz = CGSizeMake(44, 44);
    UIGraphicsBeginImageContextWithOptions(sz, NO, UIScreen.mainScreen.scale);
    [avatarImg drawInRect:CGRectMake(0, 0, sz.width, sz.height)];
    cell.imageView.image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    HOModelItem *item = _currentList[indexPath.row];
    [[HOMassEngine shared] openAddFriendPageForItem:item fromVC:self];
}

@end

#pragma mark - ==================== 6. 业务页面 Hook 实现 (严格单次交换) ====================

static void ho_openMassHelperFromMine(UIViewController *mineVC) {
    if (!mineVC) return;
    HOMassHelperViewController *vc = [[HOMassHelperViewController alloc] init];
    vc.hidesBottomBarWhenPushed = YES;
    if (mineVC.navigationController) {
        [mineVC.navigationController pushViewController:vc animated:YES];
    } else {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        [mineVC presentViewController:nav animated:YES completion:nil];
    }
}

static void ho_mine_onTapEmbeddedMassBtn(id self, SEL _cmd, UIButton *sender) {
    ho_openMassHelperFromMine((UIViewController *)self);
}

static IMP orig_mine_cellForRow = NULL;
static UITableViewCell *hook_mine_cellForRow(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    UITableViewCell *cell = ((UITableViewCell *(*)(id, SEL, UITableView *, NSIndexPath *))orig_mine_cellForRow)(self, _cmd, tableView, indexPath);
    if (cell) {
        BOOL isHaiouHelperRow = NO;
        for (UIView *sub in cell.contentView.subviews) {
            if ([sub isKindOfClass:[UILabel class]] && [[(UILabel *)sub text] containsString:@"海鸥助手"]) {
                isHaiouHelperRow = YES;
                break;
            }
        }
        UIButton *embedBtn = [cell.contentView viewWithTag:99881];
        if (isHaiouHelperRow) {
            if (!embedBtn) {
                embedBtn = [UIButton buttonWithType:UIButtonTypeSystem];
                embedBtn.tag = 99881;
                embedBtn.frame = CGRectMake(UIScreen.mainScreen.bounds.size.width - 135, 10, 96, 32);
                embedBtn.backgroundColor = [UIColor systemBlueColor];
                [embedBtn setTitle:@"🚀群发助手" forState:UIControlStateNormal];
                [embedBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
                embedBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
                embedBtn.layer.cornerRadius = 16;
                [embedBtn addTarget:self action:NSSelectorFromString(@"ho_mine_onTapEmbeddedMassBtn:") forControlEvents:UIControlEventTouchUpInside];
                [cell.contentView addSubview:embedBtn];
            }
            embedBtn.hidden = NO;
            [cell.contentView bringSubviewToFront:embedBtn];
        } else {
            if (embedBtn) embedBtn.hidden = YES;
        }
        
        if (!tableView.tableFooterView || tableView.tableFooterView.tag != 99882) {
            UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, UIScreen.mainScreen.bounds.size.width, 60)];
            footer.tag = 99882;
            UIButton *fBtn = [UIButton buttonWithType:UIButtonTypeSystem];
            fBtn.frame = CGRectMake(16, 8, UIScreen.mainScreen.bounds.size.width - 32, 44);
            fBtn.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
            [fBtn setTitle:@"✈️ 打开【海鸥群发与排行榜拓客助手】" forState:UIControlStateNormal];
            [fBtn setTitleColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
            fBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
            fBtn.layer.cornerRadius = 10;
            [fBtn addTarget:self action:NSSelectorFromString(@"ho_mine_onTapEmbeddedMassBtn:") forControlEvents:UIControlEventTouchUpInside];
            [footer addSubview:fBtn];
            tableView.tableFooterView = footer;
        }
    }
    return cell;
}

static IMP orig_chat_viewWillAppear = NULL;
static void hook_chat_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    [[HOMassEngine shared] applyGroupOwnerOnVC:(UIViewController *)self];
    if (orig_chat_viewWillAppear) {
        ((void (*)(id, SEL, BOOL))orig_chat_viewWillAppear)(self, _cmd, animated);
    }
    [[HOMassEngine shared] applyGroupOwnerOnVC:(UIViewController *)self];
}

static IMP orig_groupSet_viewWillAppear = NULL;
static void hook_groupSet_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    UIViewController *vc = (UIViewController *)self;
    [[HOMassEngine shared] applyGroupOwnerOnVC:vc];
    if (orig_groupSet_viewWillAppear) {
        ((void (*)(id, SEL, BOOL))orig_groupSet_viewWillAppear)(self, _cmd, animated);
    }
    [[HOMassEngine shared] applyGroupOwnerOnVC:vc];
    vc.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"👥全体成员" style:UIBarButtonItemStyleDone target:vc action:NSSelectorFromString(@"ho_forceOpenMemberListVC")];
}

static void ho_forceOpenMemberListVC_imp(id self, SEL _cmd) {
    UIViewController *vc = (UIViewController *)self;
    Class memberListCls = objc_getClass("_TtC7ZhengDu37ZDConversationGroupMemberListController");
    if (memberListCls && vc.navigationController) {
        UIViewController *listVC = [[memberListCls alloc] init];
        if (listVC) {
            unsigned int c1 = 0, c2 = 0;
            Ivar *ivars1 = class_copyIvarList([vc class], &c1);
            Ivar *ivars2 = class_copyIvarList(memberListCls, &c2);
            uint8_t *base1 = (__bridge void *)vc;
            uint8_t *base2 = (__bridge void *)listVC;
            if (ivars1 && ivars2) {
                for (unsigned int i = 0; i < c1; i++) {
                    ptrdiff_t off1 = ivar_getOffset(ivars1[i]);
                    uintptr_t ptr = *(uintptr_t *)(base1 + off1);
                    if (ptr > 0x100000000ULL && (ptr & 0x7) == 0) {
                        id obj = (__bridge id)(void *)ptr;
                        NSString *cn = NSStringFromClass([obj class]);
                        if ([cn containsString:@"ZDGroup"] || [cn containsString:@"ZDSession"]) {
                            for (unsigned int j = 0; j < c2; j++) {
                                const char *n2 = ivar_getName(ivars2[j]);
                                ptrdiff_t off2 = ivar_getOffset(ivars2[j]);
                                if (n2 && off2 > 0) {
                                    NSString *s2 = [NSString stringWithUTF8String:n2];
                                    if (([cn containsString:@"ZDGroup"] && [s2.lowercaseString containsString:@"group"]) ||
                                        ([cn containsString:@"ZDSession"] && [s2.lowercaseString containsString:@"session"])) {
                                        *(id __strong *)(base2 + off2) = obj;
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if (ivars1) free(ivars1);
            if (ivars2) free(ivars2);
            [vc.navigationController pushViewController:listVC animated:YES];
        }
    }
}

static IMP orig_rank_cellForItem = NULL;
static UICollectionViewCell *hook_rank_cellForItem(id self, SEL _cmd, UICollectionView *cv, NSIndexPath *indexPath) {
    UICollectionViewCell *cell = ((UICollectionViewCell *(*)(id, SEL, UICollectionView *, NSIndexPath *))orig_rank_cellForItem)(self, _cmd, cv, indexPath);
    if (cell) {
        UIViewController *vc = (UIViewController *)self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[HOMassEngine shared] harvestRankCell:cell indexPath:indexPath rankVC:vc];
        });
    }
    return cell;
}

static IMP orig_tv_dequeue = NULL;
static UITableViewCell *hook_tv_dequeue(UITableView *self, SEL _cmd, NSString *identifier, NSIndexPath *indexPath) {
    UITableViewCell *cell = ((UITableViewCell *(*)(UITableView *, SEL, NSString *, NSIndexPath *))orig_tv_dequeue)(self, _cmd, identifier, indexPath);
    if (cell && [NSStringFromClass([cell class]) containsString:@"ZDContactCell"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[HOMassEngine shared] harvestContactCell:cell];
        });
    }
    return cell;
}

static IMP orig_group_init = NULL;
static id hook_group_init(id self, SEL _cmd) {
    id ins = ((id (*)(id, SEL))orig_group_init)(self, _cmd);
    if (ins) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[HOMassEngine shared] harvestGroupObject:ins];
        });
    }
    return ins;
}

static IMP orig_member_init = NULL;
static id hook_member_init(id self, SEL _cmd) {
    id ins = ((id (*)(id, SEL))orig_member_init)(self, _cmd);
    if (ins) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[HOMassEngine shared] harvestGroupMemberObject:ins];
        });
    }
    return ins;
}

// 拦截“关于我们”页面，将显示的包名/标识强制显示为官方 com.zhengdu.haiou
static IMP orig_about_viewDidAppear = NULL;
static void hook_about_viewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    if (orig_about_viewDidAppear) {
        ((void (*)(id, SEL, BOOL))orig_about_viewDidAppear)(self, _cmd, animated);
    }
    self.title = @"关于海鸥 (com.zhengdu.haiou)";
}

#pragma mark - ==================== 7. Dylib 构造函数入口 (严格单次挂载) ====================

__attribute__((constructor))
static void HaiouMassHelperV6Init(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        static dispatch_once_t mainOnceToken;
        dispatch_once(&mainOnceToken, ^{
            // 1. 屏蔽开屏广告
            SetupAdBlockerOnce();
            
            // 2. 挂载「我的」页面 ZDMineController
            Class mineCls = objc_getClass("_TtC7ZhengDu16ZDMineController");
            if (mineCls) {
                class_addMethod(mineCls, NSSelectorFromString(@"ho_mine_onTapEmbeddedMassBtn:"), (IMP)ho_mine_onTapEmbeddedMassBtn, "v@:@");
                SafeHookInstanceMethodOnce(mineCls, @selector(tableView:cellForRowAtIndexPath:), (IMP)hook_mine_cellForRow, &orig_mine_cellForRow);
            }
            
            // 3. 挂载聊天页与群设置页 (强制模拟群主 + 提取群成员)
            Class chatCls = objc_getClass("_TtC7ZhengDu25ZDConversationController1");
            if (chatCls) {
                SafeHookInstanceMethodOnce(chatCls, @selector(viewWillAppear:), (IMP)hook_chat_viewWillAppear, &orig_chat_viewWillAppear);
            }
            
            Class groupSetCls = objc_getClass("_TtC7ZhengDu30ZDConversationGroupSetController");
            if (groupSetCls) {
                class_addMethod(groupSetCls, NSSelectorFromString(@"ho_forceOpenMemberListVC"), (IMP)ho_forceOpenMemberListVC_imp, "v@:");
                SafeHookInstanceMethodOnce(groupSetCls, @selector(viewWillAppear:), (IMP)hook_groupSet_viewWillAppear, &orig_groupSet_viewWillAppear);
            }
            
            // 4. 挂载排行榜 ZDGlobalTopItemController
            Class rankItemCls = objc_getClass("_TtC7ZhengDu25ZDGlobalTopItemController");
            if (rankItemCls) {
                DisableMethodWithNoop(rankItemCls, NSSelectorFromString(@"zd_clickUpgrade"), (IMP)ad_noop_0);
                SafeHookInstanceMethodOnce(rankItemCls, @selector(collectionView:cellForItemAtIndexPath:), (IMP)hook_rank_cellForItem, &orig_rank_cellForItem);
            }
            
            // 5. 挂载通讯录 Cell、ZDGroup、ZDGroupMember
            SafeHookInstanceMethodOnce([UITableView class], @selector(dequeueReusableCellWithIdentifier:forIndexPath:), (IMP)hook_tv_dequeue, &orig_tv_dequeue);
            
            Class grpCls = objc_getClass("_TtC7ZhengDu7ZDGroup");
            if (grpCls) {
                SafeHookInstanceMethodOnce(grpCls, @selector(init), (IMP)hook_group_init, &orig_group_init);
            }
            
            Class memCls = objc_getClass("_TtC7ZhengDu13ZDGroupMember");
            if (memCls) {
                SafeHookInstanceMethodOnce(memCls, @selector(init), (IMP)hook_member_init, &orig_member_init);
            }
            
            Class aboutCls = objc_getClass("_TtC7ZhengDu19ZDAboutUsController");
            if (aboutCls) {
                SafeHookInstanceMethodOnce(aboutCls, @selector(viewDidAppear:), (IMP)hook_about_viewDidAppear, &orig_about_viewDidAppear);
            }
        });
    });
}

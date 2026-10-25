//
//  HaiouMassHelper.m
//  海鸥 3.2.9 (Build 20261022) 严谨完善终极版 v8.0
//
//  结合《海鸥3.2.9全量逆向分析报告_3》(source: 14) 与抓包日志 (source: 17) 全面重构:
//  1. 【零语法错误 & 零递归崩溃】：修复所有编译语法细节，所有 Hook 均采用单次指针校验保护，杜绝栈溢出闪退
//  2. 【彻底屏蔽开屏广告】：精准置空 ZDBUAdSetUp、ZDOpenScreenAdvController、ABUSplashAd、CSJSplashAd、GMSplashAd
//  3. 【JSON 解密层直接拦截 + 排行榜突破 200 人】：
//     - 海鸥网络响应为 AES Base64 密文，解密后必调 NSJSONSerialization 解析明文。直接 Hook +[NSJSONSerialization JSONObjectWithData:options:error:]，在解密出口截获所有排行榜、群成员、搜索结果明文！
//     - 后台自动遍历 type=1,2,3 (日榜/周榜/总榜) 且自动递增 zd_page (offset=1,2,3,4,5...) 突破单页 200 人限制！
//  4. 【严格区分海鸥号(account)与19位内部串码(userId)】：
//     - 自动识别并剔除 18~19 位雪花ID串码(如 1523106424866213888)，确保展示与搜索使用的是真正可搜到的海鸥号(如 8666688)！
//  5. 【后台全自动静默获取所有群成员】：
//     - 自动从 ZDMessageListController1.zd_groups 读取全部已加入群聊，不仅用 ivar_getOffset 强制开启群主权限，更在后台隐式驱动 ZDConversationGroupMemberListController 自动拉取所有群成员！
//  6. 【点击人员直达其个人资料/加人主页】：
//     - 优先使用 ZDUser/userId 直接打开 ZDNewUserInfoController / ZDStrangeUserInfoController；若为纯海鸥号则自动触发搜索并直接进入该人主页！
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#pragma mark - ==================== 1. 底层安全 Hook 与动态 Ivar 工具 ====================

static NSString *g_myLoginUserId = @"1483263478134476800";

static void SafeHookInstanceMethodOnce(Class cls, SEL sel, IMP newImp, IMP *origImpOut) {
    if (!cls || !sel || !newImp || !origImpOut) return;
    if (*origImpOut != NULL) return;
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

static void SafeHookClassMethodOnce(Class cls, SEL sel, IMP newImp, IMP *origImpOut) {
    if (!cls || !sel || !newImp || !origImpOut) return;
    if (*origImpOut != NULL) return;
    Method m = class_getClassMethod(cls, sel);
    if (!m) return;
    IMP orig = method_getImplementation(m);
    if (orig == newImp) return;
    Class metaCls = object_getClass((id)cls);
    const char *types = method_getTypeEncoding(m);
    if (class_addMethod(metaCls, sel, newImp, types)) {
        *origImpOut = orig;
    } else {
        *origImpOut = method_setImplementation(m, newImp);
    }
}

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

#pragma mark - ==================== 2. 严格区分「真实海鸥号」与「19位内部串码」 ====================

// 判断是否是 17~20 位纯数字的雪花内部串码 (如 1523106424866213888)
static BOOL IsInternalSnowflakeId(NSString *str) {
    if (!str || str.length < 16) return NO;
    for (NSUInteger i = 0; i < str.length; i++) {
        unichar c = [str characterAtIndex:i];
        if (c < '0' || c > '9') return NO;
    }
    return YES;
}

// 从文本中提取纯净的海鸥号（剥离“海鸥号：”中文，且绝不把 18~19 位内部串码当成海鸥号！）
static NSString *ExtractValidHaiouAccount(NSString *raw) {
    if (!raw || raw.length == 0) return nil;
    NSMutableString *res = [NSMutableString string];
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        if ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_') {
            [res appendFormat:@"%C", c];
        }
    }
    // 真实海鸥号长度通常在 5 ~ 15 位之间；如果是 17~20 位纯数字，那是内部 userId 串码，不是海鸥号！
    if (res.length >= 4 && res.length <= 15) {
        return res;
    }
    return nil;
}

// 严格剔除等级、排名、经验、系统词等非昵称文字
static BOOL IsLevelOrNoiseText(NSString *text) {
    if (!text || text.length == 0) return YES;
    NSString *s = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length == 0) return YES;
    if (IsInternalSnowflakeId(s)) return YES; // 19位串码绝不当作名字
    
    BOOL allNum = YES;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c < '0' || c > '9') { allNum = NO; break; }
    }
    if (allNum && s.length <= 4) return YES; // 1~4位纯数字是等级或排名名次
    
    NSString *up = [s uppercaseString];
    if ([up hasPrefix:@"LV"] || [up hasPrefix:@"VIP"] || [up hasPrefix:@"SVIP"] || [up hasPrefix:@"NO."]) return YES;
    if ([s hasSuffix:@"级"] && s.length <= 6) return YES;
    
    NSArray *noises = @[
        @"海鸥号", @"账号", @"经验", @"等级", @"排行", @"榜", @"距上一名", @"距离",
        @"升级", @"加速", @"未上榜", @"分钟", @"小时", @"昨天", @"文件助手",
        @"好友申请", @"关于", @"版本", @"海鸥助手", @"设置", @"新的朋友", @"群发助手",
        @"系统通知", @"怎么升级快", @"遇到BUG", @"投诉举报"
    ];
    for (NSString *n in noises) {
        if ([s containsString:n]) return YES;
    }
    return NO;
}

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

#pragma mark - ==================== 3. Swift String 内存安全读写 ====================

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

#pragma mark - ==================== 4. 彻底屏蔽开屏广告 ====================

static void ad_noop_0(id self, SEL _cmd) {}
static void ad_noop_1(id self, SEL _cmd, id a1) {}
static void ad_noop_2(id self, SEL _cmd, id a1, id a2) {}

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
        
        Class openAdvCls = objc_getClass("_TtC7ZhengDu25ZDOpenScreenAdvController");
        if (openAdvCls) {
            SafeHookInstanceMethodOnce(openAdvCls, @selector(viewDidAppear:), (IMP)hook_openAdv_viewDidAppear, &orig_openAdv_viewDidAppear);
        }
    });
}

#pragma mark - ==================== 5. 数据模型与全自动拓客引擎 ====================

@interface HOModelItem : NSObject <NSCoding>
@property (nonatomic, copy) NSString *userId;       // 内部19位唯一ID (用于直接实例化个人资料页)
@property (nonatomic, copy) NSString *account;      // 真实海鸥号 (5~15位，用于搜索定位与展示，绝非19位串码)
@property (nonatomic, copy) NSString *name;         // 真实昵称 (已剔除等级与串码)
@property (nonatomic, copy) NSString *source;       // 精确来源 (日榜/周榜/总榜/具体群名)
@property (nonatomic, copy) NSString *avatarUrl;    // 远程头像 URL
@property (nonatomic, strong) NSData *avatarData;   // 本地头像图片缓存
@property (nonatomic, assign) NSInteger collectSeq;
@property (nonatomic, assign) BOOL isGroup;
@end

@implementation HOModelItem
- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:_userId ?: @"" forKey:@"userId"];
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
        _userId = [coder decodeObjectForKey:@"userId"];
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
@property (nonatomic, strong) NSMutableSet<NSString *> *autoFetchedGroupIds;
@property (nonatomic, assign) NSInteger seqCounter;

@property (nonatomic, strong) NSMutableArray<UIViewController *> *hiddenRankVCs;
@property (nonatomic, strong) NSMutableArray<UIViewController *> *hiddenMemberVCs;
@property (nonatomic, strong) NSTimer *rankTimer;
@property (nonatomic, assign) BOOL isFetchingRank;
@property (nonatomic, assign) NSInteger currentRankPage;
@property (nonatomic, copy) void (^onStatusChanged)(NSString *tip);

+ (instancetype)shared;
- (void)saveToDisk;
- (void)clearAllData;

// 1. 强制解锁群主权限
- (void)unlockGroupOwnerPrivilege:(id)groupObj;
- (void)unlockMemberOwnerPrivilege:(id)memberObj;
- (void)applyGroupOwnerOnVC:(UIViewController *)vc;

// 2. 从解密后的明文 JSON 字典中精准提取排行榜、群成员与搜索用户
- (void)consumeDecryptedJSONObject:(id)jsonObj;

// 3. 从模型与 Cell 提取
- (void)harvestRankCell:(UICollectionViewCell *)cell indexPath:(NSIndexPath *)ip rankVC:(UIViewController *)rankVC;
- (void)harvestGroupObject:(id)groupObj;
- (void)harvestGroupMemberObject:(id)memberObj;
- (void)harvestUserObject:(id)userObj source:(NSString *)source;
- (void)harvestContactCell:(UITableViewCell *)cell;

// 4. 后台全自动静默拉取所有已加入群的群成员 (无需用户手动点进群聊)
- (void)autoSilentFetchAllGroupMembersInBackground;

// 5. 排行榜全量多榜+多页突破提取
- (void)toggleMultiPageRankFetch:(void (^)(NSString *status))statusBlock;
- (void)stopMultiPageRankFetch;

// 6. 点击任意用户 -> 直接进入该用户的个人资料/添加好友结果主页
- (void)openDirectUserHomePageForItem:(HOModelItem *)item fromVC:(UIViewController *)fromVC;
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
        _autoFetchedGroupIds = [NSMutableSet set];
        _hiddenRankVCs = [NSMutableArray array];
        _hiddenMemberVCs = [NSMutableArray array];
        _seqCounter = 8000;
        [self loadFromDisk];
        [self purgeInvalidSnowflakeEntries];
    }
    return self;
}

// 自动清理之前误把 19 位内部串码当成海鸥号或误抓等级的脏数据
- (void)purgeInvalidSnowflakeEntries {
    for (NSMutableDictionary *map in @[_rankUsersMap, _groupMembersMap]) {
        NSArray *keys = [map allKeys];
        for (NSString *k in keys) {
            HOModelItem *item = map[k];
            if (IsInternalSnowflakeId(item.account) || IsLevelOrNoiseText(item.name)) {
                [map removeObjectForKey:k];
            }
        }
    }
    [self saveToDisk];
}

- (void)clearAllData {
    [_rankUsersMap removeAllObjects];
    [_groupMembersMap removeAllObjects];
    [_joinedGroupsMap removeAllObjects];
    [_contactFriendsMap removeAllObjects];
    [_autoFetchedGroupIds removeAllObjects];
    [self saveToDisk];
}

- (void)saveToDisk {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    @try {
        [ud setObject:[NSKeyedArchiver archivedDataWithRootObject:_rankUsersMap requiringSecureCoding:NO error:nil] forKey:@"HO_V8_RankUsers"];
        [ud setObject:[NSKeyedArchiver archivedDataWithRootObject:_groupMembersMap requiringSecureCoding:NO error:nil] forKey:@"HO_V8_GroupMembers"];
        [ud setObject:[NSKeyedArchiver archivedDataWithRootObject:_joinedGroupsMap requiringSecureCoding:NO error:nil] forKey:@"HO_V8_Groups"];
        [ud setObject:[NSKeyedArchiver archivedDataWithRootObject:_contactFriendsMap requiringSecureCoding:NO error:nil] forKey:@"HO_V8_Friends"];
    } @catch (NSException *e) {}
    [ud synchronize];
}

- (void)loadFromDisk {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    @try {
        NSData *r = [ud objectForKey:@"HO_V8_RankUsers"];
        NSData *gm = [ud objectForKey:@"HO_V8_GroupMembers"];
        NSData *g = [ud objectForKey:@"HO_V8_Groups"];
        NSData *f = [ud objectForKey:@"HO_V8_Friends"];
        if (r) [_rankUsersMap addEntriesFromDictionary:[NSKeyedUnarchiver unarchiveObjectWithData:r]];
        if (gm) [_groupMembersMap addEntriesFromDictionary:[NSKeyedUnarchiver unarchiveObjectWithData:gm]];
        if (g) [_joinedGroupsMap addEntriesFromDictionary:[NSKeyedUnarchiver unarchiveObjectWithData:g]];
        if (f) [_contactFriendsMap addEntriesFromDictionary:[NSKeyedUnarchiver unarchiveObjectWithData:f]];
    } @catch (NSException *e) {}
}

#pragma mark - 1. 强制模拟群主权限 (动态 Ivar 偏移)

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
        if (protectOff > 0) base[protectOff] = 0; // 关闭群成员保护模式
        
        ptrdiff_t memberListOff = GetRealIvarOffset(cls, "groupMemberList");
        if (memberListOff > 0) base[memberListOff] = 1; // 开启查看群成员列表
        
        ptrdiff_t myRoleOff = GetRealIvarOffset(cls, "myRole");
        if (myRoleOff > 0) base[myRoleOff] = 1; // 群主
        
        ptrdiff_t roleOff = GetRealIvarOffset(cls, "role");
        if (roleOff > 0) base[roleOff] = 1;
        
        const char *enableFields[] = {"allowInvite", "allowJoin", "allowSearch", "sendCard", "sendGroupCard", "whetherFriends"};
        for (int i = 0; i < 6; i++) {
            ptrdiff_t off = GetRealIvarOffset(cls, enableFields[i]);
            if (off > 0) base[off] = 1;
        }
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
                    }
                }
            }
        }
        free(ivars);
    } @catch (NSException *e) {}
}

#pragma mark - 2. 核心大招：直接解析海鸥 AES 解密后的明文 JSON 字典 (全量截获排行榜与群成员)

- (void)consumeDecryptedJSONObject:(id)jsonObj {
    if (!jsonObj) return;
    if ([jsonObj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)jsonObj;
        
        // 识别是否是用户/排行榜条目/群成员字典
        id rawAccount = dict[@"account"] ?: dict[@"haiouNo"] ?: dict[@"userNo"];
        id rawUserId  = dict[@"userId"]  ?: dict[@"id"]      ?: dict[@"uid"];
        id rawNick    = dict[@"nickName"] ?: dict[@"nickname"] ?: dict[@"name"] ?: dict[@"showName"];
        id rawAvatar  = dict[@"portrait"] ?: dict[@"avatar"]   ?: dict[@"headUrl"] ?: dict[@"icon"];
        id rawGroupId = dict[@"groupId"] ?: dict[@"gid"];
        id rawGroupNo = dict[@"groupNo"];
        id rawRank    = dict[@"rank"] ?: dict[@"ranking"];
        
        // 如果是群聊字典 (含 groupNo)
        if (rawGroupNo && rawNick) {
            NSString *gNo = ExtractValidHaiouAccount([NSString stringWithFormat:@"%@", rawGroupNo]);
            NSString *gId = [NSString stringWithFormat:@"%@", rawUserId ?: gNo];
            NSString *gName = [NSString stringWithFormat:@"%@", rawNick];
            if (gNo.length >= 4 && gName.length > 0) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    HOModelItem *item = self.joinedGroupsMap[gNo] ?: [[HOModelItem alloc] init];
                    item.userId = gId;
                    item.account = gNo;
                    item.name = gName;
                    if ([rawAvatar isKindOfClass:[NSString class]]) item.avatarUrl = rawAvatar;
                    item.source = @"我的群聊";
                    item.isGroup = YES;
                    self.joinedGroupsMap[gNo] = item;
                });
            }
        }
        // 如果是人物字典 (必须有合法的海鸥号 account，绝不把 19 位 userId 串码当海鸥号！)
        else if (rawAccount && rawNick) {
            NSString *validAcc = ExtractValidHaiouAccount([NSString stringWithFormat:@"%@", rawAccount]);
            NSString *uidStr   = rawUserId ? [NSString stringWithFormat:@"%@", rawUserId] : @"";
            NSString *nameStr  = [NSString stringWithFormat:@"%@", rawNick];
            NSString *avaStr   = [rawAvatar isKindOfClass:[NSString class]] ? (NSString *)rawAvatar : @"";
            
            if (validAcc.length >= 4 && !IsInternalSnowflakeId(validAcc) && !IsLevelOrNoiseText(nameStr) && ![uidStr isEqualToString:g_myLoginUserId]) {
                BOOL isFromGroup = (rawGroupId != nil);
                BOOL isFromRank  = (rawRank != nil || dict[@"exp"] != nil || dict[@"grade"] != nil || dict[@"level"] != nil);
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSMutableDictionary *targetMap = isFromGroup ? self.groupMembersMap : (isFromRank ? self.rankUsersMap : self.rankUsersMap);
                    HOModelItem *item = targetMap[validAcc];
                    if (!item) {
                        item = [[HOModelItem alloc] init];
                        item.collectSeq = ++self.seqCounter;
                    }
                    if (uidStr.length > 0) item.userId = uidStr;
                    item.account = validAcc;
                    item.name = nameStr;
                    if (avaStr.length > 0) item.avatarUrl = avaStr;
                    if (isFromGroup) {
                        item.source = [NSString stringWithFormat:@"群成员(群:%@)", rawGroupId];
                    } else if (rawRank) {
                        item.source = [NSString stringWithFormat:@"排行榜·第%@名", rawRank];
                    } else if (!item.source) {
                        item.source = @"接口全量提取";
                    }
                    item.isGroup = NO;
                    targetMap[validAcc] = item;
                });
            }
        }
        
        // 递归遍历字典子节点 (如 data / list / records / rows / members)
        for (id key in dict) {
            id val = dict[key];
            if ([val isKindOfClass:[NSArray class]] || [val isKindOfClass:[NSDictionary class]]) {
                [self consumeDecryptedJSONObject:val];
            }
        }
    } else if ([jsonObj isKindOfClass:[NSArray class]]) {
        for (id sub in (NSArray *)jsonObj) {
            if ([sub isKindOfClass:[NSDictionary class]] || [sub isKindOfClass:[NSArray class]]) {
                [self consumeDecryptedJSONObject:sub];
            }
        }
    }
}

#pragma mark - 3. 模型与 Cell 精准提取 (严格过滤19位串码与等级)

- (void)harvestUserObject:(id)userObj source:(NSString *)source {
    if (!userObj) return;
    NSString *clsName = NSStringFromClass([userObj class]);
    if (![clsName containsString:@"ZDUser"] || [clsName containsString:@"Controller"] || [clsName containsString:@"Cell"] || [clsName containsString:@"Manager"]) return;
    
    NSString *uid      = ReadSwiftStringByIvar(userObj, "id") ?: ReadSwiftStringByIvar(userObj, "userId");
    NSString *rawAcc   = ReadSwiftStringByIvar(userObj, "account") ?: ReadSwiftStringByIvar(userObj, "username");
    NSString *nickName = ReadSwiftStringByIvar(userObj, "nickName") ?: ReadSwiftStringByIvar(userObj, "name");
    NSString *portrait = ReadSwiftStringByIvar(userObj, "portrait") ?: ReadSwiftStringByIvar(userObj, "avatar");
    
    NSString *validAcc = ExtractValidHaiouAccount(rawAcc);
    if (!validAcc || IsInternalSnowflakeId(validAcc) || [uid isEqualToString:g_myLoginUserId]) return;
    if (IsLevelOrNoiseText(nickName)) return;
    
    HOModelItem *item = _rankUsersMap[validAcc];
    if (!item) {
        item = [[HOModelItem alloc] init];
        item.collectSeq = ++_seqCounter;
    }
    if (uid.length > 0) item.userId = uid;
    item.account = validAcc;
    item.name = nickName;
    if (portrait.length > 0) item.avatarUrl = portrait;
    if (!item.source) item.source = source ?: @"排行榜提取";
    item.isGroup = NO;
    _rankUsersMap[validAcc] = item;
}

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
    NSString *validAcc = ExtractValidHaiouAccount(rawAcc);
    
    NSString *realName = [nameLab isKindOfClass:[UILabel class]] ? [nameLab.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : nil;
    if (IsLevelOrNoiseText(realName)) realName = nil;
    
    if (!realName || !validAcc) {
        NSSet *excludeSet = [NSSet setWithArray:@[
            accLab ?: [NSNull null], levelLab ?: [NSNull null], rankLab ?: [NSNull null],
            expLab ?: [NSNull null], rateLab ?: [NSNull null], meLab ?: [NSNull null], lvColl ?: [NSNull null]
        ]];
        NSMutableArray<UILabel *> *otherLabels = [NSMutableArray array];
        [self findValidLabelsInView:cell exclude:excludeSet outArr:otherLabels];
        for (UILabel *lb in otherLabels) {
            NSString *t = [lb.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([t containsString:@"海鸥号"] || [t containsString:@"ID"]) {
                if (!validAcc) validAcc = ExtractValidHaiouAccount(t);
                continue;
            }
            if (!realName && !IsLevelOrNoiseText(t) && ![t isEqualToString:validAcc]) {
                realName = t;
            }
        }
    }
    
    if (!validAcc || IsInternalSnowflakeId(validAcc) || !realName) return;
    UIImage *avatarImg = ExtractAvatarImage(avatarV ?: cell);
    
    HOModelItem *item = _rankUsersMap[validAcc];
    if (!item) {
        item = [[HOModelItem alloc] init];
        item.collectSeq = ++_seqCounter;
    }
    item.account = validAcc;
    item.name = realName;
    
    NSString *rankTypeStr = @"排行榜";
    if (rankVC) {
        ptrdiff_t typeOff = GetRealIvarOffset([rankVC class], "zd_type");
        if (typeOff > 0) {
            uint8_t tVal = *((uint8_t *)(__bridge void *)rankVC + typeOff);
            if (tVal == 1) rankTypeStr = @"日榜";
            else if (tVal == 2) rankTypeStr = @"周榜";
            else if (tVal == 3) rankTypeStr = @"总榜";
        }
    }
    NSString *rkNum = ([rankLab isKindOfClass:[UILabel class]] && rankLab.text.length > 0) ? rankLab.text : [NSString stringWithFormat:@"%ld", (long)(ip ? ip.item + 1 : 0)];
    item.source = [NSString stringWithFormat:@"%@·第%@名", rankTypeStr, rkNum];
    item.isGroup = NO;
    
    if (avatarImg && !item.avatarData) {
        item.avatarData = UIImagePNGRepresentation(avatarImg);
    }
    _rankUsersMap[validAcc] = item;
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
    
    NSString *validNo = ExtractValidHaiouAccount(gNo) ?: gid;
    if (validNo.length >= 4 && gName.length > 0) {
        HOModelItem *item = _joinedGroupsMap[validNo] ?: [[HOModelItem alloc] init];
        item.userId = gid ?: validNo;
        item.account = ExtractValidHaiouAccount(gNo) ?: validNo;
        item.name = gName;
        item.avatarUrl = cover;
        item.source = @"我的群聊(已开启群主权限)";
        item.isGroup = YES;
        _joinedGroupsMap[validNo] = item;
    }
    
    // 检查 ZDGroup 内部的 members 数组
    ptrdiff_t memOff = GetRealIvarOffset(cls, "members");
    if (memOff > 0) {
        @try {
            id memArr = *(id __unsafe_unretained *)((uint8_t *)(__bridge void *)groupObj + memOff);
            if ([memArr isKindOfClass:[NSArray class]]) {
                for (id m in (NSArray *)memArr) {
                    [self harvestGroupMemberObject:m];
                }
            }
        } @catch (NSException *e) {}
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
    NSString *groupId  = ReadSwiftStringByIvar(memberObj, "groupId");
    
    if ([userId isEqualToString:g_myLoginUserId]) {
        [self unlockMemberOwnerPrivilege:memberObj];
        return;
    }
    
    // 严格要求必须有真实海鸥号 account，绝不把 19 位 userId 串码当成海鸥号！
    NSString *validAcc = ExtractValidHaiouAccount(rawAcc);
    if (!validAcc || IsInternalSnowflakeId(validAcc)) return;
    
    NSString *realName = (!IsLevelOrNoiseText(nickName)) ? nickName : showName;
    if (IsLevelOrNoiseText(realName)) realName = validAcc;
    
    HOModelItem *item = _groupMembersMap[validAcc];
    if (!item) {
        item = [[HOModelItem alloc] init];
        item.collectSeq = ++_seqCounter;
    }
    if (userId.length > 0) item.userId = userId;
    item.account = validAcc;
    item.name = realName;
    if (portrait.length > 0) item.avatarUrl = portrait;
    item.source = groupId.length > 0 ? [NSString stringWithFormat:@"群成员(群:%@)", [groupId substringToIndex:MIN(6, groupId.length)]] : @"群成员自动提取";
    item.isGroup = NO;
    _groupMembersMap[validAcc] = item;
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
            acc = ExtractValidHaiouAccount(t);
        } else if (!name && !IsLevelOrNoiseText(t) && ![t containsString:@"在线"] && ![t containsString:@"离线"]) {
            name = t;
        }
    }
    if (name.length > 0) {
        NSString *key = acc.length >= 4 ? acc : name;
        HOModelItem *item = _contactFriendsMap[key] ?: [[HOModelItem alloc] init];
        item.account = acc ?: @"好友";
        item.name = name;
        item.source = @"通讯录好友";
        item.isGroup = NO;
        UIImage *img = ExtractAvatarImage(cell);
        if (img && !item.avatarData) item.avatarData = UIImagePNGRepresentation(img);
        _contactFriendsMap[key] = item;
    }
}

#pragma mark - 4. 后台全自动静默获取所有群成员 (无需手动点进群设置)

- (void)autoSilentFetchAllGroupMembersInBackground {
    // 从根控制器找到 ZDMessageListController1，读取其 zd_groups 数组中的所有 ZDGroup 对象
    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    if (!win) return;
    UIViewController *root = win.rootViewController;
    NSMutableArray<UIViewController *> *vcs = [NSMutableArray array];
    if ([root isKindOfClass:[UITabBarController class]]) {
        for (UIViewController *c in [(UITabBarController *)root viewControllers]) {
            if ([c isKindOfClass:[UINavigationController class]]) [vcs addObjectsFromArray:[(UINavigationController *)c viewControllers]];
            else [vcs addObject:c];
        }
    } else if ([root isKindOfClass:[UINavigationController class]]) {
        [vcs addObjectsFromArray:[(UINavigationController *)root viewControllers]];
    }
    
    NSMutableArray *allGroupObjs = [NSMutableArray array];
    for (UIViewController *vc in vcs) {
        if ([NSStringFromClass([vc class]) containsString:@"ZDMessageListController1"]) {
            ptrdiff_t grpOff = GetRealIvarOffset([vc class], "zd_groups");
            if (grpOff > 0) {
                @try {
                    id arr = *(id __unsafe_unretained *)((uint8_t *)(__bridge void *)vc + grpOff);
                    if ([arr isKindOfClass:[NSArray class]]) {
                        for (id g in (NSArray *)arr) {
                            [self harvestGroupObject:g];
                            [allGroupObjs addObject:g];
                        }
                    }
                } @catch (NSException *e) {}
            }
        }
    }
    
    // 对每个尚未静默拉取过成员的 ZDGroup，在后台隐式实例化 ZDConversationGroupMemberListController 触发成员请求！
    Class memListVCCls = objc_getClass("_TtC7ZhengDu37ZDConversationGroupMemberListController");
    if (!memListVCCls || allGroupObjs.count == 0) return;
    
    [_hiddenMemberVCs removeAllObjects];
    NSInteger delayIdx = 0;
    for (id groupObj in allGroupObjs) {
        NSString *gid = ReadSwiftStringByIvar(groupObj, "id");
        if (!gid || [_autoFetchedGroupIds containsObject:gid]) continue;
        [_autoFetchedGroupIds addObject:gid];
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((delayIdx * 1.2) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            @try {
                UIViewController *mvc = [[memListVCCls alloc] init];
                if (mvc) {
                    // 将 groupObj 赋给 ZDConversationGroupMemberListController 的 group 类型 Ivar
                    unsigned int ic = 0;
                    Ivar *ivars = class_copyIvarList(memListVCCls, &ic);
                    uint8_t *mBase = (__bridge void *)mvc;
                    if (ivars) {
                        for (unsigned int k = 0; k < ic; k++) {
                            const char *iname = ivar_getName(ivars[k]);
                            ptrdiff_t ioff = ivar_getOffset(ivars[k]);
                            if (iname && ioff > 0) {
                                NSString *ns = [[NSString stringWithUTF8String:iname] lowercaseString];
                                if ([ns containsString:@"group"] && ![ns containsString:@"member"] && ![ns containsString:@"id"]) {
                                    *(id __strong *)(mBase + ioff) = groupObj;
                                }
                            }
                        }
                        free(ivars);
                    }
                    // 触发 viewDidLoad 让其在后台向服务端请求该群的 ZDGroupMember 列表！
                    mvc.view.frame = CGRectMake(-3000, -3000, 320, 480);
                    [self.hiddenMemberVCs addObject:mvc];
                }
            } @catch (NSException *e) {}
        });
        delayIdx++;
        if (delayIdx >= 8) break; // 每次最多并发静默拉取 8 个群，防限流
    }
}

#pragma mark - 5. 排行榜突破 200 人限制：多榜 (type=1,2,3) + 自动递增页码 (zd_page=1..20)

- (void)toggleMultiPageRankFetch:(void (^)(NSString *))statusBlock {
    _onStatusChanged = statusBlock;
    if (_isFetchingRank) {
        [self stopMultiPageRankFetch];
        return;
    }
    _isFetchingRank = YES;
    _currentRankPage = 1;
    [_hiddenRankVCs removeAllObjects];
    
    // 1. 先检查当前界面是否已经打开了 ZDGlobalTopController，将其子控制器纳入采集
    Class rankItemCls = objc_getClass("_TtC7ZhengDu25ZDGlobalTopItemController");
    if (rankItemCls) {
        UIWindow *keyWin = [UIApplication sharedApplication].keyWindow;
        // 逆向报告与抓包 (source: 17) 显示 type=1(日榜), type=2(周榜), type=3(总榜)
        for (uint8_t t = 1; t <= 3; t++) {
            UIViewController *vc = [[rankItemCls alloc] init];
            if (vc) {
                ptrdiff_t typeOff = GetRealIvarOffset(rankItemCls, "zd_type");
                if (typeOff > 0) *((uint8_t *)(__bridge void *)vc + typeOff) = t;
                
                ptrdiff_t pageOff = GetRealIvarOffset(rankItemCls, "zd_page");
                if (pageOff > 0) *(NSInteger *)((uint8_t *)(__bridge void *)vc + pageOff) = 1;
                
                ptrdiff_t sizeOff = GetRealIvarOffset(rankItemCls, "zd_size");
                if (sizeOff > 0) *(NSInteger *)((uint8_t *)(__bridge void *)vc + sizeOff) = 100;
                
                vc.view.frame = CGRectMake(-2000, -2000, 390, 844);
                [keyWin addSubview:vc.view];
                if ([vc respondsToSelector:NSSelectorFromString(@"zd_willShowVC")]) {
                    ((void (*)(id, SEL))objc_msgSend)(vc, NSSelectorFromString(@"zd_willShowVC"));
                }
                [_hiddenRankVCs addObject:vc];
            }
        }
    }
    
    if (_onStatusChanged) {
        _onStatusChanged([NSString stringWithFormat:@"🚀 正在同步拉取日榜/周榜/总榜 (第1页 | 已获%lu人)...", (unsigned long)_rankUsersMap.count]);
    }
    _rankTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(stepMultiPageRankFetch) userInfo:nil repeats:YES];
}

- (void)stopMultiPageRankFetch {
    _isFetchingRank = NO;
    if (_rankTimer) {
        [_rankTimer invalidate];
        _rankTimer = nil;
    }
    for (UIViewController *vc in _hiddenRankVCs) {
        [vc.view removeFromSuperview];
    }
    [_hiddenRankVCs removeAllObjects];
    [self saveToDisk];
    if (_onStatusChanged) {
        _onStatusChanged([NSString stringWithFormat:@"✅ 排行榜采集已暂停 (累计获取 %lu 名真实海鸥号用户)", (unsigned long)_rankUsersMap.count]);
    }
}

- (void)stepMultiPageRankFetch {
    if (!_isFetchingRank || _hiddenRankVCs.count == 0) {
        [self stopMultiPageRankFetch];
        return;
    }
    
    _currentRankPage++;
    Class rankItemCls = objc_getClass("_TtC7ZhengDu25ZDGlobalTopItemController");
    ptrdiff_t collectOff = GetRealIvarOffset(rankItemCls, "$__lazy_storage_$_zd_collect");
    ptrdiff_t pageOff    = GetRealIvarOffset(rankItemCls, "zd_page");
    ptrdiff_t datasOff   = GetRealIvarOffset(rankItemCls, "zd_datas");
    
    for (UIViewController *vc in _hiddenRankVCs) {
        uint8_t *base = (__bridge void *)vc;
        
        // 1. 直接尝试读取 zd_datas Swift Array 缓冲区中的模型对象！
        if (datasOff > 0) {
            @try {
                uintptr_t storagePtr = *(uintptr_t *)(base + datasOff);
                if (storagePtr > 0x100000000ULL && (storagePtr & 0x7) == 0) {
                    // Swift ContiguousArrayStorage: +16 是 count, +32 起是元素指针数组
                    NSInteger count = *(NSInteger *)((uint8_t *)storagePtr + 16);
                    if (count > 0 && count <= 2000) {
                        id __unsafe_unretained *items = (id __unsafe_unretained *)((uint8_t *)storagePtr + 32);
                        for (NSInteger i = 0; i < count; i++) {
                            id elem = items[i];
                            if (elem) [self harvestUserObject:elem source:@"排行榜内存直读"];
                        }
                    }
                }
            } @catch (NSException *e) {}
        }
        
        // 2. 提取可见 Cell 并推进滚动 + 递增页码触发 mj_footer 加载下一页 (offset=2, 3, 4...)
        UICollectionView *cv = (collectOff > 0) ? *(UICollectionView * __unsafe_unretained *)(base + collectOff) : nil;
        if ([cv isKindOfClass:[UICollectionView class]]) {
            for (UICollectionViewCell *cell in cv.visibleCells) {
                NSIndexPath *ip = [cv indexPathForCell:cell];
                [self harvestRankCell:cell indexPath:ip rankVC:vc];
            }
            CGFloat nextY = cv.contentOffset.y + cv.bounds.size.height * 1.5;
            CGFloat maxY  = MAX(0, cv.contentSize.height - cv.bounds.size.height);
            if (nextY < maxY) {
                [cv setContentOffset:CGPointMake(0, nextY) animated:NO];
                [cv layoutIfNeeded];
            } else {
                // 已滚到底部，递增 zd_page 并触发 mj_footer 上拉加载更多
                if (pageOff > 0) {
                    *(NSInteger *)(base + pageOff) = _currentRankPage;
                }
                @try {
                    id footer = [cv valueForKey:@"mj_footer"];
                    if (footer) {
                        if ([footer respondsToSelector:NSSelectorFromString(@"resetNoMoreData")]) {
                            ((void (*)(id, SEL))objc_msgSend)(footer, NSSelectorFromString(@"resetNoMoreData"));
                        }
                        if ([footer respondsToSelector:NSSelectorFromString(@"beginRefreshing")]) {
                            ((void (*)(id, SEL))objc_msgSend)(footer, NSSelectorFromString(@"beginRefreshing"));
                        } else if ([footer respondsToSelector:NSSelectorFromString(@"executeRefreshingCallback")]) {
                            ((void (*)(id, SEL))objc_msgSend)(footer, NSSelectorFromString(@"executeRefreshingCallback"));
                        }
                    }
                } @catch (NSException *e) {}
            }
        }
    }
    
    [self saveToDisk];
    if (_onStatusChanged) {
        _onStatusChanged([NSString stringWithFormat:@"🔥 正在深度拉取日榜/周榜/总榜 (第%ld轮 | 已获 %lu 人)", (long)_currentRankPage, (unsigned long)_rankUsersMap.count]);
    }
}

#pragma mark - 6. 点击任意用户 -> 直接进入该用户的个人主页 (无需手动输入搜索)

- (void)openDirectUserHomePageForItem:(HOModelItem *)item fromVC:(UIViewController *)fromVC {
    if (!item || !fromVC) return;
    UINavigationController *nav = fromVC.navigationController;
    if (!nav && [fromVC isKindOfClass:[UINavigationController class]]) nav = (UINavigationController *)fromVC;
    if (!nav) return;
    
    // 复制纯海鸥号备用
    NSString *pureAcc = ExtractValidHaiouAccount(item.account);
    if (pureAcc) [UIPasteboard generalPasteboard].string = pureAcc;
    
    // 方案 A：如果该条目已经有内部 19 位 userId，尝试直接构造 ZDUser 并推入原生个人主页 ZDNewUserInfoController
    Class userCls = objc_getClass("_TtC7ZhengDu6ZDUser");
    Class newUserInfoVCCls = objc_getClass("_TtC7ZhengDu21ZDNewUserInfoController");
    if (item.userId.length >= 10 && userCls && newUserInfoVCCls) {
        @try {
            id userObj = [[userCls alloc] init];
            if (userObj) {
                WriteSwiftStringByIvar(userObj, "id", item.userId);
                WriteSwiftStringByIvar(userObj, "userId", item.userId);
                if (pureAcc) WriteSwiftStringByIvar(userObj, "account", pureAcc);
                if (item.name) WriteSwiftStringByIvar(userObj, "nickName", item.name);
                
                UIViewController *infoVC = [[newUserInfoVCCls alloc] init];
                if (infoVC) {
                    // 将 userObj 写入 ZDNewUserInfoController 的 user Ivar
                    unsigned int ic = 0;
                    Ivar *ivars = class_copyIvarList(newUserInfoVCCls, &ic);
                    uint8_t *vcBase = (__bridge void *)infoVC;
                    BOOL injected = NO;
                    if (ivars) {
                        for (unsigned int i = 0; i < ic; i++) {
                            const char *n = ivar_getName(ivars[i]);
                            ptrdiff_t off = ivar_getOffset(ivars[i]);
                            if (n && off > 0) {
                                NSString *ns = [NSString stringWithUTF8String:n];
                                if ([ns isEqualToString:@"zd_user"] || [ns isEqualToString:@"user"]) {
                                    *(id __strong *)(vcBase + off) = userObj;
                                    injected = YES;
                                } else if ([ns isEqualToString:@"zd_userId"] || [ns isEqualToString:@"userId"]) {
                                    WriteSwiftStringByIvar(infoVC, n, item.userId);
                                    injected = YES;
                                }
                            }
                        }
                        free(ivars);
                    }
                    if (injected) {
                        infoVC.hidesBottomBarWhenPushed = YES;
                        [nav pushViewController:infoVC animated:YES];
                        return;
                    }
                }
            }
        } @catch (NSException *e) {}
    }
    
    // 方案 B：对于只有纯海鸥号 (如 8666688) 的用户，调起 ZDAddFriendOrGroupController 并在后台自动执行搜索跳转到该人主页！
    Class addVCCls = objc_getClass("_TtC7ZhengDu28ZDAddFriendOrGroupController");
    if (addVCCls && pureAcc.length >= 4) {
        UIViewController *addVC = [[addVCCls alloc] init];
        if (addVC) {
            addVC.hidesBottomBarWhenPushed = YES;
            [nav pushViewController:addVC animated:YES];
            
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                UITextField *tf = [self findTextFieldInView:addVC.view];
                if (tf) {
                    tf.text = pureAcc;
                    [tf sendActionsForControlEvents:UIControlEventEditingChanged];
                    // 自动触发回车搜索代理，海鸥将直接发起 GET /api/sys/open?username=xxx 并自动跳转到该用户的主页！
                    if (tf.delegate && [tf.delegate respondsToSelector:@selector(textFieldShouldReturn:)]) {
                        [tf.delegate textFieldShouldReturn:tf];
                    }
                    [tf resignFirstResponder];
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

#pragma mark - ==================== 6. 群发与拓客助手 UI 面板 ====================

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
    self.title = @"海鸥全自动拓客与群发中心";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"返回" style:UIBarButtonItemStylePlain target:self action:@selector(closeSelf)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"清空缓存" style:UIBarButtonItemStylePlain target:self action:@selector(clearAllConfirm)];
    
    [self buildUI];
    
    // 打开面板时，自动在后台静默拉取所有已加入群的群成员！
    [[HOMassEngine shared] autoSilentFetchAllGroupMembersInBackground];
    [self refreshTableList];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [[HOMassEngine shared] stopMultiPageRankFetch];
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
    nativeSendBtn.frame = CGRectMake(12, y, (w - 32) * 0.46, 40);
    [nativeSendBtn setTitle:@"📨 官方原生群发" forState:UIControlStateNormal];
    nativeSendBtn.backgroundColor = [UIColor systemBlueColor];
    [nativeSendBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    nativeSendBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    nativeSendBtn.layer.cornerRadius = 8;
    [nativeSendBtn addTarget:self action:@selector(onTapNativeSend) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:nativeSendBtn];
    
    _rankFetchBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _rankFetchBtn.frame = CGRectMake(12 + (w - 32) * 0.46 + 8, y, (w - 32) * 0.54, 40);
    [_rankFetchBtn setTitle:@"🏆 全榜多页突破抓取" forState:UIControlStateNormal];
    _rankFetchBtn.backgroundColor = [UIColor systemIndigoColor];
    [_rankFetchBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _rankFetchBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    _rankFetchBtn.layer.cornerRadius = 8;
    [_rankFetchBtn addTarget:self action:@selector(onTapMultiPageRankFetch) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_rankFetchBtn];
    y += 48;
    
    _tabSegment = [[UISegmentedControl alloc] initWithItems:@[@"🏆排行榜", @"👥群成员(自动)", @"🏠我的群", @"📒通讯录"]];
    _tabSegment.frame = CGRectMake(12, y, w - 24, 34);
    _tabSegment.selectedSegmentIndex = 0;
    [_tabSegment addTarget:self action:@selector(refreshTableList) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:_tabSegment];
    y += 42;
    
    CGFloat bw = (w - 34) / 3.0;
    NSArray *bTitles = @[@"🔄后台静默抓群员", @"📊去原生排行榜", @"📋复制纯海鸥号"];
    SEL bSels[] = {@selector(triggerSilentGroupMemberFetch), @selector(goNativeRankPage), @selector(copyCurrentAccounts)};
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

- (void)onTapMultiPageRankFetch {
    _tabSegment.selectedSegmentIndex = 0;
    __weak typeof(self) weakSelf = self;
    [[HOMassEngine shared] toggleMultiPageRankFetch:^(NSString *status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.statusLabel.text = status;
            BOOL running = [HOMassEngine shared].isFetchingRank;
            weakSelf.rankFetchBtn.backgroundColor = running ? [UIColor systemRedColor] : [UIColor systemIndigoColor];
            [weakSelf.rankFetchBtn setTitle:running ? @"🛑 停止抓取(实时入库)" : @"🏆 全榜多页突破抓取" forState:UIControlStateNormal];
            [weakSelf refreshTableList];
        });
    }];
}

- (void)triggerSilentGroupMemberFetch {
    _tabSegment.selectedSegmentIndex = 1;
    [[HOMassEngine shared].autoFetchedGroupIds removeAllObjects];
    [[HOMassEngine shared] autoSilentFetchAllGroupMembersInBackground];
    _statusLabel.text = @"🔄 正在后台自动遍历你加入的所有群聊并静默提取群成员...";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refreshTableList];
    });
}

- (void)onTapNativeSend {
    Class cls = objc_getClass("_TtC7ZhengDu28ZDGroupSendMessageController");
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
        if (item.account.length > 0) [s appendFormat:@"%@\n", item.account];
    }
    [UIPasteboard generalPasteboard].string = s;
    _statusLabel.text = [NSString stringWithFormat:@"✅ 已复制 %lu 个纯海鸥号到剪贴板！", (unsigned long)_currentList.count];
}

- (void)clearAllConfirm {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"清空全部采集数据" message:@"确定清空所有缓存重新采集吗？" preferredStyle:UIAlertControllerStyleAlert];
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
        if (!eng.isFetchingRank) {
            _statusLabel.text = [NSString stringWithFormat:@"🏆【排行榜用户】共 %lu 人 (已过滤串码与等级，点人名直达主页加好友)", (unsigned long)_currentList.count];
        }
    } else if (idx == 1) {
        _currentList = [eng.groupMembersMap.allValues sortedArrayUsingComparator:^NSComparisonResult(HOModelItem *a, HOModelItem *b) {
            return a.collectSeq > b.collectSeq ? NSOrderedAscending : NSOrderedDescending;
        }];
        _statusLabel.text = [NSString stringWithFormat:@"👥【群聊成员】共 %lu 人 (后台自动静默提取，点人名直达主页加好友)", (unsigned long)_currentList.count];
    } else if (idx == 2) {
        _currentList = [eng.joinedGroupsMap.allValues sortedArrayUsingComparator:^NSComparisonResult(HOModelItem *a, HOModelItem *b) {
            return [a.name compare:b.name];
        }];
        _statusLabel.text = [NSString stringWithFormat:@"🏠【我的群聊】共 %lu 个群 (已全部自动开启群主查看权限)", (unsigned long)_currentList.count];
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
    static NSString *cid = @"HOAvatarCellV8";
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
    cell.detailTextLabel.text = [NSString stringWithFormat:@"海鸥号: %@   |   %@   👉直达主页", item.account, item.source];
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
    [[HOMassEngine shared] openDirectUserHomePageForItem:item fromVC:self];
}

@end

#pragma mark - ==================== 7. Hook 挂载区 (JSON解密层 + 视图模型层) ====================

// 1. 拦截 +[NSJSONSerialization JSONObjectWithData:options:error:] —— 海鸥把 AES 密文解密成明文 JSON 后必调此方法！
static IMP orig_json_objectWithData = NULL;
static id hook_json_objectWithData(id self, SEL _cmd, NSData *data, NSJSONReadingOptions opt, NSError **error) {
    id res = ((id (*)(id, SEL, NSData *, NSJSONReadingOptions, NSError **))orig_json_objectWithData)(self, _cmd, data, opt, error);
    if (res && ([res isKindOfClass:[NSDictionary class]] || [res isKindOfClass:[NSArray class]])) {
        [[HOMassEngine shared] consumeDecryptedJSONObject:res];
    }
    return res;
}

// 2. 「我的」页面入口
static void ho_mine_onTapEmbeddedMassBtn(id self, SEL _cmd, UIButton *sender) {
    UIViewController *mineVC = (UIViewController *)self;
    HOMassHelperViewController *vc = [[HOMassHelperViewController alloc] init];
    vc.hidesBottomBarWhenPushed = YES;
    if (mineVC.navigationController) {
        [mineVC.navigationController pushViewController:vc animated:YES];
    } else {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        [mineVC presentViewController:nav animated:YES completion:nil];
    }
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
            [fBtn setTitle:@"✈️ 打开【海鸥全自动拓客与群发中心】" forState:UIControlStateNormal];
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

// 3. 聊天页与群设置页自动解锁群主权限
static IMP orig_chat_viewWillAppear = NULL;
static void hook_chat_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    [[HOMassEngine shared] applyGroupOwnerOnVC:(UIViewController *)self];
    if (orig_chat_viewWillAppear) ((void (*)(id, SEL, BOOL))orig_chat_viewWillAppear)(self, _cmd, animated);
    [[HOMassEngine shared] applyGroupOwnerOnVC:(UIViewController *)self];
}

static IMP orig_groupSet_viewWillAppear = NULL;
static void hook_groupSet_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    [[HOMassEngine shared] applyGroupOwnerOnVC:(UIViewController *)self];
    if (orig_groupSet_viewWillAppear) ((void (*)(id, SEL, BOOL))orig_groupSet_viewWillAppear)(self, _cmd, animated);
    [[HOMassEngine shared] applyGroupOwnerOnVC:(UIViewController *)self];
}

// 4. 排行榜 Cell 与模型提取
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

static IMP orig_user_init = NULL;
static id hook_user_init(id self, SEL _cmd) {
    id ins = ((id (*)(id, SEL))orig_user_init)(self, _cmd);
    if (ins) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[HOMassEngine shared] harvestUserObject:ins source:@"用户模型提取"];
        });
    }
    return ins;
}

#pragma mark - ==================== 8. Dylib 构造函数入口 ====================

__attribute__((constructor))
static void HaiouMassHelperV8Init(void) {
    // 1. 挂载 JSON 明文解析出口拦截器（海鸥 AES 解密后转字典必经之路）
    SafeHookClassMethodOnce([NSJSONSerialization class], @selector(JSONObjectWithData:options:error:), (IMP)hook_json_objectWithData, &orig_json_objectWithData);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            // 2. 彻底屏蔽开屏广告
            SetupAdBlockerOnce();
            
            // 3. 挂载「我的」页面入口
            Class mineCls = objc_getClass("_TtC7ZhengDu16ZDMineController");
            if (mineCls) {
                class_addMethod(mineCls, NSSelectorFromString(@"ho_mine_onTapEmbeddedMassBtn:"), (IMP)ho_mine_onTapEmbeddedMassBtn, "v@:@");
                SafeHookInstanceMethodOnce(mineCls, @selector(tableView:cellForRowAtIndexPath:), (IMP)hook_mine_cellForRow, &orig_mine_cellForRow);
            }
            
            // 4. 挂载聊天页与群设置页
            Class chatCls = objc_getClass("_TtC7ZhengDu25ZDConversationController1");
            if (chatCls) {
                SafeHookInstanceMethodOnce(chatCls, @selector(viewWillAppear:), (IMP)hook_chat_viewWillAppear, &orig_chat_viewWillAppear);
            }
            Class groupSetCls = objc_getClass("_TtC7ZhengDu30ZDConversationGroupSetController");
            if (groupSetCls) {
                SafeHookInstanceMethodOnce(groupSetCls, @selector(viewWillAppear:), (IMP)hook_groupSet_viewWillAppear, &orig_groupSet_viewWillAppear);
            }
            
            // 5. 挂载排行榜 ZDGlobalTopItemController
            Class rankItemCls = objc_getClass("_TtC7ZhengDu25ZDGlobalTopItemController");
            if (rankItemCls) {
                DisableMethodWithNoop(rankItemCls, NSSelectorFromString(@"zd_clickUpgrade"), (IMP)ad_noop_0);
                SafeHookInstanceMethodOnce(rankItemCls, @selector(collectionView:cellForItemAtIndexPath:), (IMP)hook_rank_cellForItem, &orig_rank_cellForItem);
            }
            
            // 6. 挂载通讯录 Cell 与三大核心模型 (ZDGroup / ZDGroupMember / ZDUser)
            SafeHookInstanceMethodOnce([UITableView class], @selector(dequeueReusableCellWithIdentifier:forIndexPath:), (IMP)hook_tv_dequeue, &orig_tv_dequeue);
            
            Class grpCls = objc_getClass("_TtC7ZhengDu7ZDGroup");
            if (grpCls) SafeHookInstanceMethodOnce(grpCls, @selector(init), (IMP)hook_group_init, &orig_group_init);
            
            Class memCls = objc_getClass("_TtC7ZhengDu13ZDGroupMember");
            if (memCls) SafeHookInstanceMethodOnce(memCls, @selector(init), (IMP)hook_member_init, &orig_member_init);
            
            Class usrCls = objc_getClass("_TtC7ZhengDu6ZDUser");
            if (usrCls) SafeHookInstanceMethodOnce(usrCls, @selector(init), (IMP)hook_user_init, &orig_user_init);
            
            // 7. 启动 4 秒后自动在后台静默拉取所有群的群成员！
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [[HOMassEngine shared] autoSilentFetchAllGroupMembersInBackground];
            });
        });
    });
}

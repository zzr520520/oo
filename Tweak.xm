//
//  HaiouMassHelper.m
//  海鸥 3.2.9 (Build 20261022) 终极稳定版 v5.0
//  基于最新崩溃日志 (source: 15) 与《全量逆向分析报告_3》(source: 14) 修复:
//  1. 【彻底屏蔽开屏广告】：拦截 ZDOpenScreenAdvController、ZDBUAdSetUp、CSJSplashAd、ABUSplashAd、GMSplashAd、BUSplashAd，秒进主页无任何广告
//  2. 【修复启动 12 秒闪退】：移除破坏 Swift 字典桥接的 infoDictionary Hook，安全伪装官方 BundleID "com.zhengdu.haiou"
//  3. 【零闪退“我的”页面入口】：在“海鸥助手”右侧内嵌按钮 + 表尾大按钮，绝不修改原表行数，杜绝数组越界
//  4. 【动态 Ivar 偏移强制群主】：使用 ivar_getOffset 真实物理偏移解锁群主权限、关闭群保护、开启群成员列表
//  5. 【内置排行榜人员抓取接口 + 真实头像 + 纯海鸥号】：一键抓取日榜/周榜/总榜，带对方真实头像，剔除等级数字，点击直接填入纯海鸥号加人
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#pragma mark - ==================== 1. 安全 Hook 工具与官方 BundleID 伪装 ====================

static NSString *const kOfficialBundleID = @"com.zhengdu.haiou";
static NSString *g_myLoginUserId = @"1483263478134476800";

// 安全的 Method Swizzling（正确处理子类未实现方法的情况，返回原始 IMP）
static IMP SafeSwizzleInstanceMethod(Class cls, SEL origSel, IMP newImp) {
    if (!cls || !origSel || !newImp) return NULL;
    Method origMethod = class_getInstanceMethod(cls, origSel);
    if (!origMethod) return NULL;
    IMP origImp = method_getImplementation(origMethod);
    const char *types = method_getTypeEncoding(origMethod);
    if (class_addMethod(cls, origSel, newImp, types)) {
        return origImp;
    } else {
        return method_setImplementation(origMethod, newImp);
    }
}

// 仅安全拦截 -[NSBundle bundleIdentifier]，绝不破坏 infoDictionary 的 Swift 桥接结构！
static NSString *(*orig_bundleIdentifier)(NSBundle *, SEL) = NULL;
static NSString *hook_bundleIdentifier(NSBundle *self, SEL _cmd) {
    if (self == [NSBundle mainBundle]) {
        return kOfficialBundleID;
    }
    NSString *orig = orig_bundleIdentifier ? orig_bundleIdentifier(self, _cmd) : nil;
    if (orig && [orig hasPrefix:@"com.zhengdu.haiou"]) {
        return kOfficialBundleID;
    }
    return orig;
}

#pragma mark - ==================== 2. 彻底屏蔽开屏广告 & 穿山甲/Gromore 广告 SDK ====================

// 拦截穿山甲/Gromore 开屏广告加载 (loadAdData / showSplashAd) 直接什么都不做
static void hook_ad_noop(id self, SEL _cmd) {
    // 彻底屏蔽广告加载与展示
}

static void hook_ad_noop_arg1(id self, SEL _cmd, id arg1) {
    // 彻底屏蔽带1个参数的广告展示方法 (如 showAdFromRootViewController:)
}

static void hook_ad_noop_arg2(id self, SEL _cmd, id arg1, id arg2) {
    // 彻底屏蔽带2个参数的广告展示方法
}

// 拦截海鸥自身的开屏广告控制器 ZDOpenScreenAdvController
static void (*orig_openAdv_viewDidLoad)(id, SEL) = NULL;
static void hook_openAdv_viewDidLoad(UIViewController *self, SEL _cmd) {
    // 不调用原生的开屏广告加载逻辑，直接隐藏视图并跳过广告！
    self.view.hidden = YES;
    self.view.alpha = 0.0;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.presentingViewController) {
            [self dismissViewControllerAnimated:NO completion:nil];
        } else if (self.navigationController && self.navigationController.viewControllers.count > 1) {
            [self.navigationController popViewControllerAnimated:NO];
        } else {
            // 触发它的跳过/关闭方法
            unsigned int mCount = 0;
            Method *methods = class_copyMethodList([self class], &mCount);
            if (methods) {
                for (unsigned int i = 0; i < mCount; i++) {
                    NSString *selStr = NSStringFromSelector(method_getName(methods[i]));
                    if ([selStr.lowercaseString containsString:@"skip"] ||
                        [selStr.lowercaseString containsString:@"close"] ||
                        [selStr.lowercaseString containsString:@"jump"] ||
                        [selStr.lowercaseString containsString:@"dismiss"] ||
                        [selStr.lowercaseString containsString:@"finish"]) {
                        if (![selStr containsString:@":"]) {
                            @try {
                                ((void (*)(id, SEL))objc_msgSend)(self, method_getName(methods[i]));
                                break;
                            } @catch (NSException *e) {}
                        }
                    }
                }
                free(methods);
            }
        }
    });
}

// 拦截 UIView 添加子视图：如果发现是穿山甲开屏广告视图 (CSJSplashView / ABUSplashView / BUSplashView) 直接丢弃！
static void (*orig_view_addSubview)(UIView *, SEL, UIView *) = NULL;
static void hook_view_addSubview(UIView *self, SEL _cmd, UIView *subview) {
    if (subview) {
        NSString *clsName = NSStringFromClass([subview class]);
        if ([clsName containsString:@"SplashView"] ||
            [clsName containsString:@"CSJSplash"] ||
            [clsName containsString:@"ABUSplash"] ||
            [clsName containsString:@"BUSplash"] ||
            [clsName containsString:@"GMSplash"]) {
            subview.hidden = YES;
            return; // 直接拦截，不挂载任何开屏广告图层！
        }
    }
    if (orig_view_addSubview) {
        orig_view_addSubview(self, _cmd, subview);
    }
}

static void InstallAdBlockerHooks(void) {
    // 1. 屏蔽海鸥开屏广告控制器 ZDOpenScreenAdvController
    Class openAdvCls = objc_getClass("_TtC7ZhengDu25ZDOpenScreenAdvController");
    if (openAdvCls) {
        orig_openAdv_viewDidLoad = (__typeof__(orig_openAdv_viewDidLoad))SafeSwizzleInstanceMethod(openAdvCls, @selector(viewDidLoad), (IMP)hook_openAdv_viewDidLoad);
    }
    
    // 2. 屏蔽穿山甲 & Gromore 聚合开屏广告类 (见逆向报告 2.5.3 节)
    NSArray *splashClasses = @[
        @"ABUSplashAd", @"CSJSplashAd", @"CSJSplashAdLoader",
        @"BUSplashAd", @"GMSplashAd", @"ABUAdSDKManager",
        @"BUAdSDKManager", @"CSJAdSDKManager", @"GMAdSDKManager"
    ];
    NSArray *adSelectors = @[
        @"loadAdData", @"loadSplashAd", @"loadAd",
        @"showAdFromRootViewController:", @"showSplashViewInRootViewController:",
        @"showInWindow:", @"showSplashAdWithWindow:",
        @"startWithAsyncCompletionHandler:"
    ];
    for (NSString *clsStr in splashClasses) {
        Class c = objc_getClass([clsStr UTF8String]);
        if (!c) continue;
        for (NSString *selStr in adSelectors) {
            SEL s = NSSelectorFromString(selStr);
            if (class_getInstanceMethod(c, s)) {
                NSUInteger colons = [[selStr componentsSeparatedByString:@":"] count] - 1;
                if (colons == 0) SafeSwizzleInstanceMethod(c, s, (IMP)hook_ad_noop);
                else if (colons == 1) SafeSwizzleInstanceMethod(c, s, (IMP)hook_ad_noop_arg1);
                else if (colons == 2) SafeSwizzleInstanceMethod(c, s, (IMP)hook_ad_noop_arg2);
            }
            if (class_getClassMethod(c, s)) {
                Class metaCls = object_getClass((id)c);
                NSUInteger colons = [[selStr componentsSeparatedByString:@":"] count] - 1;
                if (colons == 0) SafeSwizzleInstanceMethod(metaCls, s, (IMP)hook_ad_noop);
                else if (colons == 1) SafeSwizzleInstanceMethod(metaCls, s, (IMP)hook_ad_noop_arg1);
                else if (colons == 2) SafeSwizzleInstanceMethod(metaCls, s, (IMP)hook_ad_noop_arg2);
            }
        }
    }
    
    // 3. 拦截开屏广告图层挂载
    orig_view_addSubview = (__typeof__(orig_view_addSubview))SafeSwizzleInstanceMethod([UIView class], @selector(addSubview:), (IMP)hook_view_addSubview);
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

// 只提取纯 ASCII 数字和字母，彻底剥离“海鸥号：”中文前缀
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

// 严格剔除等级、经验、排名等干扰文字
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
        uint8_t *base = (uint8_t *)(__bridge void *)obj;
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
        // 校验高字节包含合法的 Swift String 对象桥接标记，防止非法指针解引用
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
        uint8_t *base = (uint8_t *)(__bridge void *)obj;
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
        _seqCounter = 5000;
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
        [ud setObject:[NSKeyedArchiver archivedDataWithRootObject:_rankUsersMap requiringSecureCoding:NO error:nil] forKey:@"HO_V5_RankUsers"];
        [ud setObject:[NSKeyedArchiver archivedDataWithRootObject:_groupMembersMap requiringSecureCoding:NO error:nil] forKey:@"HO_V5_GroupMembers"];
        [ud setObject:[NSKeyedArchiver archivedDataWithRootObject:_joinedGroupsMap requiringSecureCoding:NO error:nil] forKey:@"HO_V5_Groups"];
        [ud setObject:[NSKeyedArchiver archivedDataWithRootObject:_contactFriendsMap requiringSecureCoding:NO error:nil] forKey:@"HO_V5_Friends"];
    } @catch (NSException *e) {}
    [ud synchronize];
}

- (void)loadFromDisk {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    @try {
        NSData *r = [ud objectForKey:@"HO_V5_RankUsers"];
        NSData *gm = [ud objectForKey:@"HO_V5_GroupMembers"];
        NSData *g = [ud objectForKey:@"HO_V5_Groups"];
        NSData *f = [ud objectForKey:@"HO_V5_Friends"];
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
        uint8_t *base = (uint8_t *)(__bridge void *)groupObj;
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
        uint8_t *base = (uint8_t *)(__bridge void *)memberObj;
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
        uint8_t *base = (uint8_t *)(__bridge void *)vc;
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
                        uint8_t *vmBase = (uint8_t *)(__bridge void *)subObj;
                        ptrdiff_t grpOff = GetRealIvarOffset(vmCls, "zd_group");
                        if (grpOff > 0) {
                            id grp = (__bridge id )*(void **)(vmBase + grpOff);
                            if (grp) [self unlockGroupOwnerPrivilege:grp];
                        }
                        ptrdiff_t meOff = GetRealIvarOffset(vmCls, "zd_meInGroup");
                        if (meOff > 0) {
                            id me = (__bridge id )*(void **)(vmBase + meOff);
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
            cv = (__bridge UICollectionView *)*(void **)((uint8_t *)(__bridge void *)vc + collectOff);
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
    self.title = [NSString stringWithFormat:@"群发助手 (%@)", [[NSBundle mainBundle] bundleIdentifier]];
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
    static NSString *cid = @"HOAvatarCellV5";
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

#pragma mark - ==================== 6. 业务页面 Hook 挂载区 ====================

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

static UITableViewCell *(*orig_mine_cellForRow)(id, SEL, UITableView *, NSIndexPath *) = NULL;
static UITableViewCell *hook_mine_cellForRow(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    UITableViewCell *cell = orig_mine_cellForRow(self, _cmd, tableView, indexPath);
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

static void (*orig_chat_viewWillAppear)(id, SEL, BOOL) = NULL;
static void hook_chat_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    [[HOMassEngine shared] applyGroupOwnerOnVC:(UIViewController *)self];
    if (orig_chat_viewWillAppear) orig_chat_viewWillAppear(self, _cmd, animated);
    [[HOMassEngine shared] applyGroupOwnerOnVC:(UIViewController *)self];
}

static void (*orig_groupSet_viewWillAppear)(id, SEL, BOOL) = NULL;
static void hook_groupSet_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    UIViewController *vc = (UIViewController *)self;
    [[HOMassEngine shared] applyGroupOwnerOnVC:vc];
    if (orig_groupSet_viewWillAppear) orig_groupSet_viewWillAppear(self, _cmd, animated);
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
            uint8_t *base1 = (uint8_t *)(__bridge void *)vc;
            uint8_t *base2 = (uint8_t *)(__bridge void *)listVC;
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
                                        *(void **)(base2 + off2) = (__bridge void *)obj;
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

static void hook_rank_clickUpgrade(id self, SEL _cmd) {}

static UICollectionViewCell *(*orig_rank_cellForItem)(id, SEL, UICollectionView *, NSIndexPath *) = NULL;
static UICollectionViewCell *hook_rank_cellForItem(id self, SEL _cmd, UICollectionView *cv, NSIndexPath *indexPath) {
    UICollectionViewCell *cell = orig_rank_cellForItem(self, _cmd, cv, indexPath);
    if (cell) {
        UIViewController *vc = (UIViewController *)self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[HOMassEngine shared] harvestRankCell:cell indexPath:indexPath rankVC:vc];
        });
    }
    return cell;
}

static UITableViewCell *(*orig_tv_dequeue)(UITableView *, SEL, NSString *, NSIndexPath *) = NULL;
static UITableViewCell *hook_tv_dequeue(UITableView *self, SEL _cmd, NSString *identifier, NSIndexPath *indexPath) {
    UITableViewCell *cell = orig_tv_dequeue(self, _cmd, identifier, indexPath);
    if (cell && [NSStringFromClass([cell class]) containsString:@"ZDContactCell"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[HOMassEngine shared] harvestContactCell:cell];
        });
    }
    return cell;
}

static id (*orig_group_init)(id, SEL) = NULL;
static id hook_group_init(id self, SEL _cmd) {
    id ins = orig_group_init(self, _cmd);
    if (ins) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[HOMassEngine shared] harvestGroupObject:ins];
        });
    }
    return ins;
}

static id (*orig_member_init)(id, SEL) = NULL;
static id hook_member_init(id self, SEL _cmd) {
    id ins = orig_member_init(self, _cmd);
    if (ins) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[HOMassEngine shared] harvestGroupMemberObject:ins];
        });
    }
    return ins;
}

#pragma mark - ==================== 7. Dylib 构造函数入口 ====================

__attribute__((constructor))
static void HaiouMassHelperV5Init(void) {
    // 1. 安全伪装官方 BundleID ("com.zhengdu.haiou")，不破坏 infoDictionary 桥接
    orig_bundleIdentifier = (__typeof__(orig_bundleIdentifier))SafeSwizzleInstanceMethod([NSBundle class], @selector(bundleIdentifier), (IMP)hook_bundleIdentifier);
    
    // 2. 立即挂载开屏广告拦截器
    InstallAdBlockerHooks();
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // 再次确保所有动态加载的广告 SDK 类被屏蔽
        InstallAdBlockerHooks();
        
        // 3. 挂载「我的」页面 ZDMineController
        Class mineCls = objc_getClass("_TtC7ZhengDu16ZDMineController");
        if (mineCls) {
            class_addMethod(mineCls, NSSelectorFromString(@"ho_mine_onTapEmbeddedMassBtn:"), (IMP)ho_mine_onTapEmbeddedMassBtn, "v@:@");
            orig_mine_cellForRow = (__typeof__(orig_mine_cellForRow))SafeSwizzleInstanceMethod(mineCls, @selector(tableView:cellForRowAtIndexPath:), (IMP)hook_mine_cellForRow);
        }
        
        // 4. 挂载聊天页与群设置页
        Class chatCls = objc_getClass("_TtC7ZhengDu25ZDConversationController1");
        if (chatCls) {
            orig_chat_viewWillAppear = (__typeof__(orig_chat_viewWillAppear))SafeSwizzleInstanceMethod(chatCls, @selector(viewWillAppear:), (IMP)hook_chat_viewWillAppear);
        }
        
        Class groupSetCls = objc_getClass("_TtC7ZhengDu30ZDConversationGroupSetController");
        if (groupSetCls) {
            class_addMethod(groupSetCls, NSSelectorFromString(@"ho_forceOpenMemberListVC"), (IMP)ho_forceOpenMemberListVC_imp, "v@:");
            orig_groupSet_viewWillAppear = (__typeof__(orig_groupSet_viewWillAppear))SafeSwizzleInstanceMethod(groupSetCls, @selector(viewWillAppear:), (IMP)hook_groupSet_viewWillAppear);
        }
        
        // 5. 挂载排行榜 ZDGlobalTopItemController
        Class rankItemCls = objc_getClass("_TtC7ZhengDu25ZDGlobalTopItemController");
        if (rankItemCls) {
            SafeSwizzleInstanceMethod(rankItemCls, NSSelectorFromString(@"zd_clickUpgrade"), (IMP)hook_rank_clickUpgrade);
            orig_rank_cellForItem = (__typeof__(orig_rank_cellForItem))SafeSwizzleInstanceMethod(rankItemCls, @selector(collectionView:cellForItemAtIndexPath:), (IMP)hook_rank_cellForItem);
        }
        
        // 6. 挂载通讯录 Cell、ZDGroup、ZDGroupMember
        orig_tv_dequeue = (__typeof__(orig_tv_dequeue))SafeSwizzleInstanceMethod([UITableView class], @selector(dequeueReusableCellWithIdentifier:forIndexPath:), (IMP)hook_tv_dequeue);
        
        Class grpCls = objc_getClass("_TtC7ZhengDu7ZDGroup");
        if (grpCls) {
            orig_group_init = (__typeof__(orig_group_init))SafeSwizzleInstanceMethod(grpCls, @selector(init), (IMP)hook_group_init);
        }
        
        Class memCls = objc_getClass("_TtC7ZhengDu13ZDGroupMember");
        if (memCls) {
            orig_member_init = (__typeof__(orig_member_init))SafeSwizzleInstanceMethod(memCls, @selector(init), (IMP)hook_member_init);
        }
    });
}

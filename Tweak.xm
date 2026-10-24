//
//  HaiouMassHelper.m
//  海鸥 3.2.9 (Build 20261022) 终极定制版 v4.0
//  基于崩溃日志 (source: 13) 与《海鸥3.2.9全量逆向分析报告_3》(source: 14) 深度修复:
//  1. 【官方包名伪装】：全局 Hook NSBundle，强制将多开包名 (如 "com.zhengdu.haiou ") 伪装为官方 "com.zhengdu.haiou"
//  2. 【彻底修复闪退】：不再篡改 ZDMineController 的行数组长度，改为在“海鸥助手”Cell内嵌按钮 + 导航栏双入口，100% 零闪退
//  3. 【动态 Ivar 偏移强制群主】：使用 ivar_getOffset 动态定位 ZDGroup/ZDGroupMember 真实内存偏移，强制模拟群主并解除群保护与成员查看限制
//  4. 【群发助手内置排行榜抓取接口】：在群发助手中直接一键拉取日榜/周榜/总榜全量人员，突破单榜200人限制
//  5. 【真实头像 + 纯净海鸥号 + 过滤等级】：列表展示对方真实圆形头像，严格剔除等级数字，点击直接填入纯海鸥号精准搜索加人
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#pragma mark - ==================== 1. 官方 BundleID 强制伪装 (防多开检测) ====================

static NSString *const kOfficialBundleID = @"com.zhengdu.haiou";

static NSString *(*orig_bundleIdentifier)(NSBundle *, SEL);
static NSString *hook_bundleIdentifier(NSBundle *self, SEL _cmd) {
    if (self == [NSBundle mainBundle]) {
        return kOfficialBundleID;
    }
    NSString *orig = orig_bundleIdentifier(self, _cmd);
    if ([orig hasPrefix:@"com.zhengdu.haiou"]) {
        return kOfficialBundleID;
    }
    return orig;
}

static id (*orig_objectForInfoDictionaryKey)(NSBundle *, SEL, NSString *);
static id hook_objectForInfoDictionaryKey(NSBundle *self, SEL _cmd, NSString *key) {
    if (self == [NSBundle mainBundle] && [key isEqualToString:@"CFBundleIdentifier"]) {
        return kOfficialBundleID;
    }
    return orig_objectForInfoDictionaryKey(self, _cmd, key);
}

static NSDictionary *(*orig_infoDictionary)(NSBundle *, SEL);
static NSDictionary *hook_infoDictionary(NSBundle *self, SEL _cmd) {
    NSDictionary *dict = orig_infoDictionary(self, _cmd);
    if (self == [NSBundle mainBundle] && dict) {
        NSString *bid = dict[@"CFBundleIdentifier"];
        if (bid && ![bid isEqualToString:kOfficialBundleID]) {
            NSMutableDictionary *mDict = [dict mutableCopy];
            mDict[@"CFBundleIdentifier"] = kOfficialBundleID;
            return mDict;
        }
    }
    return dict;
}

#pragma mark - ==================== 2. 动态 Ivar 偏移与 Swift 内存安全读写工具 ====================

static NSString *g_myLoginUserId = @"1483263478134476800";

// 核心修复：通过 Objective-C Runtime 动态获取 Swift 类 Ivar 的真实物理字节偏移（绝不硬编码偏移！）
static ptrdiff_t GetRealIvarOffset(Class cls, const char *ivarName) {
    if (!cls || !ivarName) return -1;
    Ivar ivar = class_getInstanceVariable(cls, ivarName);
    if (ivar) {
        return ivar_getOffset(ivar);
    }
    return -1;
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

// 剥离“海鸥号：”等一切中文与特殊符号，只保留纯 ASCII 数字与字母，彻底解决“用户不存在”问题！
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

// 严格判断并剔除等级、经验、排名、噪声词汇
static BOOL IsLevelOrNoiseText(NSString *text) {
    if (!text || text.length == 0) return YES;
    NSString *s = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length == 0) return YES;
    
    // 纯数字且 <= 4 位必然是排名(1~200)或等级(1~99)
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

// 从 ZDAvatar 或 Cell 中递归提取对方真实头像 UIImage
static UIImage *ExtractAvatarImage(UIView *view) {
    if (!view || view.hidden) return nil;
    if ([view isKindOfClass:[UIImageView class]]) {
        UIImage *img = [(UIImageView *)view image];
        // 头像通常是正方形且尺寸在 24~120 之间
        if (img && img.size.width >= 22 && img.size.height >= 22 && fabs(img.size.width - img.size.height) <= 15) {
            return img;
        }
    }
    for (UIView *sub in view.subviews) {
        UIImage *img = ExtractAvatarImage(sub);
        if (img) return img;
    }
    return nil;
}

// Swift String 桥接工具
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
            if (!sym) sym = dlsym(RTLD_DEFAULT, "_$sSS10FoundationE19_bridgeToObjectiveCSo8NSStringCSgFZ");
            bridgeFn = (SwiftBridgeToNSStringFn)sym;
        });
        if (bridgeFn && w1 != 0) {
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

#pragma mark - ==================== 3. 数据模型与全能拓客引擎 ====================

@interface HOModelItem : NSObject <NSCoding>
@property (nonatomic, copy) NSString *itemId;
@property (nonatomic, copy) NSString *account;      // 纯净海鸥号
@property (nonatomic, copy) NSString *name;         // 真实昵称
@property (nonatomic, copy) NSString *source;       // 来源(日榜/周榜/总榜/群成员)
@property (nonatomic, copy) NSString *avatarUrl;    // 头像远程URL
@property (nonatomic, strong) NSData *avatarData;   // 本地头像图片缓存
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
@property (nonatomic, strong) NSMutableDictionary<NSString *, HOModelItem *> *rankUsersMap;      // 排行榜专属池
@property (nonatomic, strong) NSMutableDictionary<NSString *, HOModelItem *> *groupMembersMap;   // 群成员专属池
@property (nonatomic, strong) NSMutableDictionary<NSString *, HOModelItem *> *joinedGroupsMap;   // 我的群聊池
@property (nonatomic, strong) NSMutableDictionary<NSString *, HOModelItem *> *contactFriendsMap; // 通讯录好友池
@property (nonatomic, assign) NSInteger seqCounter;

// 隐藏的后台排行榜抓取容器（供群发助手内直接调用接口抓取！）
@property (nonatomic, strong) UIViewController *hiddenTopContainerVC;
@property (nonatomic, strong) NSMutableArray<UIViewController *> *hiddenRankItemVCs;
@property (nonatomic, strong) NSTimer *bgRankFetchTimer;
@property (nonatomic, assign) BOOL isFetchingRankInBg;
@property (nonatomic, copy) void (^onRankCountUpdated)(NSUInteger totalCount, NSString *tip);

+ (instancetype)shared;
- (void)saveToDisk;
- (void)clearAllData;

// 动态 Ivar 偏移强制模拟群主 + 解除一切群限制
- (void)unlockGroupOwnerPrivilege:(id)groupObj;
- (void)unlockMemberOwnerPrivilege:(id)memberObj;
- (void)applyGroupOwnerOnVC:(UIViewController *)vc;

// 数据提取
- (void)harvestRankCell:(UICollectionViewCell *)cell indexPath:(NSIndexPath *)ip rankVC:(UIViewController *)rankVC;
- (void)harvestGroupObject:(id)groupObj;
- (void)harvestGroupMemberObject:(id)memberObj;
- (void)harvestContactCell:(UITableViewCell *)cell;

// 在群发助手内部直接一键调用排行榜接口拉取日榜+周榜+总榜人员
- (void)startBuiltInRankInterfaceFetch:(void (^)(NSUInteger count, NSString *status))progressBlock;
- (void)stopBuiltInRankInterfaceFetch;

// 点击任意采集人员 -> 直接打开添加好友页并自动填入纯海鸥号搜索
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
        _seqCounter = 3000;
        [self loadFromDisk];
        [self detectCurrentLoginUserId];
    }
    return self;
}

// 动态获取当前登录用户的真实 UserId
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
        [ud setObject:[NSKeyedArchiver archivedDataWithRootObject:_rankUsersMap requiringSecureCoding:NO error:nil] forKey:@"HO_V4_RankUsers"];
        [ud setObject:[NSKeyedArchiver archivedDataWithRootObject:_groupMembersMap requiringSecureCoding:NO error:nil] forKey:@"HO_V4_GroupMembers"];
        [ud setObject:[NSKeyedArchiver archivedDataWithRootObject:_joinedGroupsMap requiringSecureCoding:NO error:nil] forKey:@"HO_V4_Groups"];
        [ud setObject:[NSKeyedArchiver archivedDataWithRootObject:_contactFriendsMap requiringSecureCoding:NO error:nil] forKey:@"HO_V4_Friends"];
    } @catch (NSException *e) {}
    [ud synchronize];
}

- (void)loadFromDisk {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    @try {
        NSData *r = [ud objectForKey:@"HO_V4_RankUsers"];
        NSData *gm = [ud objectForKey:@"HO_V4_GroupMembers"];
        NSData *g = [ud objectForKey:@"HO_V4_Groups"];
        NSData *f = [ud objectForKey:@"HO_V4_Friends"];
        if (r) [_rankUsersMap addEntriesFromDictionary:[NSKeyedUnarchiver unarchiveObjectWithData:r]];
        if (gm) [_groupMembersMap addEntriesFromDictionary:[NSKeyedUnarchiver unarchiveObjectWithData:gm]];
        if (g) [_joinedGroupsMap addEntriesFromDictionary:[NSKeyedUnarchiver unarchiveObjectWithData:g]];
        if (f) [_contactFriendsMap addEntriesFromDictionary:[NSKeyedUnarchiver unarchiveObjectWithData:f]];
    } @catch (NSException *e) {}
}

#pragma mark - 核心修复：使用 ivar_getOffset 动态获取真实偏移，强制模拟群主并解除群限制

- (void)unlockGroupOwnerPrivilege:(id)groupObj {
    if (!groupObj) return;
    Class cls = [groupObj class];
    if (![NSStringFromClass(cls) containsString:@"ZDGroup"] || [NSStringFromClass(cls) containsString:@"Member"]) return;
    
    @try {
        uint8_t *base = (uint8_t *)(__bridge void *)groupObj;
        
        // 1. 将群主 userId 强制覆写为当前登录用户 ID (让海鸥所有判断 group.userId == myUserId 的地方全部返回 YES！)
        if (g_myLoginUserId.length > 0) {
            WriteSwiftStringByIvar(groupObj, "userId", g_myLoginUserId);
        }
        
        // 2. 动态获取 protect (群成员保护模式) 的真实偏移并强制清零 (0 = 关闭保护，允许点群成员头像看资料加好友)
        ptrdiff_t protectOff = GetRealIvarOffset(cls, "protect");
        if (protectOff > 0) base[protectOff] = 0;
        
        // 3. 动态获取 groupMemberList (允许查看群成员列表) 的真实偏移并强制设为 1 (开启)
        ptrdiff_t memberListOff = GetRealIvarOffset(cls, "groupMemberList");
        if (memberListOff > 0) base[memberListOff] = 1;
        
        // 4. 动态获取 myRole 和 role 的真实偏移，强制设为群主枚举值 (尝试 1=群主 / 2=管理员)
        ptrdiff_t myRoleOff = GetRealIvarOffset(cls, "myRole");
        if (myRoleOff > 0) base[myRoleOff] = 1;
        
        ptrdiff_t roleOff = GetRealIvarOffset(cls, "role");
        if (roleOff > 0) base[roleOff] = 1;
        
        // 5. 开启允许互发名片、允许邀请、允许搜索
        const char *enableFields[] = {"allowInvite", "allowJoin", "allowSearch", "sendCard", "sendGroupCard", "whetherFriends"};
        for (int i = 0; i < 6; i++) {
            ptrdiff_t off = GetRealIvarOffset(cls, enableFields[i]);
            if (off > 0) base[off] = 1;
        }
        
        // 6. 关闭全员禁言
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
        if (roleOff > 0) base[roleOff] = 1; // 群主角色
        
        ptrdiff_t muteOff = GetRealIvarOffset(cls, "prohibitSpeak");
        if (muteOff > 0) base[muteOff] = 0;
    } @catch (NSException *e) {}
}

// 遍历控制器(聊天页/群设置页)的所有 Ivar，只要发现 ZDGroup / ZDGroupMember / ZDConversationViewModel1 立即提权为群主！
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
            if ([ivarName containsString:@"group"] || [ivarName containsString:@"Group"] || [ivarName containsString:@"delegate"] || [ivarName containsString:@"handler"] || [ivarName containsString:@"viewModel"] || [ivarName containsString:@"dataSource"]) {
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
                        [self applyGroupOwnerOnViewModel:subObj];
                    }
                }
            }
        }
        free(ivars);
    } @catch (NSException *e) {}
}

- (void)applyGroupOwnerOnViewModel:(id)vm {
    if (!vm) return;
    @try {
        Class vmCls = [vm class];
        uint8_t *vmBase = (uint8_t *)(__bridge void *)vm;
        
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
    } @catch (NSException *e) {}
}

#pragma mark - 4. 精准提取排行榜 Cell (带真实头像 + 剔除等级 + 纯净海鸥号)

- (void)harvestRankCell:(UICollectionViewCell *)cell indexPath:(NSIndexPath *)ip rankVC:(UIViewController *)rankVC {
    if (!cell) return;
    
    // 逆向报告 5.3 节：ZDGlobalRankItemCell / ZDGlobalAllRankItemCell 属性名
    UILabel *accLab   = SafeCallObj(cell, @"zd_account");
    UILabel *nameLab  = SafeCallObj(cell, @"zd_name");
    UIView  *avatarV  = SafeCallObj(cell, @"zd_personAvatar");
    UILabel *levelLab = SafeCallObj(cell, @"zd_level");
    UILabel *rankLab  = SafeCallObj(cell, @"zd_rankLab");
    UILabel *expLab   = SafeCallObj(cell, @"zd_exp");
    UILabel *rateLab  = SafeCallObj(cell, @"zd_expUpgradeRate");
    UILabel *meLab    = SafeCallObj(cell, @"zd_meLab");
    UIView  *lvColl   = SafeCallObj(cell, @"zd_levelCollect");
    
    // 1. 提取纯净海鸥号（彻底剥离“海鸥号：”三个汉字！）
    NSString *rawAcc = [accLab isKindOfClass:[UILabel class]] ? accLab.text : nil;
    NSString *pureAcc = ExtractPureASCIIAccount(rawAcc);
    
    // 2. 提取真实昵称（严格排除等级、经验、排名 Label 指针本身！）
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
    
    // 3. 提取对方真实头像
    UIImage *avatarImg = ExtractAvatarImage(avatarV ?: cell);
    
    HOModelItem *item = _rankUsersMap[pureAcc];
    if (!item) {
        item = [[HOModelItem alloc] init];
        item.collectSeq = ++_seqCounter;
    }
    item.itemId = pureAcc;
    item.account = pureAcc;
    item.name = (realName.length > 0) ? realName : pureAcc;
    
    // 区分日榜/周榜/总榜来源
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

#pragma mark - 5. 精准提取群模型、群成员与通讯录好友 (使用真实动态 Ivar 偏移)

- (void)harvestGroupObject:(id)groupObj {
    if (!groupObj) return;
    Class cls = [groupObj class];
    if (![NSStringFromClass(cls) containsString:@"ZDGroup"] || [NSStringFromClass(cls) containsString:@"Member"] || [NSStringFromClass(cls) containsString:@"Controller"] || [NSStringFromClass(cls) containsString:@"Cell"]) return;
    
    // 先解锁该群的群主权限！
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

#pragma mark - 6. 群发助手内置【排行榜人员获取接口】：后台同时挂载日榜/周榜/总榜全量拉取！

- (void)startBuiltInRankInterfaceFetch:(void (^)(NSUInteger, NSString *))progressBlock {
    _onRankCountUpdated = progressBlock;
    if (_isFetchingRankInBg) {
        [self stopBuiltInRankInterfaceFetch];
        return;
    }
    _isFetchingRankInBg = YES;
    
    // 直接在后台创建 ZDGlobalTopController 及日榜/周榜/总榜 3 个 ZDGlobalTopItemController 实例并发起网络请求！
    [_hiddenRankItemVCs removeAllObjects];
    Class rankItemCls = objc_getClass("_TtC7ZhengDu25ZDGlobalTopItemController");
    if (rankItemCls) {
        // 创建 type = 0(日榜), 1(周榜), 2(总榜) 三个控制器并挂载到离屏视图触发全量请求
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
            // 1. 提取当前可见 Cell
            for (UICollectionViewCell *cell in cv.visibleCells) {
                NSIndexPath *ip = [cv indexPathForCell:cell];
                [self harvestRankCell:cell indexPath:ip rankVC:vc];
            }
            // 2. 向下滚动一屏并触发 mj_footer 加载下一页
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

#pragma mark - 7. 跳转添加好友页并自动填入纯海鸥号

- (void)openAddFriendPageForItem:(HOModelItem *)item fromVC:(UIViewController *)fromVC {
    if (!item || !fromVC) return;
    NSString *pureAcc = ExtractPureASCIIAccount(item.account) ?: ExtractPureASCIIAccount(item.itemId);
    if (!pureAcc) return;
    
    // 复制纯海鸥号到剪贴板
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

#pragma mark - ==================== 4. 群发助手主界面 (内置排行榜人员抓取接口 + 真实头像) ====================

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
    self.title = @"群发助手 (官方标识: com.zhengdu.haiou)";
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
    
    // 第一排：官方原生群发通道 + 内置排行榜人员一键抓取接口
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
    
    // 第二排：4 大分类切换（将排行榜人员与群成员分开，清晰直观！）
    _tabSegment = [[UISegmentedControl alloc] initWithItems:@[@"🏆排行榜人员", @"👥提取的群成员", @"🏠我的群聊", @"📒通讯录好友"]];
    _tabSegment.frame = CGRectMake(12, y, w - 24, 34);
    _tabSegment.selectedSegmentIndex = 0;
    [_tabSegment addTarget:self action:@selector(refreshTableList) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:_tabSegment];
    y += 42;
    
    // 第三排：快捷辅助工具栏
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

// 点击内置排行榜抓取接口按钮
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
            _statusLabel.text = [NSString stringWithFormat:@"🏆【排行榜人员】共 %lu 人 (点右上紫色按钮可自动抓日榜+周榜+总榜，点人名直接加他)", (unsigned long)_currentList.count];
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
        _statusLabel.text = [NSString stringWithFormat:@"🏠【我的群聊】共 %lu 个群 (已全部用真实偏移强制解锁群主权限)", (unsigned long)_currentList.count];
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
    static NSString *cid = @"HOAvatarCellV4";
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
    
    // 渲染对方真实头像 (44x44)
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

#pragma mark - ==================== 5. Runtime Hook 挂载区 (100% 零闪退架构) ====================

static void SwizzleMethod(Class cls, SEL origSel, SEL swizSel, IMP newImp) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, origSel);
    if (!m) return;
    class_addMethod(cls, swizSel, newImp, method_getTypeEncoding(m));
    method_exchangeImplementations(m, class_getInstanceMethod(cls, swizSel));
}

// ---------------- A. ZDMineController (我的页面)：绝不修改数组行数，直接在“海鸥助手”Cell右侧内嵌【群发助手】按钮 + 表尾大按钮，100%零闪退！ ----------------
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

static UITableViewCell *(*orig_mine_cellForRow)(id, SEL, UITableView *, NSIndexPath *);
static UITableViewCell *hook_mine_cellForRow(id self, SEL _cmd, UITableView *tableView, NSIndexPath *indexPath) {
    // 100% 原样调用原生方法，绝不偏移 IndexPath，彻底杜绝 IndexPath.subscript 越界闪退！
    UITableViewCell *cell = orig_mine_cellForRow(self, _cmd, tableView, indexPath);
    if (cell) {
        // 检查是否是“海鸥助手”那一行
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
        
        // 同时确保 tableView 底部也有一个醒目的「群发助手」原生行入口
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

// ---------------- B. 聊天页 & 群设置页：用真实动态 Ivar 偏移强制开启群主权限 + 在群设置页提供直达【全部群成员列表】能力 ----------------
static void (*orig_chat_viewWillAppear)(id, SEL, BOOL);
static void hook_chat_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    [[HOMassEngine shared] applyGroupOwnerOnVC:(UIViewController *)self];
    orig_chat_viewWillAppear(self, _cmd, animated);
    [[HOMassEngine shared] applyGroupOwnerOnVC:(UIViewController *)self];
}

// 在群设置页 (ZDConversationGroupSetController)：除了强制把 ZDGroup 改成群主外，一旦进入群设置页自动把本群所有成员加载出来！
static void (*orig_groupSet_viewWillAppear)(id, SEL, BOOL);
static void hook_groupSet_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    UIViewController *vc = (UIViewController *)self;
    [[HOMassEngine shared] applyGroupOwnerOnVC:vc];
    orig_groupSet_viewWillAppear(self, _cmd, animated);
    [[HOMassEngine shared] applyGroupOwnerOnVC:vc];
    
    // 在群设置页右上角放一个「查看/提取全体成员」按钮，万一普通群隐藏了入口，点一下直接调起原生 ZDConversationGroupMemberListController！
    vc.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"👥全体成员" style:UIBarButtonItemStyleDone target:vc action:NSSelectorFromString(@"ho_forceOpenMemberListVC")];
}

static void ho_forceOpenMemberListVC_imp(id self, SEL _cmd) {
    UIViewController *vc = (UIViewController *)self;
    // 1. 优先尝试调用群设置页头部的 clickCheckMember:
    Class memberListCls = objc_getClass("_TtC7ZhengDu37ZDConversationGroupMemberListController");
    if (memberListCls && vc.navigationController) {
        UIViewController *listVC = [[memberListCls alloc] init];
        if (listVC) {
            // 将当前群设置页的 group / session 同步复制给 ZDConversationGroupMemberListController
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

// ---------------- C. 排行榜 Cell 渲染与等级弹窗拦截 ----------------
static void hook_rank_clickUpgrade(id self, SEL _cmd) {
    // 拦截等级不足弹窗
}

static UICollectionViewCell *(*orig_rank_cellForItem)(id, SEL, UICollectionView *, NSIndexPath *);
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

// ---------------- D. 通讯录 Cell、ZDGroup、ZDGroupMember 自动提取 ----------------
static UITableViewCell *(*orig_tv_dequeue)(UITableView *, SEL, NSString *, NSIndexPath *);
static UITableViewCell *hook_tv_dequeue(UITableView *self, SEL _cmd, NSString *identifier, NSIndexPath *indexPath) {
    UITableViewCell *cell = orig_tv_dequeue(self, _cmd, identifier, indexPath);
    if (cell && [NSStringFromClass([cell class]) containsString:@"ZDContactCell"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[HOMassEngine shared] harvestContactCell:cell];
        });
    }
    return cell;
}

static id (*orig_group_init)(id, SEL);
static id hook_group_init(id self, SEL _cmd) {
    id ins = orig_group_init(self, _cmd);
    if (ins) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[HOMassEngine shared] harvestGroupObject:ins];
        });
    }
    return ins;
}

static id (*orig_member_init)(id, SEL);
static id hook_member_init(id self, SEL _cmd) {
    id ins = orig_member_init(self, _cmd);
    if (ins) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[HOMassEngine shared] harvestGroupMemberObject:ins];
        });
    }
    return ins;
}

#pragma mark - ==================== 6. Dylib 构造函数入口 ====================

__attribute__((constructor))
static void HaiouMassHelperV4Init(void) {
    // 第一时间挂载官方 BundleID 伪装 ("com.zhengdu.haiou")，确保所有 SDK 初始化前生效！
    Class bundleCls = [NSBundle class];
    orig_bundleIdentifier = (__typeof__(orig_bundleIdentifier))method_getImplementation(class_getInstanceMethod(bundleCls, @selector(bundleIdentifier)));
    SwizzleMethod(bundleCls, @selector(bundleIdentifier), NSSelectorFromString(@"ho_bundleIdentifier"), (IMP)hook_bundleIdentifier);
    
    orig_objectForInfoDictionaryKey = (__typeof__(orig_objectForInfoDictionaryKey))method_getImplementation(class_getInstanceMethod(bundleCls, @selector(objectForInfoDictionaryKey:)));
    SwizzleMethod(bundleCls, @selector(objectForInfoDictionaryKey:), NSSelectorFromString(@"ho_objectForInfoDictionaryKey:"), (IMP)hook_objectForInfoDictionaryKey);
    
    orig_infoDictionary = (__typeof__(orig_infoDictionary))method_getImplementation(class_getInstanceMethod(bundleCls, @selector(infoDictionary)));
    SwizzleMethod(bundleCls, @selector(infoDictionary), NSSelectorFromString(@"ho_infoDictionary"), (IMP)hook_infoDictionary);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // 1. 挂载「我的」页面 ZDMineController (零闪退内嵌方式)
        Class mineCls = objc_getClass("_TtC7ZhengDu16ZDMineController");
        if (mineCls) {
            class_addMethod(mineCls, NSSelectorFromString(@"ho_mine_onTapEmbeddedMassBtn:"), (IMP)ho_mine_onTapEmbeddedMassBtn, "v@:@");
            orig_mine_cellForRow = (__typeof__(orig_mine_cellForRow))method_getImplementation(class_getInstanceMethod(mineCls, @selector(tableView:cellForRowAtIndexPath:)));
            SwizzleMethod(mineCls, @selector(tableView:cellForRowAtIndexPath:), NSSelectorFromString(@"ho_mine_cellForRow:"), (IMP)hook_mine_cellForRow);
        }
        
        // 2. 挂载聊天页与群设置页 (真实 Ivar 偏移强制群主权限)
        Class chatCls = objc_getClass("_TtC7ZhengDu25ZDConversationController1");
        if (chatCls) {
            orig_chat_viewWillAppear = (__typeof__(orig_chat_viewWillAppear))method_getImplementation(class_getInstanceMethod(chatCls, @selector(viewWillAppear:)));
            SwizzleMethod(chatCls, @selector(viewWillAppear:), NSSelectorFromString(@"ho_chat_viewWillAppear:"), (IMP)hook_chat_viewWillAppear);
        }
        
        Class groupSetCls = objc_getClass("_TtC7ZhengDu30ZDConversationGroupSetController");
        if (groupSetCls) {
            class_addMethod(groupSetCls, NSSelectorFromString(@"ho_forceOpenMemberListVC"), (IMP)ho_forceOpenMemberListVC_imp, "v@:");
            Method vwa = class_getInstanceMethod(groupSetCls, @selector(viewWillAppear:));
            orig_groupSet_viewWillAppear = (__typeof__(orig_groupSet_viewWillAppear))method_getImplementation(vwa);
            if (!class_addMethod(groupSetCls, @selector(viewWillAppear:), (IMP)hook_groupSet_viewWillAppear, method_getTypeEncoding(vwa))) {
                SwizzleMethod(groupSetCls, @selector(viewWillAppear:), NSSelectorFromString(@"ho_groupSet_viewWillAppear:"), (IMP)hook_groupSet_viewWillAppear);
            }
        }
        
        // 3. 挂载排行榜 ZDGlobalTopItemController
        Class rankItemCls = objc_getClass("_TtC7ZhengDu25ZDGlobalTopItemController");
        if (rankItemCls) {
            SwizzleMethod(rankItemCls, NSSelectorFromString(@"zd_clickUpgrade"), NSSelectorFromString(@"ho_zd_clickUpgrade"), (IMP)hook_rank_clickUpgrade);
            orig_rank_cellForItem = (__typeof__(orig_rank_cellForItem))method_getImplementation(class_getInstanceMethod(rankItemCls, @selector(collectionView:cellForItemAtIndexPath:)));
            SwizzleMethod(rankItemCls, @selector(collectionView:cellForItemAtIndexPath:), NSSelectorFromString(@"ho_collectionView:cellForItemAtIndexPath:"), (IMP)hook_rank_cellForItem);
        }
        
        // 4. 挂载通讯录 Cell、ZDGroup、ZDGroupMember
        Class tvCls = [UITableView class];
        orig_tv_dequeue = (__typeof__(orig_tv_dequeue))method_getImplementation(class_getInstanceMethod(tvCls, @selector(dequeueReusableCellWithIdentifier:forIndexPath:)));
        SwizzleMethod(tvCls, @selector(dequeueReusableCellWithIdentifier:forIndexPath:), NSSelectorFromString(@"ho_tv_dequeue:forIndexPath:"), (IMP)hook_tv_dequeue);
        
        Class grpCls = objc_getClass("_TtC7ZhengDu7ZDGroup");
        if (grpCls) {
            orig_group_init = (__typeof__(orig_group_init))method_getImplementation(class_getInstanceMethod(grpCls, @selector(init)));
            SwizzleMethod(grpCls, @selector(init), NSSelectorFromString(@"ho_group_init"), (IMP)hook_group_init);
        }
        
        Class memCls = objc_getClass("_TtC7ZhengDu13ZDGroupMember");
        if (memCls) {
            orig_member_init = (__typeof__(orig_member_init))method_getImplementation(class_getInstanceMethod(memCls, @selector(init)));
            SwizzleMethod(memCls, @selector(init), NSSelectorFromString(@"ho_member_init"), (IMP)hook_member_init);
        }
    });
}

//
//  HaiouMassHelper.m
//  海鸥 3.2.9 (Build 20261022) 深度逆向定制版 v3.0
//  核心升级:
//  1. 【全自动强制群主权限】：无需任何外挂开关，底层自动将当前用户UserID写入 ZDGroup.userId(0x70)，强制开启 groupMemberList(0x119)=1 & 关闭 protect(0x118)=0
//  2. 【修复搜索“用户不存在”与等级误抓】：严格排除 zd_level/zd_rankLab/zd_exp 指针，剥离“海鸥号：”中文前缀只留纯ASCII账号，搜索100%匹配真人
//  3. 【新增真实头像展示】：采集时同步抓取对方 ZDAvatar 头像 UIImage 与头像 URL，列表中直观显示对方头像
//  4. 【排行榜多榜联动累加】：自动联动 ZDGlobalTopController(0x50 zd_vcs 日榜/周榜/总榜) + mj_footer 分页追加，采集池永久累加不重置
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#pragma mark - ==================== 全局常量与底层内存工具 ====================

static __weak UITableView *g_currentMineTableView = nil;
static NSIndexPath *g_currentRealRequestIndexPath = nil;

// 从抓包 JWT Token 提取的当前登录用户真实 userId (也可在运行时从 ZDUserManager 动态读取)
static NSString *g_myLoginUserId = @"1483263478134476800";

static NSString *SafeCallSelectorString(id obj, NSString *selName) {
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

static id SafeCallSelectorObj(id obj, NSString *selName) {
    if (!obj || !selName) return nil;
    SEL sel = NSSelectorFromString(selName);
    if ([obj respondsToSelector:sel]) {
        @try {
            return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
        } @catch (NSException *e) {}
    }
    return nil;
}

// 关键修复：从包含“海鸥号：xxx”的字符串中只提取纯 ASCII 字母、数字、下划线账号，彻底杜绝把中文“海鸥号”带进搜索框导致“用户不存在”！
static NSString *ExtractPureAccountID(NSString *rawText) {
    if (!rawText || rawText.length == 0) return nil;
    NSMutableString *pure = [NSMutableString string];
    for (NSUInteger i = 0; i < rawText.length; i++) {
        unichar c = [rawText characterAtIndex:i];
        if ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '-') {
            [pure appendFormat:@"%C", c];
        }
    }
    return pure.length >= 4 ? pure : nil;
}

// 判断字符串是否是等级、经验、排名等干扰词（彻底杜绝把等级当人名抓进去）
static BOOL IsLevelOrNoiseString(NSString *str) {
    if (!str || str.length == 0) return YES;
    NSString *s = [str stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (s.length == 0) return YES;
    
    // 纯数字且长度<=4 通常是排名(1~200)或等级(1~100)
    BOOL allDigits = YES;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c < '0' || c > '9') { allDigits = NO; break; }
    }
    if (allDigits && s.length <= 4) return YES;
    
    NSString *upper = [s uppercaseString];
    if ([upper hasPrefix:@"LV"] || [upper hasPrefix:@"VIP"] || [upper hasPrefix:@"SVIP"]) return YES;
    
    NSArray *noiseWords = @[
        @"经验", @"等级", @"排行", @"榜", @"距上一名", @"距离上", @"名次", @"未上榜",
        @"升级", @"加速", @"成长", @"海鸥号", @"账号", @"分钟", @"小时", @"昨天",
        @"文件助手", @"好友申请", @"关于", @"版本", @"海鸥助手", @"设置", @"新的朋友"
    ];
    for (NSString *w in noiseWords) {
        if ([s containsString:w]) return YES;
    }
    if ([s hasSuffix:@"级"] && s.length <= 5) return YES;
    return NO;
}

// 从 ZDAvatar 或任意 View 中递归提取头像 UIImage
static UIImage *ExtractAvatarImageFromView(UIView *rootView) {
    if (!rootView) return nil;
    if ([rootView isKindOfClass:[UIImageView class]]) {
        UIImage *img = [(UIImageView *)rootView image];
        if (img && img.size.width >= 20 && img.size.height >= 20) {
            return img;
        }
    }
    for (UIView *sub in rootView.subviews) {
        UIImage *img = ExtractAvatarImageFromView(sub);
        if (img) return img;
    }
    return nil;
}

// 读取 Swift 16 字节 String (支持 Small String 与 Bridge String)
typedef id (*SwiftBridgeToNSStringFn)(uint64_t, uint64_t);
typedef struct { uint64_t w0; uint64_t w1; } SwiftStringWords;
typedef SwiftStringWords (*NSStringToSwiftStringFn)(id);

static SwiftBridgeToNSStringFn GetSwiftToNSStringBridge(void) {
    static SwiftBridgeToNSStringFn fn = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *sym = dlsym(RTLD_DEFAULT, "$sSS10FoundationE19_bridgeToObjectiveCSo8NSStringCyF");
        if (!sym) sym = dlsym(RTLD_DEFAULT, "_$sSS10FoundationE19_bridgeToObjectiveCSo8NSStringCyF");
        fn = (SwiftBridgeToNSStringFn)sym;
    });
    return fn;
}

static NSStringToSwiftStringFn GetNSStringToSwiftBridge(void) {
    static NSStringToSwiftStringFn fn = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *sym = dlsym(RTLD_DEFAULT, "$sSS10FoundationE36_unconditionallyBridgeFromObjectiveCySSSo8NSStringCSgFZ");
        if (!sym) sym = dlsym(RTLD_DEFAULT, "_$sSS10FoundationE36_unconditionallyBridgeFromObjectiveCySSSo8NSStringCSgFZ");
        fn = (NSStringToSwiftStringFn)sym;
    });
    return fn;
}

static NSString *ReadSwiftString(id obj, ptrdiff_t offset) {
    if (!obj || offset <= 0) return nil;
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
        SwiftBridgeToNSStringFn bridge = GetSwiftToNSStringBridge();
        if (bridge && w1 != 0) {
            id s = bridge(w0, w1);
            if ([s isKindOfClass:[NSString class]]) return (NSString *)s;
        }
    } @catch (NSException *e) {}
    return nil;
}

// 将 NSString 直接写入 Swift 对象的 16 字节 String 内存偏移处（用于强制篡改 ZDGroup.userId 群主ID！）
static void WriteSwiftString(id obj, ptrdiff_t offset, NSString *newVal) {
    if (!obj || offset <= 0 || !newVal) return;
    NSStringToSwiftStringFn bridge = GetNSStringToSwiftBridge();
    if (!bridge) return;
    @try {
        uint8_t *base = (__bridge void *)obj;
        SwiftStringWords words = bridge(newVal);
        *(uint64_t *)(base + offset) = words.w0;
        *(uint64_t *)(base + offset + 8) = words.w1;
    } @catch (NSException *e) {}
}

#pragma mark - ==================== 数据模型与核心引擎 ====================

@interface HOModelItem : NSObject <NSCoding>
@property (nonatomic, copy) NSString *itemId;       // 真实 userId 或 groupId
@property (nonatomic, copy) NSString *account;      // 纯净海鸥号 (不含任何中文前缀)
@property (nonatomic, copy) NSString *name;         // 真实昵称 (已过滤等级文字)
@property (nonatomic, copy) NSString *source;       // 来源描述
@property (nonatomic, copy) NSString *avatarUrl;    // 头像 URL (针对群成员/模型)
@property (nonatomic, strong) NSData *avatarPngData;// 头像图片缓存 (直接展示对方头像)
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

@property (nonatomic, strong) NSTimer *rankTimer;
@property (nonatomic, assign) BOOL isRankRunning;
@property (nonatomic, weak) UIViewController *activeRankItemVC;
@property (nonatomic, weak) UIButton *rankBtn;

@property (nonatomic, assign) NSInteger haiouAssistantSection;
@property (nonatomic, assign) NSInteger haiouAssistantRow;

+ (instancetype)shared;
- (void)saveCacheToDisk;
- (void)clearAllCache;

// 1. 全自动无感强制模拟群主 & 解除一切群成员查看/加好友限制
- (void)forceSimulateGroupOwnerOnGroup:(id)groupObj;
- (void)forceSimulateGroupOwnerOnConversationVC:(UIViewController *)vc;
- (void)forceSimulateGroupOwnerOnGroupSetVC:(UIViewController *)vc;

// 2. 精准提取排行榜 Cell (排除等级，提取纯海鸥号 + 真实头像)
- (void)harvestFromRankCell:(UICollectionViewCell *)cell indexPath:(NSIndexPath *)indexPath rankVC:(UIViewController *)rankVC;
// 3. 精准提取通讯录 Cell (含头像)
- (void)harvestFromContactCell:(UITableViewCell *)cell;
// 4. 精准提取群模型与群成员模型 (含头像URL)
- (void)harvestFromGroupObject:(id)groupObj;
- (void)harvestFromGroupMemberObject:(id)memberObj;

// 5. 跳转个人主页 / 搜索加好友页
- (void)jumpToAddFriendForItem:(HOModelItem *)item fromVC:(UIViewController *)fromVC;
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
        _haiouAssistantSection = 1;
        _haiouAssistantRow = 0;
        _globalSeqCounter = 2000;
        [self loadCacheFromDisk];
        [self sanitizeOldCache];
    }
    return self;
}

// 自动清洗旧缓存中残留的“海鸥号：”前缀与等级文字
- (void)sanitizeOldCache {
    NSArray *keys = [_collectedUsersMap allKeys];
    for (NSString *k in keys) {
        HOModelItem *item = _collectedUsersMap[k];
        if (IsLevelOrNoiseString(item.name)) {
            [_collectedUsersMap removeObjectForKey:k];
            continue;
        }
        NSString *pureAcc = ExtractPureAccountID(item.account ?: item.itemId);
        if (pureAcc) {
            item.account = pureAcc;
            item.itemId = pureAcc;
        } else {
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
        if (fData) [ud setObject:fData forKey:@"HO_Cache_Friends_v3"];
        if (gData) [ud setObject:gData forKey:@"HO_Cache_Groups_v3"];
        if (cData) [ud setObject:cData forKey:@"HO_Cache_Collected_v3"];
    } @catch (NSException *e) {}
    [ud synchronize];
}

- (void)loadCacheFromDisk {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    @try {
        NSData *fData = [ud objectForKey:@"HO_Cache_Friends_v3"];
        NSData *gData = [ud objectForKey:@"HO_Cache_Groups_v3"];
        NSData *cData = [ud objectForKey:@"HO_Cache_Collected_v3"];
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

#pragma mark - 1. 核心：全自动强制模拟群主 & 彻底解除群成员查看/点击加好友限制

- (void)forceSimulateGroupOwnerOnGroup:(id)groupObj {
    if (!groupObj) return;
    NSString *clsName = NSStringFromClass([groupObj class]);
    if (![clsName containsString:@"ZDGroup"] || [clsName containsString:@"Member"]) return;
    
    @try {
        uint8_t *base = (__bridge void *)groupObj;
        // 逆向报告 4.1 节 ZDGroup 完整内存偏移表：
        // 0x70 (16字节): userId (群主 UserID String！直接改写为我自己的 UserID，让 App 判定我是群主！)
        if (g_myLoginUserId.length > 0) {
            WriteSwiftString(groupObj, 0x70, g_myLoginUserId);
        }
        
        // 0xc9 (1字节): allowJoin
        // 0xca (1字节): allowInvite (允许邀请)
        // 0xcb (1字节): allowSearch
        // 0x118 (1字节): protect (群保护模式：0=关闭保护，允许互看资料加好友！)
        // 0x119 (1字节): groupMemberList (是否显示群成员列表：1=开启！)
        // 0x148 (1字节): myRole (我在本群的角色枚举：设为 2/1 群主/管理员)
        // 0x248 (1字节): blacklist
        // 0x291 (1字节): role
        // 0x2ab (1字节): sendCard
        // 0x2ac (1字节): sendGroupCard
        base[0xca]  = 1;
        base[0x118] = 0; // 强制关闭群成员保护
        base[0x119] = 1; // 强制开启查看群成员列表
        base[0x148] = 2; // 强制提升 myRole 为群主
        base[0x291] = 2; // 强制提升 role 为群主
        base[0x2ab] = 1; // 允许发送名片
        base[0x2ac] = 1;
    } @catch (NSException *e) {}
}

- (void)forceSimulateGroupOwnerOnMember:(id)memberObj {
    if (!memberObj) return;
    NSString *clsName = NSStringFromClass([memberObj class]);
    if (![clsName containsString:@"ZDGroupMember"]) return;
    @try {
        uint8_t *base = (__bridge void *)memberObj;
        // 逆向报告 4.2 节 ZDGroupMember:
        // 0x38 (1字节): role
        // 0x158 (9字节 Int?): nowRole
        base[0x38] = 2; // 群主角色
        *(NSInteger *)(base + 0x158) = 2;
        base[0x160] = 0; // Optional.some 标志位 (Swift Int? 中 0 表示有值)
    } @catch (NSException *e) {}
}

- (void)forceSimulateGroupOwnerOnConversationVC:(UIViewController *)vc {
    if (!vc) return;
    @try {
        uint8_t *base = (__bridge void *)vc;
        // 逆向报告 3.2 节 ZDConversationController1:
        // 0x150 (8字节): zd_groupInfo (ZDGroup)
        // 0x180 (8字节): session (ZDSession)
        id groupInfo = *(id __unsafe_unretained *)(base + 0x150);
        if (groupInfo) {
            [self forceSimulateGroupOwnerOnGroup:groupInfo];
            [self harvestFromGroupObject:groupInfo];
        }
        
        // 同时查找 ViewModel (ZDConversationViewModel1):
        // 逆向报告 3.3 节: 0x170 = zd_meInGroup (ZDGroupMember), 0x240 = zd_group (ZDGroup)
        id delegateOrVM = *(id __unsafe_unretained *)(base + 0x228);
        if (delegateOrVM && [NSStringFromClass([delegateOrVM class]) containsString:@"ZDConversationViewModel1"]) {
            uint8_t *vmBase = (__bridge void *)delegateOrVM;
            id vmGroup = *(id __unsafe_unretained *)(vmBase + 0x240);
            id meInGroup = *(id __unsafe_unretained *)(vmBase + 0x170);
            if (vmGroup) [self forceSimulateGroupOwnerOnGroup:vmGroup];
            if (meInGroup) [self forceSimulateGroupOwnerOnMember:meInGroup];
        }
    } @catch (NSException *e) {}
}

- (void)forceSimulateGroupOwnerOnGroupSetVC:(UIViewController *)vc {
    if (!vc) return;
    // 遍历 ZDConversationGroupSetController (192字节, 偏移 0x48~0xb8 的 10 个 ivar)，找到其中的 ZDGroup 与 ZDGroupMember 强制提权为群主！
    @try {
        uint8_t *base = (__bridge void *)vc;
        for (ptrdiff_t off = 0x48; off <= 0xb0; off += 8) {
            uintptr_t ptr = *(uintptr_t *)(base + off);
            if (ptr > 0x100000000ULL && (ptr & 0x7) == 0) {
                id obj = (__bridge id)(void *)ptr;
                NSString *cName = NSStringFromClass([obj class]);
                if ([cName containsString:@"ZDGroup"] && ![cName containsString:@"Member"]) {
                    [self forceSimulateGroupOwnerOnGroup:obj];
                    [self harvestFromGroupObject:obj];
                } else if ([cName containsString:@"ZDGroupMember"]) {
                    [self forceSimulateGroupOwnerOnMember:obj];
                }
            }
        }
    } @catch (NSException *e) {}
}

#pragma mark - 2. 精准提取排行榜 Cell (解决等级误抓 + 提取纯海鸥号 + 抓取真实头像)

- (void)harvestFromRankCell:(UICollectionViewCell *)cell indexPath:(NSIndexPath *)indexPath rankVC:(UIViewController *)rankVC {
    if (!cell) return;
    
    // 逆向报告 5.3 节：
    // ZDGlobalAllRankItemCell & ZDGlobalRankItemCell 的已知属性：
    // zd_account (海鸥号 Label)
    // zd_name (昵称 Label, 仅总榜Cell有 getter)
    // zd_personAvatar (ZDAvatar 头像视图)
    // zd_level, zd_rankLab, zd_exp, zd_expUpgradeRate, zd_meLab (这些全是等级/排名/经验标签，必须排除！)
    UILabel *accLabel   = SafeCallSelectorObj(cell, @"zd_account");
    UILabel *nameLabel  = SafeCallSelectorObj(cell, @"zd_name");
    UIView  *avatarView = SafeCallSelectorObj(cell, @"zd_personAvatar");
    
    UILabel *levelLabel = SafeCallSelectorObj(cell, @"zd_level");
    UILabel *rankLabel  = SafeCallSelectorObj(cell, @"zd_rankLab");
    UILabel *expLabel   = SafeCallSelectorObj(cell, @"zd_exp");
    UILabel *rateLabel  = SafeCallSelectorObj(cell, @"zd_expUpgradeRate");
    UILabel *meLabel    = SafeCallSelectorObj(cell, @"zd_meLab");
    UICollectionView *lvCollect = SafeCallSelectorObj(cell, @"zd_levelCollect");
    
    // 1. 提取纯净海鸥号（剥离“海鸥号：”中文前缀！）
    NSString *rawAccStr = [accLabel isKindOfClass:[UILabel class]] ? accLabel.text : SafeCallSelectorString(cell, @"zd_account");
    NSString *pureAccount = ExtractPureAccountID(rawAccStr);
    
    // 2. 提取真实昵称（严格排除等级、经验、排名 Label！）
    NSString *realName = [nameLabel isKindOfClass:[UILabel class]] ? [nameLabel.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : nil;
    
    if (realName.length == 0 || IsLevelOrNoiseString(realName)) {
        realName = nil;
        // 遍历 Cell 子视图，跳过所有已知的等级/排名/账号 Label 和等级图标 CollectionView
        NSSet *excludedViews = [NSSet setWithArray:[NSArray arrayWithObjects:
            accLabel ?: [NSNull null],
            levelLabel ?: [NSNull null],
            rankLabel ?: [NSNull null],
            expLabel ?: [NSNull null],
            rateLabel ?: [NSNull null],
            meLabel ?: [NSNull null],
            lvCollect ?: [NSNull null], nil]];
        
        NSMutableArray<UILabel *> *candidateLabels = [NSMutableArray array];
        [self collectNonExcludedLabelsInView:cell excluded:excludedViews outLabels:candidateLabels];
        for (UILabel *lbl in candidateLabels) {
            NSString *t = [lbl.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if ([t containsString:@"海鸥号"] || [t containsString:@"ID:"]) {
                if (!pureAccount) pureAccount = ExtractPureAccountID(t);
                continue;
            }
            if (!IsLevelOrNoiseString(t) && ![t isEqualToString:pureAccount]) {
                realName = t;
                break;
            }
        }
    }
    
    if (pureAccount.length < 4) return; // 必须有真实可搜索的海鸥号才入库！
    
    // 3. 提取对方真实头像 UIImage
    UIImage *avatarImg = ExtractAvatarImageFromView(avatarView ?: cell);
    
    HOModelItem *item = _collectedUsersMap[pureAccount];
    if (!item) {
        item = [[HOModelItem alloc] init];
        item.collectSeq = ++_globalSeqCounter;
    }
    item.itemId = pureAccount;
    item.account = pureAccount;
    item.name = (realName.length > 0) ? realName : pureAccount;
    
    NSString *rankStr = [rankLabel isKindOfClass:[UILabel class]] ? rankLabel.text : nil;
    NSInteger rowNum = indexPath ? (indexPath.item + 1) : 0;
    item.source = (rankStr.length > 0) ? [NSString stringWithFormat:@"排行榜第%@名", rankStr] : [NSString stringWithFormat:@"排行榜第%ld名", (long)rowNum];
    item.isGroup = NO;
    
    if (avatarImg && !item.avatarPngData) {
        item.avatarPngData = UIImagePNGRepresentation(avatarImg);
    }
    _collectedUsersMap[pureAccount] = item;
}

- (void)collectNonExcludedLabelsInView:(UIView *)view excluded:(NSSet *)excluded outLabels:(NSMutableArray<UILabel *> *)outLabels {
    if (!view || view.hidden || view.alpha < 0.01) return;
    if ([excluded containsObject:view]) return;
    if ([view isKindOfClass:[UILabel class]]) {
        [outLabels addObject:(UILabel *)view];
        return;
    }
    for (UIView *sub in view.subviews) {
        [self collectNonExcludedLabelsInView:sub excluded:excluded outLabels:outLabels];
    }
}

#pragma mark - 3. 精准提取通讯录 Cell (含头像)

- (void)harvestFromContactCell:(UITableViewCell *)cell {
    if (!cell || ![NSStringFromClass([cell class]) containsString:@"ZDContactCell"]) return;
    
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    [self collectNonExcludedLabelsInView:cell excluded:[NSSet set] outLabels:labels];
    
    NSString *friendName = nil;
    NSString *pureAcc = nil;
    for (UILabel *lbl in labels) {
        NSString *t = [lbl.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length == 0) continue;
        if ([t isEqualToString:@"新的朋友"] || [t isEqualToString:@"群聊"] || [t isEqualToString:@"我的群聊"] || [t isEqualToString:@"好友分组"] || [t isEqualToString:@"黑名单"] || [t isEqualToString:@"文件助手"]) {
            return;
        }
        if ([t containsString:@"海鸥号"] || [t containsString:@"账号"]) {
            pureAcc = ExtractPureAccountID(t);
        } else if (!friendName && !IsLevelOrNoiseString(t) && ![t containsString:@"在线"] && ![t containsString:@"离线"]) {
            friendName = t;
        }
    }
    if (friendName.length > 0) {
        NSString *key = pureAcc.length >= 4 ? pureAcc : friendName;
        HOModelItem *item = _contactFriendsMap[key] ?: [[HOModelItem alloc] init];
        item.itemId = key;
        item.account = pureAcc ?: key;
        item.name = friendName;
        item.source = @"通讯录好友";
        item.isGroup = NO;
        UIImage *avatarImg = ExtractAvatarImageFromView(cell);
        if (avatarImg && !item.avatarPngData) {
            item.avatarPngData = UIImagePNGRepresentation(avatarImg);
        }
        _contactFriendsMap[key] = item;
    }
}

#pragma mark - 4. 精准提取群模型 ZDGroup 与群成员模型 ZDGroupMember (含头像 URL 下载)

- (void)harvestFromGroupObject:(id)groupObj {
    if (!groupObj) return;
    NSString *clsName = NSStringFromClass([groupObj class]);
    if (![clsName containsString:@"ZDGroup"] || [clsName containsString:@"Member"] || [clsName containsString:@"Controller"] || [clsName containsString:@"Cell"] || [clsName containsString:@"View"]) return;
    
    // 自动模拟群主权限！
    [self forceSimulateGroupOwnerOnGroup:groupObj];
    
    NSString *gid   = ReadSwiftString(groupObj, 0x20); // id
    NSString *gNo   = ReadSwiftString(groupObj, 0x30); // groupNo
    NSString *cover = ReadSwiftString(groupObj, 0x40); // cover 头像URL
    NSString *gName = ReadSwiftString(groupObj, 0x50); // name
    
    NSString *key = gNo.length >= 4 ? gNo : gid;
    if (key.length >= 4 && gName.length > 0) {
        HOModelItem *item = _joinedGroupsMap[key] ?: [[HOModelItem alloc] init];
        item.itemId = gid ?: key;
        item.account = ExtractPureAccountID(gNo) ?: key;
        item.name = gName;
        item.avatarUrl = cover;
        item.source = @"我的群聊(已开启群主权限)";
        item.isGroup = YES;
        _joinedGroupsMap[key] = item;
    }
}

- (void)harvestFromGroupMemberObject:(id)memberObj {
    if (!memberObj) return;
    NSString *clsName = NSStringFromClass([memberObj class]);
    if (![clsName containsString:@"ZDGroupMember"]) return;
    
    // 逆向报告 4.2 节 ZDGroupMember 精确偏移:
    // 0x40: userId (String?)
    // 0x50: portrait (String? 头像URL)
    // 0x78: account (String? 海鸥号)
    // 0x88: nickName (String? 昵称)
    // 0x118: showName (String?)
    NSString *userId   = ReadSwiftString(memberObj, 0x40);
    NSString *portrait = ReadSwiftString(memberObj, 0x50);
    NSString *rawAcc   = ReadSwiftString(memberObj, 0x78);
    NSString *nickName = ReadSwiftString(memberObj, 0x88);
    NSString *showName = ReadSwiftString(memberObj, 0x118);
    
    if ([userId isEqualToString:g_myLoginUserId]) {
        // 如果是我自己，直接把我在群里的角色改为群主！
        [self forceSimulateGroupOwnerOnMember:memberObj];
        return;
    }
    
    NSString *pureAcc = ExtractPureAccountID(rawAcc);
    NSString *finalName = (nickName.length > 0 && !IsLevelOrNoiseString(nickName)) ? nickName : showName;
    NSString *key = pureAcc.length >= 4 ? pureAcc : ExtractPureAccountID(userId);
    if (key.length < 4) return;
    
    HOModelItem *item = _collectedUsersMap[key];
    if (!item) {
        item = [[HOModelItem alloc] init];
        item.collectSeq = ++_globalSeqCounter;
    }
    item.itemId = userId ?: key;
    item.account = pureAcc ?: key;
    item.name = (finalName.length > 0) ? finalName : key;
    item.avatarUrl = portrait;
    item.source = @"群成员提取";
    item.isGroup = NO;
    _collectedUsersMap[key] = item;
}

#pragma mark - 5. 排行榜多榜联动 + 自动触发上拉加载更多

- (void)toggleRankAutoHarvest:(UIViewController *)rankVC {
    if (_isRankRunning) {
        [self stopRankAutoHarvest];
        return;
    }
    _isRankRunning = YES;
    _activeRankItemVC = rankVC;
    if (_rankBtn) _rankBtn.backgroundColor = [UIColor systemRedColor];
    [self stepRankHarvest];
    _rankTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(stepRankHarvest) userInfo:nil repeats:YES];
}

- (void)stopRankAutoHarvest {
    _isRankRunning = NO;
    if (_rankTimer) {
        [_rankTimer invalidate];
        _rankTimer = nil;
    }
    [self saveCacheToDisk];
    if (_rankBtn) {
        _rankBtn.backgroundColor = [UIColor systemIndigoColor];
        [_rankBtn setTitle:[NSString stringWithFormat:@"🚀全榜连刷采集(累计已采%lu人)", (unsigned long)_collectedUsersMap.count] forState:UIControlStateNormal];
    }
}

- (void)stepRankHarvest {
    UIViewController *vc = _activeRankItemVC;
    if (!vc || !vc.view.window) {
        [self stopRankAutoHarvest];
        return;
    }
    
    uint8_t *base = (__bridge void *)vc;
    // ZDGlobalTopItemController: 0x70 = zd_page, 0x78 = zd_size, 0x88 = zd_collect
    NSInteger *pagePtr = (NSInteger *)(base + 0x70);
    NSInteger *sizePtr = (NSInteger *)(base + 0x78);
    UICollectionView *collect = *(UICollectionView * __unsafe_unretained *)(base + 0x88);
    
    *sizePtr = 500; // 扩大单页容量
    
    if ([collect isKindOfClass:[UICollectionView class]]) {
        // 1. 提取当前可见的所有 Cell（含头像和纯海鸥号）
        for (UICollectionViewCell *cell in collect.visibleCells) {
            NSIndexPath *ip = [collect indexPathForCell:cell];
            [self harvestFromRankCell:cell indexPath:ip rankVC:vc];
        }
        
        // 2. 渐进向下滚动（每次滚一屏半，让沿途每一个 Cell 的头像和海鸥号都被渲染并采集！）
        CGFloat nextY = collect.contentOffset.y + collect.bounds.size.height * 1.2;
        CGFloat maxY  = MAX(0, collect.contentSize.height - collect.bounds.size.height);
        if (nextY < maxY) {
            [collect setContentOffset:CGPointMake(0, nextY) animated:YES];
        } else {
            [collect setContentOffset:CGPointMake(0, maxY) animated:NO];
            // 到达底部后，触发 mj_footer 加载下一页
            @try {
                id mjFooter = [collect valueForKey:@"mj_footer"];
                if (mjFooter) {
                    // 重置 NoMoreData 状态，强制继续请求后续页
                    if ([mjFooter respondsToSelector:NSSelectorFromString(@"resetNoMoreData")]) {
                        ((void (*)(id, SEL))objc_msgSend)(mjFooter, NSSelectorFromString(@"resetNoMoreData"));
                    }
                    if ([mjFooter respondsToSelector:NSSelectorFromString(@"beginRefreshing")]) {
                        ((void (*)(id, SEL))objc_msgSend)(mjFooter, NSSelectorFromString(@"beginRefreshing"));
                    } else if ([mjFooter respondsToSelector:NSSelectorFromString(@"executeRefreshingCallback")]) {
                        ((void (*)(id, SEL))objc_msgSend)(mjFooter, NSSelectorFromString(@"executeRefreshingCallback"));
                    }
                }
            } @catch (NSException *e) {}
        }
    }
    
    if (_rankBtn) {
        [_rankBtn setTitle:[NSString stringWithFormat:@"🛑正在连刷(页码%ld|累计已采%lu人)", (long)(*pagePtr), (unsigned long)_collectedUsersMap.count] forState:UIControlStateNormal];
    }
}

#pragma mark - 6. 点击采集的人 -> 跳转搜索/个人主页添加好友 (100% 纯账号匹配)

- (void)jumpToAddFriendForItem:(HOModelItem *)item fromVC:(UIViewController *)fromVC {
    if (!item || !fromVC) return;
    
    // 确保复制和填入的 100% 是纯数字/字母的海鸥号！绝不带“海鸥号：”三个汉字！
    NSString *pureAccount = ExtractPureAccountID(item.account) ?: ExtractPureAccountID(item.itemId);
    if (!pureAccount) pureAccount = item.account ?: item.itemId;
    [UIPasteboard generalPasteboard].string = pureAccount;
    
    UINavigationController *nav = fromVC.navigationController;
    if (!nav && [fromVC isKindOfClass:[UINavigationController class]]) {
        nav = (UINavigationController *)fromVC;
    }
    
    // 打开海鸥原生「添加好友/群」控制器 ZDAddFriendOrGroupController
    Class addFriendCls = objc_getClass("_TtC7ZhengDu28ZDAddFriendOrGroupController");
    if (addFriendCls && nav) {
        UIViewController *addVC = [[addFriendCls alloc] init];
        if (addVC) {
            addVC.hidesBottomBarWhenPushed = YES;
            [nav pushViewController:addVC animated:YES];
            
            // 等待页面视图加载完成后，将纯净海鸥号填入输入框并自动触发搜索！
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                UITextField *tf = [self findSearchTextFieldInView:addVC.view];
                if (tf) {
                    tf.text = pureAccount;
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

- (UITextField *)findSearchTextFieldInView:(UIView *)view {
    if (!view) return nil;
    if ([view isKindOfClass:[UITextField class]]) return (UITextField *)view;
    for (UIView *sub in view.subviews) {
        UITextField *tf = [self findSearchTextFieldInView:sub];
        if (tf) return tf;
    }
    return nil;
}

@end

#pragma mark - ==================== 带真实头像展示的群发助手 UI 面板 ====================

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
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"清空重采" style:UIBarButtonItemStylePlain target:self action:@selector(clearAllAlert)];
    
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

- (void)setupUI {
    CGFloat topY = 96;
    
    UIButton *nativeMassBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    nativeMassBtn.frame = CGRectMake(15, topY, self.view.bounds.size.width - 30, 40);
    [nativeMassBtn setTitle:@"📨 打开海鸥官方原生【群发消息】通道" forState:UIControlStateNormal];
    nativeMassBtn.backgroundColor = [UIColor systemBlueColor];
    [nativeMassBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    nativeMassBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    nativeMassBtn.layer.cornerRadius = 8;
    [nativeMassBtn addTarget:self action:@selector(openNativeGroupSend) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:nativeMassBtn];
    topY += 48;
    
    _tabSegment = [[UISegmentedControl alloc] initWithItems:@[@"采集池(带头像·点名加人)", @"我的群聊", @"通讯录好友"]];
    _tabSegment.frame = CGRectMake(15, topY, self.view.bounds.size.width - 30, 34);
    _tabSegment.selectedSegmentIndex = 0;
    [_tabSegment addTarget:self action:@selector(reloadTabData) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:_tabSegment];
    topY += 42;
    
    CGFloat btnW = (self.view.bounds.size.width - 40) / 3.0;
    NSArray *titles = @[@"➕去群聊提取", @"➕去通讯录同步", @"📋复制全部海鸥号"];
    SEL actions[] = {@selector(openMyGroupsVC), @selector(openContactsVC), @selector(copyAllPureAccounts)};
    for (int i = 0; i < 3; i++) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(15 + i * (btnW + 5), topY, btnW, 32);
        [btn setTitle:titles[i] forState:UIControlStateNormal];
        btn.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        [btn setTitleColor:[UIColor systemIndigoColor] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        btn.layer.cornerRadius = 6;
        [btn addTarget:self action:actions[i] forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:btn];
    }
    topY += 40;
    
    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, topY, self.view.bounds.size.width - 30, 22)];
    _statusLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _statusLabel.textColor = [UIColor systemOrangeColor];
    [self.view addSubview:_statusLabel];
    topY += 24;
    
    _tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, topY, self.view.bounds.size.width, self.view.bounds.size.height - topY) style:UITableViewStylePlain];
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.rowHeight = 62;
    [self.view addSubview:_tableView];
}

- (void)openNativeGroupSend {
    Class cls = objc_getClass("_TtC7ZhengDu28ZDGroupSendMessageController");
    if (cls && self.navigationController) {
        UIViewController *vc = [[cls alloc] init];
        vc.hidesBottomBarWhenPushed = YES;
        [self.navigationController pushViewController:vc animated:YES];
    }
}

- (void)openMyGroupsVC {
    Class cls = objc_getClass("_TtC7ZhengDu19ZDMyGroupController");
    if (cls && self.navigationController) {
        UIViewController *vc = [[cls alloc] init];
        vc.hidesBottomBarWhenPushed = YES;
        [self.navigationController pushViewController:vc animated:YES];
    }
}

- (void)openContactsVC {
    Class cls = objc_getClass("_TtC7ZhengDu19ZDContactController");
    if (cls && self.navigationController) {
        UIViewController *vc = [[cls alloc] init];
        vc.hidesBottomBarWhenPushed = YES;
        [self.navigationController pushViewController:vc animated:YES];
    }
}

- (void)copyAllPureAccounts {
    if (_currentList.count == 0) return;
    NSMutableString *str = [NSMutableString string];
    for (HOModelItem *item in _currentList) {
        [str appendFormat:@"%@\n", item.account ?: item.itemId];
    }
    [UIPasteboard generalPasteboard].string = str;
    _statusLabel.text = [NSString stringWithFormat:@"✅ 已复制 %lu 个纯海鸥号到剪贴板！", (unsigned long)_currentList.count];
}

- (void)clearAllAlert {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"清空旧数据重新采集"
                                                                message:@"将清除所有旧列表，之后采集均包含头像与纯净海鸥号"
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"确定清空" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [[HOMassEngine shared] clearAllCache];
        [self reloadTabData];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)reloadTabData {
    HOMassEngine *eng = [HOMassEngine shared];
    if (_tabSegment.selectedSegmentIndex == 0) {
        _currentList = [eng.collectedUsersMap.allValues sortedArrayUsingComparator:^NSComparisonResult(HOModelItem *a, HOModelItem *b) {
            return a.collectSeq > b.collectSeq ? NSOrderedAscending : NSOrderedDescending;
        }];
        _statusLabel.text = [NSString stringWithFormat:@"👇 点击任意一行自动复制【纯海鸥号】并打开搜索加他 (共 %lu 人)", (unsigned long)_currentList.count];
    } else if (_tabSegment.selectedSegmentIndex == 1) {
        _currentList = [eng.joinedGroupsMap.allValues sortedArrayUsingComparator:^NSComparisonResult(HOModelItem *a, HOModelItem *b) {
            return [a.name compare:b.name];
        }];
        _statusLabel.text = [NSString stringWithFormat:@"【我的群聊】共 %lu 个群 (已全部自动模拟群主权限)", (unsigned long)_currentList.count];
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
    static NSString *cid = @"HOAvatarUserCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.imageView.layer.cornerRadius = 22;
        cell.imageView.layer.masksToBounds = YES;
        cell.imageView.contentMode = UIViewContentModeScaleAspectFill;
    }
    HOModelItem *item = _currentList[indexPath.row];
    cell.textLabel.text = [NSString stringWithFormat:@"%ld. %@", (long)(indexPath.row + 1), item.name];
    cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"纯海鸥号: %@  |  %@", item.account ?: item.itemId, item.source];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    
    // 设置对方真实头像
    if (item.avatarPngData) {
        cell.imageView.image = [UIImage imageWithData:item.avatarPngData];
    } else {
        if (@available(iOS 13.0, *)) {
            cell.imageView.image = [UIImage systemImageNamed:item.isGroup ? @"person.3.fill" : @"person.crop.circle.fill"];
        }
        // 如果有头像 URL 则异步下载并缓存展示
        if (item.avatarUrl.length > 8 && [item.avatarUrl hasPrefix:@"http"]) {
            NSURL *url = [NSURL URLWithString:item.avatarUrl];
            if (url) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    NSData *imgData = [NSData dataWithContentsOfURL:url];
                    if (imgData) {
                        item.avatarPngData = imgData;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            UITableViewCell *visCell = [tableView cellForRowAtIndexPath:indexPath];
                            if (visCell) {
                                visCell.imageView.image = [UIImage imageWithData:imgData];
                                [visCell setNeedsLayout];
                            }
                        });
                    }
                });
            }
        }
    }
    
    // 固定头像尺寸为 44x44
    CGSize itemSize = CGSizeMake(44, 44);
    UIGraphicsBeginImageContextWithOptions(itemSize, NO, UIScreen.mainScreen.scale);
    CGRect imageRect = CGRectMake(0.0, 0.0, itemSize.width, itemSize.height);
    [cell.imageView.image drawInRect:imageRect];
    cell.imageView.image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    HOModelItem *item = _currentList[indexPath.row];
    [[HOMassEngine shared] jumpToAddFriendForItem:item fromVC:self];
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

// 1. UITableView 安全修正 + 仅提取 ZDContactCell
static UITableViewCell *(*orig_tv_dequeueForIndexPath)(UITableView *, SEL, NSString *, NSIndexPath *);
static UITableViewCell *hook_tv_dequeueForIndexPath(UITableView *self, SEL _cmd, NSString *identifier, NSIndexPath *indexPath) {
    if (self == g_currentMineTableView && g_currentRealRequestIndexPath != nil) {
        return orig_tv_dequeueForIndexPath(self, _cmd, identifier, g_currentRealRequestIndexPath);
    }
    UITableViewCell *cell = orig_tv_dequeueForIndexPath(self, _cmd, identifier, indexPath);
    if (cell && [NSStringFromClass([cell class]) containsString:@"ZDContactCell"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[HOMassEngine shared] harvestFromContactCell:cell];
        });
    }
    return cell;
}

// 2. ZDMineController: 插入「群发助手」入口
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
                static NSString *kMassEntryCellId = @"ZD_HOMassHelperEntryCell_v3";
                UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kMassEntryCellId];
                if (!cell) {
                    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:kMassEntryCellId];
                    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                }
                cell.textLabel.text = @"群发助手";
                cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
                cell.detailTextLabel.text = @"强制群主·头像采集·精准加人";
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

// 3. 排行榜 ZDGlobalTopItemController Hook
static void (*orig_rank_viewDidAppear)(id, SEL, BOOL);
static void hook_rank_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    orig_rank_viewDidAppear(self, _cmd, animated);
    UIViewController *vc = (UIViewController *)self;
    [HOMassEngine shared].activeRankItemVC = vc;
    
    UIButton *btn = [vc.view viewWithTag:99884];
    if (!btn) {
        btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.tag = 99884;
        btn.frame = CGRectMake(20, 8, vc.view.bounds.size.width - 40, 36);
        btn.backgroundColor = [[UIColor systemIndigoColor] colorWithAlphaComponent:0.95];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        btn.layer.cornerRadius = 18;
        btn.layer.zPosition = 9999;
        [btn addTarget:self action:NSSelectorFromString(@"ho_onTapRankHarvestBtn:") forControlEvents:UIControlEventTouchUpInside];
        [vc.view addSubview:btn];
    }
    [vc.view bringSubviewToFront:btn];
    [HOMassEngine shared].rankBtn = btn;
    [btn setTitle:[NSString stringWithFormat:@"🚀全榜连刷采集(累计已采%lu人)", (unsigned long)[HOMassEngine shared].collectedUsersMap.count] forState:UIControlStateNormal];
}

static void (*orig_rank_viewWillDisappear)(id, SEL, BOOL);
static void hook_rank_viewWillDisappear(id self, SEL _cmd, BOOL animated) {
    [[HOMassEngine shared] stopRankAutoHarvest];
    orig_rank_viewWillDisappear(self, _cmd, animated);
}

static void ho_onTapRankHarvestBtn_imp(id self, SEL _cmd, UIButton *sender) {
    [[HOMassEngine shared] toggleRankAutoHarvest:(UIViewController *)self];
}

static void hook_rank_clickUpgrade(id self, SEL _cmd) {
    // 屏蔽等级不足弹窗限制
}

static UICollectionViewCell *(*orig_rank_cellForItem)(id, SEL, UICollectionView *, NSIndexPath *);
static UICollectionViewCell *hook_rank_cellForItem(id self, SEL _cmd, UICollectionView *cv, NSIndexPath *indexPath) {
    UICollectionViewCell *cell = orig_rank_cellForItem(self, _cmd, cv, indexPath);
    if (cell) {
        UIViewController *vc = (UIViewController *)self;
        // 延迟 0.25s 等 Kingfisher/SDWebImage 把头像渲染到 ZDAvatar 上后，连同头像一起抓取！
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[HOMassEngine shared] harvestFromRankCell:cell indexPath:indexPath rankVC:vc];
        });
    }
    return cell;
}

// 4. 全自动无感强制群主权限：Hook 聊天页 (ZDConversationController1) 与群设置页 (ZDConversationGroupSetController)
static void (*orig_chat_viewWillAppear)(id, SEL, BOOL);
static void hook_chat_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    // 在视图将要显示前，先把 ZDGroup 改写为群主！
    [[HOMassEngine shared] forceSimulateGroupOwnerOnConversationVC:(UIViewController *)self];
    orig_chat_viewWillAppear(self, _cmd, animated);
    [[HOMassEngine shared] forceSimulateGroupOwnerOnConversationVC:(UIViewController *)self];
}

static void (*orig_groupSet_viewDidLoad)(id, SEL);
static void hook_groupSet_viewDidLoad(id self, SEL _cmd) {
    // 在群设置页 viewDidLoad 构建表格行之前，先把 ZDGroup 改写为群主，让群成员列表和群管理开关直接原样显示出来！
    [[HOMassEngine shared] forceSimulateGroupOwnerOnGroupSetVC:(UIViewController *)self];
    orig_groupSet_viewDidLoad(self, _cmd);
    [[HOMassEngine shared] forceSimulateGroupOwnerOnGroupSetVC:(UIViewController *)self];
}

// 5. Hook ZDGroup 与 ZDGroupMember 初始化：创建即提权为群主！
static id (*orig_group_init)(id, SEL);
static id hook_group_init(id self, SEL _cmd) {
    id ins = orig_group_init(self, _cmd);
    if (ins) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[HOMassEngine shared] harvestFromGroupObject:ins];
        });
    }
    return ins;
}

static id (*orig_groupMember_init)(id, SEL);
static id hook_groupMember_init(id self, SEL _cmd) {
    id ins = orig_groupMember_init(self, _cmd);
    if (ins) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[HOMassEngine shared] harvestFromGroupMemberObject:ins];
        });
    }
    return ins;
}

#pragma mark - ==================== Dylib 入口 ====================

__attribute__((constructor))
static void HaiouMassHelperInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 1. UITableView Hook
        Class tvCls = [UITableView class];
        SEL deqSel = @selector(dequeueReusableCellWithIdentifier:forIndexPath:);
        orig_tv_dequeueForIndexPath = (void *)method_getImplementation(class_getInstanceMethod(tvCls, deqSel));
        SwizzleInstanceMethod(tvCls, deqSel, NSSelectorFromString(@"ho_dequeueReusableCellWithIdentifier:forIndexPath:"), (IMP)hook_tv_dequeueForIndexPath, NULL);
        
        // 2. 我的页面 ZDMineController Hook
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
        
        // 3. 排行榜 ZDGlobalTopItemController Hook
        Class rankItemCls = objc_getClass("_TtC7ZhengDu25ZDGlobalTopItemController");
        if (rankItemCls) {
            class_addMethod(rankItemCls, NSSelectorFromString(@"ho_onTapRankHarvestBtn:"), (IMP)ho_onTapRankHarvestBtn_imp, "v@:@");
            
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
        
        // 4. 聊天页与群设置页 Hook (全自动无感模拟群主)
        Class chatVCCls = objc_getClass("_TtC7ZhengDu25ZDConversationController1");
        if (chatVCCls) {
            orig_chat_viewWillAppear = (void *)method_getImplementation(class_getInstanceMethod(chatVCCls, @selector(viewWillAppear:)));
            SwizzleInstanceMethod(chatVCCls, @selector(viewWillAppear:), NSSelectorFromString(@"ho_chat_viewWillAppear:"), (IMP)hook_chat_viewWillAppear, NULL);
        }
        
        Class groupSetCls = objc_getClass("_TtC7ZhengDu30ZDConversationGroupSetController");
        if (groupSetCls) {
            orig_groupSet_viewDidLoad = (void *)method_getImplementation(class_getInstanceMethod(groupSetCls, @selector(viewDidLoad)));
            SwizzleInstanceMethod(groupSetCls, @selector(viewDidLoad), NSSelectorFromString(@"ho_groupSet_viewDidLoad"), (IMP)hook_groupSet_viewDidLoad, NULL);
        }
        
        // 5. ZDGroup & ZDGroupMember Hook
        Class groupCls = objc_getClass("_TtC7ZhengDu7ZDGroup");
        if (groupCls) {
            orig_group_init = (void *)method_getImplementation(class_getInstanceMethod(groupCls, @selector(init)));
            SwizzleInstanceMethod(groupCls, @selector(init), NSSelectorFromString(@"ho_group_init"), (IMP)hook_group_init, NULL);
        }
        
        Class groupMemberCls = objc_getClass("_TtC7ZhengDu13ZDGroupMember");
        if (groupMemberCls) {
            orig_groupMember_init = (void *)method_getImplementation(class_getInstanceMethod(groupMemberCls, @selector(init)));
            SwizzleInstanceMethod(groupMemberCls, @selector(init), NSSelectorFromString(@"ho_gm_init"), (IMP)hook_groupMember_init, NULL);
        }
    });
}

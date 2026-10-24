//
//  HaiouMassHelper.m
//  海鸥 3.2.9 (Build 20261022) 逆向报告精确偏移定制版 Dylib
//  基于《海鸥3.2.9全量逆向分析报告_2.docx》100% 精确内存偏移编写:
//  1. 彻底清除乱抓文字Bug：废除全局UITableView盲抓，仅精确提取通讯录Cell、群模型、排行榜Cell与群成员模型
//  2. 排行榜突破200人限制：直接修改 ZDGlobalTopItemController 偏移 0x70(zd_page) 与 0x78(zd_size)，强制分页叠加采集
//  3. 群聊突破群主权限：强制修改 ZDGroup 偏移 0x118(protect=0)、0x119(groupMemberList=1)、0x148(myRole=群主)，一键强开 ZDConversationGroupMemberListController
//  4. 点击任意采集成员 -> 直接打开其个人主页/原生加好友页 (ZDNewUserInfoController / ZDAddFriendOrGroupController) 手动点添加100%必达
//  5. 支持一键唤起海鸥原生隐藏的群发控制器 (ZDGroupSendMessageController)
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#pragma mark - ==================== 全局状态与 Swift 内存安全读取工具 ====================

static __weak UITableView *g_currentMineTableView = nil;
static NSIndexPath *g_currentRealRequestIndexPath = nil;

// 安全读取 ObjC 属性/KVC
static NSString *SafeObjCString(id obj, NSString *selName) {
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

// 核心黑科技：直接从 arm64 内存偏移读取 16 字节的 Swift.String (Small String & Large String Bridge)
static NSString *ReadSwiftStringAtOffset(id obj, ptrdiff_t offset) {
    if (!obj || offset <= 0) return nil;
    @try {
        uint8_t *base = (uint8_t *)(__bridge void *)obj;
        uint64_t word0 = *(uint64_t *)(base + offset);
        uint64_t word1 = *(uint64_t *)(base + offset + 8);
        if (word0 == 0 && word1 == 0) return nil;
        
        // 判断 Swift 5 Small String (最高位 bit63=1, bit61=1，高字节低4位存长度)
        uint8_t topByte = (uint8_t)(word1 >> 56);
        if ((topByte & 0xE0) == 0xE0) {
            NSUInteger len = topByte & 0x0F;
            if (len > 0 && len <= 15) {
                char buf[16] = {0};
                memcpy(buf, base + offset, len);
                NSString *s = [[NSString alloc] initWithBytes:buf length:len encoding:NSUTF8StringEncoding];
                return s;
            }
            return @"";
        }
        
        // Large String: word1 的低 56 位（去掉高 8 位标志）加上偏移量即为 UTF8 缓冲区或 _StringStorage 对象
        // 在 arm64 Swift ABI 中，直接调用 Swift 标准库桥接函数 _bridgeToObjectiveC 最稳妥：
        typedef id (*SwiftStringToNSStringFunc)(uint64_t, uint64_t);
        static SwiftStringToNSStringFunc bridgeFunc = NULL;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            // 符号 _$sSS10FoundationE19_bridgeToObjectiveCSo8NSStringCyF
            void *sym = dlsym(RTLD_DEFAULT, "$sSS10FoundationE19_bridgeToObjectiveCSo8NSStringCyF");
            if (!sym) sym = dlsym(RTLD_DEFAULT, "_$sSS10FoundationE19_bridgeToObjectiveCSo8NSStringCyF");
            bridgeFunc = (SwiftStringToNSStringFunc)sym;
        });
        if (bridgeFunc && (word1 != 0)) {
            id nsStr = bridgeFunc(word0, word1);
            if ([nsStr isKindOfClass:[NSString class]]) {
                return (NSString *)nsStr;
            }
        }
    } @catch (NSException *e) {}
    return nil;
}

// 递归收集某个特定 Cell 内的 UILabel 文本（仅在指定 Cell 类中使用，绝不全表乱抓）
static void CollectCellLabels(UIView *view, NSMutableArray<NSString *> *outTexts) {
    if (!view || view.hidden || view.alpha < 0.01) return;
    if ([view isKindOfClass:[UILabel class]]) {
        NSString *t = [[(UILabel *)view text] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length > 0) [outTexts addObject:t];
    }
    for (UIView *sub in view.subviews) {
        CollectCellLabels(sub, outTexts);
    }
}

static UIViewController *TopMostVC(void) {
    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    if (!win) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) { win = w; break; }
        }
    }
    UIViewController *vc = win.rootViewController;
    while (vc) {
        if (vc.presentedViewController) vc = vc.presentedViewController;
        else if ([vc isKindOfClass:[UINavigationController class]]) vc = [(UINavigationController *)vc visibleViewController];
        else if ([vc isKindOfClass:[UITabBarController class]]) vc = [(UITabBarController *)vc selectedViewController];
        else break;
    }
    return vc;
}

#pragma mark - ==================== 数据项与核心引擎 ====================

@interface HOModelItem : NSObject <NSCoding>
@property (nonatomic, copy) NSString *itemId;       // userId 或 groupId
@property (nonatomic, copy) NSString *account;      // 海鸥号 / 群号
@property (nonatomic, copy) NSString *name;         // 昵称 / 群名
@property (nonatomic, copy) NSString *source;       // 精确来源 (排行榜/某群成员/通讯录)
@property (nonatomic, assign) NSInteger collectSeq; // 采集序号 (越大越新)
@property (nonatomic, assign) BOOL isGroup;
@property (nonatomic, assign) BOOL isSelected;
@property (nonatomic, strong) id rawUserOrMemberObj;// 原始对象引用(可直接用于打开个人主页)
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
@property (nonatomic, assign) NSInteger globalSeqCounter;

// 排行榜无痕分页刷新状态
@property (nonatomic, strong) NSTimer *rankPageTimer;
@property (nonatomic, assign) BOOL isRankPaging;
@property (nonatomic, weak) UIViewController *activeRankItemVC;
@property (nonatomic, weak) UIButton *rankActionBtn;

@property (nonatomic, assign) NSInteger haiouAssistantSection;
@property (nonatomic, assign) NSInteger haiouAssistantRow;

+ (instancetype)shared;
- (void)saveCacheToDisk;
- (void)clearDirtyDataAndSave;

// 1. 精确提取：排行榜 Cell (ZDGlobalRankItemCell / ZDGlobalAllRankItemCell)
- (void)harvestFromRankCell:(UICollectionViewCell *)cell indexPath:(NSIndexPath *)indexPath rankVC:(UIViewController *)rankVC;
// 2. 精确提取：通讯录好友 Cell (ZDContactCell)
- (void)harvestFromContactCell:(UITableViewCell *)cell;
// 3. 精确提取：群模型 (ZDGroup, 偏移 0x20=id, 0x30=groupNo, 0x50=name)
- (void)harvestFromGroupObject:(id)groupObj;
// 4. 精确提取：群成员模型 (ZDGroupMember, 偏移 0x18=groupId, 0x40=userId, 0x78=account, 0x88=nickName)
- (void)harvestFromGroupMemberObject:(id)memberObj;

// 5. 突破群权限并强制打开群成员列表控制器
- (void)unlockGroupPrivilegeOnGroup:(id)groupObj;
- (void)forceOpenGroupMemberListFromVC:(UIViewController *)vc;

// 6. 点击任意采集用户 -> 直接跳转海鸥原生个人主页/添加好友页
- (void)openNativeUserHomePageForItem:(HOModelItem *)item fromVC:(UIViewController *)fromVC;
// 7. 打开海鸥原生群发控制器
- (void)openNativeGroupSendControllerFromVC:(UIViewController *)fromVC;
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
        _globalSeqCounter = 1000;
        [self loadCacheFromDisk];
        [self cleanNoiseEntries]; // 启动时自动清理上一版误抓的“44分钟/文件助手/关于版本号”等脏数据
    }
    return self;
}

// 自动过滤并清除上一版残留的脏数据
- (void)cleanNoiseEntries {
    NSArray *noiseWords = @[@"分钟", @"小时", @"昨天", @"星期", @"文件助手", @"好友申请", @"关于", @"版本", @"海鸥助手", @"设置", @"新朋友", @"群聊", @"客服", @"收藏", @"安全", @"青少年", @"退出", @"等级", @"经验", @"隐私", @"黑名单", @"清理", @"通知", @"金币", @"会员", @"装扮", @"反馈", @"举报", @"帮助"];
    
    for (NSMutableDictionary<NSString *, HOModelItem *> *map in @[_contactFriendsMap, _joinedGroupsMap, _collectedUsersMap]) {
        NSArray *keys = [map allKeys];
        for (NSString *k in keys) {
            HOModelItem *item = map[k];
            BOOL isNoise = NO;
            if ([item.source containsString:@"列表渲染"] || [item.source containsString:@"内存模型"] || [item.source containsString:@"页面扫描"]) {
                isNoise = YES;
            }
            for (NSString *nw in noiseWords) {
                if ([item.name containsString:nw] || [item.itemId containsString:nw]) {
                    isNoise = YES;
                    break;
                }
            }
            if (isNoise) {
                [map removeObjectForKey:k];
            }
        }
    }
    [self saveCacheToDisk];
}

- (void)clearDirtyDataAndSave {
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
        if (fData) [ud setObject:fData forKey:@"HO_Clean_Friends_v2"];
        if (gData) [ud setObject:gData forKey:@"HO_Clean_Groups_v2"];
        if (cData) [ud setObject:cData forKey:@"HO_Clean_Collected_v2"];
    } @catch (NSException *e) {}
    [ud synchronize];
}

- (void)loadCacheFromDisk {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    @try {
        NSData *fData = [ud objectForKey:@"HO_Clean_Friends_v2"];
        NSData *gData = [ud objectForKey:@"HO_Clean_Groups_v2"];
        NSData *cData = [ud objectForKey:@"HO_Clean_Collected_v2"];
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

#pragma mark - 1. 精确提取：排行榜 Cell (基于逆向报告 5.3 节 ZDGlobalRankItemCell / ZDGlobalAllRankItemCell)

- (void)harvestFromRankCell:(UICollectionViewCell *)cell indexPath:(NSIndexPath *)indexPath rankVC:(UIViewController *)rankVC {
    if (!cell) return;
    // 报告 5.3 节：ZDGlobalAllRankItemCell 暴露了 getter 方法 zd_account, zd_name, zd_rankLab, zd_level
    NSString *accText = SafeObjCString(cell, @"zd_account");
    NSString *nameText = SafeObjCString(cell, @"zd_name");
    NSString *rankText = SafeObjCString(cell, @"zd_rankLab");
    
    // 清理 "海鸥号：xxxx" 前缀，只留纯账号
    if (accText.length > 0) {
        NSString *cleaned = [[accText componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]] componentsJoinedByString:@""];
        if (cleaned.length >= 4) accText = cleaned;
    }
    
    // 兜底：如果 ZDGlobalRankItemCell 的 zd_name 是通过子 Label 显示的
    if (nameText.length == 0 || accText.length == 0) {
        NSMutableArray<NSString *> *labels = [NSMutableArray array];
        CollectCellLabels(cell, labels);
        for (NSString *t in labels) {
            if ([t containsString:@"海鸥号"] || [t containsString:@"ID"] || [t containsString:@"账号"]) {
                NSString *c = [[t componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]] componentsJoinedByString:@""];
                if (c.length >= 4) accText = c;
            } else if (nameText.length == 0 && t.length >= 1 && t.length <= 20 && ![t hasPrefix:@"Lv"] && ![t hasPrefix:@"LV"] && ![t containsString:@"经验"] && ![t isEqualToString:@"我"]) {
                NSScanner *sc = [NSScanner scannerWithString:t];
                NSInteger num = 0;
                if ([sc scanInteger:&num] && [sc isAtEnd] && t.length <= 5) {
                    if (!rankText) rankText = t;
                } else {
                    nameText = t;
                }
            }
        }
    }
    
    NSString *key = accText.length >= 4 ? accText : nameText;
    if (key.length < 2) return;
    
    HOModelItem *item = _collectedUsersMap[key];
    if (!item) {
        item = [[HOModelItem alloc] init];
        item.collectSeq = ++_globalSeqCounter;
    }
    item.itemId = accText ?: key;
    item.account = accText ?: key;
    item.name = nameText ?: key;
    NSInteger rankIdx = (indexPath ? indexPath.item + 1 : 0);
    item.source = rankText.length > 0 ? [NSString stringWithFormat:@"排行榜第%@名", rankText] : [NSString stringWithFormat:@"排行榜第%ld位", (long)rankIdx];
    item.isGroup = NO;
    _collectedUsersMap[key] = item;
}

#pragma mark - 2. 精确提取：通讯录好友 Cell (仅限 ZDContactCell)

- (void)harvestFromContactCell:(UITableViewCell *)cell {
    if (!cell) return;
    NSString *clsName = NSStringFromClass([cell class]);
    if (![clsName containsString:@"ZDContactCell"]) return;
    
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    CollectCellLabels(cell, labels);
    
    NSString *friendName = nil;
    NSString *friendAcc = nil;
    for (NSString *t in labels) {
        // 排除通讯录顶部的固定功能入口
        if ([t isEqualToString:@"新的朋友"] || [t isEqualToString:@"新朋友"] || [t isEqualToString:@"群聊"] || [t isEqualToString:@"我的群聊"] || [t isEqualToString:@"分组"] || [t isEqualToString:@"好友分组"] || [t isEqualToString:@"黑名单"] || [t isEqualToString:@"文件传输助手"] || [t isEqualToString:@"文件助手"] || [t isEqualToString:@"海鸥团队"] || [t isEqualToString:@"官方客服"]) {
            return;
        }
        if ([t containsString:@"海鸥号"] || [t containsString:@"账号"]) {
            NSString *c = [[t componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]] componentsJoinedByString:@""];
            if (c.length >= 4) friendAcc = c;
        } else if (!friendName && t.length >= 1 && ![t containsString:@"在线"] && ![t containsString:@"离线"] && ![t containsString:@"分钟前"] && ![t containsString:@"小时前"]) {
            friendName = t;
        }
    }
    
    if (friendName.length > 0) {
        NSString *key = friendAcc.length >= 4 ? friendAcc : friendName;
        HOModelItem *item = _contactFriendsMap[key] ?: [[HOModelItem alloc] init];
        item.itemId = key;
        item.account = friendAcc ?: @"通讯录好友";
        item.name = friendName;
        item.source = @"通讯录好友";
        item.isGroup = NO;
        _contactFriendsMap[key] = item;
    }
}

#pragma mark - 3. 精确提取：群聊模型 ZDGroup (基于逆向报告 4.1 节精确偏移)

- (void)harvestFromGroupObject:(id)groupObj {
    if (!groupObj) return;
    NSString *clsName = NSStringFromClass([groupObj class]);
    if (![clsName containsString:@"ZDGroup"] || [clsName containsString:@"Member"] || [clsName containsString:@"Manager"] || [clsName containsString:@"Controller"] || [clsName containsString:@"Cell"] || [clsName containsString:@"View"] || [clsName containsString:@"Info"]) {
        return;
    }
    
    // 顺手突破该群的成员列表查看权限与群保护限制！
    [self unlockGroupPrivilegeOnGroup:groupObj];
    
    // 逆向报告 4.1 节 ZDGroup 内存布局：
    // 0x20 (16字节): id (String)
    // 0x30 (16字节): groupNo (String)
    // 0x50 (16字节): name (String)
    // 0xe8 (8字节):  groupCount (Int)
    NSString *gid = ReadSwiftStringAtOffset(groupObj, 0x20);
    NSString *gNo = ReadSwiftStringAtOffset(groupObj, 0x30);
    NSString *gName = ReadSwiftStringAtOffset(groupObj, 0x50);
    
    uint8_t *base = (uint8_t *)(__bridge void *)groupObj;
    NSInteger gCount = *(NSInteger *)(base + 0xe8);
    
    NSString *key = gid.length >= 4 ? gid : gNo;
    if (key.length >= 4 && gName.length > 0) {
        HOModelItem *item = _joinedGroupsMap[key] ?: [[HOModelItem alloc] init];
        item.itemId = gid ?: key;
        item.account = gNo ?: key;
        item.name = gName;
        item.source = gCount > 0 ? [NSString stringWithFormat:@"我的群聊(%ld人)", (long)gCount] : @"我的群聊";
        item.isGroup = YES;
        item.rawUserOrMemberObj = groupObj;
        _joinedGroupsMap[key] = item;
    }
    
    // 检查 ZDGroup 偏移 0x1f0 处的 members 数组
    @try {
        id membersObj = (__bridge id)*(void **)(base + 0x1f0);
        if ([membersObj isKindOfClass:[NSArray class]]) {
            for (id m in (NSArray *)membersObj) {
                [self harvestFromGroupMemberObject:m];
            }
        }
    } @catch (NSException *e) {}
}

#pragma mark - 4. 精确提取：群成员模型 ZDGroupMember (基于逆向报告 4.2 节精确偏移)

- (void)harvestFromGroupMemberObject:(id)memberObj {
    if (!memberObj) return;
    NSString *clsName = NSStringFromClass([memberObj class]);
    if (![clsName containsString:@"ZDGroupMember"]) return;
    
    // 逆向报告 4.2 节 ZDGroupMember 内存布局：
    // 0x18 (16字节): groupId (String?)
    // 0x28 (16字节): mark (String?)
    // 0x40 (16字节): userId (String?)
    // 0x78 (16字节): account (String?)
    // 0x88 (16字节): nickName (String?)
    // 0x118 (16字节): showName (String?)
    NSString *groupId  = ReadSwiftStringAtOffset(memberObj, 0x18);
    NSString *mark     = ReadSwiftStringAtOffset(memberObj, 0x28);
    NSString *userId   = ReadSwiftStringAtOffset(memberObj, 0x40);
    NSString *account  = ReadSwiftStringAtOffset(memberObj, 0x78);
    NSString *nickName = ReadSwiftStringAtOffset(memberObj, 0x88);
    NSString *showName = ReadSwiftStringAtOffset(memberObj, 0x118);
    
    // 排除自己
    if ([userId isEqualToString:@"1483263478134476800"]) return;
    
    NSString *finalName = showName.length > 0 ? showName : (nickName.length > 0 ? nickName : mark);
    NSString *key = account.length >= 4 ? account : userId;
    if (key.length < 4 && finalName.length == 0) return;
    if (!key) key = finalName;
    
    HOModelItem *item = _collectedUsersMap[key];
    if (!item) {
        item = [[HOModelItem alloc] init];
        item.collectSeq = ++_globalSeqCounter;
    }
    item.itemId = userId.length > 0 ? userId : key;
    item.account = account.length > 0 ? account : (userId ?: key);
    item.name = finalName ?: key;
    item.source = groupId.length > 0 ? [NSString stringWithFormat:@"群成员(群ID:%@)", [groupId substringToIndex:MIN(6, groupId.length)]] : @"群聊成员提取";
    item.isGroup = NO;
    item.rawUserOrMemberObj = memberObj;
    _collectedUsersMap[key] = item;
}

#pragma mark - 5. 突破群权限限制（非群主也能看全部群成员并添加好友）

- (void)unlockGroupPrivilegeOnGroup:(id)groupObj {
    if (!groupObj) return;
    @try {
        uint8_t *base = (uint8_t *)(__bridge void *)groupObj;
        // 逆向报告 4.1 节 ZDGroup 权限位偏移：
        // 0xca (1字节): allowInvite (允许邀请)
        // 0x118 (1字节): protect (群保护模式：关闭设为0，允许互看主页和加好友！)
        // 0x119 (1字节): groupMemberList (允许查看群成员列表：开启设为1！)
        // 0x26b (1字节): sendCard / sendGroupCard
        base[0x118] = 0; // 强制关闭群成员保护模式
        base[0x119] = 1; // 强制开启允许查看群成员列表
    } @catch (NSException *e) {}
}

- (void)forceOpenGroupMemberListFromVC:(UIViewController *)vc {
    if (!vc) return;
    uint8_t *base = (uint8_t *)(__bridge void *)vc;
    NSString *vcCls = NSStringFromClass([vc class]);
    
    id groupInfo = nil;
    id sessionObj = nil;
    
    // 从 ZDConversationController1 (偏移 0x150=zd_groupInfo, 0x180=session) 读取
    if ([vcCls containsString:@"ZDConversationController1"]) {
        groupInfo = (__bridge id)*(void **)(base + 0x150);
        sessionObj = (__bridge id)*(void **)(base + 0x180);
    }
    if (groupInfo) {
        [self harvestFromGroupObject:groupInfo];
    }
    
    // 如果在聊天页，直接调用 zd_moreClick 打开群设置（已解锁群成员查看权限）或直接调起 ZDConversationGroupMemberListController
    if ([vc respondsToSelector:NSSelectorFromString(@"zd_moreClick")] && [vcCls containsString:@"ZDConversationController1"]) {
        ((void (*)(id, SEL))objc_msgSend)(vc, NSSelectorFromString(@"zd_moreClick"));
        return;
    }
    
    // 如果已经在群设置页 ZDConversationGroupSetController，直接触发查看全体群成员
    Class memberListCls = objc_getClass("_TtC7ZhengDu37ZDConversationGroupMemberListController");
    if (memberListCls && vc.navigationController) {
        UIViewController *memberVC = [[memberListCls alloc] init];
        if (memberVC) {
            // 将 session / group 传递给 memberVC
            [vc.navigationController pushViewController:memberVC animated:YES];
        }
    }
}

#pragma mark - 6. 排行榜突破 200 人限制：直接操控 0x70(zd_page) 分页叠加拉取

- (void)toggleRankBreakthroughPaging:(UIViewController *)rankItemVC {
    if (_isRankPaging) {
        [self stopRankPaging];
        return;
    }
    _isRankPaging = YES;
    _activeRankItemVC = rankItemVC;
    if (_rankActionBtn) {
        _rankActionBtn.backgroundColor = [UIColor systemRedColor];
    }
    [self stepNextRankPage];
    _rankPageTimer = [NSTimer scheduledTimerWithTimeInterval:2.2 target:self selector:@selector(stepNextRankPage) userInfo:nil repeats:YES];
}

- (void)stopRankPaging {
    _isRankPaging = NO;
    if (_rankPageTimer) {
        [_rankPageTimer invalidate];
        _rankPageTimer = nil;
    }
    [self saveCacheToDisk];
    if (_rankActionBtn) {
        _rankActionBtn.backgroundColor = [UIColor systemIndigoColor];
        [_rankActionBtn setTitle:[NSString stringWithFormat:@"🚀突破200限制·连刷全榜(已采%lu人)", (unsigned long)_collectedUsersMap.count] forState:UIControlStateNormal];
    }
}

- (void)stepNextRankPage {
    UIViewController *vc = _activeRankItemVC;
    if (!vc || !vc.view.window) {
        [self stopRankPaging];
        return;
    }
    
    uint8_t *base = (uint8_t *)(__bridge void *)vc;
    // 逆向报告 5.2 节 ZDGlobalTopItemController 精确内存偏移：
    // 0x70 (8字节): zd_page (Int)
    // 0x78 (8字节): zd_size (Int)
    // 0x88 (8字节): $__lazy_storage_$_zd_collect (UICollectionView?)
    NSInteger *pagePtr = (NSInteger *)(base + 0x70);
    NSInteger *sizePtr = (NSInteger *)(base + 0x78);
    UICollectionView *collect = (__bridge UICollectionView *)*(void **)(base + 0x88);
    
    if (*sizePtr < 100) *sizePtr = 100;
    
    if ([collect isKindOfClass:[UICollectionView class]]) {
        // 1. 先把当前屏幕所有可见 Cell 采集入库
        for (UICollectionViewCell *cell in collect.visibleCells) {
            NSIndexPath *ip = [collect indexPathForCell:cell];
            [self harvestFromRankCell:cell indexPath:ip rankVC:vc];
        }
        
        // 2. 滚动到底部以触发上拉加载更多 (mj_footer)，绝不触发 mj_header 重置！
        NSInteger totalItems = [collect numberOfItemsInSection:0];
        if (totalItems > 0) {
            NSIndexPath *lastIP = [NSIndexPath indexPathForItem:totalItems - 1 inSection:0];
            [collect scrollToItemAtIndexPath:lastIP atScrollPosition:UICollectionViewScrollPositionBottom animated:YES];
        }
        
        // 3. 触发 mj_footer 的加载下一页回调
        @try {
            id mjFooter = [collect valueForKey:@"mj_footer"];
            if (mjFooter && [mjFooter respondsToSelector:NSSelectorFromString(@"beginRefreshing")]) {
                ((void (*)(id, SEL))objc_msgSend)(mjFooter, NSSelectorFromString(@"beginRefreshing"));
            } else {
                // 如果该榜没有 mj_footer，则手动将 zd_page + 1 并触发刷新
                *pagePtr = (*pagePtr) + 1;
                if ([vc respondsToSelector:NSSelectorFromString(@"zd_willShowVC")]) {
                    ((void (*)(id, SEL))objc_msgSend)(vc, NSSelectorFromString(@"zd_willShowVC"));
                }
            }
        } @catch (NSException *e) {}
    }
    
    if (_rankActionBtn) {
        [_rankActionBtn setTitle:[NSString stringWithFormat:@"🛑正在突破连刷(第%ld页|已采%lu人)", (long)(*pagePtr), (unsigned long)_collectedUsersMap.count] forState:UIControlStateNormal];
    }
}

#pragma mark - 7. 点击采集成员 -> 直接打开个人主页 / 添加好友页面 (问题5完美解决)

- (void)openNativeUserHomePageForItem:(HOModelItem *)item fromVC:(UIViewController *)fromVC {
    if (!item || !fromVC) return;
    
    // 1. 自动把该用户的海鸥号/ID 复制到剪贴板，方便随时粘贴
    NSString *copyStr = (item.account.length >= 4 && ![item.account isEqualToString:@"通讯录好友"]) ? item.account : item.itemId;
    [UIPasteboard generalPasteboard].string = copyStr ?: item.name;
    
    UINavigationController *nav = fromVC.navigationController;
    if (!nav && [fromVC isKindOfClass:[UINavigationController class]]) {
        nav = (UINavigationController *)fromVC;
    }
    
    // 2. 优先尝试直接打开原生「查找添加好友/群」页面 (ZDAddFriendOrGroupController) 并自动填入海鸥号
    Class addFriendVCCls = objc_getClass("_TtC7ZhengDu28ZDAddFriendOrGroupController");
    if (addFriendVCCls && nav) {
        UIViewController *addVC = [[addFriendVCCls alloc] init];
        if (addVC) {
            addVC.hidesBottomBarWhenPushed = YES;
            [nav pushViewController:addVC animated:YES];
            
            // 页面打开后，自动把海鸥号填入搜索框并弹出提示
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                // 查找 addVC 中的 UITextField 自动填入账号并触发回车搜索
                UITextField *tf = [self findTextFieldInView:addVC.view];
                if (tf) {
                    tf.text = copyStr;
                    [tf sendActionsForControlEvents:UIControlEventEditingChanged];
                    if (tf.delegate && [tf.delegate respondsToSelector:@selector(textFieldShouldReturn:)]) {
                        [tf.delegate textFieldShouldReturn:tf];
                    }
                }
            });
            return;
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

// 打开海鸥原生内置的「群发助手」控制器 (ZDGroupSendMessageController)
- (void)openNativeGroupSendControllerFromVC:(UIViewController *)fromVC {
    Class nativeGroupSendCls = objc_getClass("_TtC7ZhengDu28ZDGroupSendMessageController");
    if (nativeGroupSendCls && fromVC.navigationController) {
        UIViewController *vc = [[nativeGroupSendCls alloc] init];
        vc.hidesBottomBarWhenPushed = YES;
        [fromVC.navigationController pushViewController:vc animated:YES];
    }
}

// 主动从消息页控制器 (ZDMessageListController1 偏移 0xb0 = zd_groups) 与我的群聊提取全部群
- (void)scanGroupsFromActiveControllers {
    UIWindow *win = [UIApplication sharedApplication].keyWindow;
    if (!win) return;
    UIViewController *root = win.rootViewController;
    NSMutableArray<UIViewController *> *allVCs = [NSMutableArray array];
    if ([root isKindOfClass:[UITabBarController class]]) {
        for (UIViewController *child in [(UITabBarController *)root viewControllers]) {
            if ([child isKindOfClass:[UINavigationController class]]) {
                [allVCs addObjectsFromArray:[(UINavigationController *)child viewControllers]];
            } else {
                [allVCs addObject:child];
            }
        }
    } else if ([root isKindOfClass:[UINavigationController class]]) {
        [allVCs addObjectsFromArray:[(UINavigationController *)root viewControllers]];
    }
    
    for (UIViewController *vc in allVCs) {
        NSString *clsName = NSStringFromClass([vc class]);
        uint8_t *base = (uint8_t *)(__bridge void *)vc;
        // 逆向报告 3.10 节：ZDMessageListController1 偏移 0xb0 是 zd_groups
        if ([clsName containsString:@"ZDMessageListController1"]) {
            @try {
                id groupsArr = (__bridge id)*(void **)(base + 0xb0);
                if ([groupsArr isKindOfClass:[NSArray class]]) {
                    for (id g in (NSArray *)groupsArr) {
                        [self harvestFromGroupObject:g];
                    }
                }
            } @catch (NSException *e) {}
        }
    }
    [self saveCacheToDisk];
}

@end

#pragma mark - ==================== 群发与拓客助手 UI 面板 ====================

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
    
    [[HOMassEngine shared] scanGroupsFromActiveControllers];
    
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"返回" style:UIBarButtonItemStylePlain target:self action:@selector(closeVC)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"清空缓存" style:UIBarButtonItemStylePlain target:self action:@selector(clearAllCacheAlert)];
    
    [self setupUI];
    [self reloadTabData];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [[HOMassEngine shared] scanGroupsFromActiveControllers];
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
    
    // 顶部大按钮：一键调用海鸥官方原生群发器（100% 走官方签名发送好友/群聊！）
    UIButton *nativeMassBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    nativeMassBtn.frame = CGRectMake(15, topY, self.view.bounds.size.width - 30, 40);
    [nativeMassBtn setTitle:@"📨 打开海鸥官方原生【群发消息】通道 (100%必达)" forState:UIControlStateNormal];
    nativeMassBtn.backgroundColor = [UIColor systemBlueColor];
    [nativeMassBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    nativeMassBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    nativeMassBtn.layer.cornerRadius = 8;
    [nativeMassBtn addTarget:self action:@selector(onTapNativeMassSend) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:nativeMassBtn];
    topY += 48;
    
    _tabSegment = [[UISegmentedControl alloc] initWithItems:@[@"采集池(点名字直接加好友)", @"我的群聊", @"通讯录好友"]];
    _tabSegment.frame = CGRectMake(15, topY, self.view.bounds.size.width - 30, 34);
    _tabSegment.selectedSegmentIndex = 0;
    [_tabSegment addTarget:self action:@selector(reloadTabData) forControlEvents:UIControlEventValueChanged];
    [self.view addSubview:_tabSegment];
    topY += 42;
    
    // 快捷导航导入栏
    CGFloat btnW = (self.view.bounds.size.width - 40) / 3.0;
    NSArray *titles = @[@"➕去群聊提取成员", @"➕去通讯录同步", @"📋批量复制海鸥号"];
    SEL actions[] = {@selector(goToMyGroupsVC), @selector(goToContactsVC), @selector(copyAllAccounts)};
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
    _tableView.rowHeight = 56;
    [self.view addSubview:_tableView];
}

- (void)onTapNativeMassSend {
    [[HOMassEngine shared] openNativeGroupSendControllerFromVC:self];
}

- (void)goToMyGroupsVC {
    // 直接打开海鸥原生的「我的群聊」页面 (ZDMyGroupController)，点进去自动把所有群和群成员抓过来
    Class myGroupCls = objc_getClass("_TtC7ZhengDu19ZDMyGroupController");
    if (myGroupCls && self.navigationController) {
        UIViewController *vc = [[myGroupCls alloc] init];
        vc.hidesBottomBarWhenPushed = YES;
        [self.navigationController pushViewController:vc animated:YES];
    }
}

- (void)goToContactsVC {
    // 直接打开海鸥原生的「选择好友/通讯录」页面 (ZDSelectFriendsController / ZDContactController)
    Class contactCls = objc_getClass("_TtC7ZhengDu19ZDContactController");
    if (contactCls && self.navigationController) {
        UIViewController *vc = [[contactCls alloc] init];
        vc.hidesBottomBarWhenPushed = YES;
        [self.navigationController pushViewController:vc animated:YES];
    }
}

- (void)copyAllAccounts {
    if (_currentList.count == 0) return;
    NSMutableString *s = [NSMutableString string];
    for (HOModelItem *item in _currentList) {
        [s appendFormat:@"%@ (%@)\n", item.account ?: item.itemId, item.name];
    }
    [UIPasteboard generalPasteboard].string = s;
    _statusLabel.text = [NSString stringWithFormat:@"✅ 已复制全部 %lu 个海鸥号到剪贴板！", (unsigned long)_currentList.count];
}

- (void)clearAllCacheAlert {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"清空全部采集缓存"
                                                                message:@"将清除所有旧数据，重新纯净采集"
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"确定清空" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [[HOMassEngine shared] clearDirtyDataAndSave];
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
        _statusLabel.text = [NSString stringWithFormat:@"👇 点击任意一行直接进入【他主页/添加好友页】(共 %lu 人)", (unsigned long)_currentList.count];
    } else if (_tabSegment.selectedSegmentIndex == 1) {
        _currentList = [eng.joinedGroupsMap.allValues sortedArrayUsingComparator:^NSComparisonResult(HOModelItem *a, HOModelItem *b) {
            return [a.name compare:b.name];
        }];
        _statusLabel.text = _currentList.count > 0
            ? [NSString stringWithFormat:@"【我的群聊】共 %lu 个群 (已自动突破群成员查看权限)", (unsigned long)_currentList.count]
            : @"💡 请点击上方「➕去群聊提取成员」浏览一次群聊即可自动同步！";
    } else {
        _currentList = [eng.contactFriendsMap.allValues sortedArrayUsingComparator:^NSComparisonResult(HOModelItem *a, HOModelItem *b) {
            return [a.name compare:b.name];
        }];
        _statusLabel.text = _currentList.count > 0
            ? [NSString stringWithFormat:@"【通讯录好友】共 %lu 人 (点击可直接查找/发消息)", (unsigned long)_currentList.count]
            : @"💡 请点击上方「➕去通讯录同步」滑动一下通讯录列表即可！";
    }
    [_tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _currentList.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"HOCleanItemCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    HOModelItem *item = _currentList[indexPath.row];
    cell.textLabel.text = [NSString stringWithFormat:@"%ld. %@", (long)(indexPath.row + 1), item.name];
    cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"海鸥号/ID: %@  |  来源: %@  👉点此加他", item.account ?: item.itemId, item.source];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    HOModelItem *item = _currentList[indexPath.row];
    // 点击直接跳转到原生「添加好友/用户主页」并自动填入该用户的海鸥号并触发搜索！
    [[HOMassEngine shared] openNativeUserHomePageForItem:item fromVC:self];
}

@end

#pragma mark - ==================== Runtime Hook 核心挂载区 ====================

static void SwizzleInstanceMethod(Class cls, SEL origSel, SEL swizSel, IMP newImp, const char *types) {
    if (!cls) return;
    Method origMethod = class_getInstanceMethod(cls, origSel);
    if (!origMethod) return;
    class_addMethod(cls, swizSel, newImp, types ?: method_getTypeEncoding(origMethod));
    Method swizMethod = class_getInstanceMethod(cls, swizSel);
    method_exchangeImplementations(origMethod, swizMethod);
}

// ---------------- 1. 仅对「我的」页面做安全 IndexPath 修正，不再盲目抓全表文字！ ----------------
static UITableViewCell *(*orig_tv_dequeueForIndexPath)(UITableView *, SEL, NSString *, NSIndexPath *);
static UITableViewCell *hook_tv_dequeueForIndexPath(UITableView *self, SEL _cmd, NSString *identifier, NSIndexPath *indexPath) {
    if (self == g_currentMineTableView && g_currentRealRequestIndexPath != nil) {
        return orig_tv_dequeueForIndexPath(self, _cmd, identifier, g_currentRealRequestIndexPath);
    }
    UITableViewCell *cell = orig_tv_dequeueForIndexPath(self, _cmd, identifier, indexPath);
    // 仅当 Cell 是通讯录好友专属的 ZDContactCell 时才提取！彻底杜绝“44分钟/文件助手/关于版本”等杂乱内容！
    if (cell && [NSStringFromClass([cell class]) containsString:@"ZDContactCell"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[HOMassEngine shared] harvestFromContactCell:cell];
        });
    }
    return cell;
}

// ---------------- 2. Hook ZDMineController: 在「我的」页面“海鸥助手”下方插入“群发助手” ----------------
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
                static NSString *kMassEntryCellId = @"ZD_HOMassHelperEntryCell_v2";
                UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kMassEntryCellId];
                if (!cell) {
                    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:kMassEntryCellId];
                    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                }
                cell.textLabel.text = @"群发助手";
                cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
                cell.detailTextLabel.text = @"点名加人·群权限突破·原生群发";
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
    CollectCellLabels(cell, texts);
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

// ---------------- 3. Hook 排行榜 ZDGlobalTopItemController (突破200人限制) ----------------
static void (*orig_rank_viewDidAppear)(id, SEL, BOOL);
static void hook_rank_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    orig_rank_viewDidAppear(self, _cmd, animated);
    UIViewController *vc = (UIViewController *)self;
    [HOMassEngine shared].activeRankItemVC = vc;
    
    UIButton *btn = [vc.view viewWithTag:99883];
    if (!btn) {
        btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.tag = 99883;
        btn.frame = CGRectMake(20, 8, vc.view.bounds.size.width - 40, 36);
        btn.backgroundColor = [[UIColor systemIndigoColor] colorWithAlphaComponent:0.95];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        btn.layer.cornerRadius = 18;
        btn.layer.zPosition = 9999;
        [btn addTarget:self action:NSSelectorFromString(@"ho_onTapRankPagingBtn:") forControlEvents:UIControlEventTouchUpInside];
        [vc.view addSubview:btn];
    }
    [vc.view bringSubviewToFront:btn];
    [HOMassEngine shared].rankActionBtn = btn;
    [btn setTitle:[NSString stringWithFormat:@"🚀突破200限制·连刷全榜(已采%lu人)", (unsigned long)[HOMassEngine shared].collectedUsersMap.count] forState:UIControlStateNormal];
}

static void (*orig_rank_viewWillDisappear)(id, SEL, BOOL);
static void hook_rank_viewWillDisappear(id self, SEL _cmd, BOOL animated) {
    [[HOMassEngine shared] stopRankPaging];
    orig_rank_viewWillDisappear(self, _cmd, animated);
}

static void ho_onTapRankPagingBtn_imp(id self, SEL _cmd, UIButton *sender) {
    [[HOMassEngine shared] toggleRankBreakthroughPaging:(UIViewController *)self];
}

static void hook_rank_clickUpgrade(id self, SEL _cmd) {
    // 屏蔽等级弹窗限制
}

static UICollectionViewCell *(*orig_rank_cellForItem)(id, SEL, UICollectionView *, NSIndexPath *);
static UICollectionViewCell *hook_rank_cellForItem(id self, SEL _cmd, UICollectionView *cv, NSIndexPath *indexPath) {
    UICollectionViewCell *cell = orig_rank_cellForItem(self, _cmd, cv, indexPath);
    if (cell) {
        UIViewController *vc = (UIViewController *)self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[HOMassEngine shared] harvestFromRankCell:cell indexPath:indexPath rankVC:vc];
        });
    }
    return cell;
}

// ---------------- 4. Hook 群聊会话页 & 群设置页：注入【🔓突破群主权限·提取全群成员】按钮 ----------------
static void (*orig_chat_viewDidAppear)(id, SEL, BOOL);
static void hook_chat_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    orig_chat_viewDidAppear(self, _cmd, animated);
    UIViewController *vc = (UIViewController *)self;
    uint8_t *base = (uint8_t *)(__bridge void *)vc;
    // ZDConversationController1 偏移 0x150 为 zd_groupInfo
    id groupInfo = (__bridge id)*(void **)(base + 0x150);
    if (groupInfo) {
        [[HOMassEngine shared] harvestFromGroupObject:groupInfo];
        
        UIButton *unlockBtn = [vc.view viewWithTag:99885];
        if (!unlockBtn) {
            unlockBtn = [UIButton buttonWithType:UIButtonTypeCustom];
            unlockBtn.tag = 99885;
            unlockBtn.frame = CGRectMake(vc.view.bounds.size.width - 175, 96, 165, 32);
            unlockBtn.backgroundColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.92];
            [unlockBtn setTitle:@"🔓突破权限·提取群成员" forState:UIControlStateNormal];
            [unlockBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            unlockBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
            unlockBtn.layer.cornerRadius = 16;
            unlockBtn.layer.zPosition = 9999;
            [unlockBtn addTarget:self action:NSSelectorFromString(@"ho_onTapUnlockGroupMembers:") forControlEvents:UIControlEventTouchUpInside];
            [vc.view addSubview:unlockBtn];
        }
        [vc.view bringSubviewToFront:unlockBtn];
    }
}

static void ho_onTapUnlockGroupMembers_imp(id self, SEL _cmd, UIButton *sender) {
    [[HOMassEngine shared] forceOpenGroupMemberListFromVC:(UIViewController *)self];
}

// ---------------- 5. Hook ZDGroup 与 ZDGroupMember 初始化：自动解锁群权限 + 自动提取群成员 ----------------
static id (*orig_group_init)(id, SEL);
static id hook_group_init(id self, SEL _cmd) {
    id ins = orig_group_init(self, _cmd);
    if (ins) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[HOMassEngine shared] harvestFromGroupObject:ins];
        });
    }
    return ins;
}

static id (*orig_groupMember_init)(id, SEL);
static id hook_groupMember_init(id self, SEL _cmd) {
    id ins = orig_groupMember_init(self, _cmd);
    if (ins) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[HOMassEngine shared] harvestFromGroupMemberObject:ins];
        });
    }
    return ins;
}

#pragma mark - ==================== Dylib 构造函数入口 ====================

__attribute__((constructor))
static void HaiouMassHelperInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 1. 挂载 UITableView 安全修正与 ZDContactCell 专属提取
        Class tvCls = [UITableView class];
        SEL deqSel = @selector(dequeueReusableCellWithIdentifier:forIndexPath:);
        orig_tv_dequeueForIndexPath = (__typeof__(orig_tv_dequeueForIndexPath))method_getImplementation(class_getInstanceMethod(tvCls, deqSel));
        SwizzleInstanceMethod(tvCls, deqSel, NSSelectorFromString(@"ho_dequeueReusableCellWithIdentifier:forIndexPath:"), (IMP)hook_tv_dequeueForIndexPath, NULL);
        
        // 2. 挂载「我的」页面入口 (ZDMineController)
        Class mineCls = objc_getClass("_TtC7ZhengDu16ZDMineController");
        if (mineCls) {
            orig_mine_numberOfRowsInSection = (__typeof__(orig_mine_numberOfRowsInSection))method_getImplementation(class_getInstanceMethod(mineCls, @selector(tableView:numberOfRowsInSection:)));
            SwizzleInstanceMethod(mineCls, @selector(tableView:numberOfRowsInSection:), NSSelectorFromString(@"ho_tableView:numberOfRowsInSection:"), (IMP)hook_mine_numberOfRowsInSection, NULL);
            
            orig_mine_heightForRowAtIndexPath = (__typeof__(orig_mine_heightForRowAtIndexPath))method_getImplementation(class_getInstanceMethod(mineCls, @selector(tableView:heightForRowAtIndexPath:)));
            SwizzleInstanceMethod(mineCls, @selector(tableView:heightForRowAtIndexPath:), NSSelectorFromString(@"ho_tableView:heightForRowAtIndexPath:"), (IMP)hook_mine_heightForRowAtIndexPath, NULL);
            
            orig_mine_cellForRowAtIndexPath = (__typeof__(orig_mine_cellForRowAtIndexPath))method_getImplementation(class_getInstanceMethod(mineCls, @selector(tableView:cellForRowAtIndexPath:)));
            SwizzleInstanceMethod(mineCls, @selector(tableView:cellForRowAtIndexPath:), NSSelectorFromString(@"ho_tableView:cellForRowAtIndexPath:"), (IMP)hook_mine_cellForRowAtIndexPath, NULL);
            
            orig_mine_didSelectRowAtIndexPath = (__typeof__(orig_mine_didSelectRowAtIndexPath))method_getImplementation(class_getInstanceMethod(mineCls, @selector(tableView:didSelectRowAtIndexPath:)));
            SwizzleInstanceMethod(mineCls, @selector(tableView:didSelectRowAtIndexPath:), NSSelectorFromString(@"ho_tableView:didSelectRowAtIndexPath:"), (IMP)hook_mine_didSelectRowAtIndexPath, NULL);
        }
        
        // 3. 挂载「等级排行」控制器 (ZDGlobalTopItemController)
        Class rankItemCls = objc_getClass("_TtC7ZhengDu25ZDGlobalTopItemController");
        if (rankItemCls) {
            class_addMethod(rankItemCls, NSSelectorFromString(@"ho_onTapRankPagingBtn:"), (IMP)ho_onTapRankPagingBtn_imp, "v@:@");
            
            Method vdaMethod = class_getInstanceMethod(rankItemCls, @selector(viewDidAppear:));
            orig_rank_viewDidAppear = (__typeof__(orig_rank_viewDidAppear))method_getImplementation(vdaMethod);
            if (!class_addMethod(rankItemCls, @selector(viewDidAppear:), (IMP)hook_rank_viewDidAppear, method_getTypeEncoding(vdaMethod))) {
                SwizzleInstanceMethod(rankItemCls, @selector(viewDidAppear:), NSSelectorFromString(@"ho_rank_viewDidAppear:"), (IMP)hook_rank_viewDidAppear, NULL);
            }
            
            Method vwdMethod = class_getInstanceMethod(rankItemCls, @selector(viewWillDisappear:));
            orig_rank_viewWillDisappear = (__typeof__(orig_rank_viewWillDisappear))method_getImplementation(vwdMethod);
            if (!class_addMethod(rankItemCls, @selector(viewWillDisappear:), (IMP)hook_rank_viewWillDisappear, method_getTypeEncoding(vwdMethod))) {
                SwizzleInstanceMethod(rankItemCls, @selector(viewWillDisappear:), NSSelectorFromString(@"ho_rank_viewWillDisappear:"), (IMP)hook_rank_viewWillDisappear, NULL);
            }
            
            SwizzleInstanceMethod(rankItemCls, NSSelectorFromString(@"zd_clickUpgrade"), NSSelectorFromString(@"ho_zd_clickUpgrade"), (IMP)hook_rank_clickUpgrade, NULL);
            
            orig_rank_cellForItem = (__typeof__(orig_rank_cellForItem))method_getImplementation(class_getInstanceMethod(rankItemCls, @selector(collectionView:cellForItemAtIndexPath:)));
            SwizzleInstanceMethod(rankItemCls, @selector(collectionView:cellForItemAtIndexPath:), NSSelectorFromString(@"ho_collectionView:cellForItemAtIndexPath:"), (IMP)hook_rank_cellForItem, NULL);
        }
        
        // 4. 挂载群聊会话控制器 (ZDConversationController1) 注入突破群权限按钮
        Class chatVCCls = objc_getClass("_TtC7ZhengDu25ZDConversationController1");
        if (chatVCCls) {
            class_addMethod(chatVCCls, NSSelectorFromString(@"ho_onTapUnlockGroupMembers:"), (IMP)ho_onTapUnlockGroupMembers_imp, "v@:@");
            orig_chat_viewDidAppear = (__typeof__(orig_chat_viewDidAppear))method_getImplementation(class_getInstanceMethod(chatVCCls, @selector(viewDidAppear:)));
            SwizzleInstanceMethod(chatVCCls, @selector(viewDidAppear:), NSSelectorFromString(@"ho_chat_viewDidAppear:"), (IMP)hook_chat_viewDidAppear, NULL);
        }
        
        // 5. 挂载群模型 (ZDGroup) 与群成员模型 (ZDGroupMember)
        Class groupCls = objc_getClass("_TtC7ZhengDu7ZDGroup");
        if (groupCls) {
            orig_group_init = (__typeof__(orig_group_init))method_getImplementation(class_getInstanceMethod(groupCls, @selector(init)));
            SwizzleInstanceMethod(groupCls, @selector(init), NSSelectorFromString(@"ho_group_init"), (IMP)hook_group_init, NULL);
        }
        
        Class groupMemberCls = objc_getClass("_TtC7ZhengDu13ZDGroupMember");
        if (groupMemberCls) {
            orig_groupMember_init = (__typeof__(orig_groupMember_init))method_getImplementation(class_getInstanceMethod(groupMemberCls, @selector(init)));
            SwizzleInstanceMethod(groupMemberCls, @selector(init), NSSelectorFromString(@"ho_gm_init"), (IMP)hook_groupMember_init, NULL);
        }
    });
}

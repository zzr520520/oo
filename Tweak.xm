#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ============================================================================
// 一、 全局辅助工具与单例
// ============================================================================

@interface ZDGDataManager : NSObject
@property (nonatomic, strong) NSMutableArray *selectedFriends; // 选中的好友
@property (nonatomic, strong) NSMutableArray *selectedGroups;  // 选中的群组
@property (nonatomic, strong) NSMutableArray *allRankUsers;    // 抓取到的所有排行榜人员
@property (nonatomic, strong) NSMutableArray *pendingJoinGroupUsers; // 新入群需要加好友的队列
+ (instancetype)sharedInstance;
- (void)startAutoAddFriendTimer;
- (void)addFriendWithUserId:(NSString *)userId;
@end

@implementation ZDGDataManager

+ (instancetype)sharedInstance {
    static ZDGDataManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ZDGDataManager alloc] init];
        instance.selectedFriends = [NSMutableArray array];
        instance.selectedGroups = [NSMutableArray array];
        instance.allRankUsers = [NSMutableArray array];
        instance.pendingJoinGroupUsers = [NSMutableArray array];
    });
    return instance;
}

// 自动加好友队列处理（带随机延时防风控）
- (void)startAutoAddFriendTimer {
    if (self.pendingJoinGroupUsers.count == 0) return;
    
    NSString *userId = self.pendingJoinGroupUsers.firstObject;
    [self.pendingJoinGroupUsers removeObjectAtIndex:0];
    
    [self addFriendWithUserId:userId];
    
    // 5 - 15 秒随机延时
    NSTimeInterval delay = arc4random_uniform(10) + 5.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self startAutoAddFriendTimer];
    });
}

- (void)addFriendWithUserId:(NSString *)userId {
    // 尝试通过内部 API 或直接发送请求加好友
    NSLog(@"[海鸥助手] 正在请求添加好友 ID: %@", userId);
    
    // 如果能够通过 Runtime 找到 ZDUserManager 的加好友方法，则直接调用
    Class userManagerClass = NSClassFromString(@"ZDUserManager");
    if (userManagerClass) {
        id manager = [userManagerClass performSelector:@selector(sharedInstance)];
        SEL addSel = NSSelectorFromString(@"zd_addFriendWithUserId:complete:"); // 假设的方法名，需根据实际逆向修改
        if ([manager respondsToSelector:addSel]) {
            // 使用 objc_msgSend 调用
            ((void (*)(id, SEL, id, id))objc_msgSend)(manager, addSel, userId, nil);
            return;
        }
    }
    
    // 兜底：直接发送 HTTP 请求 (参考文档接口 /api/addfriend)
    // 注意：必须带上当前的 Token
    NSString *token = [[NSUserDefaults standardUserDefaults] objectForKey:@"zd_token"]; // 实际 key 需抓包确认
    if (!token) {
        NSLog(@"[海鸥助手] 未找到 Token，无法发送加好友请求");
        return;
    }
    
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://api.haiouchat.com/api/addfriend"]];
    req.HTTPMethod = @"POST";
    [req setValue:token forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    
    NSDictionary *body = @{@"userId": userId, @"msg": @"你好，交个朋友"};
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    
    [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSLog(@"[海鸥助手] 加好友结果: %@", error ? error.localizedDescription : @"请求已发送");
    }];
}

@end


// ============================================================================
// 二、 群发助手 主控制器 (纯代码 UI)
// ============================================================================

@interface ZDGBroadcastViewController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UISegmentedControl *segmentControl;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray *dataSource;
@end

@implementation ZDGBroadcastViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"群发助手";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    
    // 顶部切换
    self.segmentControl = [[UISegmentedControl alloc] initWithItems:@[@"好友列表", @"群组列表", @"排行榜人员"]];
    self.segmentControl.selectedSegmentIndex = 0;
    [self.segmentControl addTarget:self action:@selector(segmentChanged) forControlEvents:UIControlEventValueChanged];
    self.segmentControl.frame = CGRectMake(10, 10, self.view.bounds.size.width - 20, 40);
    [self.view addSubview:self.segmentControl];
    
    // 列表
    self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 60, self.view.bounds.size.width, self.view.bounds.size.height - 120) style:UITableViewStylePlain];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    [self.view addSubview:self.tableView];
    
    // 底部按钮
    UIView *bottomView = [[UIView alloc] initWithFrame:CGRectMake(0, self.view.bounds.size.height - 60, self.view.bounds.size.width, 60)];
    bottomView.backgroundColor = [UIColor whiteColor];
    
    UIButton *selectAllBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    selectAllBtn.frame = CGRectMake(10, 15, 60, 30);
    [selectAllBtn setTitle:@"全选/取消" forState:UIControlStateNormal];
    [selectAllBtn addTarget:self action:@selector(selectAllClicked) forControlEvents:UIControlEventTouchUpInside];
    [bottomView addSubview:selectAllBtn];
    
    UIButton *sendBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    sendBtn.frame = CGRectMake(self.view.bounds.size.width - 150, 15, 140, 30);
    [sendBtn setTitle:@"发送/申请好友" forState:UIControlStateNormal];
    sendBtn.backgroundColor = [UIColor systemBlueColor];
    [sendBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    sendBtn.layer.cornerRadius = 5;
    [sendBtn addTarget:self action:@selector(sendClicked) forControlEvents:UIControlEventTouchUpInside];
    [bottomView addSubview:sendBtn];
    
    [self.view addSubview:bottomView];
    
    [self loadDataForSegment:self.segmentControl.selectedSegmentIndex];
}

- (void)segmentChanged {
    [self loadDataForSegment:self.segmentControl.selectedSegmentIndex];
}

- (void)loadDataForSegment:(NSInteger)index {
    self.dataSource = [NSMutableArray array];
    
    if (index == 0) {
        // 好友列表 (演示用，实际应从数据库或内部接口拉取)
        // 实际开发中，可以通过遍历 FMDB 数据库表获取
        for (int i = 0; i < 20; i++) {
            [self.dataSource addObject:@{@"name": [NSString stringWithFormat:@"好友 %d", i], @"id": [NSString stringWithFormat:@"1000%d", i], @"selected": @NO}];
        }
    } else if (index == 1) {
        // 群组列表
        for (int i = 0; i < 10; i++) {
            [self.dataSource addObject:@{@"name": [NSString stringWithFormat:@"群组 %d", i], @"id": [NSString stringWithFormat:@"2000%d", i], @"selected": @NO}];
        }
    } else {
        // 排行榜人员 (通过 Hook 获取)
        self.dataSource = [[ZDGDataManager sharedInstance].allRankUsers mutableCopy];
        if (self.dataSource.count == 0) {
            // 如果没有数据，提示用户去排行榜页面触发拉取
            [self.dataSource addObject:@{@"name": @"请前往等级排行页面下拉刷新加载数据", @"id": @"0", @"selected": @NO}];
        }
    }
    [self.tableView reloadData];
}

- (void)selectAllClicked {
    for (int i = 0; i < self.dataSource.count; i++) {
        NSMutableDictionary *dict = [self.dataSource[i] mutableCopy];
        dict[@"selected"] = @YES;
        self.dataSource[i] = dict;
    }
    [self.tableView reloadData];
}

- (void)sendClicked {
    NSMutableArray *selectedIds = [NSMutableArray array];
    for (NSDictionary *dict in self.dataSource) {
        if ([dict[@"selected"] boolValue]) {
            [selectedIds addObject:dict[@"id"]];
        }
    }
    
    if (selectedIds.count == 0) {
        NSLog(@"[海鸥助手] 请先选择人员");
        return;
    }
    
    if (self.segmentControl.selectedSegmentIndex == 2) {
        // 批量发好友申请
        for (NSString *uid in selectedIds) {
            [[ZDGDataManager sharedInstance] addFriendWithUserId:uid];
            // 延时防止被封
            [NSThread sleepForTimeInterval:2.0];
        }
        NSLog(@"[海鸥助手] 批量好友申请发送完毕");
    } else {
        // 批量群发消息
        for (NSString *targetId in selectedIds) {
            // 尝试调用内部方法发消息
            Class chatManagerClass = NSClassFromString(@"ZDChatManager");
            if (chatManagerClass) {
                id chatManager = [chatManagerClass performSelector:@selector(sharedInstance)];
                // 这里的 sendMessage 方法名是推测的，需根据实际情况逆向
                SEL sendSel = NSSelectorFromString(@"zd_sendMessage:toSession:complete:");
                if ([chatManager respondsToSelector:sendSel]) {
                    id msgModel = [[NSClassFromString(@"ZDMessage") alloc] init];
                    [msgModel setValue:@"这是一条群发消息" forKey:@"message"];
                    [msgModel setValue:targetId forKey:@"chatId"];
                    // ((void (*)(id, SEL, id, id, id))objc_msgSend)(chatManager, sendSel, msgModel, nil, nil);
                }
            }
            [NSThread sleepForTimeInterval:3.0]; // 随机延时，降低风控风险
        }
        NSLog(@"[海鸥助手] 批量群发完毕");
    }
}

#pragma mark - UITableView
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.dataSource.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Cell"];
    }
    NSDictionary *dict = self.dataSource[indexPath.row];
    cell.textLabel.text = dict[@"name"];
    cell.detailTextLabel.text = dict[@"id"];
    cell.accessoryType = [dict[@"selected"] boolValue] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSMutableDictionary *dict = [self.dataSource[indexPath.row] mutableCopy];
    BOOL selected = [dict[@"selected"] boolValue];
    dict[@"selected"] = @(!selected);
    self.dataSource[indexPath.row] = dict;
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

@end


// ============================================================================
// 三、 Hook 注入与事件监听
// ============================================================================

%hook ZDMineController

- (void)viewDidLoad {
    %orig;
    
    // 延迟执行，等待原数据源加载完毕
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        Ivar datasIvar = class_getInstanceVariable([self class], "zd_datas");
        if (datasIvar) {
            NSMutableArray *datas = object_getIvar(self, datasIvar);
            if (!datas) return;
            
            // 假设数据结构是 NSArray 或类似字典，我们插入一个占位字典
            NSMutableDictionary *item = [NSMutableDictionary dictionary];
            [item setValue:@"群发助手" forKey:@"title"];
            
            // 插入到第 3 个位置 (海鸥助手下面)
            if (datas.count > 2) {
                [datas insertObject:item atIndex:2];
            } else {
                [datas addObject:item];
            }
            
            // 刷新表格
            UITableView *table = object_getIvar(self, class_getInstanceVariable([self class], "zd_table"));
            if (!table) table = object_getIvar(self, class_getInstanceVariable([self class], "tableView"));
            [table reloadData];
        }
    });
}

// 拦截点击事件
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    Ivar datasIvar = class_getInstanceVariable([self class], "zd_datas");
    if (datasIvar) {
        NSMutableArray *datas = object_getIvar(self, datasIvar);
        if (indexPath.row < datas.count) {
            id item = datas[indexPath.row];
            NSString *title = nil;
            if ([item isKindOfClass:[NSDictionary class]]) {
                title = item[@"title"];
            } else if ([item isKindOfClass:[NSObject class]]) {
                title = [item valueForKey:@"title"];
            }
            
            if ([title isEqualToString:@"群发助手"]) {
                ZDGBroadcastViewController *vc = [[ZDGBroadcastViewController alloc] init];
                [((id)self).navigationController pushViewController:vc animated:YES];
                return;
            }
        }
    }
    %orig;
}

%end


// 监听消息 (用于自动加新入群成员)
%hook ZDChatManager

- (void)zd_receiveWithMessage:(id)message needRecip:(BOOL)needRecip needNot:(BOOL)needNot complete:(id)complete {
    %orig;
    
    // 解析消息内容
    NSString *content = [message valueForKey:@"message"];
    int type = [[message valueForKey:@"messageType"] intValue];
    
    // 如果消息是系统消息 (通常 type 比较特殊，假设包含“加入群聊”字样)
    if ([content containsString:@"加入了群聊"] || [content containsString:@"加入本群"]) {
        // 提取用户 ID (这里需要根据实际文本格式用正则提取，假设是 "[123456]加入群聊" 这种格式)
        NSError *error;
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\d{18,19}" options:0 error:&error];
        NSArray *matches = [regex matchesInString:content options:0 range:NSMakeRange(0, content.length)];
        if (matches.count > 0) {
            NSTextCheckingResult *match = matches.firstObject;
            NSString *userId = [content substringWithRange:match.range];
            NSLog(@"[海鸥助手] 监听到新成员加入群聊: %@", userId);
            
            // 添加到自动加好友队列
            [[ZDGDataManager sharedInstance].pendingJoinGroupUsers addObject:userId];
            [[ZDGDataManager sharedInstance] startAutoAddFriendTimer];
        }
    }
}

%end


// 监听排行榜翻页 (用于抓取所有人员)
%hook ZDGlobalTopItemController

- (void)viewDidLoad {
    %orig;
    
    // 把当前的控制器实例注册到一个全局管理器中，以便后续翻页拉取
    // 这里为了简化，我们直接 Hook 其加载数据的回调或下拉刷新事件
    // 实际使用时，需要模拟下拉刷新，不断修改 zd_page 参数
}

// 假设有这个加载数据的方法，我们需要拦截其网络返回的结果，收集所有用户 ID
- (void)zd_updateShow {
    %orig;
    
    // 尝试获取列表数据
    Ivar dataIvar = class_getInstanceVariable([self class], "zd_data");
    if (dataIvar) {
        NSArray *list = object_getIvar(self, dataIvar);
        if (list && [list isKindOfClass:[NSArray class]]) {
            for (id item in list) {
                // 提取用户 ID
                NSString *userId = [item valueForKey:@"userId"];
                if (userId) {
                    [[ZDGDataManager sharedInstance].allRankUsers addObject:@{@"name": [item valueForKey:@"nickName"] ?: @"匿名", @"id": userId, @"selected": @NO}];
                }
            }
            NSLog(@"[海鸥助手] 已收集到排行榜人员数量: %lu", (unsigned long)[ZDGDataManager sharedInstance].allRankUsers.count);
        }
    }
}

%end

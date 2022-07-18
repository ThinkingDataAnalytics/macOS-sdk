#import "ThinkingAnalyticsSDKPrivate.h"

#if TARGET_OS_IOS
#import "TDAutoTrackManager.h"
#endif

#import "TDCalibratedTimeWithNTP.h"
#import "TDConfig.h"
#import "TDPublicConfig.h"
#import "TDFile.h"
#import "TDCheck.h"
#import "TDJSONUtil.h"
#import "NSString+TDString.h"
#import "TDPresetProperties+TDDisProperties.h"
#import "TDAppState.h"
#import "TDEventRecord.h"
#import "TAAppExtensionAnalytic.h"
#import "TAReachability.h"

#if !__has_feature(objc_arc)
#error The ThinkingSDK library must be compiled with ARC enabled
#endif

#define td_force_inline __inline__ __attribute__((always_inline))

@interface TDPresetProperties (ThinkingAnalytics)

- (instancetype)initWithDictionary:(NSDictionary *)dict;
- (void)updateValuesWithDictionary:(NSDictionary *)dict;

@end

@interface ThinkingAnalyticsSDK ()
@property (nonatomic, strong) TAEventTracker *eventTracker;
@property (strong,nonatomic) TDFile *file;

@end

@implementation ThinkingAnalyticsSDK

static NSMutableDictionary *instances;
static NSString *defaultProjectAppid;
static TDCalibratedTime *calibratedTime;
// track操作、操作数据库等在td_trackQueue中进行
static dispatch_queue_t td_trackQueue;

+ (NSMutableDictionary *)_getAllInstances {
    return instances;
}

+ (void)_clearCalibratedTime {
    calibratedTime = nil;
}

+ (nullable ThinkingAnalyticsSDK *)sharedInstance {
    if (instances.count == 0) {
        TDLogError(@"sharedInstance called before creating a Thinking instance");
        return nil;
    }
    return instances[defaultProjectAppid];
}

+ (ThinkingAnalyticsSDK *)sharedInstanceWithAppid:(NSString *)appid {
    appid = appid.td_trim;// 去除空格
    if (instances[appid]) {
        return instances[appid];
    } else {
        TDLogError(@"sharedInstanceWithAppid called before creating a Thinking instance");
        return nil;
    }
}

+ (ThinkingAnalyticsSDK *)startWithAppId:(NSString *)appId withUrl:(NSString *)url withConfig:(TDConfig *)config {
    appId = appId.td_trim; // 去除空格
    
    // name存在，先从内存取，取不到再初始化
    NSString *name = config.name;
    if (name && [name isKindOfClass:[NSString class]] && name.length) {
        if (instances[name]) {
            return instances[name];
        } else {
            return [[self alloc] initWithAppkey:appId withServerURL:url withConfig:config];
        }
    }
    
    // name不存在，(原逻辑)appid存在，先从内存取，取不到再初始化
    if (instances[appId]) {
        return instances[appId];
    } else if (![url isKindOfClass:[NSString class]] || url.length == 0) {
        return nil;
    }
    return [[self alloc] initWithAppkey:appId withServerURL:url withConfig:config];
}

+ (ThinkingAnalyticsSDK *)startWithAppId:(NSString *)appId withUrl:(NSString *)url {
    return [ThinkingAnalyticsSDK startWithAppId:appId withUrl:url withConfig:nil];
}

+ (ThinkingAnalyticsSDK *)startWithConfig:(nullable TDConfig *)config {
    return [ThinkingAnalyticsSDK startWithAppId:config.appid withUrl:config.configureURL withConfig:config];
}

- (instancetype)init:(NSString *)appID {
    if (self = [super init]) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            instances = [NSMutableDictionary dictionary];
            defaultProjectAppid = appID;
        });
    }
    return self;
}

+ (void)initialize {
    static dispatch_once_t ThinkingOnceToken;
    dispatch_once(&ThinkingOnceToken, ^{
        NSString *queuelabel = [NSString stringWithFormat:@"cn.thinkingdata.%p", (void *)self];
        td_trackQueue = dispatch_queue_create([queuelabel UTF8String], DISPATCH_QUEUE_SERIAL);
    });
}

+ (dispatch_queue_t)td_trackQueue {
    return td_trackQueue;
}

- (instancetype)initLight:(NSString *)appid withServerURL:(NSString *)serverURL withConfig:(TDConfig *)config {
    if (self = [self init]) {
        serverURL = [serverURL ta_formatUrlString];
        _appid = appid;
        _isEnabled = YES;
        _serverURL = serverURL;
        _config = [config copy];
        _config.configureURL = serverURL;
        
        // 初始化公共属性管理
        self.superProperty = [[TASuperProperty alloc] initWithToken:[self td_getMapInstanceTag] isLight:YES];
        
        self.trackTimer = [[TATrackTimer alloc] init];
        
        if (![TDPresetProperties disableNetworkType]) {
            [[TAReachability shareInstance] startMonitoring];
        }
        
        self.file = [[TDFile alloc] initWithAppid:appid];
        
        self.dataQueue = [TDSqliteDataQueue sharedInstanceWithAppid:appid];
        if (self.dataQueue == nil) {
            TDLogError(@"SqliteException: init SqliteDataQueue failed");
        }
        
        self.eventTracker = [[TAEventTracker alloc] initWithQueue:td_trackQueue instanceToken:[config getMapInstanceToken]];
    }
    return self;
}

- (instancetype)initWithAppkey:(NSString *)appid withServerURL:(NSString *)serverURL withConfig:(TDConfig *)config {
    if (self = [self init:appid]) {
        serverURL = [serverURL ta_formatUrlString];
        self.serverURL = serverURL;
        self.appid = appid;
        
        if (!config) {
            config = TDConfig.defaultTDConfig;
        }
        
        _config = [config copy];
        _config.appid = appid;
        _config.configureURL = serverURL;
        
        instances[[self td_getMapInstanceTag]] = self;

        self.file = [[TDFile alloc] initWithAppid:[self td_getMapInstanceTag]];
        // 恢复配置
        [self retrievePersistedData];
        
        // 初始化公共属性管理
        self.superProperty = [[TASuperProperty alloc] initWithToken:[self td_getMapInstanceTag] isLight:NO];
        
        // 注册属性插件
        self.propertyPluginManager = [[TAPropertyPluginManager alloc] init];
        TAPresetPropertyPlugin *presetPlugin = [[TAPresetPropertyPlugin alloc] init];
        [self.propertyPluginManager registerPropertyPlugin:presetPlugin];
        
        // config获取intanceName
        NSString *instanceName = [self td_getMapInstanceTag];
        
        _config.getInstanceName = ^NSString * _Nonnull{
            return instanceName;
        };
        
#if TARGET_OS_IOS
        // 加载加密插件
        if (_config.enableEncrypt) {
            self.encryptManager = [[TDEncryptManager alloc] initWithConfig:config];
        }
        __weak __typeof(self)weakSelf = self;
        //次序不能调整，异步获取加密配置
        [_config updateConfig:^(NSDictionary * _Nonnull secretKey) {
            if (weakSelf.config.enableEncrypt && secretKey) {
                [weakSelf.encryptManager handleEncryptWithConfig:secretKey];
            }
        }];
#elif TARGET_OS_OSX
        // 获取一般配置
        [_config updateConfig:^(NSDictionary * _Nonnull secretKey) {}];
#endif
        
        self.trackTimer = [[TATrackTimer alloc] init];
        
        _ignoredViewControllers = [[NSMutableSet alloc] init];
        _ignoredViewTypeList = [[NSMutableSet alloc] init];
                
        self.dataQueue = [TDSqliteDataQueue sharedInstanceWithAppid:[self td_getMapInstanceTag]];
        if (self.dataQueue == nil) {
            TDLogError(@"SqliteException: init SqliteDataQueue failed");
        }
                
        if (![TDPresetProperties disableNetworkType]) {
            [[TAReachability shareInstance] startMonitoring];
        }
        
        self.eventTracker = [[TAEventTracker alloc] initWithQueue:td_trackQueue instanceToken:[config getMapInstanceToken]];
                
        [self startFlushTimer];
        
        [TAAppLifeCycle startMonitor];
        
        [self registerAppLifeCycleListener];
        
        if ([self ableMapInstanceTag]) {
            TDLogInfo(@"Thinking Analytics SDK %@ instance initialized successfully with mode: %@, Instance Name: %@,  APP ID: %@, server url: %@, device ID: %@", [TDDeviceInfo libVersion], [self modeEnumToString:config.debugMode], _config.name, appid, serverURL, [self getDeviceId]);
        } else {
            TDLogInfo(@"Thinking Analytics SDK %@ instance initialized successfully with mode: %@, APP ID: %@, server url: %@, device ID: %@", [TDDeviceInfo libVersion], [self modeEnumToString:config.debugMode], appid, serverURL, [self getDeviceId]);
        }
        
    }
    return self;
}

- (void)registerAppLifeCycleListener {
    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];

    [notificationCenter addObserver:self selector:@selector(appStateWillChangeNotification:) name:kTAAppLifeCycleStateWillChangeNotification object:nil];
    [notificationCenter addObserver:self selector:@selector(appStateDidChangeNotification:) name:kTAAppLifeCycleStateDidChangeNotification object:nil];
}

- (NSString*)modeEnumToString:(ThinkingAnalyticsDebugMode)enumVal {
    NSArray *modeEnumArray = [[NSArray alloc] initWithObjects:kModeEnumArray];
    return [modeEnumArray objectAtIndex:enumVal];
}

- (BOOL)ableMapInstanceTag {
    return _config.name && [_config.name isKindOfClass:[NSString class]] && _config.name.length;
}

- (NSString *)td_getMapInstanceTag {
    return [self.config getMapInstanceToken];
}

- (NSString *)description {
    if ([self ableMapInstanceTag]) {
        return [NSString stringWithFormat:@"<ThinkingAnalyticsSDK: %p - instanceName: %@ appid: %@ serverUrl: %@>", (void *)self, _config.name, self.appid, self.serverURL];
    } else {
        return [NSString stringWithFormat:@"<ThinkingAnalyticsSDK: %p - appid: %@ serverUrl: %@>", (void *)self, self.appid, self.serverURL];
    }
}

+ (id)sharedUIApplication {
    return [TDAppState sharedApplication];
}

/// 数据上报状态
/// @param status 数据上报状态
- (void)setTrackStatus: (TATrackStatus)status {
    switch (status) {
            // 暂停SDK上报
        case TATrackStatusPause: {
            TDLogDebug(@"%@ switchTrackStatus: TATrackStatusStop...", self);
            [self enableTracking:NO];
            break;
        }
            // 停止SDK上报并清除缓存
        case TATrackStatusStop: {
            TDLogDebug(@"%@ switchTrackStatus: TATrackStatusStopAndClean...", self);
            [self doOptOutTracking];
            break;
        }
            // 可以入库 暂停发送数据
        case TATrackStatusSaveOnly: {
            TDLogDebug(@"%@ switchTrackStatus: TATrackStatusPausePost...", self);
            self.trackPause = YES;
            dispatch_async(td_trackQueue, ^{
                [self.file archiveTrackPause:YES];
            });
            break;
        }
            // 恢复所有状态
        case TATrackStatusNormal: {
            TDLogDebug(@"%@ switchTrackStatus: TATrackStatusRestartAll...", self);
            self.trackPause = NO;
            self.isEnabled = YES;
            self.isOptOut = NO;
            dispatch_async(td_trackQueue, ^{
                [self.file archiveTrackPause:NO];
                [self.file archiveIsEnabled:self.isEnabled];
                [self.file archiveOptOut:NO];
            });
            [self flush];
            break;
        }
        default:
            break;
    }
}

#pragma mark - EnableTracking
- (void)enableTracking:(BOOL)enabled {
    self.isEnabled = enabled;
    dispatch_async(td_trackQueue, ^{
        [self.file archiveIsEnabled:self.isEnabled];
    });
}

- (BOOL)hasDisabled {
    return !_isEnabled || _isOptOut;
}

- (void)optOutTracking {
    TDLogDebug(@"%@ optOutTracking...", self);
    [self doOptOutTracking];
}

- (void)doOptOutTracking {
    self.isOptOut = YES;
    
    @synchronized (self.trackTimer) {
        [self.trackTimer clear];
    }
    
    @synchronized (self.superProperty) {
        [self.superProperty clearSuperProperties];
    }
    
#if TARGET_OS_IOS
    @synchronized (self.autoTrackSuperProperty) {
        [self.autoTrackSuperProperty clearSuperProperties];
    }
#endif
    
    @synchronized (self.identifyId) {
        self.identifyId = [TDDeviceInfo sharedManager].uniqueId;
    }
    
    @synchronized (self.accountId) {
        self.accountId = nil;
    }
    
    dispatch_async(td_trackQueue, ^{
        @synchronized (TDSqliteDataQueue.class) {
            [self.dataQueue deleteAll:[self td_getMapInstanceTag]];
        }
        
        [self.file archiveAccountID:nil];
        [self.file archiveIdentifyId:nil];
        [self.file archiveSuperProperties:nil];
        [self.file archiveOptOut:YES];
    });
}

- (void)optOutTrackingAndDeleteUser {
    TDLogDebug(@"%@ optOutTrackingAndDeleteUser...", self);
    TAUserEventDelete *deleteEvent = [[TAUserEventDelete alloc] init];
    deleteEvent.immediately = YES;
    // 立即上报事件
    [self test_ta_internalUserEvent:deleteEvent properties:nil];
    
    [self doOptOutTracking];
}

- (void)optInTracking {
    TDLogDebug(@"%@ optInTracking...", self);
    self.isOptOut = NO;
    dispatch_async(td_trackQueue, ^{
        [self.file archiveOptOut:NO];
    });
}

#pragma mark - LightInstance
- (ThinkingAnalyticsSDK *)createLightInstance {
    ThinkingAnalyticsSDK *lightInstance = [[LightThinkingAnalyticsSDK alloc] initWithAPPID:self.appid withServerURL:self.serverURL withConfig:self.config];
    lightInstance.identifyId = [TDDeviceInfo sharedManager].uniqueId;
    return lightInstance;
}

#pragma mark - Persistence
- (void)retrievePersistedData {
    self.accountId = [self.file unarchiveAccountID];
    self.identifyId = [self.file unarchiveIdentifyID];
    self.trackPause = [self.file unarchiveTrackPause];
    self.isEnabled = [self.file unarchiveEnabled];
    self.isOptOut  = [self.file unarchiveOptOut];
    self.config.uploadSize = [self.file unarchiveUploadSize];
    self.config.uploadInterval = [self.file unarchiveUploadInterval];
    if (self.identifyId.length == 0) {
        self.identifyId = [TDDeviceInfo sharedManager].uniqueId;
    }
    // 兼容老版本
    if (self.accountId.length == 0) {
        self.accountId = [self.file unarchiveAccountID];
        [self.file archiveAccountID:self.accountId];
        [self.file deleteOldLoginId];
    }
}

- (void)deleteAll {
    dispatch_async(td_trackQueue, ^{
        @synchronized (TDSqliteDataQueue.class) {
            [self.dataQueue deleteAll:[self td_getMapInstanceTag]];
        }
    });
}

//MARK: - AppLifeCycle

- (void)appStateWillChangeNotification:(NSNotification *)notification {
    TAAppLifeCycleState newState = [[notification.userInfo objectForKey:kTAAppLifeCycleNewStateKey] integerValue];

    if (newState == TAAppLifeCycleStateEnd) {
        [self stopFlushTimer];
    }
}

- (void)appStateDidChangeNotification:(NSNotification *)notification {
    TAAppLifeCycleState newState = [[notification.userInfo objectForKey:kTAAppLifeCycleNewStateKey] integerValue];

    if (newState == TAAppLifeCycleStateStart) {
        [self startFlushTimer];

        // 更新时长统计
        NSTimeInterval systemUpTime = NSProcessInfo.processInfo.systemUptime;
        [self.trackTimer enterForegroundWithSystemUptime:systemUpTime];
    } else if (newState == TAAppLifeCycleStateEnd) {
        // 更新事件时长统计
        NSTimeInterval systemUpTime = NSProcessInfo.processInfo.systemUptime;
        [self.trackTimer enterBackgroundWithSystemUptime:systemUpTime];
        
#if TARGET_OS_IOS
        // 开启后台任务发送事件
        UIApplication *application = [TDAppState sharedApplication];;
        __block UIBackgroundTaskIdentifier backgroundTaskIdentifier = UIBackgroundTaskInvalid;
        void (^endBackgroundTask)(void) = ^() {
            [application endBackgroundTask:backgroundTaskIdentifier];
            backgroundTaskIdentifier = UIBackgroundTaskInvalid;
        };
        backgroundTaskIdentifier = [application beginBackgroundTaskWithExpirationHandler:endBackgroundTask];
        
        // 进入后台时，事件发送完毕，需要关闭后台任务。
        [self.eventTracker _asyncWithCompletion:endBackgroundTask];
#else
        [self.eventTracker flush];
#endif
        
    } else if (newState == TAAppLifeCycleStateTerminate) {
        // 保证在app杀掉的时候，同步执行完队列内的任务
        dispatch_sync(td_trackQueue, ^{});
        [self.eventTracker syncSendAllData];
    }
}

// MARK: -

- (void)setNetworkType:(ThinkingAnalyticsNetworkType)type {
    if ([self hasDisabled])
        return;
    
    [self.config setNetworkType:type];
}

+ (NSString *)getNetWorkStates {
    return [[TAReachability shareInstance] networkState];
}

//MARK: - Track 事件

- (void)track:(NSString *)event {
    [self track:event properties:nil];
}

- (void)track:(NSString *)event properties:(NSDictionary *)propertiesDict {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
    [self track:event properties:propertiesDict time:nil timeZone:nil];
#pragma clang diagnostic pop
}

// deprecated  使用 track:properties:time:timeZone: 方法传入
- (void)track:(NSString *)event properties:(NSDictionary *)propertiesDict time:(NSDate *)time {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
    [self track:event properties:propertiesDict time:time timeZone:nil];
#pragma clang diagnostic pop
}

- (void)track:(NSString *)event properties:(nullable NSDictionary *)properties time:(NSDate *)time timeZone:(NSTimeZone *)timeZone {
    if ([self hasDisabled])
        return;
    
    TATrackEvent *trackEvent = [[TATrackEvent alloc] initWithName:event];
    [self configEventTimeValueWithEvent:trackEvent time:time timeZone:timeZone];
    [self asyncTrackEventObject:trackEvent properties:properties isH5:NO];
}

- (void)trackWithEventModel:(TDEventModel *)eventModel {
    TATrackEvent *baseEvent = nil;
    if ([eventModel.eventType isEqualToString:TD_EVENT_TYPE_TRACK_FIRST]) {
        TATrackFirstEvent *trackEvent = [[TATrackFirstEvent alloc] initWithName:eventModel.eventName];
        [self configEventTimeValueWithEvent:baseEvent time:eventModel.time timeZone:eventModel.timeZone];
        trackEvent.firstCheckId = eventModel.extraID;
        baseEvent = trackEvent;
    } else if ([eventModel.eventType isEqualToString:TD_EVENT_TYPE_TRACK_UPDATE]) {
        TATrackUpdateEvent *trackEvent = [[TATrackUpdateEvent alloc] initWithName:eventModel.eventName];
        [self configEventTimeValueWithEvent:baseEvent time:eventModel.time timeZone:eventModel.timeZone];
        trackEvent.eventId = eventModel.extraID;
        baseEvent = trackEvent;
    } else if ([eventModel.eventType isEqualToString:TD_EVENT_TYPE_TRACK_OVERWRITE]) {
        TATrackOverwriteEvent *trackEvent = [[TATrackOverwriteEvent alloc] initWithName:eventModel.eventName];
        [self configEventTimeValueWithEvent:baseEvent time:eventModel.time timeZone:eventModel.timeZone];
        trackEvent.eventId = eventModel.extraID;
        baseEvent = trackEvent;
    } else if ([eventModel.eventType isEqualToString:TD_EVENT_TYPE_TRACK]) {
        TATrackEvent *trackEvent = [[TATrackEvent alloc] initWithName:eventModel.eventName];
        [self configEventTimeValueWithEvent:baseEvent time:eventModel.time timeZone:eventModel.timeZone];
        baseEvent = trackEvent;
    }
    [self asyncTrackEventObject:baseEvent properties:eventModel.properties isH5:NO];
}

- (void)trackFromAppExtensionWithAppGroupId:(NSString *)appGroupId {
    @try {
        if (appGroupId == nil || [appGroupId isEqualToString:@""]) {
            return;
        }
        
        TAAppExtensionAnalytic *analytic = [TAAppExtensionAnalytic analyticWithInstanceName:[self td_getMapInstanceTag] appGroupId:appGroupId];
        NSArray *eventArray = [analytic readAllEvents];
        if (eventArray) {
            for (NSDictionary *dict in eventArray) {
                NSString *eventName = dict[kTAAppExtensionEventName];
                NSDictionary *properties = dict[kTAAppExtensionEventProperties];
                NSDate *time = dict[kTAAppExtensionTime];
                // track event
                if ([time isKindOfClass:NSDate.class]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
                    [self track:eventName properties:properties time:time timeZone:nil];
#pragma clang diagnostic pop
                } else {
                    [self track:eventName properties:properties];
                }
            }
            [analytic deleteEvents];
        }
    } @catch (NSException *exception) {
        return;
    }
}

#pragma mark - Private

/// 将事件加入到事件队列
/// @param event 事件
/// @param properties 自定义属性
- (void)asyncTrackEventObject:(TATrackEvent *)event properties:(NSDictionary *)properties isH5:(BOOL)isH5 {
    // 在当前线程获取动态公共属性
    event.dynamicSuperProperties = [self.superProperty obtainDynamicSuperProperties];
    dispatch_async(td_trackQueue, ^{
        [self test_ta_internalTrackEvent:event properties:properties isH5:isH5];
    });
}

/// 将事件加入到事件队列
/// @param event 事件
/// @param properties 自定义属性
- (void)asyncUserEventObject:(TAUserEvent *)event properties:(NSDictionary *)properties {
    dispatch_async(td_trackQueue, ^{
        [self test_ta_internalUserEvent:event properties:properties];
    });
}

- (void)configEventTimeValueWithEvent:(TABaseEvent *)event time:(NSDate *)time timeZone:(NSTimeZone *)timeZone {
    event.timeZone = timeZone ?: self.config.defaultTimeZone;
    if (time) {
        event.time = time;
        if (timeZone == nil) {
            event.timeValueType = TAEventTimeValueTypeTimeOnly;
        } else {
            event.timeValueType = TAEventTimeValueTypeTimeAndZone;
        }
    } else {
        event.timeValueType = TAEventTimeValueTypeNone;
    }
}

+ (BOOL)isTrackEvent:(NSString *)eventType {
    return [TD_EVENT_TYPE_TRACK isEqualToString:eventType]
    || [TD_EVENT_TYPE_TRACK_FIRST isEqualToString:eventType]
    || [TD_EVENT_TYPE_TRACK_UPDATE isEqualToString:eventType]
    || [TD_EVENT_TYPE_TRACK_OVERWRITE isEqualToString:eventType]
    ;
}

#pragma mark - User

- (void)user_add:(NSString *)propertyName andPropertyValue:(NSNumber *)propertyValue {
    [self user_add:propertyName andPropertyValue:propertyValue withTime:nil];
}

- (void)user_add:(NSString *)propertyName andPropertyValue:(NSNumber *)propertyValue withTime:(NSDate *)time {
    if (propertyName && propertyValue) {
        [self user_add:@{propertyName: propertyValue} withTime:time];
    }
}

- (void)user_add:(NSDictionary *)properties {
    [self user_add:properties withTime:nil];
}

- (void)user_add:(NSDictionary *)properties withTime:(NSDate *)time {
    TAUserEventAdd *event = [[TAUserEventAdd alloc] init];
    event.time = time;
    [self asyncUserEventObject:event properties:properties];
}

- (void)user_setOnce:(NSDictionary *)properties {
    [self user_setOnce:properties withTime:nil];
}

- (void)user_setOnce:(NSDictionary *)properties withTime:(NSDate *)time {
    TAUserEventSetOnce *event = [[TAUserEventSetOnce alloc] init];
    event.time = time;
    [self asyncUserEventObject:event properties:properties];
}

- (void)user_set:(NSDictionary *)properties {
    [self user_set:properties withTime:nil];
}

- (void)user_set:(NSDictionary *)properties withTime:(NSDate *)time {
    TAUserEventSet *event = [[TAUserEventSet alloc] init];
    event.time = time;
    [self asyncUserEventObject:event properties:properties];
}

- (void)user_unset:(NSString *)propertyName {
    [self user_unset:propertyName withTime:nil];
}

- (void)user_unset:(NSString *)propertyName withTime:(NSDate *)time {
    if ([propertyName isKindOfClass:[NSString class]] && propertyName.length > 0) {
        NSDictionary *properties = @{propertyName: @0};
        TAUserEventUnset *event = [[TAUserEventUnset alloc] init];
        event.time = time;
        [self asyncUserEventObject:event properties:properties];
    }
}

- (void)user_delete {
    [self user_delete:nil];
}

- (void)user_delete:(NSDate *)time {
    TAUserEventDelete *event = [[TAUserEventDelete alloc] init];
    event.time = time;
    [self asyncUserEventObject:event properties:nil];
}

- (void)user_append:(NSDictionary<NSString *, NSArray *> *)properties {
    [self user_append:properties withTime:nil];
}

- (void)user_append:(NSDictionary<NSString *, NSArray *> *)properties withTime:(NSDate *)time {
    TAUserEventAppend *event = [[TAUserEventAppend alloc] init];
    event.time = time;
    [self asyncUserEventObject:event properties:properties];
}

- (void)user_uniqAppend:(NSDictionary<NSString *, NSArray *> *)properties {
    [self user_uniqAppend:properties withTime:nil];
}

- (void)user_uniqAppend:(NSDictionary<NSString *, NSArray *> *)properties withTime:(NSDate *)time {
    TAUserEventUniqueAppend *event = [[TAUserEventUniqueAppend alloc] init];
    event.time = time;
    [self asyncUserEventObject:event properties:properties];
}

//MARK: -

+ (void)setCustomerLibInfoWithLibName:(NSString *)libName libVersion:(NSString *)libVersion {
    if (libName.length > 0) {
        [TDDeviceInfo sharedManager].libName = libName;
    }
    if (libVersion.length > 0) {
        [TDDeviceInfo sharedManager].libVersion = libVersion;
    }
    [[TDDeviceInfo sharedManager] td_updateData];
}

- (NSString *)getAccountId {
    return _accountId;
}

- (NSString *)getDistinctId {
    return [self.identifyId copy];
}

+ (NSString *)getSDKVersion {
    return TDPublicConfig.version;
}

- (NSString *)getDeviceId {
    return [TDDeviceInfo sharedManager].deviceId;
}

- (void)registerDynamicSuperProperties:(NSDictionary<NSString *, id> *(^)(void)) dynamicSuperProperties {
    if ([self hasDisabled])
        return;
    [self.superProperty registerDynamicSuperProperties:dynamicSuperProperties];
}

- (void)setSuperProperties:(NSDictionary *)properties {
    if ([self hasDisabled])
        return;
    dispatch_async(td_trackQueue, ^{
        [self.superProperty registerSuperProperties:properties];
    });
}

- (void)unsetSuperProperty:(NSString *)propertyKey {
    if ([self hasDisabled])
        return;
    dispatch_async(td_trackQueue, ^{
        [self.superProperty unregisterSuperProperty:propertyKey];
    });
}

- (void)clearSuperProperties {
    if ([self hasDisabled])
        return;
    dispatch_async(td_trackQueue, ^{
        [self.superProperty clearSuperProperties];
    });
}

- (NSDictionary *)currentSuperProperties {
    return [self.superProperty currentSuperProperties];
}

- (TDPresetProperties *)getPresetProperties {
    NSMutableDictionary *presetDic = [NSMutableDictionary dictionary];

    NSDictionary *pluginProperties = [self.propertyPluginManager currentPropertiesForPluginClasses:@[TAPresetPropertyPlugin.class]];
    [presetDic addEntriesFromDictionary:pluginProperties];
    
    if (![TDPresetProperties disableZoneOffset]) {
        double offset = [[NSDate date] ta_timeZoneOffset:self.config.defaultTimeZone];
        [presetDic setObject:@(offset) forKey:@"#zone_offset"];
    }
    if (![TDPresetProperties disableNetworkType]) {
        NSString *networkType = [self.class getNetWorkStates];
        [presetDic setObject:networkType?:@"" forKey:@"#network_type"];
    }
    static TDPresetProperties *presetProperties = nil;
    if (presetProperties == nil) {
        presetProperties = [[TDPresetProperties alloc] initWithDictionary:presetDic];
    } else {
        @synchronized (instances) {
            [presetProperties updateValuesWithDictionary:presetDic];
        }
    }
    return presetProperties;
}

- (void)identify:(NSString *)distinctId {
    if ([self hasDisabled])
        return;
    
    if (![distinctId isKindOfClass:[NSString class]] || distinctId.length == 0) {
        TDLogError(@"identify cannot null");
        return;
    }
    
    @synchronized (self.identifyId) {
        self.identifyId = distinctId;
    }
    dispatch_async(td_trackQueue, ^{
        [self.file archiveIdentifyId:distinctId];
    });
}

- (void)login:(NSString *)accountId {
    if ([self hasDisabled])
        return;
    
    if (![accountId isKindOfClass:[NSString class]] || accountId.length == 0) {
        TDLogError(@"accountId invald", accountId);
        return;
    }
    
    @synchronized (self.accountId) {
        self.accountId = accountId;
    }
    
    dispatch_async(td_trackQueue, ^{
        [self.file archiveAccountID:accountId];
    });
}

- (void)logout {
    if ([self hasDisabled])
        return;
    
    @synchronized (self.accountId) {
        self.accountId = nil;
    }
    dispatch_async(td_trackQueue, ^{
        [self.file archiveAccountID:nil];
    });
}

- (void)timeEvent:(NSString *)event {
    if ([self hasDisabled])
        return;
    
    NSError *error = nil;
    [TAPropertyValidator validateEventOrPropertyName:event withError:&error];
    if (error) {
        return;
    }
    
    @synchronized (self.trackTimer) {
        [self.trackTimer trackEvent:event withSystemUptime:NSProcessInfo.processInfo.systemUptime];
    };
}

//MARK: - H5 track

- (void)clickFromH5:(NSString *)data {
    NSData *jsonData = [data dataUsingEncoding:NSUTF8StringEncoding];
    NSError *err;
    NSDictionary *eventDict = [NSJSONSerialization JSONObjectWithData:jsonData
                                                              options:NSJSONReadingMutableContainers
                                                                error:&err];
    NSString *appid = [eventDict[@"#app_id"] isKindOfClass:[NSString class]] ? eventDict[@"#app_id"] : self.appid;
    id dataArr = eventDict[@"data"];
    if (!err && [dataArr isKindOfClass:[NSArray class]]) {
        NSDictionary *dataInfo = [dataArr objectAtIndex:0];
        if (dataInfo != nil) {
            NSString *type = [dataInfo objectForKey:@"#type"];
            NSString *event_name = [dataInfo objectForKey:@"#event_name"];
            NSString *time = [dataInfo objectForKey:@"#time"];
            NSDictionary *properties = [dataInfo objectForKey:@"properties"];
            
            NSString *extraID;
            
            if ([type isEqualToString:TD_EVENT_TYPE_TRACK]) {
                extraID = [dataInfo objectForKey:@"#first_check_id"];
            } else {
                extraID = [dataInfo objectForKey:@"#event_id"];
            }
            
            NSMutableDictionary *dic = [properties mutableCopy];
            [dic removeObjectForKey:@"#account_id"];
            [dic removeObjectForKey:@"#distinct_id"];
            [dic removeObjectForKey:@"#device_id"];
            [dic removeObjectForKey:@"#lib"];
            [dic removeObjectForKey:@"#lib_version"];
            [dic removeObjectForKey:@"#screen_height"];
            [dic removeObjectForKey:@"#screen_width"];
            
            ThinkingAnalyticsSDK *instance = [ThinkingAnalyticsSDK sharedInstanceWithAppid:appid];
            if (instance) {
                dispatch_async(td_trackQueue, ^{
                    [instance h5track:event_name
                              extraID:extraID
                           properties:dic
                                 type:type
                                 time:time];
                });
            } else {
                dispatch_async(td_trackQueue, ^{
                    [self h5track:event_name
                          extraID:extraID
                       properties:dic
                             type:type
                             time:time];
                });
            }
        }
    }
}

- (void)h5track:(NSString *)eventName
        extraID:(NSString *)extraID
     properties:(NSDictionary *)propertieDict
           type:(NSString *)type
           time:(NSString *)time {
    
    if ([self hasDisabled])
        return;
    
    if ([ThinkingAnalyticsSDK isTrackEvent:type]) {
        TATrackEvent *event = nil;
        if ([type isEqualToString:TD_EVENT_TYPE_TRACK]) {
            TATrackEvent *trackEvent = [[TATrackEvent alloc] initWithName:eventName];
            event = trackEvent;
        } else if ([type isEqualToString:TD_EVENT_TYPE_TRACK_FIRST]) {
            TATrackFirstEvent *firstEvent = [[TATrackFirstEvent alloc] initWithName:eventName];
            firstEvent.firstCheckId = extraID;
            event = firstEvent;
        } else if ([type isEqualToString:TD_EVENT_TYPE_TRACK_UPDATE]) {
            TATrackUpdateEvent *updateEvent = [[TATrackUpdateEvent alloc] initWithName:eventName];
            updateEvent.eventId = extraID;
            event = updateEvent;
        } else if ([type isEqualToString:TD_EVENT_TYPE_TRACK_OVERWRITE]) {
            TATrackOverwriteEvent *overwriteEvent = [[TATrackOverwriteEvent alloc] initWithName:eventName];
            overwriteEvent.eventId = extraID;
            event = overwriteEvent;
        }
        event.h5TimeString = time;
        if ([propertieDict objectForKey:@"#zone_offset"]) {
            event.h5ZoneOffSet = [propertieDict objectForKey:@"#zone_offset"];
        }
        [self asyncTrackEventObject:event properties:propertieDict isH5:YES];
    } else {
        // 用户属性
        TAUserEvent *event = [[TAUserEvent alloc] initWithType:[TABaseEvent typeWithTypeString:type]];
        [self asyncUserEventObject:event properties:propertieDict];
    }
}

//MARK: -

- (void)test_ta_internalBaseEvent:(TABaseEvent *)event properties:(NSDictionary *)properties {
    if ([self hasDisabled]) {
        return;
    }
    if ([TDAppState shareInstance].relaunchInBackground && !self.config.trackRelaunchedInBackgroundEvents) {
        return;
    }
    // 添加通用的属性
    event.accountId = self.accountId;
    event.distinctId = self.getDistinctId;
    // 如果没有设置timezone，则获取config对象中的默认时区
    if (event.timeZone == nil) {
        event.timeZone = self.config.defaultTimeZone;
    }
    // 事件如果没有指定时间，那么使用系统时间时需要校准
    if (event.timeValueType == TAEventTimeValueTypeNone && calibratedTime && calibratedTime.stopCalibrate == NO) {
        NSTimeInterval outTime = NSProcessInfo.processInfo.systemUptime - calibratedTime.systemUptime;
        NSDate *serverDate = [NSDate dateWithTimeIntervalSince1970:(calibratedTime.serverTime + outTime)];
        event.time = serverDate;
    }
}

- (void)test_ta_internalUserEvent:(TAUserEvent *)event properties:(NSDictionary *)properties {
    // 组装通用属性
    [self test_ta_internalBaseEvent:event properties:properties];
    // 校验并添加用户自定义属性
    [event.properties addEntriesFromDictionary:[TAPropertyValidator validateProperties:properties validator:event]];
    // 将属性中所有NSDate对象，用指定的 timezone 转换成时间字符串
    NSDictionary *jsonObj = [event formatDateWithDict:event.jsonObject];
    
    [self test_eventTrack:jsonObj immediately:event.immediately];
}

- (void)test_ta_internalTrackEvent:(TATrackEvent *)event properties:(NSDictionary *)properties isH5:(BOOL)isH5 {
    // 组装通用属性
    [self test_ta_internalBaseEvent:event properties:properties];
    // 验证事件本身的合法性，具体的验证策略由事件对象本身定义。
    NSError *error = nil;
    [event validateWithError:&error];
    if (error) {
        return;
    }
    // 过滤事件
    if ([self.config.disableEvents containsObject:event.eventName]) {
        return;
    }
    // 添加事件统计时长
    BOOL isTrackDuration = [self.trackTimer isExistEvent:event.eventName];
    if (isTrackDuration) {
        // app 是否在前台
        BOOL isActive = !([TDAppState shareInstance].relaunchInBackground);
        // 计算累计前台时长
        event.foregroundDuration = [self.trackTimer foregroundDurationOfEvent:event.eventName isActive:isActive systemUptime:event.systemUpTime];
        // 计算累计后台时长
        event.backgroundDuration = [self.trackTimer backgroundDurationOfEvent:event.eventName isActive:isActive systemUptime:event.systemUpTime];
        // 计算时长后，删除当前事件的记录
        [self.trackTimer removeEvent:event.eventName];
    } else {
        // 没有事件时长的 TD_APP_END_EVENT 事件，判定为重复的无效 end 事件。（系统的生命周期方法可能回调用多次，会造成重复上报）
        if (event.eventName == TD_APP_END_EVENT) {
            return;
        }
    }
    // 是否是从后台启动
    if ([TDAppState shareInstance].relaunchInBackground) {
        event.properties[@"#relaunched_in_background"] = @YES;
    }
    // 添加从属性插件获取的属性，属性插件只有系统使用，不支持用户自定义。所以属性名字是可信的，不用验证格式
    NSMutableDictionary *pluginProperties = [self.propertyPluginManager propertiesWithEventType:event.eventType];
    // 过滤预置属性
    [TDPresetProperties handleFilterDisPresetProperties:pluginProperties];
    // 静态公共属性
    NSDictionary *superProperties = self.superProperty.currentSuperProperties;
    
    // 如果是h5事件，那么native侧的预制属性优先级高于h5侧的属性，native侧的公共属性优先级低于h5侧的属性，且h5侧的属性不需要验证有效性
    if (isH5) {
        NSMutableDictionary *mutableDict = [superProperties mutableCopy];
        [mutableDict addEntriesFromDictionary:event.dynamicSuperProperties];
        [mutableDict addEntriesFromDictionary:properties];
        [mutableDict addEntriesFromDictionary:pluginProperties];
        properties = pluginProperties;
    } else {
        [event.properties addEntriesFromDictionary:pluginProperties];
        event.superProperties = superProperties;
        // 校验用户自定义属性
        properties = [TAPropertyValidator validateProperties:properties validator:event];
        // 验证公共属性
        event.superProperties = [TAPropertyValidator validateProperties:event.superProperties validator:event];
        event.dynamicSuperProperties = [TAPropertyValidator validateProperties:event.dynamicSuperProperties validator:event];
    }
    
#if TARGET_OS_IOS
    // 获取自动采集事件的公共属性
    if ([event isKindOfClass:[TAAutoTrackEvent class]]) {
        TAAutoTrackEvent *autoEvent = (TAAutoTrackEvent *)event;
        NSDictionary *autoSuperProperties = [self.autoTrackSuperProperty currentSuperPropertiesWithEventName:event.eventName];
        // 验证自动采集事件的公共属性
        autoEvent.autoSuperProperties = [TAPropertyValidator validateProperties:autoSuperProperties validator:autoEvent];
        autoEvent.autoDynamicSuperProperties = [TAPropertyValidator validateProperties:autoEvent.autoDynamicSuperProperties validator:autoEvent];
    }
#endif
    // 添加用户自定义属性
    [event.properties addEntriesFromDictionary:properties];
    
    NSMutableDictionary *jsonObj = event.jsonObject;
    // 将属性中所有NSDate对象，用指定的 timezone 转换成时间字符串
    jsonObj = [event formatDateWithDict:jsonObj];
    
    if (isH5) {
        // 替换h5的时间和时区偏移
        if (event.h5TimeString) {
            jsonObj[@"#time"] = event.h5TimeString;
        }
        if (event.h5ZoneOffSet) {
            if (![TDPresetProperties disableZoneOffset]) {
                jsonObj[@"#zone_offset"] = event.h5ZoneOffSet;
            }
        }
    }
        
    [self test_eventTrack:jsonObj immediately:event.immediately];
}

- (void)test_eventTrack:(NSDictionary *)event immediately:(BOOL)immediately {
    [self.eventTracker test_eventTrack:event immediately:immediately];
}

// 发送将数据库数据
- (void)flush {
    if (self.trackPause)
        return; // trackPause = YES 表示暂停数据网络上报
    
    [self.eventTracker flush];
}

#pragma mark - Flush control
- (void)startFlushTimer {
    [self stopFlushTimer];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.config.uploadInterval > 0) {
            self.timer = [NSTimer scheduledTimerWithTimeInterval:3
                                                          target:self
                                                        selector:@selector(flush)
                                                        userInfo:nil
                                                         repeats:YES];
        }
    });
}

- (void)stopFlushTimer {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.timer) {
            [self.timer invalidate];
            self.timer = nil;
        }
    });
}

#if TARGET_OS_IOS

//MARK: - Thired Party

- (void)enableThirdPartySharing:(TAThirdPartyShareType)type {
    [self enableThirdPartySharing:type customMap:@{}];
}

- (void)enableThirdPartySharing:(TAThirdPartyShareType)type customMap:(NSDictionary<NSString *, NSObject *> *)customMap {
    if (!self.thirdPartyManager) {
        Class cls = NSClassFromString(@"TAThirdPartyManager");
        if (!cls) {
    //        TDLog(@"请安装三方扩展插件");
            return;
        }
        self.thirdPartyManager = [[cls alloc] init];
    }
    
    [self.thirdPartyManager enableThirdPartySharing:type instance:self property:customMap];
}

//MARK: - Auto Track

- (void)enableAutoTrack:(ThinkingAnalyticsAutoTrackEventType)eventType {
    [self _enableAutoTrack:eventType properties:nil callback:nil];
}

- (void)enableAutoTrack:(ThinkingAnalyticsAutoTrackEventType)eventType properties:(NSDictionary *)properties {
    [self _enableAutoTrack:eventType properties:properties callback:nil];
}

- (void)enableAutoTrack:(ThinkingAnalyticsAutoTrackEventType)eventType callback:(NSDictionary *(^)(ThinkingAnalyticsAutoTrackEventType eventType, NSDictionary *properties))callback {
    [self _enableAutoTrack:eventType properties:nil callback:callback];
}

- (void)_enableAutoTrack:(ThinkingAnalyticsAutoTrackEventType)eventType properties:(NSDictionary *)properties callback:(NSDictionary *(^)(ThinkingAnalyticsAutoTrackEventType eventType, NSDictionary *properties))callback {
    
    // 未开启不采集
    if ([self hasDisabled])
        return;
    
    if (self.autoTrackSuperProperty == nil) {
        self.autoTrackSuperProperty = [[TAAutoTrackSuperProperty alloc] init];
    }
    [self.autoTrackSuperProperty registerSuperProperties:properties withType:eventType];
    [self.autoTrackSuperProperty registerDynamicSuperProperties:callback];
    
    // 走原来方法
    [self _enableAutoTrack:eventType];
}

- (void)_enableAutoTrack:(ThinkingAnalyticsAutoTrackEventType)eventType {
    self.config.autoTrackEventType = eventType;
    
    // 开启监听界面点击、界面浏览事件
    [[TDAutoTrackManager sharedManager] trackWithAppid:[self td_getMapInstanceTag] withOption:eventType];
}

- (void)setAutoTrackProperties:(ThinkingAnalyticsAutoTrackEventType)eventType properties:(NSDictionary *)properties {
    // 未开启不更新数据
    if ([self hasDisabled])
        return;
    
    if (properties == nil) {
        return;
    }
    
    @synchronized (self) {
        [self.autoTrackSuperProperty registerSuperProperties:[properties copy] withType:eventType];
    }
}

- (void)ignoreViewType:(Class)aClass {
    if ([self hasDisabled])
        return;
    
    dispatch_async(td_trackQueue, ^{
        [self->_ignoredViewTypeList addObject:aClass];
    });
}

- (BOOL)isViewTypeIgnored:(Class)aClass {
    return [_ignoredViewTypeList containsObject:aClass];
}

- (BOOL)isAutoTrackEventTypeIgnored:(ThinkingAnalyticsAutoTrackEventType)eventType {
    return !(_config.autoTrackEventType & eventType);
}

- (void)ignoreAutoTrackViewControllers:(NSArray *)controllers {
    if ([self hasDisabled])
        return;
    
    if (controllers == nil || controllers.count == 0) {
        return;
    }
    
    dispatch_async(td_trackQueue, ^{
        [self->_ignoredViewControllers addObjectsFromArray:controllers];
    });
}

- (void)autotrack:(NSString *)event properties:(NSDictionary *)propertieDict withTime:(NSDate *)time {
    if ([self hasDisabled])
        return;
    TAAutoTrackEvent *trackEvent = [[TAAutoTrackEvent alloc] initWithName:event];
    trackEvent.time = time;
    [self asyncAutoTrackEventObject:trackEvent properties:propertieDict];
}

- (void)test_autoTrackWithEvent:(TAAutoTrackEvent *)event properties:(NSDictionary *)properties {
    [self asyncAutoTrackEventObject:event properties:properties];
}

/// 将事件加入到事件队列
/// @param event 事件
/// @param properties 自定义属性
- (void)asyncAutoTrackEventObject:(TAAutoTrackEvent *)event properties:(NSDictionary *)properties {
    // 在当前线程获取动态公共属性
    event.dynamicSuperProperties = [self.superProperty obtainDynamicSuperProperties];
    NSDictionary *autoDynamicSuperProperties = [self.autoTrackSuperProperty obtainDynamicSuperPropertiesWithType:event.autoTrackEventType currentProperties:properties];
    event.autoDynamicSuperProperties = autoDynamicSuperProperties;
    dispatch_async(td_trackQueue, ^{
        [self test_ta_internalTrackEvent:event properties:properties isH5:NO];
    });
}

- (BOOL)isViewControllerIgnored:(UIViewController *)viewController {
    if (viewController == nil) {
        return false;
    }
    NSString *screenName = NSStringFromClass([viewController class]);
    if (_ignoredViewControllers != nil && _ignoredViewControllers.count > 0) {
        if ([_ignoredViewControllers containsObject:screenName]) {
            return true;
        }
    }
    return false;
}

#endif

#pragma mark - H5 tracking

/// 根据date和时区，获取偏移（h5 有调用）
- (double)getTimezoneOffset:(NSDate *)date timeZone:(NSTimeZone *)timeZone {
    return [date ta_timeZoneOffset:timeZone];
}

- (BOOL)showUpWebView:(id)webView WithRequest:(NSURLRequest *)request {
    if (webView == nil || request == nil || ![request isKindOfClass:NSURLRequest.class]) {
        TDLogInfo(@"showUpWebView request error");
        return NO;
    }
    
    NSString *urlStr = request.URL.absoluteString;
    if (!urlStr) {
        return NO;
    }
    
    if ([urlStr rangeOfString:TA_JS_TRACK_SCHEME].length == 0) {
        return NO;
    }
    
    NSString *query = [[request URL] query];
    NSArray *queryItem = [query componentsSeparatedByString:@"="];
    
    if (queryItem.count != 2)
        return YES;
    
    NSString *queryValue = [queryItem lastObject];
    if ([urlStr rangeOfString:TA_JS_TRACK_SCHEME].length > 0) {
        if ([self hasDisabled])
            return YES;
        
        NSString *eventData = [queryValue stringByRemovingPercentEncoding];
        if (eventData.length > 0)
            [self clickFromH5:eventData];
    }
    return YES;
}

- (void)wkWebViewGetUserAgent:(void (^)(NSString *))completion {
    self.wkWebView = [[WKWebView alloc] initWithFrame:CGRectZero];
    [self.wkWebView evaluateJavaScript:@"navigator.userAgent" completionHandler:^(id __nullable userAgent, NSError * __nullable error) {
        completion(userAgent);
    }];
}

- (void)addWebViewUserAgent {
    if ([self hasDisabled])
        return;
    
    void (^setUserAgent)(NSString *userAgent) = ^void (NSString *userAgent) {
        if ([userAgent rangeOfString:@"td-sdk-ios"].location == NSNotFound) {
            userAgent = [userAgent stringByAppendingString:@" /td-sdk-ios"];
            
            NSDictionary *userAgentDic = [[NSDictionary alloc] initWithObjectsAndKeys:userAgent, @"UserAgent", nil];
            [[NSUserDefaults standardUserDefaults] registerDefaults:userAgentDic];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }
    };
    
    dispatch_block_t getUABlock = ^() {
        [self wkWebViewGetUserAgent:^(NSString *userAgent) {
            setUserAgent(userAgent);
        }];
    };
    
    td_dispatch_main_sync_safe(getUABlock);
}

#pragma mark - Logging
+ (void)setLogLevel:(TDLoggingLevel)level {
    [TDLogging sharedInstance].loggingLevel = level;
}

#pragma mark - Calibrate time

+ (void)calibrateTime:(NSTimeInterval)timestamp {
    calibratedTime = [TDCalibratedTime sharedInstance];
    [[TDCalibratedTime sharedInstance] recalibrationWithTimeInterval:timestamp/1000.];
}

+ (void)calibrateTimeWithNtp:(NSString *)ntpServer {
    if ([ntpServer isKindOfClass:[NSString class]] && ntpServer.length > 0) {
        calibratedTime = [TDCalibratedTimeWithNTP sharedInstance];
        [[TDCalibratedTimeWithNTP sharedInstance] recalibrationWithNtps:@[ntpServer]];
    }
}

// for UNITY
- (NSString *)getTimeString:(NSDate *)date {
    return [date ta_formatWithTimeZone:self.config.defaultTimeZone formatString:kDefaultTimeFormat];
}

//MARK: - Private

- (BOOL)isValidName:(NSString *)name isAutoTrack:(BOOL)isAutoTrack {
    return YES;
}

- (BOOL)checkEventProperties:(NSDictionary *)properties withEventType:(NSString *_Nullable)eventType haveAutoTrackEvents:(BOOL)haveAutoTrackEvents {
    return YES;
}

- (void)flushImmediately:(NSDictionary *)dataDic {
    
}

+ (dispatch_queue_t)td_networkQueue {
    return [TAEventTracker td_networkQueue];
}

- (NSInteger)saveEventsData:(NSDictionary *)data {
    return [self.eventTracker saveEventsData:data];
}

@end

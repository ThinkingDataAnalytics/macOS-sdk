#import "TDAutoTrackManager.h"

#import "TDSwizzler.h"
#import "UIViewController+AutoTrack.h"
#import "NSObject+TDSwizzle.h"
#import "TDJSONUtil.h"
#import "UIApplication+AutoTrack.h"
#import "ThinkingAnalyticsSDKPrivate.h"
#import "TDPublicConfig.h"
#import "TAAutoClickEvent.h"
#import "TAAutoPageViewEvent.h"
#import "TAAppLifeCycle.h"
#import "TDAppState.h"
#import "TDRunTime.h"
#import "TDPresetProperties+TDDisProperties.h"

#import "TAAppStartEvent.h"
#import "TAAppEndEvent.h"
#import "TDAppEndTracker.h"
#import "TDColdStartTracker.h"
#import "TDInstallTracker.h"

#ifndef TD_LOCK
#define TD_LOCK(lock) dispatch_semaphore_wait(lock, DISPATCH_TIME_FOREVER);
#endif

#ifndef TD_UNLOCK
#define TD_UNLOCK(lock) dispatch_semaphore_signal(lock);
#endif

NSString * const TD_EVENT_PROPERTY_TITLE = @"#title";
NSString * const TD_EVENT_PROPERTY_URL_PROPERTY = @"#url";
NSString * const TD_EVENT_PROPERTY_REFERRER_URL = @"#referrer";
NSString * const TD_EVENT_PROPERTY_SCREEN_NAME = @"#screen_name";
NSString * const TD_EVENT_PROPERTY_ELEMENT_ID = @"#element_id";
NSString * const TD_EVENT_PROPERTY_ELEMENT_TYPE = @"#element_type";
NSString * const TD_EVENT_PROPERTY_ELEMENT_CONTENT = @"#element_content";
NSString * const TD_EVENT_PROPERTY_ELEMENT_POSITION = @"#element_position";

@interface TDAutoTrackManager ()
/// key: 数据采集SDK的唯一标识  value: 开启的自动采集事件类型
@property (atomic, strong) NSMutableDictionary<NSString *, id> *autoTrackOptions;
@property (nonatomic, strong, nonnull) dispatch_semaphore_t trackOptionLock;
@property (atomic, copy) NSString *referrerViewControllerUrl;
@property (nonatomic, strong) TDHotStartTracker *appHotStartTracker;
@property (nonatomic, strong) TDAppEndTracker *appEndTracker;
@property (nonatomic, strong) TDColdStartTracker *appColdStartTracker;
@property (nonatomic, strong) TDInstallTracker *appInstallTracker;

@end


@implementation TDAutoTrackManager

#pragma mark - Public

+ (instancetype)sharedManager {
    static dispatch_once_t once;
    static TDAutoTrackManager *manager = nil;
    dispatch_once(&once, ^{
        manager = [[[TDAutoTrackManager class] alloc] init];
        manager.autoTrackOptions = [NSMutableDictionary new];
        manager.trackOptionLock = dispatch_semaphore_create(1);
        [manager registerAppLifeCycleListener];
    });
    return manager;
}

- (void)trackEventView:(UIView *)view {
    [self trackEventView:view withIndexPath:nil];
}

- (void)trackEventView:(UIView *)view withIndexPath:(NSIndexPath *)indexPath {
    if (view.thinkingAnalyticsIgnoreView) {
        return;
    }
    
    NSString *elementId = nil;
    NSString *elementType = nil;
    NSString *elementContent = nil;
    NSString *elementPosition = nil;
    NSString *elementPageTitle = nil;
    NSString *elementScreenName = nil;
    NSMutableDictionary *yx_customProperties = [NSMutableDictionary dictionary];

    
    elementId = view.thinkingAnalyticsViewID;
    elementType = NSStringFromClass([view class]);
    
    
    NSMutableDictionary *properties = [[NSMutableDictionary alloc] init];
    properties[TD_EVENT_PROPERTY_ELEMENT_ID] = view.thinkingAnalyticsViewID;
    properties[TD_EVENT_PROPERTY_ELEMENT_TYPE] = NSStringFromClass([view class]);
    UIViewController *viewController = [self viewControllerForView:view];
    if (viewController != nil) {
        NSString *screenName = NSStringFromClass([viewController class]);
        properties[TD_EVENT_PROPERTY_SCREEN_NAME] = screenName;
        
        elementScreenName = screenName;

        NSString *controllerTitle = [self titleFromViewController:viewController];
        if (controllerTitle) {
            properties[TD_EVENT_PROPERTY_TITLE] = controllerTitle;
            
            elementPageTitle = controllerTitle;
        }
    }
    
    
    NSDictionary *propDict = view.thinkingAnalyticsViewProperties;
    if ([propDict isKindOfClass:[NSDictionary class]]) {
        [properties addEntriesFromDictionary:propDict];

        [yx_customProperties addEntriesFromDictionary:propDict];
    }
    
    UIView *contentView;
    NSDictionary *propertyWithAppid;
    if (indexPath) {
        if ([view isKindOfClass:[UITableView class]]) {
            UITableView *tableView = (UITableView *)view;
            contentView = [tableView cellForRowAtIndexPath:indexPath];
            if (!contentView) {
                [tableView layoutIfNeeded];
                contentView = [tableView cellForRowAtIndexPath:indexPath];
            }
            properties[TD_EVENT_PROPERTY_ELEMENT_POSITION] = [NSString stringWithFormat: @"%ld:%ld", (unsigned long)indexPath.section, (unsigned long)indexPath.row];
            
            elementPosition = [NSString stringWithFormat: @"%ld:%ld", (unsigned long)indexPath.section, (unsigned long)indexPath.row];
            
            if ([tableView.thinkingAnalyticsDelegate conformsToProtocol:@protocol(TDUIViewAutoTrackDelegate)]) {
                if ([tableView.thinkingAnalyticsDelegate respondsToSelector:@selector(thinkingAnalytics_tableView:autoTrackPropertiesAtIndexPath:)]) {
                    NSDictionary *dic = [view.thinkingAnalyticsDelegate thinkingAnalytics_tableView:tableView autoTrackPropertiesAtIndexPath:indexPath];
                    if ([dic isKindOfClass:[NSDictionary class]]) {
                        [properties addEntriesFromDictionary:dic];
                     
                        [yx_customProperties addEntriesFromDictionary:dic];

                    }
                }
                
                if ([tableView.thinkingAnalyticsDelegate respondsToSelector:@selector(thinkingAnalyticsWithAppid_tableView:autoTrackPropertiesAtIndexPath:)]) {
                    propertyWithAppid = [view.thinkingAnalyticsDelegate thinkingAnalyticsWithAppid_tableView:tableView autoTrackPropertiesAtIndexPath:indexPath];
                }
            }
        } else if ([view isKindOfClass:[UICollectionView class]]) {
            UICollectionView *collectionView = (UICollectionView *)view;
            contentView = [collectionView cellForItemAtIndexPath:indexPath];
            if (!contentView) {
                [collectionView layoutIfNeeded];
                contentView = [collectionView cellForItemAtIndexPath:indexPath];
            }
            properties[TD_EVENT_PROPERTY_ELEMENT_POSITION] = [NSString stringWithFormat: @"%ld:%ld", (unsigned long)indexPath.section, (unsigned long)indexPath.row];
            
            elementPosition = [NSString stringWithFormat: @"%ld:%ld", (unsigned long)indexPath.section, (unsigned long)indexPath.row];

            if ([collectionView.thinkingAnalyticsDelegate conformsToProtocol:@protocol(TDUIViewAutoTrackDelegate)]) {
                if ([collectionView.thinkingAnalyticsDelegate respondsToSelector:@selector(thinkingAnalytics_collectionView:autoTrackPropertiesAtIndexPath:)]) {
                    NSDictionary *dic = [view.thinkingAnalyticsDelegate thinkingAnalytics_collectionView:collectionView autoTrackPropertiesAtIndexPath:indexPath];
                    if ([dic isKindOfClass:[NSDictionary class]]) {
                        [properties addEntriesFromDictionary:dic];
                        
                        [yx_customProperties addEntriesFromDictionary:dic];

                    }
                }
                if ([collectionView.thinkingAnalyticsDelegate respondsToSelector:@selector(thinkingAnalyticsWithAppid_collectionView:autoTrackPropertiesAtIndexPath:)]) {
                    propertyWithAppid = [view.thinkingAnalyticsDelegate thinkingAnalyticsWithAppid_collectionView:collectionView autoTrackPropertiesAtIndexPath:indexPath];
                }
            }
        }
    } else {
        contentView = view;
        properties[TD_EVENT_PROPERTY_ELEMENT_POSITION] = [TDAutoTrackManager getPosition:contentView];
        
        elementPosition = [TDAutoTrackManager getPosition:contentView];

    }
    
    NSString *content = [TDAutoTrackManager getText:contentView];
    if (content.length > 0) {
        properties[TD_EVENT_PROPERTY_ELEMENT_CONTENT] = content;
        
        elementContent = content;

    }
    

    
    NSDate *trackDate = [NSDate date];
    for (NSString *appid in self.autoTrackOptions) {

        ThinkingAnalyticsAutoTrackEventType type = (ThinkingAnalyticsAutoTrackEventType)[self.autoTrackOptions[appid] integerValue];
        
        if (type & ThinkingAnalyticsEventTypeAppClick) {
    
            
            
            
            ThinkingAnalyticsSDK *instance = [ThinkingAnalyticsSDK sharedInstanceWithAppid:appid];
            NSMutableDictionary *trackProperties = [properties mutableCopy];
            
            NSMutableDictionary *yx_trackProperties = [yx_customProperties mutableCopy];

            if ([instance isViewTypeIgnored:[view class]]) {
                continue;
            }
            NSDictionary *ignoreViews = view.thinkingAnalyticsIgnoreViewWithAppid;
            if (ignoreViews != nil && [[ignoreViews objectForKey:appid] isKindOfClass:[NSNumber class]]) {
                BOOL ignore = [[ignoreViews objectForKey:appid] boolValue];
                if (ignore)
                    continue;
            }
            
            if ([instance isViewControllerIgnored:viewController]) {
                continue;
            }
            
            // view 的控件id
            NSDictionary *viewIDs = view.thinkingAnalyticsViewIDWithAppid;
            if (viewIDs != nil && [viewIDs objectForKey:appid]) {
                trackProperties[TD_EVENT_PROPERTY_ELEMENT_ID] = [viewIDs objectForKey:appid];
                
                elementId = [viewIDs objectForKey:appid];

            }
            
            // 用户自定义属性
            NSDictionary *viewProperties = view.thinkingAnalyticsViewPropertiesWithAppid;
            if (viewProperties != nil && [viewProperties objectForKey:appid]) {
                NSDictionary *properties = [viewProperties objectForKey:appid];
                if ([properties isKindOfClass:[NSDictionary class]]) {
                    [trackProperties addEntriesFromDictionary:properties];

                    [yx_trackProperties addEntriesFromDictionary:properties];
                }
            }
            
            // tableview 或者 collection 的用户自定义属性
            if (propertyWithAppid) {
                NSDictionary *autoTrackproperties = [propertyWithAppid objectForKey:appid];
                if ([autoTrackproperties isKindOfClass:[NSDictionary class]]) {
                    [trackProperties addEntriesFromDictionary:autoTrackproperties];
                    
                    [yx_trackProperties addEntriesFromDictionary:autoTrackproperties];
                }
            }
            
            TAAutoClickEvent *yx_event = [[TAAutoClickEvent alloc] initWithName:TD_APP_CLICK_EVENT];
            yx_event.time = trackDate;
            yx_event.elementId = elementId;
            yx_event.elementType = elementType;
            yx_event.elementContent = elementContent;
            yx_event.elementPosition = elementPosition;
            yx_event.pageTitle = elementPageTitle;
            yx_event.screenName = elementScreenName;
            
            [instance test_autoTrackWithEvent:yx_event properties:yx_trackProperties];
        }
    }
}

- (void)trackWithAppid:(NSString *)appid withOption:(ThinkingAnalyticsAutoTrackEventType)type {
    TD_LOCK(self.trackOptionLock);
    self.autoTrackOptions[appid] = @(type);
    TD_UNLOCK(self.trackOptionLock);
    
    if (type & ThinkingAnalyticsEventTypeAppClick || type & ThinkingAnalyticsEventTypeAppViewScreen) {
        [self swizzleVC];
    }
    
    //安装事件
    if (type & ThinkingAnalyticsEventTypeAppInstall) {
        TAAutoTrackEvent *event = [[TAAutoTrackEvent alloc] initWithName:TD_APP_INSTALL_EVENT];
        // 安装事件提前1s统计
        event.time = [[NSDate date] dateByAddingTimeInterval: -1];
        [self.appInstallTracker test_trackWithInstanceTag:appid event:event params:nil];
    }
    
    // 开始记录end事件时长
    if (type & ThinkingAnalyticsEventTypeAppEnd) {
        ThinkingAnalyticsSDK *instance = [ThinkingAnalyticsSDK sharedInstanceWithAppid:appid];
        [instance timeEvent:TD_APP_END_EVENT];
    }

    // 上报app_start 冷启动
    if (type & ThinkingAnalyticsEventTypeAppStart) {
        dispatch_block_t mainThreadBlock = ^(){
            // 在下一个runloop中执行，此代码，否则relaunchInBackground会不准确。relaunchInBackground 在 AppLifeCycle 管理类中获得
            NSString *eventName = [TDAppState shareInstance].relaunchInBackground ? TD_APP_START_BACKGROUND_EVENT : TD_APP_START_EVENT;
            TAAppStartEvent *event = [[TAAppStartEvent alloc] initWithName:eventName];
            event.resumeFromBackground = NO;
            // 启动原因
            if (![TDPresetProperties disableStartReason]) {
                NSString *reason = [TDRunTime getAppLaunchReason];
                if (reason && reason.length) {
                    event.startReason = reason;
                }
            }
            [self.appColdStartTracker test_trackWithInstanceTag:appid event:event params:nil];
        };
        dispatch_async(dispatch_get_main_queue(), mainThreadBlock);
    }

    // 开启监听crash
    if (type & ThinkingAnalyticsEventTypeAppViewCrash) {
        ThinkingAnalyticsSDK *instance = [ThinkingAnalyticsSDK sharedInstanceWithAppid:appid];
        [[ThinkingExceptionHandler sharedHandler] addThinkingInstance:instance];
    }
}

- (void)viewControlWillAppear:(UIViewController *)controller {
    [self trackViewController:controller];
}

+ (UIViewController *)topPresentedViewController {
    UIWindow *keyWindow = [self findWindow];
    if (keyWindow != nil && !keyWindow.isKeyWindow) {
        [keyWindow makeKeyWindow];
    }
    
    UIViewController *topController = keyWindow.rootViewController;
    if ([topController isKindOfClass:[UINavigationController class]]) {
        topController = [(UINavigationController *)topController topViewController];
    }
    while (topController.presentedViewController) {
        topController = topController.presentedViewController;
    }
    return topController;
}

#pragma mark - Private

- (BOOL)isAutoTrackEventType:(ThinkingAnalyticsAutoTrackEventType)eventType {
    BOOL isIgnored = YES;
    for (NSString *appid in self.autoTrackOptions) {
        ThinkingAnalyticsAutoTrackEventType type = (ThinkingAnalyticsAutoTrackEventType)[self.autoTrackOptions[appid] integerValue];
        isIgnored = !(type & eventType);
        if (isIgnored == NO)
            break;
    }
    return !isIgnored;
}

- (UIViewController *)viewControllerForView:(UIView *)view {
    UIResponder *responder = view.nextResponder;
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            if ([responder isKindOfClass:[UINavigationController class]]) {
                responder = [(UINavigationController *)responder topViewController];
                continue;
            } else if ([responder isKindOfClass:UITabBarController.class]) {
                responder = [(UITabBarController *)responder selectedViewController];
                continue;
            }
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }
    return nil;
}

- (void)trackViewController:(UIViewController *)controller {
    if (![self shouldTrackViewContrller:[controller class]]) {
        return;
    }
    
    NSString *pageUrl = nil;
    NSString *pageReferrer = nil;
    NSString *pageTitle = nil;
    NSString *pageScreenName = nil;
    NSMutableDictionary *yx_customProperties = [NSMutableDictionary dictionary];
    
    NSMutableDictionary *properties = [[NSMutableDictionary alloc] init];
    [properties setValue:NSStringFromClass([controller class]) forKey:TD_EVENT_PROPERTY_SCREEN_NAME];
    
    pageScreenName = NSStringFromClass([controller class]);
    
    NSString *controllerTitle = [self titleFromViewController:controller];
    if (controllerTitle) {
        [properties setValue:controllerTitle forKey:TD_EVENT_PROPERTY_TITLE];
        
        pageTitle = controllerTitle;
    }
    
    NSDictionary *autoTrackerAppidDic;
    if ([controller conformsToProtocol:@protocol(TDAutoTracker)]) {
        UIViewController<TDAutoTracker> *autoTrackerController = (UIViewController<TDAutoTracker> *)controller;
        NSDictionary *autoTrackerDic;
        if ([controller respondsToSelector:@selector(getTrackPropertiesWithAppid)])
            autoTrackerAppidDic = [autoTrackerController getTrackPropertiesWithAppid];
        if ([controller respondsToSelector:@selector(getTrackProperties)])
            autoTrackerDic = [autoTrackerController getTrackProperties];
        
        if ([autoTrackerDic isKindOfClass:[NSDictionary class]]) {
            [properties addEntriesFromDictionary:autoTrackerDic];
            
            [yx_customProperties addEntriesFromDictionary:autoTrackerDic];
        }
    }
    
    NSDictionary *screenAutoTrackerAppidDic;
    if ([controller conformsToProtocol:@protocol(TDScreenAutoTracker)]) {
        UIViewController<TDScreenAutoTracker> *screenAutoTrackerController = (UIViewController<TDScreenAutoTracker> *)controller;
        if ([screenAutoTrackerController respondsToSelector:@selector(getScreenUrlWithAppid)])
            screenAutoTrackerAppidDic = [screenAutoTrackerController getScreenUrlWithAppid];
        if ([screenAutoTrackerController respondsToSelector:@selector(getScreenUrl)]) {
            NSString *currentUrl = [screenAutoTrackerController getScreenUrl];
            [properties setValue:currentUrl forKey:TD_EVENT_PROPERTY_URL_PROPERTY];
            
            pageUrl = currentUrl;
            
            [properties setValue:_referrerViewControllerUrl forKey:TD_EVENT_PROPERTY_REFERRER_URL];
            
            pageReferrer = _referrerViewControllerUrl;
            
            _referrerViewControllerUrl = currentUrl;
        }
    }
    
    NSDate *trackDate = [NSDate date];
    for (NSString *appid in self.autoTrackOptions) {
        ThinkingAnalyticsAutoTrackEventType type = [self.autoTrackOptions[appid] integerValue];
        if (type & ThinkingAnalyticsEventTypeAppViewScreen) {
            
            
            
            ThinkingAnalyticsSDK *instance = [ThinkingAnalyticsSDK sharedInstanceWithAppid:appid];
            NSMutableDictionary *trackProperties = [properties mutableCopy];
            
            NSMutableDictionary *yx_trackProperties = [yx_customProperties mutableCopy];

            if ([instance isViewControllerIgnored:controller]
                || [instance isViewTypeIgnored:[controller class]]) {
                continue;
            }
            
            if (autoTrackerAppidDic && [autoTrackerAppidDic objectForKey:appid]) {
                NSDictionary *dic = [autoTrackerAppidDic objectForKey:appid];
                if ([dic isKindOfClass:[NSDictionary class]]) {
                    [trackProperties addEntriesFromDictionary:dic];
                    
                    [yx_trackProperties addEntriesFromDictionary:dic];
                }
            }
            
            if (screenAutoTrackerAppidDic && [screenAutoTrackerAppidDic objectForKey:appid]) {
                NSString *screenUrl = [screenAutoTrackerAppidDic objectForKey:appid];
                [trackProperties setValue:screenUrl forKey:TD_EVENT_PROPERTY_URL_PROPERTY];
                
                pageUrl = screenUrl;
            }
            
            TAAutoPageViewEvent *pageEvent = [[TAAutoPageViewEvent alloc] initWithName:TD_APP_VIEW_EVENT];
            pageEvent.time = trackDate;
            pageEvent.pageUrl = pageUrl;
            pageEvent.pageTitle = pageTitle;
            pageEvent.referrer = pageReferrer;
            pageEvent.screenName = pageScreenName;
            
            [instance test_autoTrackWithEvent:pageEvent properties:yx_trackProperties];
        }
    }
}

- (BOOL)shouldTrackViewContrller:(Class)aClass {
    return ![TDPublicConfig.controllers containsObject:NSStringFromClass(aClass)];
}

- (ThinkingAnalyticsAutoTrackEventType)autoTrackOptionForAppid:(NSString *)appid {
    return (ThinkingAnalyticsAutoTrackEventType)[[self.autoTrackOptions objectForKey:appid] integerValue];
}

- (void)swizzleSelected:(UIView *)view delegate:(id)delegate {
    if ([view isKindOfClass:[UITableView class]]
        && [delegate conformsToProtocol:@protocol(UITableViewDelegate)]) {
        void (^block)(id, SEL, id, id) = ^(id target, SEL command, UITableView *tableView, NSIndexPath *indexPath) {
            [self trackEventView:tableView withIndexPath:indexPath];
        };
        
        [TDSwizzler swizzleSelector:@selector(tableView:didSelectRowAtIndexPath:)
                            onClass:[delegate class]
                          withBlock:block
                              named:@"td_table_select"];
    }
    
    if ([view isKindOfClass:[UICollectionView class]]
        && [delegate conformsToProtocol:@protocol(UICollectionViewDelegate)]) {
        
        void (^block)(id, SEL, id, id) = ^(id target, SEL command, UICollectionView *collectionView, NSIndexPath *indexPath) {
            [self trackEventView:collectionView withIndexPath:indexPath];
        };
        [TDSwizzler swizzleSelector:@selector(collectionView:didSelectItemAtIndexPath:)
                            onClass:[delegate class]
                          withBlock:block
                              named:@"td_collection_select"];
    }
}

- (void)swizzleVC {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void (^tableViewBlock)(UITableView *tableView,
                               SEL cmd,
                               id<UITableViewDelegate> delegate) =
        ^(UITableView *tableView, SEL cmd, id<UITableViewDelegate> delegate) {
            if (!delegate) {
                return;
            }
            
            [self swizzleSelected:tableView delegate:delegate];
        };
        
        [TDSwizzler swizzleSelector:@selector(setDelegate:)
                            onClass:[UITableView class]
                          withBlock:tableViewBlock
                              named:@"td_table_delegate"];
        
        void (^collectionViewBlock)(UICollectionView *, SEL, id<UICollectionViewDelegate>) = ^(UICollectionView *collectionView, SEL cmd, id<UICollectionViewDelegate> delegate) {
            if (nil == delegate) {
                return;
            }
            
            [self swizzleSelected:collectionView delegate:delegate];
        };
        [TDSwizzler swizzleSelector:@selector(setDelegate:)
                            onClass:[UICollectionView class]
                          withBlock:collectionViewBlock
                              named:@"td_collection_delegate"];
        
        
        [UIViewController td_swizzleMethod:@selector(viewWillAppear:)
                                withMethod:@selector(td_autotrack_viewWillAppear:)
                                     error:NULL];
        
        [UIApplication td_swizzleMethod:@selector(sendAction:to:from:forEvent:)
                             withMethod:@selector(td_sendAction:to:from:forEvent:)
                                  error:NULL];
    });
}

+ (NSString *)getPosition:(UIView *)view {
    NSString *position = nil;
    if ([view isKindOfClass:[UIView class]] && view.thinkingAnalyticsIgnoreView) {
        return nil;
    }
    
    if ([view isKindOfClass:[UITabBar class]]) {
        UITabBar *tabbar = (UITabBar *)view;
        position = [NSString stringWithFormat: @"%ld", (long)[tabbar.items indexOfObject:tabbar.selectedItem]];
    } else if ([view isKindOfClass:[UISegmentedControl class]]) {
        UISegmentedControl *segment = (UISegmentedControl *)view;
        position = [NSString stringWithFormat:@"%ld", (long)segment.selectedSegmentIndex];
    } else if ([view isKindOfClass:[UIProgressView class]]) {
        UIProgressView *progress = (UIProgressView *)view;
        position = [NSString stringWithFormat:@"%f", progress.progress];
    } else if ([view isKindOfClass:[UIPageControl class]]) {
        UIPageControl *pageControl = (UIPageControl *)view;
        position = [NSString stringWithFormat:@"%ld", (long)pageControl.currentPage];
    }
    
    return position;
}

+ (NSString *)getText:(NSObject *)obj {
    NSString *text = nil;
    if ([obj isKindOfClass:[UIView class]] && [(UIView *)obj thinkingAnalyticsIgnoreView]) {
        return nil;
    }
    
    if ([obj isKindOfClass:[UIButton class]]) {
        text = ((UIButton *)obj).currentTitle;
    } else if ([obj isKindOfClass:[UITextView class]] ||
               [obj isKindOfClass:[UITextField class]]) {
        //ignore
    } else if ([obj isKindOfClass:[UILabel class]]) {
        text = ((UILabel *)obj).text;
    } else if ([obj isKindOfClass:[UIPickerView class]]) {
        UIPickerView *picker = (UIPickerView *)obj;
        NSInteger sections = picker.numberOfComponents;
        NSMutableArray *titles = [NSMutableArray array];
        
        for(NSInteger i = 0; i < sections; i++) {
            NSInteger row = [picker selectedRowInComponent:i];
            NSString *title;
            if ([picker.delegate
                 respondsToSelector:@selector(pickerView:titleForRow:forComponent:)]) {
                title = [picker.delegate pickerView:picker titleForRow:row forComponent:i];
            } else if ([picker.delegate
                        respondsToSelector:@selector(pickerView:attributedTitleForRow:forComponent:)]) {
                title = [picker.delegate
                         pickerView:picker
                         attributedTitleForRow:row forComponent:i].string;
            }
            [titles addObject:title ?: @""];
        }
        if (titles.count > 0) {
            text = [titles componentsJoinedByString:@","];
        }
    } else if ([obj isKindOfClass:[UIDatePicker class]]) {
        UIDatePicker *picker = (UIDatePicker *)obj;
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = kDefaultTimeFormat;
        text = [formatter stringFromDate:picker.date];
    } else if ([obj isKindOfClass:[UISegmentedControl class]]) {
        UISegmentedControl *segment = (UISegmentedControl *)obj;
        text =  [NSString stringWithFormat:@"%@", [segment titleForSegmentAtIndex:segment.selectedSegmentIndex]];
    } else if ([obj isKindOfClass:[UISwitch class]]) {
        UISwitch *switchItem = (UISwitch *)obj;
        text = switchItem.on ? @"on" : @"off";
    } else if ([obj isKindOfClass:[UISlider class]]) {
        UISlider *slider = (UISlider *)obj;
        text = [NSString stringWithFormat:@"%f", [slider value]];
    } else if ([obj isKindOfClass:[UIStepper class]]) {
        UIStepper *step = (UIStepper *)obj;
        text = [NSString stringWithFormat:@"%f", [step value]];
    } else {
        if ([obj isKindOfClass:[UIView class]]) {
            for(UIView *subView in [(UIView *)obj subviews]) {
                text = [TDAutoTrackManager getText:subView];
                if ([text isKindOfClass:[NSString class]] && text.length > 0) {
                    break;
                }
            }
        }
    }
    return text;
}

- (NSString *)titleFromViewController:(UIViewController *)viewController {
    if (!viewController) {
        return nil;
    }
    
    UIView *titleView = viewController.navigationItem.titleView;
    NSString *elementContent = nil;
    if (titleView) {
        elementContent = [TDAutoTrackManager getText:titleView];
    }
    
    return elementContent.length > 0 ? elementContent : viewController.navigationItem.title;
}

+ (UIWindow *)findWindow {
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (window == nil || window.windowLevel != UIWindowLevelNormal) {
        for (window in [UIApplication sharedApplication].windows) {
            if (window.windowLevel == UIWindowLevelNormal) {
                break;
            }
        }
    }
    
    if (@available(iOS 13.0, tvOS 13, *)) {
        NSSet *scenes = [[UIApplication sharedApplication] valueForKey:@"connectedScenes"];
        for (id scene in scenes) {
            if (window) {
                break;
            }
            
            id activationState = [scene valueForKeyPath:@"activationState"];
            BOOL isActive = activationState != nil && [activationState integerValue] == 0;
            if (isActive) {
                Class WindowScene = NSClassFromString(@"UIWindowScene");
                if ([scene isKindOfClass:WindowScene]) {
                    NSArray<UIWindow *> *windows = [scene valueForKeyPath:@"windows"];
                    for (UIWindow *w in windows) {
                        if (w.isKeyWindow) {
                            window = w;
                            break;
                        }
                    }
                }
            }
        }
    }

    return window;
}

//MARK: - App Life Cycle

- (void)registerAppLifeCycleListener {
    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];

    [notificationCenter addObserver:self selector:@selector(appStateWillChangeNotification:) name:kTAAppLifeCycleStateWillChangeNotification object:nil];
}

- (void)appStateWillChangeNotification:(NSNotification *)notification {
    TAAppLifeCycleState newState = [[notification.userInfo objectForKey:kTAAppLifeCycleNewStateKey] integerValue];
    TAAppLifeCycleState oldState = [[notification.userInfo objectForKey:kTAAppLifeCycleOldStateKey] integerValue];

    if (newState == TAAppLifeCycleStateStart) {
        for (NSString *appid in self.autoTrackOptions) {
            ThinkingAnalyticsAutoTrackEventType type = (ThinkingAnalyticsAutoTrackEventType)[self.autoTrackOptions[appid] integerValue];
            
            // 只开启采集热启动的start事件。冷启动事件，在开启自动采集的时候上报
            if ((type & ThinkingAnalyticsEventTypeAppStart) && oldState != TAAppLifeCycleStateInit) {
                NSString *eventName = [TDAppState shareInstance].relaunchInBackground ? TD_APP_START_BACKGROUND_EVENT : TD_APP_START_EVENT;
                TAAppStartEvent *event = [[TAAppStartEvent alloc] initWithName:eventName];
                event.resumeFromBackground = YES;
                // 启动原因
                if (![TDPresetProperties disableStartReason]) {
                    NSString *reason = [TDRunTime getAppLaunchReason];
                    if (reason && reason.length) {
                        event.startReason = reason;
                    }
                }
                [self.appHotStartTracker test_trackWithInstanceTag:appid event:event params:@{}];
            }
            
            if (type & ThinkingAnalyticsEventTypeAppEnd) {
                // 开始记录app_end 事件的时间
                ThinkingAnalyticsSDK *instance = [ThinkingAnalyticsSDK sharedInstanceWithAppid:appid];
                [instance timeEvent:TD_APP_END_EVENT];
            }
        }
    } else if (newState == TAAppLifeCycleStateEnd) {
        for (NSString *appid in self.autoTrackOptions) {
            ThinkingAnalyticsAutoTrackEventType type = (ThinkingAnalyticsAutoTrackEventType)[self.autoTrackOptions[appid] integerValue];
            if (type & ThinkingAnalyticsEventTypeAppEnd) {
                TAAppEndEvent *event = [[TAAppEndEvent alloc] initWithName:TD_APP_END_EVENT];
                td_dispatch_main_sync_safe(^{
                    // 记录当前界面的名字，有UI操作，需要在主线程执行。
                    NSString *screenName = NSStringFromClass([[TDAutoTrackManager topPresentedViewController] class]);
                    event.screenName = screenName;
                    [self.appEndTracker test_trackWithInstanceTag:appid event:event params:@{}];
                });
            }
            
            if (type & ThinkingAnalyticsEventTypeAppStart) {
                // 开始记录app_start 事件的时间
                ThinkingAnalyticsSDK *instance = [ThinkingAnalyticsSDK sharedInstanceWithAppid:appid];
                [instance timeEvent:TD_APP_START_EVENT];
            }
        }
    }
}

//MARK: - Getter & Setter

- (TDHotStartTracker *)appHotStartTracker {
    if (!_appHotStartTracker) {
        _appHotStartTracker = [[TDHotStartTracker alloc] init];
    }
    return _appHotStartTracker;
}

- (TDColdStartTracker *)appColdStartTracker {
    if (!_appColdStartTracker) {
        _appColdStartTracker = [[TDColdStartTracker alloc] init];
    }
    return _appColdStartTracker;
}

- (TDInstallTracker *)appInstallTracker {
    if (!_appInstallTracker) {
        _appInstallTracker = [[TDInstallTracker alloc] init];
    }
    return _appInstallTracker;
}

- (TDAppEndTracker *)appEndTracker {
    if (!_appEndTracker) {
        _appEndTracker = [[TDAppEndTracker alloc] init];
    }
    return _appEndTracker;
}

@end

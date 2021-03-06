//
//  TATrackEvent.m
//  ThinkingSDK
//
//  Created by 杨雄 on 2022/6/12.
//

#import "TATrackEvent.h"
#import "TDPresetProperties.h"
#import "TDPresetProperties+TDDisProperties.h"
#import "NSDate+TAFormat.h"

@implementation TATrackEvent

- (instancetype)initWithName:(NSString *)eventName {
    if (self = [self init]) {
        self.eventName = eventName;
    }
    return self;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        self.eventType = TAEventTypeTrack;
        // 获取当前开机时长
        self.systemUpTime = NSProcessInfo.processInfo.systemUptime;
    }
    return self;
}

- (void)validateWithError:(NSError *__autoreleasing  _Nullable *)error {
    // 验证事件名字
    [TAPropertyValidator validateEventOrPropertyName:self.eventName withError:error];
}

- (NSMutableDictionary *)jsonObject {
    NSMutableDictionary *dict = [super jsonObject];
    
    dict[@"#event_name"] = self.eventName;
    
    [self.properties addEntriesFromDictionary:self.superProperties];
    [self.properties addEntriesFromDictionary:self.dynamicSuperProperties];

    if (self.foregroundDuration) {
        self.properties[@"#duration"] = @([[NSString stringWithFormat:@"%.3f", self.foregroundDuration] doubleValue]);
    }
    if (self.backgroundDuration) {
        self.properties[@"#background_duration"] = @([[NSString stringWithFormat:@"%.3f", self.backgroundDuration] doubleValue]);
    }
    
    if (self.timeValueType != TAEventTimeValueTypeTimeOnly) {
        if (![TDPresetProperties disableZoneOffset]) {
            self.properties[@"#zone_offset"] = @([self timeZoneOffset]);
        }
    }
    
    return dict;
}

- (double)timeZoneOffset {
    NSTimeZone *tz = self.timeZone ?: [NSTimeZone localTimeZone];
    return [[NSDate date] ta_timeZoneOffset:tz];
}

//MARK: - Delegate

- (void)ta_validateKey:(NSString *)key value:(id)value error:(NSError *__autoreleasing  _Nullable *)error {
    [TAPropertyValidator validateNormalTrackEventPropertyKey:key value:value error:error];
}

@end

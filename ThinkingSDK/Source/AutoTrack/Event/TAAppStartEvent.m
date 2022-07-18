//
//  TAAppStartEvent.m
//  ThinkingSDK
//
//  Created by 杨雄 on 2022/6/17.
//

#import "TAAppStartEvent.h"

@implementation TAAppStartEvent

- (NSMutableDictionary *)jsonObject {
    NSMutableDictionary *dict = [super jsonObject];
    self.properties[@"#resume_from_background"] = @(self.resumeFromBackground);
    self.properties[@"#start_reason"] = self.startReason;
    
    // 重新处理 app_start 事件的时长
    // app_start 事件是自动采集管理类采集到的。存在以下问题：自动采集管理类 和 timeTracker事件时长管理类 都是通过监听appLifeCycle的通知来做出处理，所以不在一个精确的统一的时间点。会存在有微小误差，需要消除。
    // 测试下来，误差都小于0.01s.
    CGFloat minDuration = 0.01;
    self.properties[@"#duration"] = self.foregroundDuration > minDuration ? @([[NSString stringWithFormat:@"%.3f", self.foregroundDuration] doubleValue]) : nil;
    self.properties[@"#background_duration"] = self.backgroundDuration > minDuration ? @([[NSString stringWithFormat:@"%.3f", self.backgroundDuration] doubleValue]) : nil;
    
    return dict;
}

@end

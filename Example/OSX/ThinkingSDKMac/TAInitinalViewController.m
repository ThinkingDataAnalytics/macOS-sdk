//
//  TAInitinalViewController.m
//  ThinkingSDKMac
//
//  Created by 杨雄 on 2022/7/5.
//

#import "TAInitinalViewController.h"
#import <ThinkingSDKMacOS/ThinkingSDK.h>

@interface TAInitinalViewController ()
@property (nonatomic, weak) IBOutlet NSTextField *appidTextField;
@property (nonatomic, weak) IBOutlet NSTextField *serverUrlTextField;

@end

@implementation TAInitinalViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    NSString *appid = @"您的appid";
    NSString *url = @"您的url";
    self.appidTextField.stringValue = appid;
    self.serverUrlTextField.stringValue = url;
}

- (IBAction)cancelAction:(NSButton *)button {
    [self dismissViewController:self];
}

- (IBAction)initAction:(id)sender {
    [self dismissViewController:self];
    [self initThinkingAnalytics];
}

- (void)initThinkingAnalytics {
    [ThinkingAnalyticsSDK setLogLevel:TDLoggingLevelDebug];
    NSString *appid = self.appidTextField.stringValue;
    NSString *url = self.serverUrlTextField.stringValue;
    TDConfig *config = [TDConfig new];
    config.appid = appid;
    config.configureURL = url;
    [ThinkingAnalyticsSDK startWithConfig:config];
}


@end

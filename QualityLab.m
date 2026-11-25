#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>
#import <stdatomic.h>

// Standalone experiment. No Substrate dependency and no network interception.
static __weak id preferences;
static NSMutableArray<NSString *> *events;
static NSMutableSet<NSString *> *seen;
static NSLock *eventLock;
static atomic_bool experiment;
static UIButton *labButton;
static NSString *const prefsClass = @"_TtC31Preferences_CorePreferencesImpl28SPTPreferencesImplementation";

static void record(NSString *line) {
    [eventLock lock];
    if (![seen containsObject:line]) {
        [seen addObject:line];
        [events addObject:[NSString stringWithFormat:@"%@ %@", NSDate.date, line]];
        if (events.count > 600) [events removeObjectAtIndex:0];
        if (seen.count > 1200) [seen removeAllObjects];
    }
    [eventLock unlock];
}

static BOOL abi(Method method, const char *result, const char *argument) {
    if (!method || method_getNumberOfArguments(method) != (argument ? 3 : 2)) return NO;
    char type[128] = {0};
    method_getReturnType(method, type, sizeof(type));
    if (strcmp(type, result)) return NO;
    if (argument) {
        method_getArgumentType(method, 2, type, sizeof(type));
        // Object arguments may carry a quoted class name.
        if (!strcmp(argument, "@")) return type[0] == '@';
        return !strcmp(type, argument);
    }
    return YES;
}

static void replace(Class cls, SEL selector, IMP replacement, Method method) {
    if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method)))
        method_setImplementation(class_getInstanceMethod(cls, selector), replacement);
    record([NSString stringWithFormat:@"hook %@ %@", NSStringFromClass(cls), NSStringFromSelector(selector)]);
}

static NSString *forcedValue(NSString *key) {
    if (!experiment || ![key isKindOfClass:NSString.class]) return nil;
    // These are local experiments, never evidence of a server entitlement.
    if ([key isEqual:@"high-bitrate"] || [key isEqual:@"very-high-bitrate"]) return @"1";
    if ([key isEqual:@"type"] || [key isEqual:@"product"] || [key isEqual:@"catalogue"]) return @"premium";
    return nil;
}

static BOOL relevantKey(NSString *key) {
    return [@[@"type", @"product", @"catalogue", @"high-bitrate", @"very-high-bitrate", @"audio-quality"] containsObject:key];
}

static id productDictionary(id original) {
    if (![original isKindOfClass:NSDictionary.class]) return original;
    NSDictionary *input = original;
    for (NSString *key in @[@"type", @"product", @"catalogue", @"high-bitrate", @"very-high-bitrate", @"audio-quality"]) {
        id value = input[key];
        if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class])
            record([NSString stringWithFormat:@"account ORIGINAL %@=%@", key, value]);
    }
    if (!experiment) return original;
    NSMutableDictionary *result = input.mutableCopy;
    for (NSString *key in @[@"type", @"product", @"catalogue", @"high-bitrate", @"very-high-bitrate"])
        result[key] = forcedValue(key);
    return result;
}

static void hookProduct(void) {
    Class cls = NSClassFromString(@"SPTCoreProductState");
    if (!cls) { record(@"missing SPTCoreProductState"); return; }
    for (NSString *name in @[@"stringForKey:", @"objectForKeyedSubscript:"]) {
        SEL selector = NSSelectorFromString(name);
        Method method = class_getInstanceMethod(cls, selector);
        if (!abi(method, "@", "@")) { record([@"ABI mismatch " stringByAppendingString:name]); continue; }
        IMP original = method_getImplementation(method);
        IMP replacement = imp_implementationWithBlock(^id(id object, id key) {
            id value = ((id(*)(id,SEL,id))original)(object,selector,key);
            if ([key isKindOfClass:NSString.class] && relevantKey(key) &&
                ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]))
                record([NSString stringWithFormat:@"account ORIGINAL %@=%@",key,value]);
            return forcedValue(key) ?: value;
        });
        replace(cls, selector, replacement, method);
    }
    for (NSString *name in @[@"values", @"originalValues"]) {
        SEL selector = NSSelectorFromString(name);
        Method method = class_getInstanceMethod(cls, selector);
        if (!abi(method, "@", NULL)) continue;
        IMP original = method_getImplementation(method);
        replace(cls, selector, imp_implementationWithBlock(^id(id object) {
            return productDictionary(((id(*)(id,SEL))original)(object,selector));
        }), method);
    }
}

static void hookPreferences(void) {
    Class cls = NSClassFromString(prefsClass);
    if (!cls) { record(@"missing native preferences class"); return; }
    for (NSString *name in @[@"audioPlayBitrate", @"audioPlayBitrateNonMetered", @"audioSyncBitrate"]) {
        SEL selector = NSSelectorFromString(name);
        Method method = class_getInstanceMethod(cls, selector);
        if (!abi(method, @encode(NSInteger), NULL)) { record([@"ABI mismatch " stringByAppendingString:name]); continue; }
        IMP original = method_getImplementation(method);
        replace(cls, selector, imp_implementationWithBlock(^NSInteger(id object) {
            preferences = object;
            NSInteger value = ((NSInteger(*)(id,SEL))original)(object,selector);
            record([NSString stringWithFormat:@"native %@=%ld", name, (long)value]);
            return value;
        }), method);
    }
    for (NSString *name in @[@"setAudioPlayBitrate:", @"setAudioPlayBitrateNonMetered:"]) {
        SEL selector = NSSelectorFromString(name);
        Method method = class_getInstanceMethod(cls, selector);
        if (!abi(method, "v", @encode(NSInteger))) continue;
        IMP original = method_getImplementation(method);
        replace(cls, selector, imp_implementationWithBlock(^(id object, NSInteger value) {
            preferences = object;
            record([NSString stringWithFormat:@"native %@ %ld", name, (long)value]);
            ((void(*)(id,SEL,NSInteger))original)(object,selector,value);
        }), method);
    }
}

static void observeMetadata(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return;
    // Deliberately exclude URLs, tokens, IDs, titles and other account metadata.
    for (NSString *key in @[@"source_is_lossless", @"audio_quality", @"bitrate", @"audio_bitrate", @"codec", @"codec_name", @"file_type", @"sample_rate", @"bits_per_sample"]) {
        id item = value[key];
        if ([item isKindOfClass:NSString.class] || [item isKindOfClass:NSNumber.class])
            record([NSString stringWithFormat:@"player METADATA %@=%@ (reported; not independently verified)",key,item]);
    }
}

static void hookTrackMetadata(void) {
    unsigned count = 0;
    Class *classes = objc_copyClassList(&count);
    unsigned installed = 0;
    for (unsigned i = 0; i < count; i++) {
        Class cls = classes[i];
        NSString *name = NSStringFromClass(cls);
        if ([name rangeOfString:@"PlayerTrack" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        // Hook only methods declared on this class, never its shared superclass.
        unsigned number = 0; Method *methods = class_copyMethodList(cls, &number);
        for (unsigned j = 0; j < number; j++) {
            Method method = methods[j]; SEL selector = method_getName(method);
            if (selector != NSSelectorFromString(@"metadata") || !abi(method,"@",NULL)) continue;
            IMP original = method_getImplementation(method);
            replace(cls,selector,imp_implementationWithBlock(^id(id object) {
                id value = ((id(*)(id,SEL))original)(object,selector);
                observeMetadata(value); return value;
            }),method);
            installed++;
        }
        free(methods);
    }
    free(classes);
    record([NSString stringWithFormat:@"metadata observers installed=%u; absent fields mean UNKNOWN, not lossless", installed]);
}

static UIViewController *presenter(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.isKeyWindow) continue;
            UIViewController *vc = window.rootViewController;
            while (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) vc=vc.presentedViewController;
            return vc;
        }
    }
    return nil;
}

static void message(NSString *text) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Quality Lab" message:text preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [presenter() presentViewController:alert animated:YES completion:nil];
}

static void writeQuality(NSInteger value) {
    id object = preferences;
    if (!object) { message(@"尚未捕获原生偏好对象。先打开 Spotify 音质设置，再重试。未写入任何值。"); return; }
    // 3/4/5 are hypotheses based on the 9.1.90 native enum. Readback on 9.2.2
    // is recorded; the stock UI labels must be checked on the user's device.
    NSArray *setters = @[@"setAudioPlayBitrate:", @"setAudioPlayBitrateNonMetered:"];
    for (NSString *name in setters) {
        if (!abi(class_getInstanceMethod(object_getClass(object),NSSelectorFromString(name)),"v",@encode(NSInteger))) {
            message(@"偏好接口签名不匹配，取消写入。"); return;
        }
    }
    record([NSString stringWithFormat:@"EXPERIMENT native requested enum=%ld (NOT actual stream quality)",(long)value]);
    for (NSString *name in setters) ((void(*)(id,SEL,NSInteger))objc_msgSend)(object,NSSelectorFromString(name),value);
    for (NSString *name in @[@"audioPlayBitrate",@"audioPlayBitrateNonMetered"]) {
        SEL selector = NSSelectorFromString(name);
        if (abi(class_getInstanceMethod(object_getClass(object),selector),@encode(NSInteger),NULL))
            record([NSString stringWithFormat:@"READBACK %@=%ld",name,(long)((NSInteger(*)(id,SEL))objc_msgSend)(object,selector)]);
    }
    message(@"已调用原生音质设置。请重新打开音质页核对标签，再切换一首未缓存的歌曲。写入成功不代表服务端接受或实际播放达到该音质。");
}

@interface QLController : NSObject
+ (void)show;
@end
@implementation QLController
+ (void)show {
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Quality Lab · 实验版" message:[NSString stringWithFormat:@"当前：%@\n实际音源质量：尚未验证\n枚举 3/4/5 需用本机设置标签核对。", experiment ? @"尝试修改客户端属性" : @"只观察"] preferredStyle:UIAlertControllerStyleActionSheet];
    [menu addAction:[UIAlertAction actionWithTitle:experiment ? @"关闭属性修改（随后重启）" : @"启用属性修改（随后重启）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        experiment = !experiment;
        [NSUserDefaults.standardUserDefaults setBool:experiment forKey:@"QualityLabExperiment"];
        record(experiment ? @"MODE experiment ON" : @"MODE observation ON");
        message(@"请从后台彻底退出 Spotify 后重新打开，使账号属性重新读取。此模式仅修改本地读值。");
    }]];
    NSArray *names = @[@"写入高：枚举 3（恢复用）",@"尝试超高：枚举 4",@"尝试无损：枚举 5"];
    for (NSInteger i=0;i<3;i++) {
        NSInteger value=i+3;
        [menu addAction:[UIAlertAction actionWithTitle:names[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { writeQuality(value); }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"导出诊断日志" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [eventLock lock]; NSString *log=[events componentsJoinedByString:@"\n"]; [eventLock unlock];
        NSURL *url=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"QualityLab.txt"]];
        NSError *error=nil;
        if (![log writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:&error]) { message(@"日志写入失败"); return; }
        UIActivityViewController *share=[[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
        share.popoverPresentationController.sourceView=labButton;
        share.popoverPresentationController.sourceRect=labButton.bounds;
        [presenter() presentViewController:share animated:YES completion:nil];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView=labButton;
    menu.popoverPresentationController.sourceRect=labButton.bounds;
    [presenter() presentViewController:menu animated:YES completion:nil];
}
@end

static void attachButton(void) {
    UIViewController *vc=presenter();
    if (!vc || labButton.window) return;
    if (!labButton) {
        labButton=[UIButton buttonWithType:UIButtonTypeSystem];
        [labButton setTitle:@"QL" forState:UIControlStateNormal];
        labButton.backgroundColor=[UIColor colorWithRed:0 green:0.35 blue:0.2 alpha:0.9];
        [labButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        labButton.layer.cornerRadius=22;
        labButton.accessibilityLabel=@"Quality Lab 实验与日志";
        [labButton addTarget:QLController.class action:@selector(show) forControlEvents:UIControlEventTouchUpInside];
    }
    UIWindow *window=vc.view.window;
    labButton.frame=CGRectMake(window.bounds.size.width-58,window.safeAreaInsets.top+70,44,44);
    labButton.autoresizingMask=UIViewAutoresizingFlexibleLeftMargin|UIViewAutoresizingFlexibleBottomMargin;
    [window addSubview:labButton];
}

__attribute__((constructor)) static void startQualityLab(void) {
    @autoreleasepool {
        eventLock=NSLock.new; events=NSMutableArray.new; seen=NSMutableSet.new;
        NSDictionary *info=NSBundle.mainBundle.infoDictionary;
        if (![info[@"CFBundleExecutable"] isEqual:@"Spotify"]) return;
        experiment=[NSUserDefaults.standardUserDefaults boolForKey:@"QualityLabExperiment"];
        record([NSString stringWithFormat:@"QualityLab 0.1 app=%@ build=%@ mode=%@; actual source quality UNKNOWN",info[@"CFBundleShortVersionString"],info[@"CFBundleVersion"],experiment?@"experiment":@"observation"]);
        if (![info[@"CFBundleShortVersionString"] isEqual:@"9.2.2"]) {
            record(@"Unsupported version: hooks disabled");
        } else {
            hookProduct(); hookPreferences(); hookTrackMetadata();
        }
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { attachButton(); }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3*NSEC_PER_SEC),dispatch_get_main_queue(),^{ attachButton(); });
    }
}

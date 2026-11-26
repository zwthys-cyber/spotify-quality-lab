#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>
#import <stdatomic.h>
#import <mach-o/dyld.h>

// Standalone experiment. No Substrate dependency and no network interception.
static __weak id preferences;
static __weak id latestManifest;
static atomic_uint metadataReads, manifestReads, playbackErrors;
static BOOL nativeCapabilityVerified;
static NSMutableArray<NSString *> *events;
static NSMutableDictionary<NSString *, NSString *> *lastStates;
static NSLock *eventLock;
static atomic_bool experiment;
static UIButton *labButton;
static NSString *const prefsClass = @"_TtC31Preferences_CorePreferencesImpl28SPTPreferencesImplementation";

static void record(NSString *line) {
    [eventLock lock];
    [events addObject:[NSString stringWithFormat:@"%@ %@", NSDate.date, line]];
    if (events.count > 2000) [events removeObjectAtIndex:0];
    [eventLock unlock];
}

// Suppress consecutive equal values per object/field, not every value ever seen.
// A -> B -> A must emit all three transitions. Explicit snapshots never dedupe.
static void recordState(NSString *key, NSString *line) {
    [eventLock lock];
    if (![lastStates[key] isEqual:line]) {
        lastStates[key] = line;
        [events addObject:[NSString stringWithFormat:@"%@ %@", NSDate.date, line]];
        if (events.count > 2000) [events removeObjectAtIndex:0];
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
    if ([key isEqual:@"audio-quality"]) return @"2";
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
            recordState([@"account dictionary " stringByAppendingString:key], [NSString stringWithFormat:@"account LOCAL_INPUT %@=%@ (may include earlier local rewrites)", key, value]);
    }
    if (!experiment) return original;
    NSMutableDictionary *result = input.mutableCopy;
    for (NSString *key in @[@"type", @"product", @"catalogue", @"high-bitrate", @"very-high-bitrate", @"audio-quality"])
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
                recordState([NSString stringWithFormat:@"account %p %@ %@", (__bridge void *)object,name,key], [NSString stringWithFormat:@"account LOCAL_INPUT %@ %@=%@", name,key,value]);
            NSString *forced=forcedValue(key);
            if (forced && [key isEqual:@"audio-quality"])
                recordState(@"audio-quality output", [NSString stringWithFormat:@"account LOCAL_OUTPUT audio-quality=%@ (client only)",forced]);
            return forced ?: value;
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
            recordState([NSString stringWithFormat:@"native %p %@", (__bridge void *)object,name], [NSString stringWithFormat:@"native object=%p %@=%ld", (__bridge void *)object,name,(long)value]);
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
            record([NSString stringWithFormat:@"native SET object=%p %@ %ld", (__bridge void *)object,name,(long)value]);
            ((void(*)(id,SEL,NSInteger))original)(object,selector,value);
        }), method);
    }
}

static void observeMetadata(id value) {
    if (![value isKindOfClass:NSDictionary.class]) return;
    unsigned sample=atomic_fetch_add(&metadataReads,1);
    // The skip loop can read metadata thousands of times a second. Count all
    // reads but limit diagnostic dictionary processing to one in every 64.
    if (sample%64) return;
    NSUInteger present=0;
    // Deliberately exclude URLs, tokens, IDs, titles and other account metadata.
    for (NSString *key in @[@"source_is_lossless", @"audio_quality", @"bitrate", @"audio_bitrate", @"codec", @"codec_name", @"file_type", @"sample_rate", @"bits_per_sample"]) {
        id item = value[key];
        if ([item isKindOfClass:NSString.class] || [item isKindOfClass:NSNumber.class]) {
            present++;
            recordState([@"metadata " stringByAppendingString:key], [NSString stringWithFormat:@"player METADATA %@=%@ (reported; not independently verified)",key,item]);
        }
    }
    recordState(@"metadata schema",[NSString stringWithFormat:@"metadata dictionary observed; allowed audio fields present=%lu",(unsigned long)present]);
}

static NSString *safeErrorDomain(NSString *domain) {
    if (![domain isKindOfClass:NSString.class] || domain.length>128) return @"redacted";
    static NSCharacterSet *allowed;
    static dispatch_once_t once;
    dispatch_once(&once,^{allowed=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];});
    return [domain rangeOfCharacterFromSet:allowed.invertedSet].location==NSNotFound?domain:@"redacted";
}

static BOOL reasonToken(id value) {
    if (![value isKindOfClass:NSString.class] || ![value length] || [value length]>96) return NO;
    static NSCharacterSet *allowed;
    static dispatch_once_t once;
    dispatch_once(&once,^{allowed=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_- "];});
    // Reason names only; no URI, identifier digits, punctuation or arbitrary text.
    return [value rangeOfCharacterFromSet:allowed.invertedSet].location==NSNotFound &&
        ([value rangeOfString:@"_"].location!=NSNotFound || [@[@"Forbidden",@"Not found",@"Conflict",@"Unknown",@"unknown",@"forbidden",@"restricted",@"unavailable",@"premium",@"free",@"true",@"false"] containsObject:value]);
}

static void observeReasonValue(id value,NSString *source,NSString *path,unsigned depth) {
    if (!value || depth>4) return;
    NSString *stateKey=[NSString stringWithFormat:@"reason %@ %@",source,path];
    if ([value isKindOfClass:NSNumber.class]) {
        recordState(stateKey,[NSString stringWithFormat:@"PLAYBACK_REASON source=%@ %@=%@",source,path,value]);
    } else if ([value isKindOfClass:NSString.class]) {
        if (reasonToken(value)) {
            recordState(stateKey,[NSString stringWithFormat:@"PLAYBACK_REASON source=%@ %@=%@",source,path,value]);
        } else if ([value length]<=4096 && ([value hasPrefix:@"{"] || [value hasPrefix:@"["])) {
            id decoded=[NSJSONSerialization JSONObjectWithData:[value dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
            if (decoded) observeReasonValue(decoded,source,path,depth+1);
        } else recordState(stateKey,[NSString stringWithFormat:@"PLAYBACK_REASON source=%@ %@=redacted_non_enum_string",source,path]);
    } else if ([value isKindOfClass:NSSet.class]) {
        NSSet *reasons=value;
        recordState([stateKey stringByAppendingString:@" shape"],[NSString stringWithFormat:@"PLAYBACK_REASON source=%@ %@ set_count=%lu",source,path,(unsigned long)reasons.count]);
        NSUInteger index=0;
        for (id reason in reasons) {
            if (index>=16) break;
            observeReasonValue(reason,source,[path stringByAppendingFormat:@"[%lu]",(unsigned long)index],depth+1);
            index++;
        }
    } else if ([value isKindOfClass:NSArray.class]) {
        recordState([stateKey stringByAppendingString:@" shape"],[NSString stringWithFormat:@"PLAYBACK_REASON source=%@ %@ array_count=%lu",source,path,(unsigned long)[value count]]);
        NSUInteger limit=MIN((NSUInteger)16,[value count]);
        for (NSUInteger i=0;i<limit;i++) observeReasonValue(value[i],source,[path stringByAppendingFormat:@"[%lu]",(unsigned long)i],depth+1);
    } else if ([value isKindOfClass:NSDictionary.class]) {
        // Read only semantic diagnostic keys; never export a whole dictionary.
        NSArray *keys=@[@"reason",@"reasons",@"disallow_reason",@"disallow_reasons",@"error",@"errors",@"code",@"error_code",@"type",@"name",@"category",@"status",@"http_status",@"restriction",@"restrictions",@"context",@"data"];
        NSMutableArray *present=NSMutableArray.new;
        for (NSString *key in keys) if (value[key]) {
            [present addObject:key];
            observeReasonValue(value[key],source,[path stringByAppendingFormat:@".%@",key],depth+1);
        }
        // Some reasons are maps whose enum-like keys are the actual reason
        // names. Keep bounded diagnostic labels, never identifier/token keys.
        NSArray *excluded=@[@"track_uri",@"track_id",@"file_id",@"playback_id",@"session_id",@"user_id",@"url",@"uri",@"id",@"message",@"description"];
        unsigned labels=0;
        for (id key in value) {
            if (labels>=16) break;
            if (!reasonToken(key) || [present containsObject:key]) continue;
            NSString *lower=[key lowercaseString];
            if ([excluded containsObject:lower] || [lower containsString:@"token"] || [lower containsString:@"secret"] || [lower containsString:@"authorization"]) continue;
            [present addObject:key]; labels++;
            observeReasonValue(value[key],source,[path stringByAppendingFormat:@".%@",key],depth+1);
        }
        recordState([stateKey stringByAppendingString:@" shape"],[NSString stringWithFormat:@"PLAYBACK_REASON source=%@ %@ dictionary_count=%lu allowed_keys=%@",source,path,(unsigned long)[value count],[present componentsJoinedByString:@","]]);
    } else {
        recordState(stateKey,[NSString stringWithFormat:@"PLAYBACK_REASON source=%@ %@ unsupported_class=%@",source,path,NSStringFromClass(object_getClass(value))]);
    }
}

// This is used only for kSPTPlayerErrorDisallowReasonsKey. The value has
// already been identified as a disallow reason, so its typography must not
// determine whether the reason is kept (e.g. NoFile, 101, or plain sentences).
static NSString *disallowText(NSString *value) {
    NSString *text=value.length>2048?[value substringToIndex:2048]:value;
    NSArray *patterns=@[@"(?i)(?:https?://|spotify:)[^\\s]+",
                         @"(?i)\\bBearer\\s+[^\\s]+",
                         @"(?i)\\b(access_token|refresh_token|authorization|token)\\s*[:=]\\s*[^\\s,;]+"];
    NSArray *replacements=@[@"<url>",@"Bearer <token>",@"$1=<token>"];
    for (NSUInteger i=0;i<patterns.count;i++) {
        NSRegularExpression *regex=[NSRegularExpression regularExpressionWithPattern:patterns[i] options:0 error:NULL];
        text=[regex stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0,text.length) withTemplate:replacements[i]];
    }
    text=[text stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"];
    text=[text stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    return [text stringByReplacingOccurrencesOfString:@"\t" withString:@"\\t"];
}

static void observeDisallowReason(id value,NSString *source,NSString *path,unsigned depth) {
    if (!value || depth>4) return;
    if ([value isKindOfClass:NSString.class]) {
        recordState([NSString stringWithFormat:@"reason text %@ %@",source,path],[NSString stringWithFormat:@"PLAYBACK_REASON_TEXT source=%@ %@=%@",source,path,disallowText(value)]);
    } else if ([value isKindOfClass:NSSet.class] || [value isKindOfClass:NSArray.class]) {
        recordState([NSString stringWithFormat:@"reason collection %@ %@",source,path],[NSString stringWithFormat:@"PLAYBACK_REASON_TEXT source=%@ %@ %@_count=%lu",source,path,[value isKindOfClass:NSSet.class]?@"set":@"array",(unsigned long)[value count]]);
        NSUInteger index=0;
        for (id item in value) {
            if (index>=16) break;
            observeDisallowReason(item,source,[path stringByAppendingFormat:@"[%lu]",(unsigned long)index],depth+1);
            index++;
        }
    } else observeReasonValue(value,source,path,depth);
}

static void observePlaybackError(NSString *source,id error) {
    atomic_fetch_add(&playbackErrors,1);
    if (![error isKindOfClass:NSError.class]) {
        recordState([@"playback error " stringByAppendingString:source],[NSString stringWithFormat:@"PLAYBACK_ERROR source=%@ class=%@ (not NSError; no arbitrary fields read)",source,error?NSStringFromClass(object_getClass(error)):@"nil"]);
        return;
    }
    NSError *current=error;
    for (unsigned depth=0;current && depth<3;depth++) {
        NSString *line=[NSString stringWithFormat:@"PLAYBACK_ERROR source=%@ depth=%u domain=%@ code=%ld",source,depth,safeErrorDomain(current.domain),(long)current.code];
        recordState([NSString stringWithFormat:@"playback error %@ %u",source,depth],line);
        if ([current.domain isEqual:@"com.spotify.SPTPlayer"]) {
            NSDictionary *info=current.userInfo;
            id reasons=info[@"kSPTPlayerErrorDisallowReasonsKey"];
            id name=info[@"kSPTPlayerErrorNameKey"];
            recordState([NSString stringWithFormat:@"reason presence %@ %u",source,depth],[NSString stringWithFormat:@"PLAYBACK_REASON_FIELDS source=%@ depth=%u disallow_present=%@ name_present=%@",source,depth,reasons?@"yes":@"no",name?@"yes":@"no"]);
            observeDisallowReason(reasons,source,[NSString stringWithFormat:@"depth%u.disallow",depth],0);
            observeReasonValue(name,source,[NSString stringWithFormat:@"depth%u.name",depth],0);
        }
        id underlying=current.userInfo[NSUnderlyingErrorKey];
        if (![underlying isKindOfClass:NSError.class] || underlying==current) break;
        current=underlying;
    }
}

static void hookPlaybackErrors(void) {
    for (NSString *name in @[@"_TtC23NowPlaying_PlatformImpl28StatefulPlayerImplementation",@"SPTPlaybackErrorPicker",@"SPTExternalIntegrationPlaybackControllerImplementation"]) {
        Class cls=NSClassFromString(name);
        SEL selector=NSSelectorFromString(@"player:didEncounterError:");
        Method method=cls?class_getInstanceMethod(cls,selector):NULL;
        char type[128]={0};
        BOOL matches=method && method_getNumberOfArguments(method)==4;
        if (matches) {method_getReturnType(method,type,sizeof(type));matches=!strcmp(type,"v");}
        for (unsigned i=2;matches && i<4;i++) {
            method_getArgumentType(method,i,type,sizeof(type)); matches=type[0]=='@';
        }
        if (!matches) {record([@"playback error observer ABI unavailable " stringByAppendingString:name]);continue;}
        IMP original=method_getImplementation(method);
        replace(cls,selector,imp_implementationWithBlock(^(id object,id player,id error) {
            observePlaybackError(name,error);
            // Observe only. Always forward, never swallow errors or force retry.
            ((void(*)(id,SEL,id,id))original)(object,selector,player,error);
        }),method);
    }
}

static void hookManifest(void) {
    Class cls=NSClassFromString(@"SPTPlayerMediaManifest");
    if (!cls) { record(@"manifest observer: class absent"); return; }
    SEL bitrate=NSSelectorFromString(@"bitrate");
    Method method=class_getInstanceMethod(cls,bitrate);
    if (abi(method,@encode(NSUInteger),NULL)) {
        IMP original=method_getImplementation(method);
        replace(cls,bitrate,imp_implementationWithBlock(^NSUInteger(id object) {
            latestManifest=object; atomic_fetch_add(&manifestReads,1);
            NSUInteger value=((NSUInteger(*)(id,SEL))original)(object,bitrate);
            recordState([NSString stringWithFormat:@"manifest %p bitrate",(__bridge void *)object],[NSString stringWithFormat:@"MANIFEST object=%p bitrate=%lu (advertised; units and active playback unverified)",(__bridge void *)object,(unsigned long)value]);
            return value;
        }),method);
    }
    SEL setter=NSSelectorFromString(@"setBitrate:");
    method=class_getInstanceMethod(cls,setter);
    if (abi(method,"v",@encode(NSUInteger))) {
        IMP original=method_getImplementation(method);
        replace(cls,setter,imp_implementationWithBlock(^(id object,NSUInteger value) {
            latestManifest=object; atomic_fetch_add(&manifestReads,1);
            record([NSString stringWithFormat:@"MANIFEST SET object=%p bitrate=%lu (advertised only)",(__bridge void *)object,(unsigned long)value]);
            ((void(*)(id,SEL,NSUInteger))original)(object,setter,value);
        }),method);
    }
    SEL mime=NSSelectorFromString(@"mimeType");
    method=class_getInstanceMethod(cls,mime);
    if (abi(method,"@",NULL)) {
        IMP original=method_getImplementation(method);
        replace(cls,mime,imp_implementationWithBlock(^id(id object) {
            latestManifest=object; atomic_fetch_add(&manifestReads,1);
            id value=((id(*)(id,SEL))original)(object,mime);
            if ([value isKindOfClass:NSString.class] && [value length]<128 && ([value hasPrefix:@"audio/"] || [value hasPrefix:@"application/"]))
                recordState([NSString stringWithFormat:@"manifest %p mime",(__bridge void *)object],[NSString stringWithFormat:@"MANIFEST mime=%@ (advertised only)",value]);
            return value;
        }),method);
    }
}

static BOOL verifyNativeCapability(void) {
    NSDictionary *info=NSBundle.mainBundle.infoDictionary;
    if ([info[@"QualityLabNativeCapability"] integerValue]!=2) {
        record(@"NATIVE_CAPABILITY no packaging marker; ordinary dylib injection cannot apply the native static patch");
        return NO;
    }
    const struct mach_header_64 *header=(const struct mach_header_64 *)_dyld_get_image_header(0);
    if (!header || header->magic!=MH_MAGIC_64) return NO;
    const uint8_t *cursor=(const uint8_t *)(header+1);
    const uint64_t target=0x9307988;
    for (uint32_t i=0;i<header->ncmds;i++) {
        const struct load_command *cmd=(const struct load_command *)cursor;
        if (cmd->cmd==LC_SEGMENT_64) {
            const struct segment_command_64 *segment=(const struct segment_command_64 *)cursor;
            if (segment->fileoff==0 && !strncmp(segment->segname,"__TEXT",16) && target+8<=segment->filesize) {
                const uint8_t expected[8]={0x40,0x00,0x80,0x52,0xc0,0x03,0x5f,0xd6};
                BOOL matches=!memcmp((const uint8_t *)header+target,expected,sizeof(expected));
                record(matches?@"NATIVE_CAPABILITY live entry verified: local getter returns 2; NOT server entitlement or stream quality":@"NATIVE_CAPABILITY WARNING packaging marker exists but live code does not match");
                return matches;
            }
        }
        cursor+=cmd->cmdsize;
    }
    record(@"NATIVE_CAPABILITY unable to verify live code bounds");
    return NO;
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

static NSString *snapshot(NSString *reason) {
    id object = preferences;
    NSMutableArray<NSString *> *lines=NSMutableArray.new;
    [lines addObject:[NSString stringWithFormat:@"SNAPSHOT %@ mode=%@ object=%p class=%@",reason,experiment?@"experiment":@"observation",(__bridge void *)object,object?NSStringFromClass(object_getClass(object)):@"none"]];
    if (!object) [lines addObject:@"No preferences object captured. Open the native quality page first."];
    else for (NSString *name in @[@"audioPlayBitrate",@"audioPlayBitrateNonMetered",@"audioSyncBitrate"]) {
        SEL selector=NSSelectorFromString(name);
        if (abi(class_getInstanceMethod(object_getClass(object),selector),@encode(NSInteger),NULL))
            [lines addObject:[NSString stringWithFormat:@"SNAPSHOT %@=%ld",name,(long)((NSInteger(*)(id,SEL))objc_msgSend)(object,selector)]];
    }
    for (NSString *line in lines) record(line);
    record([NSString stringWithFormat:@"OBSERVERS metadata dictionaries=%u manifest calls=%u playback error callbacks=%u native-capability-patch=%@",atomic_load(&metadataReads),atomic_load(&manifestReads),atomic_load(&playbackErrors),nativeCapabilityVerified?@"verified-local-2":@"unverified-or-absent"]);
    id manifest=latestManifest;
    if (manifest) for (NSString *name in @[@"bitrate",@"mimeType"]) {
        SEL selector=NSSelectorFromString(name);
        Method method=class_getInstanceMethod(object_getClass(manifest),selector);
        if ([name isEqual:@"bitrate"] && abi(method,@encode(NSUInteger),NULL))
            (void)((NSUInteger(*)(id,SEL))objc_msgSend)(manifest,selector);
        else if ([name isEqual:@"mimeType"] && abi(method,"@",NULL))
            (void)((id(*)(id,SEL))objc_msgSend)(manifest,selector);
    }
    return [lines componentsJoinedByString:@"\n"];
}

static void describeInterfaces(void) {
    // Method names/signatures only; never invoke unknown selectors or log data.
    for (NSString *name in @[@"SPTCoreProductState",prefsClass,@"_TtC20Lossless_SettingsKit38UbiquityAudioQualitySettingsController",@"StreamQualitySettingsSection"]) {
        Class cls=NSClassFromString(name);
        record([NSString stringWithFormat:@"INTERFACE %@ %@",name,cls?@"present":@"absent"]);
        if (!cls) continue;
        unsigned count=0; Method *methods=class_copyMethodList(cls,&count);
        for (unsigned i=0;i<count;i++) {
            NSString *methodName=NSStringFromSelector(method_getName(methods[i]));
            NSString *lower=methodName.lowercaseString;
            BOOL relevant=[lower containsString:@"bitrate"] || [lower containsString:@"quality"] || [lower containsString:@"premium"] || [lower containsString:@"forkey"] || [lower containsString:@"lossless"];
            if (relevant) record([NSString stringWithFormat:@"INTERFACE %@ %@ ABI=%s",name,methodName,method_getTypeEncoding(methods[i])]);
        }
        free(methods);
    }
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
    snapshot(@"immediate-after-write");
    for (NSNumber *delay in @[@5,@20]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,delay.longLongValue*NSEC_PER_SEC),dispatch_get_main_queue(),^{
            snapshot([NSString stringWithFormat:@"%@s-after-write requested=%ld",delay,(long)value]);
        });
    }
    message(@"已调用原生音质设置。请重新打开音质页核对标签，再切换一首未缓存的歌曲。写入成功不代表服务端接受或实际播放达到该音质。");
}

@interface QLController : NSObject
+ (void)show;
@end
@implementation QLController
+ (void)show {
    NSString *nativeNote=nativeCapabilityVerified?@"此包含固定原生能力补丁；关闭属性修改不会撤销，需原包恢复。":@"未确认原生能力补丁。";
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Quality Lab 0.7 · 原因诊断版" message:[NSString stringWithFormat:@"当前：%@\n%@\n实际音源质量：尚未验证。", experiment ? @"尝试修改客户端属性" : @"观察本地读值",nativeNote] preferredStyle:UIAlertControllerStyleActionSheet];
    [menu addAction:[UIAlertAction actionWithTitle:@"读取当前状态（不修改）" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        message(snapshot(@"manual-read-current"));
    }]];
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
        snapshot(@"before-export");
        describeInterfaces();
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
        eventLock=NSLock.new; events=NSMutableArray.new; lastStates=NSMutableDictionary.new;
        NSDictionary *info=NSBundle.mainBundle.infoDictionary;
        if (![info[@"CFBundleExecutable"] isEqual:@"Spotify"]) return;
        experiment=[NSUserDefaults.standardUserDefaults boolForKey:@"QualityLabExperiment"];
        record([NSString stringWithFormat:@"QualityLab 0.7 app=%@ build=%@ mode=%@; actual source quality UNKNOWN",info[@"CFBundleShortVersionString"],info[@"CFBundleVersion"],experiment?@"experiment":@"observation"]);
        if (![info[@"CFBundleShortVersionString"] isEqual:@"9.2.2"]) {
            record(@"Unsupported version: hooks disabled");
        } else {
            nativeCapabilityVerified=verifyNativeCapability();
            hookProduct(); hookPreferences(); hookTrackMetadata(); hookManifest(); hookPlaybackErrors();
        }
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { attachButton(); }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3*NSEC_PER_SEC),dispatch_get_main_queue(),^{ attachButton(); });
    }
}

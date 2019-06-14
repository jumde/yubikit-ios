// Copyright 2018-2019 Yubico AB
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#import "YKFKeyConnectionController.h"
#import "YubiKitManager.h"
#import "YKFPCSCLayer.h"
#import "YKFPCSCErrors.h"
#import "YKFPCSCTypes.h"
#import "YKFAssert.h"
#import "YKFBlockMacros.h"
#import "YKFPCSCErrorMap.h"
#import "YKFLogger.h"
#import "YKFKeySession+Private.h"
#import "YKFNSDataAdditions+Private.h"

static NSString* const YKFPCSCLayerReaderName = @"YubiKey Lightning";

// NEO V3 ATR
static const UInt8 YKFPCSCNeoAtrSize = 22;
static const UInt8 YKFPCSCNeoAtr[] = {0x3b, 0xfc, 0x13, 0x00, 0x00, 0x81, 0x31, 0xfe, 0x15, 0x59, 0x75, 0x62, 0x69, 0x6b, 0x65, 0x79, 0x4e, 0x45, 0x4f, 0x72, 0x33, 0xe1};

// Some constants to avoid too many unnecessary contexts in one app. Ideally the host app should
// use a singleton to access the key, even when using PC/SC instead of replicating the same execution
// code on multiple threads.
static const NSUInteger YKFPCSCLayerContextLimit = 10;
static const NSUInteger YKFPCSCLayerCardLimitPerContext = 10;


@interface YKFPCSCLayer()

@property (nonatomic) id<YKFKeySessionProtocol> keySession;
@property (nonatomic) YKFPCSCErrorMap *errorMap;

// Maps a context value to a list of card values
@property (nonatomic) NSMutableDictionary<NSNumber*, NSMutableArray<NSNumber*>*> *contextMap;

// Reverse lookup map between a card and a context.
@property (nonatomic) NSMutableDictionary<NSNumber*, NSNumber*> *cardMap;

@end


@implementation YKFPCSCLayer

#pragma mark - Lifecycle

static id<YKFPCSCLayerProtocol> sharedInstance;

+ (id<YKFPCSCLayerProtocol>)shared {
#ifdef DEBUG
    if (staticFakePCSCLayer) {
        return staticFakePCSCLayer;
    }
#endif
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[YKFPCSCLayer alloc] initWithKeySession:YubiKitManager.shared.keySession];
    });
    return sharedInstance;
}

- (instancetype)initWithKeySession:(id<YKFKeySessionProtocol>)session {
    YKFAssertAbortInit(session);
    
    self = [super init];
    if (self) {
        self.keySession = session;        
        self.contextMap = [[NSMutableDictionary alloc] init];
        self.cardMap = [[NSMutableDictionary alloc] init];
        self.errorMap = [[YKFPCSCErrorMap alloc] init];
    }
    return self;
}

#pragma mark - PC/SC

- (SInt64)connectCard {
    if (!self.keySession.isKeyConnected) {
        return YKF_SCARD_E_NO_SMARTCARD;
    }
    
    BOOL sessionOpened = [self.keySession startSessionSync];
    return sessionOpened ? YKF_SCARD_S_SUCCESS : YKF_SCARD_F_WAITED_TOO_LONG;
}

- (SInt64)disconnectCard {
    if (!self.keySession.isKeyConnected) {
        return YKF_SCARD_E_NO_SMARTCARD;
    }
    
    BOOL sessionClosed = [self.keySession stopSessionSync];
    return sessionClosed ? YKF_SCARD_S_SUCCESS : YKF_SCARD_F_WAITED_TOO_LONG;
}

- (SInt64)reconnectCard {
    SInt64 disconnectResult = [self disconnectCard];
    if (disconnectResult != YKF_SCARD_S_SUCCESS) {
        return disconnectResult;
    }
    return [self connectCard];
}

- (SInt64)transmit:(NSData *)commandData response:(NSData **)response {
    YKFAssertReturnValue(self.keySession.sessionState == YKFKeySessionStateOpen, @"Session is closed. Cannot send command.", YKF_SCARD_E_READER_UNAVAILABLE);
    YKFAssertReturnValue(commandData.length, @"The command data is empty.", YKF_SCARD_E_INVALID_PARAMETER);
    
    YKFAPDU *command = [[YKFAPDU alloc] initWithData:commandData];
    YKFAssertReturnValue(command, @"Could not create APDU with data.", YKF_SCARD_E_INVALID_PARAMETER);

    __block NSData *responseData = nil;
    
    [self.keySession.rawCommandService executeSyncCommand:command completion:^(NSData *resp, NSError *error) {
        if (!error && resp) {
            responseData = resp;
        }
    }];
    
    if (responseData) {
        *response = responseData;
        return YKF_SCARD_S_SUCCESS;
    }
    
    return YKF_SCARD_F_WAITED_TOO_LONG;
}

- (SInt64)listReaders:(NSString **)yubikeyReaderName {
    if (self.keySession.isKeyConnected) {
        *yubikeyReaderName = YKFPCSCLayerReaderName;
        return YKF_SCARD_S_SUCCESS;
    }
    return YKF_SCARD_E_NO_READERS_AVAILABLE;
}

- (SInt32)getCardState {
    if (self.keySession.isKeyConnected) {
        if (self.keySession.sessionState == YKFKeySessionStateOpen) {
            return YKF_SCARD_SPECIFICMODE;
        }
        return YKF_SCARD_SWALLOWED;
    }
    return YKF_SCARD_ABSENT;
}

- (SInt64)getStatusChange {    
    if (self.keySession.isKeyConnected) {
        return YKF_SCARD_STATE_PRESENT | YKF_SCARD_STATE_CHANGED;
    }
    return YKF_SCARD_STATE_EMPTY | YKF_SCARD_STATE_CHANGED;
}

- (NSString *)getCardSerial {
    if (self.keySession.isKeyConnected) {
        return self.keySession.keyDescription.serialNumber;
    }
    return nil;
}

- (NSData *)getCardAtr {
    return [NSData dataWithBytes:YKFPCSCNeoAtr length:YKFPCSCNeoAtrSize];
}

#pragma mark - Context and Card tracking helpers

- (BOOL)addContext:(SInt32)context {
    @synchronized (self.contextMap) {
        if (self.contextMap.allKeys.count >= YKFPCSCLayerContextLimit) {
            YKFLogError(@"PC/SC - Could not establish context %d. Too many contexts started by the application.", (int)context);
            return NO;
        }
        NSMutableArray<NSNumber*> *contextCards = [[NSMutableArray alloc] init];
        self.contextMap[@(context)] = contextCards;
        
        YKFLogInfo(@"PC/SC - Context %d established.", (int)context);
        return YES;
    }
}

- (BOOL)removeContext:(SInt32)context {
    @synchronized (self.contextMap) {
        if (!self.contextMap[@(context)]) {
            YKFLogError(@"PC/SC - Could not release context %d. Unknown context.", (int)context);
            return NO;
        }
        
        NSMutableArray<NSNumber*> *associatedCards = self.contextMap[@(context)];
        [self.contextMap removeObjectForKey:@(context)];
        
        @synchronized (self.cardMap) {
            ykf_weak_self();
            [associatedCards enumerateObjectsUsingBlock:^(NSNumber *obj, NSUInteger idx, BOOL *stop) {
                [weakSelf.cardMap removeObjectForKey:obj];
            }];
            
            YKFLogInfo(@"PC/SC - Context %d released.", (int)context);
            return YES;
        }
    }
}

- (BOOL)addCard:(SInt32)card toContext:(SInt32)context {
    if (![self contextIsValid:context]) {
        // YKFLogError(@"PC/SC - Could not use context %d. Unknown context.", context);
        return NO;
    }
    
    @synchronized (self.contextMap) {
        if (self.contextMap[@(context)].count >= YKFPCSCLayerCardLimitPerContext) {
            // YKFLogError(@"PC/SC - Could not connect to card %d in context %d. Too many cards per context.", card, context);
            return NO;
        }
        [self.contextMap[@(context)] addObject:@(card)];
    }
    @synchronized (self.cardMap) {
        self.cardMap[@(card)] = @(context);
    }
    
    // YKFLogInfo(@"PC/SC - Connected to card %d in context %d.", card, context);
    return YES;
}

- (BOOL)removeCard:(SInt32)card {    
    if (![self cardIsValid:card]) {
        // YKFLogError(@"PC/SC - Could not disconnect from card %d. Unknown card.", card);
        return NO;
    }

    @synchronized (self.cardMap) {
        NSNumber *context = self.cardMap[@(card)];
        [self.cardMap removeObjectForKey:@(card)];
        
        @synchronized (self.contextMap) {
            [self.contextMap[context] removeObject:@(card)];
        }
        
        // YKFLogInfo(@"PC/SC - Disconnected from card %d.", card);
        return YES;
    }
}

- (BOOL)contextIsValid:(SInt32)context {
    @synchronized (self.contextMap) {
        return self.contextMap[@(context)] != nil;
    }
}

- (BOOL)cardIsValid:(SInt32)card {
    @synchronized (self.cardMap) {
        return self.cardMap[@(card)] != nil;
    }
}

- (SInt32)contextForCard:(SInt32)card {
    @synchronized (self.cardMap) {
        return self.cardMap[@(card)] != nil ? self.cardMap[@(card)].intValue : 0;
    }
}

- (NSString *)stringifyError:(SInt64)errorCode {
    return [self.errorMap errorForCode:errorCode];
}

#pragma mark - Testing additions

#ifdef DEBUG

static id<YKFPCSCLayerProtocol> staticFakePCSCLayer;

+ (void)setFakePCSCLayer:(id<YKFPCSCLayerProtocol>)fakePCSCLayer {
    staticFakePCSCLayer = fakePCSCLayer;
}

+ (id<YKFPCSCLayerProtocol>)fakePCSCLayer {
    return staticFakePCSCLayer;
}

#endif

@end

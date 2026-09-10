//
//  ControllerSupport.m
//  Moonlight
//
//  Created by Cameron Gutman on 10/20/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//
//  Modified by True砖家 since 2024.6.16
//  Copyright © 2024 True砖家 @ Bilibili. All rights reserved.
//

#import "ControllerSupport.h"
#import "OnScreenControls.h"
#import "VoidController.h"
#import "VoidLink-Swift.h"

#import "DataManager.h"
#include "Limelight.h"
#include <stdio.h>

@import GameController;
#if !TARGET_OS_TV
    @import CoreMotion;
#endif
@import AudioToolbox;

static const double MOUSE_SPEED_DIVISOR = 1.25;
static __weak ControllerSupport *VLSharedControllerSupport = nil;

typedef struct _VL_ADAPTIVE_TRIGGER_EFFECT {
    uint8_t type;
    float parameter0;
    float parameter1;
    float parameter2;
} VL_ADAPTIVE_TRIGGER_EFFECT;

static VL_ADAPTIVE_TRIGGER_EFFECT DecodeAdaptiveTriggerEffect(uint8_t type, const uint8_t* payload)
{
    const float byteScale = 1.0f / 255.0f;
    VL_ADAPTIVE_TRIGGER_EFFECT effect = {
        .type = type,
        .parameter0 = payload[0] * byteScale,
        .parameter1 = payload[1] * byteScale,
        .parameter2 = payload[2] * byteScale,
    };
    return effect;
}

static void ApplyAdaptiveTriggerEffect(GCDualSenseAdaptiveTrigger* trigger,
                                       VL_ADAPTIVE_TRIGGER_EFFECT effect)
    API_AVAILABLE(ios(14.5), tvos(14.5));

static void ApplyAdaptiveTriggerEffect(GCDualSenseAdaptiveTrigger* trigger,
                                       VL_ADAPTIVE_TRIGGER_EFFECT effect)
{
    switch (effect.type) {
        case 0x00:
            [trigger setModeOff];
            break;
        case 0x01:
            [trigger setModeFeedbackWithStartPosition:effect.parameter0
                                   resistiveStrength:effect.parameter1];
            break;
        case 0x02:
            if (effect.parameter1 > effect.parameter0) {
                [trigger setModeWeaponWithStartPosition:effect.parameter0
                                            endPosition:effect.parameter1
                                     resistiveStrength:effect.parameter2];
            }
            else {
                // Log(LOG_W, @"Ignoring invalid adaptive weapon effect: start=%.3f end=%.3f", effect.parameter0, effect.parameter1);
            }
            break;
        case 0x06:
            [trigger setModeVibrationWithStartPosition:effect.parameter2
                                             amplitude:effect.parameter1
                                             frequency:effect.parameter0];
            break;
        default:
            // Log(LOG_W, @"Ignoring unsupported adaptive trigger effect type: 0x%02X", effect.type);
            break;
    }
}

@interface ControllerSupport()

@property (assign,nonatomic) bool shallDisableGyroHotSwitch;

@end


@implementation ControllerSupport {
    id _controllerConnectObserver;
    id _controllerDisconnectObserver;
    id _mouseConnectObserver;
    id _mouseDisconnectObserver;
    id _keyboardConnectObserver;
    id _keyboardDisconnectObserver;
    
    NSLock *_controllerStreamLock;
    NSMutableDictionary *_voidControllers;
    StreamConfiguration* _streamConfig;
    __weak id<ControllerSupportDelegate> _delegate;
    
    float accumulatedDeltaX;
    float accumulatedDeltaY;
    float accumulatedScrollX;
    float accumulatedScrollY;
    
    bool _controllerNavigationEnabled;

    float stickMaxOffset;
    float _leftStickMinOffset;
    float _rightStickMinOffset;

    OnScreenControls *_osc;
    VoidController *_oscController;
    TemporarySettings* tempSettings;
    OSCProfile* oscProfile;
    OSCProfilesManager* oscProfileMan;
#if !TARGET_OS_TV
    GameSirG8MFiRumbler *_gameSirG8MFiRumbler;
    KishiV3ProXLRumbler *_kishiRumbler;
#endif

#define EMULATING_SELECT     0x1
#define EMULATING_SPECIAL    0x2
    
    bool _oscEnabled;
    char _controllerNumbers;
    bool _multiController;
    bool _swapABXYButtons;
    int _gyroMode;
    CGFloat _gyroSensitivity;
    bool _captureMouse;
    
    bool _controllerGyroSwitchEnabled;
    bool _gyroEnabledFlag; // bool flag for both DS4 gyro & VL motion control
    int _controllerGyroSwitchToggle;
    int _controllerGyroSwitchHold;
    bool _reverseHoldButton;
    bool _controllerGyroSwitchTogglePressed;
    bool _controllerGyroSwitchHoldPressed;
    ControllerGyroSwitchMode _gyroSwitchMode;

    uint64_t _authoredHapticsGeneration;

    __weak MotionHandler* motionHandler;
}

+(ControllerSupport*) sharedInstance
{
    return VLSharedControllerSupport;
}

// UPDATE_BUTTON_FLAG(controller, flag, pressed)
#define UPDATE_BUTTON_FLAG(controller, x, y) \
((y) ? [self setButtonFlag:controller flags:x] : [self clearButtonFlag:controller flags:x])

#define MAX_MAGNITUDE(x, y) (abs(x) > abs(y) ? (x) : (y))

-(void) applyPhysicalControllerRumble:(VoidController*)controller lowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor
{
#if !TARGET_OS_TV
    if ([_kishiRumbler isTargetController:controller.gamepad]) {
        [_kishiRumbler setLowFrequencyMotor:lowFreqMotor highFrequencyMotor:highFreqMotor];
        return;
    }
    if (controller.hardware == ControllerHardwareG8PlusMFi) {
        // NSLog(@"[G8Rumble] route native rumble low=%hu high=%hu", lowFreqMotor, highFreqMotor);
        [_gameSirG8MFiRumbler setLowFrequencyMotor:lowFreqMotor highFrequencyMotor:highFreqMotor];
        return;
    }
#endif

    [controller.lowFreqMotor setMotorAmplitude:lowFreqMotor];
    [controller.highFreqMotor setMotorAmplitude:highFreqMotor];
}

-(void) rumble:(unsigned short)controllerNumber lowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor
{
    VoidController* voidController = [_voidControllers objectForKey:[NSNumber numberWithInteger:controllerNumber]];
    
    HapticEnginePreference preference = tempSettings.hapticEngine.intValue;
        
    if (voidController == nil && controllerNumber == 0 && _oscEnabled) {
        // no physical controller connected:
        if(preference != RumbleOff){
            [_oscController.lowFreqMotor setMotorAmplitude:lowFreqMotor];
            [_oscController.highFreqMotor setMotorAmplitude:highFreqMotor];
        }
    }
    
    if (voidController == nil) {
        // No connected controller for this player
        return;
    }

    /*
    NSLog(@"[G8Rumble] rumble request controller=%hu low=%hu high=%hu preference=%ld vendor=%@",
          controllerNumber,
          lowFreqMotor,
          highFreqMotor,
          (long)preference,
          voidController.gamepad.vendorName);
     */
    
    // physical controller connected:
    switch (preference) {
        case HapticEngineAuto:
            // if controller has no haptic profile, it already falled bakc to device engine
            [self applyPhysicalControllerRumble:voidController lowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
            break;
        case RumbleDevice:
            [self applyPhysicalControllerRumble:voidController lowFreqMotor:0 highFreqMotor:0];
            [_oscController.lowFreqMotor setMotorAmplitude:lowFreqMotor];
            [_oscController.highFreqMotor setMotorAmplitude:highFreqMotor];
            break;
        case LeftRightSwapped:
            [self applyPhysicalControllerRumble:voidController lowFreqMotor:highFreqMotor highFreqMotor:lowFreqMotor];
            break;
        case RumbleOff:
            [self applyPhysicalControllerRumble:voidController lowFreqMotor:0 highFreqMotor:0];
            break;
        default:
            break;
    }
}

-(void) rumbleTriggers:(uint16_t)controllerNumber leftTrigger:(uint16_t)leftTrigger rightTrigger:(uint16_t)rightTrigger
{
    VoidController* controller = [_voidControllers objectForKey:[NSNumber numberWithInteger:controllerNumber]];
    if (controller == nil && controllerNumber == 0 && _oscEnabled) {
        // TODO: Trigger rumble emulation for OSC
    }
    if (controller == nil) {
        // No connected controller for this player
        return;
    }
    [controller.leftTriggerMotor setMotorAmplitude:leftTrigger];
    [controller.rightTriggerMotor setMotorAmplitude:rightTrigger];
}

- (bool)isLandscapeNow {
    return CGRectGetWidth([[UIScreen mainScreen]bounds]) > CGRectGetHeight([[UIScreen mainScreen]bounds]);
}

#if !TARGET_OS_TV
- (UIInterfaceOrientation)currentInterfaceOrientation
{
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) {
                continue;
            }

            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (windowScene.activationState != UISceneActivationStateForegroundActive) {
                continue;
            }

            if (windowScene.interfaceOrientation != UIInterfaceOrientationUnknown) {
                return windowScene.interfaceOrientation;
            }
        }

        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) {
                continue;
            }

            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (windowScene.activationState == UISceneActivationStateUnattached) {
                continue;
            }

            if (windowScene.interfaceOrientation != UIInterfaceOrientationUnknown) {
                return windowScene.interfaceOrientation;
            }
        }
    }

    return UIApplication.sharedApplication.statusBarOrientation;
}
#endif

-(void)updateTimerStateForController:(VoidController* )voidController{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateTimerStateForController:voidController];
        });
        return;
    }

    if (voidController == nil || voidController.reportRateHz == 0) {
        [self stopTimerForController:voidController];
        return;
    }

    // if (@available(iOS 14.0, tvOS 14.0, *)) {
    if(_gyroMode == GyroModeOff){
        [self stopTimerForController:voidController];
        return;
    }
    if([ControllerUtil hasControllerAccelerometer:voidController.gamepad]) {
        [voidController.motionTypes addObject:@(LI_MOTION_TYPE_ACCEL)];
    }
    if (@available(iOS 14.0, *)) if(voidController.gamepad.motion.hasRotationRate){
        [voidController.motionTypes addObject:@(LI_MOTION_TYPE_GYRO)];
    }

    for(NSNumber* motionTypeObj in voidController.motionTypes){
        uint8_t motionType = motionTypeObj.intValue;

#if !TARGET_OS_TV //tvOS has no device motion
        if(voidController == _oscController){
            //Player has no controller *or* no motion for controller 1 *or* wants to override controller 1 motion with device motion
            if(!voidController.motionManager) {
                voidController.motionManager = [[CMMotionManager alloc] init];
            }
            
            switch (motionType) {
                case LI_MOTION_TYPE_ACCEL: {
                    [voidController.accelTimer invalidate];
                    voidController.accelTimer = nil;
                    // Reset the last motion sample
                    CMAcceleration emptyDeviceAccelSample = {};
                    voidController.lastDeviceAccelSample = emptyDeviceAccelSample;
                    voidController.motionManager.deviceMotionUpdateInterval = 1.0 / voidController.reportRateHz;
                    [voidController.motionManager startDeviceMotionUpdates];
                    {NSLog(@"setup device built-in accelTimer");
                        voidController.hasAccelerometer = YES;
                        voidController.accelTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / voidController.reportRateHz repeats:YES block:^(NSTimer *timer) {
                            CMAcceleration deviceAccelSample = voidController.motionManager.deviceMotion.userAcceleration;
                            //userAcceleration does not contain gravity, add gravity to x, y and z values:
                            deviceAccelSample.x += voidController.motionManager.deviceMotion.gravity.x;
                            deviceAccelSample.y += voidController.motionManager.deviceMotion.gravity.y;
                            deviceAccelSample.z += voidController.motionManager.deviceMotion.gravity.z;
                            // NSLog(@"sending device accel %f", CACurrentMediaTime());

                            UIInterfaceOrientation interfaceOrientation = [self currentInterfaceOrientation];
                            CMAcceleration mappedDeviceAccelSample = {};
                            switch (interfaceOrientation) {
                                case UIInterfaceOrientationLandscapeLeft:
                                    mappedDeviceAccelSample.x = deviceAccelSample.y * -9.80665f;
                                    mappedDeviceAccelSample.y = deviceAccelSample.z * -9.80665f;
                                    mappedDeviceAccelSample.z = deviceAccelSample.x * -9.80665f;
                                    break;
                                case UIInterfaceOrientationLandscapeRight:
                                    mappedDeviceAccelSample.x = deviceAccelSample.y * 9.80665f;
                                    mappedDeviceAccelSample.y = deviceAccelSample.z * -9.80665f;
                                    mappedDeviceAccelSample.z = deviceAccelSample.x * 9.80665f;
                                    break;
                                case UIInterfaceOrientationPortrait:
                                    mappedDeviceAccelSample.x = deviceAccelSample.x * -9.80665f;
                                    mappedDeviceAccelSample.y = deviceAccelSample.z * -9.80665f;
                                    mappedDeviceAccelSample.z = deviceAccelSample.y * 9.80665f;
                                    break;
                                case UIInterfaceOrientationPortraitUpsideDown:
                                    mappedDeviceAccelSample.x = deviceAccelSample.x * 9.80665f;
                                    mappedDeviceAccelSample.y = deviceAccelSample.z * -9.80665f;
                                    mappedDeviceAccelSample.z = deviceAccelSample.y * -9.80665f;
                                    break;
                                default:
                                    mappedDeviceAccelSample.x = deviceAccelSample.y * -9.80665f;
                                    mappedDeviceAccelSample.y = deviceAccelSample.z * -9.80665f;
                                    mappedDeviceAccelSample.z = deviceAccelSample.x * -9.80665f;
                                    break;
                            }

                            // Don't send duplicate samples after orientation remapping.
                            CMAcceleration lastDeviceAccelSample = voidController.lastDeviceAccelSample;
                            if (memcmp(&mappedDeviceAccelSample, &lastDeviceAccelSample, sizeof(mappedDeviceAccelSample)) == 0) {
                                return;
                            }
                            voidController.lastDeviceAccelSample = mappedDeviceAccelSample;
                            
                            // Convert g to m/s^2
                            LiSendControllerMotionEvent((uint8_t)voidController.controllerNumber,
                                                        LI_MOTION_TYPE_ACCEL,
                                                        mappedDeviceAccelSample.x,
                                                        mappedDeviceAccelSample.y,
                                                        mappedDeviceAccelSample.z);
                        }];}
                    break;
                }
                case LI_MOTION_TYPE_GYRO: {
                    [voidController.gyroTimer invalidate];
                    voidController.gyroTimer = nil;
                    
                    // Reset the last motion sample
                    CMRotationRate emptyDeviceGyroSample = {};
                    voidController.lastDeviceGyroSample = emptyDeviceGyroSample;
                    [voidController.motionManager startDeviceMotionUpdates];
                    
                    NSLog(@"setup device built-in gyro gyroTimer");
                    voidController.hasGyroscope = YES;
                    voidController.gyroTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / voidController.reportRateHz repeats:YES block:^(NSTimer *timer) {
                        
                        // Don't send duplicate samples
                        CMRotationRate lastDeviceGyroSample = voidController.lastDeviceGyroSample;
                        CMRotationRate deviceGyroSample = voidController.motionManager.deviceMotion.rotationRate;
                        if (memcmp(&deviceGyroSample, &lastDeviceGyroSample, sizeof(deviceGyroSample)) == 0) {
                                return;
                        }
                        voidController.lastDeviceGyroSample = deviceGyroSample;
                        
                        // Convert rad/s to deg/s
                        
                        UIInterfaceOrientation interfaceOrientation = [self currentInterfaceOrientation];
                        
                        switch (interfaceOrientation) {
                            case UIInterfaceOrientationLandscapeLeft:
                                LiSendControllerMotionEvent((uint8_t)voidController.controllerNumber,
                                                            LI_MOTION_TYPE_GYRO,
                                                            self->_gyroEnabledFlag ? deviceGyroSample.y * 57.2957795f * self->_gyroSensitivity : 0,
                                                            self->_gyroEnabledFlag ? deviceGyroSample.z * 57.2957795f * self->_gyroSensitivity : 0,
                                                            self->_gyroEnabledFlag ? deviceGyroSample.x * 57.2957795f * self->_gyroSensitivity : 0);
                                break;
                            case UIInterfaceOrientationLandscapeRight:
                                LiSendControllerMotionEvent((uint8_t)voidController.controllerNumber,
                                                            LI_MOTION_TYPE_GYRO,
                                                            self->_gyroEnabledFlag ? deviceGyroSample.y * -57.2957795f * self->_gyroSensitivity : 0,
                                                            self->_gyroEnabledFlag ? deviceGyroSample.z * 57.2957795f * self->_gyroSensitivity : 0,
                                                            self->_gyroEnabledFlag ? deviceGyroSample.x * -57.2957795f * self->_gyroSensitivity : 0);
                                break;
                            case UIInterfaceOrientationPortrait:
                                LiSendControllerMotionEvent((uint8_t)voidController.controllerNumber,
                                                            LI_MOTION_TYPE_GYRO,
                                                            self->_gyroEnabledFlag ? deviceGyroSample.x * 57.2957795f * self->_gyroSensitivity : 0,
                                                            self->_gyroEnabledFlag ? deviceGyroSample.z * 57.2957795f * self->_gyroSensitivity : 0,
                                                            self->_gyroEnabledFlag ? deviceGyroSample.y * -57.2957795f * self->_gyroSensitivity : 0);
                                break;
                            case UIInterfaceOrientationPortraitUpsideDown:
                                LiSendControllerMotionEvent((uint8_t)voidController.controllerNumber,
                                                            LI_MOTION_TYPE_GYRO,
                                                            self->_gyroEnabledFlag ? deviceGyroSample.x * -57.2957795f * self->_gyroSensitivity : 0,
                                                            self->_gyroEnabledFlag ? deviceGyroSample.z * 57.2957795f * self->_gyroSensitivity : 0,
                                                            self->_gyroEnabledFlag ? deviceGyroSample.y * 57.2957795f * self->_gyroSensitivity : 0);
                                break;
                            default:
                                LiSendControllerMotionEvent((uint8_t)voidController.controllerNumber,
                                                            LI_MOTION_TYPE_GYRO,
                                                            self->_gyroEnabledFlag ? deviceGyroSample.y * 57.2957795f * self->_gyroSensitivity : 0,
                                                            self->_gyroEnabledFlag ? deviceGyroSample.z * 57.2957795f * self->_gyroSensitivity : 0,
                                                            self->_gyroEnabledFlag ? deviceGyroSample.x * 57.2957795f * self->_gyroSensitivity : 0);
                                break;
                        }
                        
                        /*
                        if(UIApplication.sharedApplication.windows.firstObject.windowScene.interfaceOrientation == 4){//check for landscape left or landscape right
                            LiSendControllerMotionEvent((uint8_t)voidController.controllerNumber,
                                                        LI_MOTION_TYPE_GYRO,
                                                        self->_gyroEnabledFlag ? deviceGyroSample.y * 57.2957795f * self->_gyroSensitivity : 0,
                                                        self->_gyroEnabledFlag ? deviceGyroSample.z * 57.2957795f * self->_gyroSensitivity : 0,
                                                        self->_gyroEnabledFlag ? deviceGyroSample.x * 57.2957795f * self->_gyroSensitivity : 0);
                        }
                        else{
                            LiSendControllerMotionEvent((uint8_t)voidController.controllerNumber,
                                                        LI_MOTION_TYPE_GYRO,
                                                        self->_gyroEnabledFlag ? deviceGyroSample.y * -57.2957795f * self->_gyroSensitivity : 0,
                                                        self->_gyroEnabledFlag ? deviceGyroSample.z * 57.2957795f * self->_gyroSensitivity : 0,
                                                        self->_gyroEnabledFlag ? deviceGyroSample.x * -57.2957795f * self->_gyroSensitivity : 0);
                        }
                        */
                    }];
                    break;
                }
            }
        }
        
#endif
        else{
            // NSLog(@"controller obj timer update: controller timer ");
            if (@available(iOS 14.0, *)) {
                switch (motionType) {
                    case LI_MOTION_TYPE_ACCEL:
                        [voidController.accelTimer invalidate];
                        voidController.accelTimer = nil;
                        
                        // if (voidController.reportRateHz && voidController.gamepad.motion.hasGravityAndUserAcceleration) {
                        if (voidController.reportRateHz) {
                            // Reset the last motion sample
                            GCAcceleration emptyAccelSample = {};
                            voidController.lastAccelSample = emptyAccelSample;
                            void (^setupAccelTimer)(void) = ^{
                                voidController.hasAccelerometer = YES;
                                voidController.accelTimer =
                                [NSTimer scheduledTimerWithTimeInterval:1.0 / voidController.reportRateHz
                                                                repeats:YES
                                                                  block:^(NSTimer *timer) {
                                    GCAcceleration lastAccelSample = voidController.lastAccelSample;
                                    GCAcceleration accelSample = voidController.gamepad.motion.acceleration;
                                    if (memcmp(&accelSample, &lastAccelSample, sizeof(accelSample)) == 0) {
                                        return;
                                    }
                                    // NSLog(@"sending controller accel %f", CACurrentMediaTime());
                                    
                                    voidController.lastAccelSample = accelSample;
                                    
                                    LiSendControllerMotionEvent((uint8_t)voidController.controllerNumber,
                                                                LI_MOTION_TYPE_ACCEL,
                                                                accelSample.x * -9.80665f,
                                                                accelSample.y * -9.80665f,
                                                                accelSample.z * -9.80665f);
                                }];
                            };
                            if ([NSThread isMainThread]) {
                                setupAccelTimer();
                            } else {
                                dispatch_async(dispatch_get_main_queue(), setupAccelTimer);
                            }
                        }
                        break;
                        
                    case LI_MOTION_TYPE_GYRO:
                        [voidController.gyroTimer invalidate];
                        voidController.gyroTimer = nil;
                        
                        if (voidController.reportRateHz && voidController.gamepad.motion.hasRotationRate) {
                            // Reset the last motion sample
                            GCRotationRate emptyGyroSample = {};
                            voidController.lastGyroSample = emptyGyroSample;
                            //dispatch_sync(dispatch_get_main_queue(), ^{
                            void (^setupGyroTimer)(void) = ^{
                                voidController.hasGyroscope = YES;
                                voidController.gyroTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / voidController.reportRateHz repeats:YES block:^(NSTimer *timer) {
                                    // Don't send duplicate samples
                                    GCRotationRate lastGyroSample = voidController.lastGyroSample;
                                    GCRotationRate gyroSample = voidController.gamepad.motion.rotationRate;
                                    if (memcmp(&gyroSample, &lastGyroSample, sizeof(gyroSample)) == 0) {
                                        return;
                                    }
                                    voidController.lastGyroSample = gyroSample;
                                    
                                    // Convert rad/s to deg/s
                                    // NSLog(@"sending controller gyro data, gyroSample data 00: %f, playerIndex: %ld, obj: %@",gyroSample.x, (long)voidController.gamepad.playerIndex, voidController);
                                    LiSendControllerMotionEvent((uint8_t)voidController.controllerNumber,
                                                                LI_MOTION_TYPE_GYRO,
                                                                self->_gyroEnabledFlag ? gyroSample.x * 57.2957795f * self->_gyroSensitivity : 0,
                                                                self->_gyroEnabledFlag ? gyroSample.z * 57.2957795f * self->_gyroSensitivity : 0,
                                                                self->_gyroEnabledFlag ? gyroSample.y * -57.2957795f * self->_gyroSensitivity : 0);
                                }];
                            };
                            if ([NSThread isMainThread]) setupGyroTimer();
                            else dispatch_async(dispatch_get_main_queue(), setupGyroTimer);
                        }
                        break;
                }
            }
        }
    }
    
    NSLog(@"controller obj timer, motionTypes: %lu", (unsigned long)voidController.motionTypes.count);

    // Set the motion sensor state if they require manual activation
    [self updateSensorSateForController:voidController];
    // NSLog(@"sensor active: %d", voidController.gamepad.motion.sensorsActive);
}

- (void)updateSensorSateForController:(VoidController* )voidController{
    if (@available(iOS 14.0, *)) {
        if (voidController.gamepad.motion.sensorsRequireManualActivation) {
            if ((voidController.hasGyroscope || voidController.hasAccelerometer) && _gyroMode != GyroModeOff) {
                voidController.gamepad.motion.sensorsActive = YES;
            }
            else {
                voidController.gamepad.motion.sensorsActive = NO;
            }
        }
    }
}

- (void) setMotionEventState:(uint16_t)controllerNumber motionType:(uint8_t)motionType reportRateHz:(uint16_t)reportRateHz {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setMotionEventState:controllerNumber motionType:motionType reportRateHz:reportRateHz];
        });
        return;
    }

    //if (@available(iOS 14.0, tvOS 14.0, *)) {
        NSLog(@"gyroMode: %ld", (long)_gyroMode);
        
        VoidController* voidController = [_voidControllers objectForKey:[NSNumber numberWithInteger:controllerNumber]];
        //using device motion
        if (voidController == nil || _gyroMode == AlwaysDevice) {
            // No connected controller for this player, use the _oscController instead
            voidController = _oscController;
            if(!voidController.motionTypes){
                voidController.motionTypes = [[NSMutableSet alloc] init];
            }
            if (reportRateHz == 0) {
                [voidController.motionTypes removeObject:@(motionType)];
            }
            else {
                [voidController.motionTypes addObject:@(motionType)];
            }
            
            voidController.hasGyroscope = NO;
            voidController.hasAccelerometer = NO;
        }
        
        voidController.reportRateHz = reportRateHz;
        voidController.controllerNumber = controllerNumber;

        if (reportRateHz == 0) {
            [self stopTimerForController:voidController];
        }
        else if(voidController == _oscController) {
            [self updateTimerStateForController:voidController];
        }
    //}
}

-(void) setControllerLed:(uint16_t)controllerNumber r:(uint8_t)r g:(uint8_t)g b:(uint8_t)b {
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        VoidController* controller = [_voidControllers objectForKey:[NSNumber numberWithInteger:controllerNumber]];
        if (controller == nil) {
            // No connected controller for this player
            return;
        }
        
        if (controller.gamepad.light == nil) {
            // No LED control supported for this controller
            return;
        }
        
        controller.gamepad.light.color = [[GCColor alloc] initWithRed:(r / 255.0f) green:(g / 255.0f) blue:(b / 255.0f)];
    }
}

-(void) setAdaptiveTriggers:(uint16_t)controllerNumber eventFlags:(uint8_t)eventFlags
                    typeLeft:(uint8_t)typeLeft typeRight:(uint8_t)typeRight
                        left:(const uint8_t*)left right:(const uint8_t*)right {
    char leftPayload[DS_EFFECT_PAYLOAD_SIZE * 3] = {0};
    char rightPayload[DS_EFFECT_PAYLOAD_SIZE * 3] = {0};

    for (int i = 0; i < DS_EFFECT_PAYLOAD_SIZE; i++) {
        snprintf(leftPayload + (i * 3), sizeof(leftPayload) - (i * 3),
                 i == DS_EFFECT_PAYLOAD_SIZE - 1 ? "%02X" : "%02X ", left[i]);
        snprintf(rightPayload + (i * 3), sizeof(rightPayload) - (i * 3),
                 i == DS_EFFECT_PAYLOAD_SIZE - 1 ? "%02X" : "%02X ", right[i]);
    }


    Log(LOG_I, @"Adaptive trigger: controller=%u flags=0x%02X "
                "leftType=0x%02X left=[%s] rightType=0x%02X right=[%s]",
        controllerNumber, eventFlags,
        typeLeft, leftPayload, typeRight, rightPayload);


    VL_ADAPTIVE_TRIGGER_EFFECT leftEffect = DecodeAdaptiveTriggerEffect(typeLeft, left);
    VL_ADAPTIVE_TRIGGER_EFFECT rightEffect = DecodeAdaptiveTriggerEffect(typeRight, right);
    bool applyLeft = (eventFlags & DS_EFFECT_LEFT_TRIGGER) != 0;
    bool applyRight = (eventFlags & DS_EFFECT_RIGHT_TRIGGER) != 0;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (@available(iOS 14.5, tvOS 14.5, *)) {
            VoidController* controller = [self->_voidControllers objectForKey:@(controllerNumber)];
            if (controller == nil) {
                Log(LOG_W, @"Ignoring adaptive trigger effect for missing gamepad %u", controllerNumber);
                return;
            }

            if (![controller.gamepad.extendedGamepad isKindOfClass:[GCDualSenseGamepad class]]) {
                Log(LOG_W, @"Ignoring adaptive trigger effect for non-DualSense gamepad %u", controllerNumber);
                return;
            }

            GCDualSenseGamepad* dualSense = (GCDualSenseGamepad*)controller.gamepad.extendedGamepad;
            if (applyLeft) {
                ApplyAdaptiveTriggerEffect(dualSense.leftTrigger, leftEffect);
            }
            if (applyRight) {
                ApplyAdaptiveTriggerEffect(dualSense.rightTrigger, rightEffect);
            }
        }
    });
}

-(void) renderDualSenseHaptics:(uint16_t)controllerNumber
                 leftAmplitude:(float)leftAmplitude
                 leftSharpness:(float)leftSharpness
                 leftTransient:(float)leftTransient
                rightAmplitude:(float)rightAmplitude
                rightSharpness:(float)rightSharpness
                rightTransient:(float)rightTransient
                   delaySeconds:(double)delaySeconds {
    __block uint64_t generation;
    @synchronized(self) {
        generation = _authoredHapticsGeneration;
    }
    dispatch_block_t renderBlock = ^{
        @synchronized(self) {
            if (generation != self->_authoredHapticsGeneration) {
                return;
            }
        }
        if (@available(iOS 14.5, tvOS 14.5, *)) {
            VoidController* controller = [self->_voidControllers objectForKey:@(controllerNumber)];
            if (controller == nil ||
                ![controller.gamepad.extendedGamepad isKindOfClass:[GCDualSenseGamepad class]]) {
                return;
            }

            [controller.lowFreqMotor setAuthoredAmplitude:leftAmplitude
                                                sharpness:leftSharpness
                                        transientStrength:leftTransient];
            [controller.highFreqMotor setAuthoredAmplitude:rightAmplitude
                                                 sharpness:rightSharpness
                                         transientStrength:rightTransient];
        }
    };

    if (delaySeconds > 0.0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySeconds * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), renderBlock);
    }
    else {
        dispatch_async(dispatch_get_main_queue(), renderBlock);
    }
}

-(BOOL) hasDualSenseController:(uint16_t)controllerNumber {
    __block BOOL result = NO;
    dispatch_block_t checkBlock = ^{
        if (@available(iOS 14.5, tvOS 14.5, *)) {
            VoidController* controller = [self->_voidControllers objectForKey:@(controllerNumber)];
            result = controller != nil &&
                [controller.gamepad.extendedGamepad isKindOfClass:[GCDualSenseGamepad class]];
        }
    };

    if ([NSThread isMainThread]) {
        checkBlock();
    }
    else {
        dispatch_sync(dispatch_get_main_queue(), checkBlock);
    }
    return result;
}

-(void) renderDeviceDualSenseHaptics:(uint16_t)controllerNumber
                        leftAmplitude:(float)leftAmplitude
                        leftSharpness:(float)leftSharpness
                        leftTransient:(float)leftTransient
                       rightAmplitude:(float)rightAmplitude
                       rightSharpness:(float)rightSharpness
                       rightTransient:(float)rightTransient
                          delaySeconds:(double)delaySeconds {
    __block uint64_t generation;
    @synchronized(self) {
        generation = _authoredHapticsGeneration;
    }
    dispatch_block_t renderBlock = ^{
        @synchronized(self) {
            if (generation != self->_authoredHapticsGeneration) {
                return;
            }
        }
        if (@available(iOS 14.0, tvOS 14.0, *)) {
            [self->_oscController.lowFreqMotor setAuthoredAmplitude:leftAmplitude
                                                          sharpness:leftSharpness
                                                  transientStrength:leftTransient];
            [self->_oscController.highFreqMotor setAuthoredAmplitude:rightAmplitude
                                                           sharpness:rightSharpness
                                                   transientStrength:rightTransient];
        }
    };

    if (delaySeconds > 0.0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaySeconds * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), renderBlock);
    }
    else {
        dispatch_async(dispatch_get_main_queue(), renderBlock);
    }
}

-(void) cancelScheduledDualSenseHaptics {
    @synchronized(self) {
        _authoredHapticsGeneration++;
    }
}

-(void) updateLeftStick:(VoidController*)controller x:(short)x y:(short)y
{
    @synchronized(controller) {
        controller.lastLeftStickX = x;
        controller.lastLeftStickY = y;
    }
}

-(void) updateRightStick:(VoidController*)controller x:(short)x y:(short)y
{
    @synchronized(controller) {
        controller.lastRightStickX = x;
        controller.lastRightStickY = y;
    }
}

-(void) updateLeftTrigger:(VoidController*)controller left:(unsigned char)left
{
    @synchronized(controller) {
        controller.lastLeftTrigger = left;
    }
}

-(void) updateRightTrigger:(VoidController*)controller right:(unsigned char)right
{
    @synchronized(controller) {
        controller.lastRightTrigger = right;
    }
}

-(void) updateTriggers:(VoidController*) controller left:(unsigned char)left right:(unsigned char)right
{
    @synchronized(controller) {
        controller.lastLeftTrigger = left;
        controller.lastRightTrigger = right;
    }
}

-(void) handleSpecialCombosReleased:(VoidController*)controller releasedButtons:(int)releasedButtons
{
    if ((controller.emulatingButtonFlags & EMULATING_SELECT) && (releasedButtons & (LB_FLAG | PLAY_FLAG))) {
        controller.lastButtonFlags &= ~BACK_FLAG;
        controller.emulatingButtonFlags &= ~EMULATING_SELECT;
    }
    
    if (controller.emulatingButtonFlags & EMULATING_SPECIAL) {
        // If Select is emulated, we use RB+Start to emulate special, otherwise we use Start+Select
        if (controller.supportedEmulationFlags & EMULATING_SELECT) {
            if (releasedButtons & (RB_FLAG | PLAY_FLAG)) {
                controller.lastButtonFlags &= ~SPECIAL_FLAG;
                controller.emulatingButtonFlags &= ~EMULATING_SPECIAL;
            }
        }
        else {
            if (releasedButtons & (BACK_FLAG | PLAY_FLAG)) {
                controller.lastButtonFlags &= ~SPECIAL_FLAG;
                controller.emulatingButtonFlags &= ~EMULATING_SPECIAL;
            }
        }
    }
}

-(void) handleSpecialCombosPressed:(VoidController*)controller pressedButtons:(int)pressedButtons
{
    // Special button combos for select and special
    if (controller.lastButtonFlags & PLAY_FLAG) {
        // If LB and start are down, trigger select
        if (controller.lastButtonFlags & LB_FLAG) {
            if (controller.supportedEmulationFlags & EMULATING_SELECT) {
                controller.lastButtonFlags |= BACK_FLAG;
                controller.lastButtonFlags &= ~(pressedButtons & (PLAY_FLAG | LB_FLAG));
                controller.emulatingButtonFlags |= EMULATING_SELECT;
            }
        }
        else if (controller.supportedEmulationFlags & EMULATING_SPECIAL) {
            // If Select is emulated too, use RB+Start to emulate special
            if (controller.supportedEmulationFlags & EMULATING_SELECT) {
                if (controller.lastButtonFlags & RB_FLAG) {
                    controller.lastButtonFlags |= SPECIAL_FLAG;
                    controller.lastButtonFlags &= ~(pressedButtons & (PLAY_FLAG | RB_FLAG));
                    controller.emulatingButtonFlags |= EMULATING_SPECIAL;
                }
            }
            else {
                // If Select is physical, use Start+Select to emulate special
                if (controller.lastButtonFlags & BACK_FLAG) {
                    controller.lastButtonFlags |= SPECIAL_FLAG;
                    controller.lastButtonFlags &= ~(pressedButtons & (PLAY_FLAG | BACK_FLAG));
                    controller.emulatingButtonFlags |= EMULATING_SPECIAL;
                }
            }
        }
    }
}

-(void) updateButtonFlags:(VoidController*)controller flags:(int)flags
{
    @synchronized(controller) {
        controller.lastButtonFlags = flags;
        
        // This must be called before handleSpecialCombosPressed
        // because we clear the original button flags there
        int releasedButtons = (controller.lastButtonFlags ^ flags) & ~flags;
        int pressedButtons = (controller.lastButtonFlags ^ flags) & flags;
        
        [self handleSpecialCombosReleased:controller releasedButtons:releasedButtons];
        
        [self handleSpecialCombosPressed:controller pressedButtons:pressedButtons];
    }
}

-(void) setButtonFlag:(VoidController*)controller flags:(int)flags
{
    @synchronized(controller) {
        controller.lastButtonFlags |= flags;
        [self handleSpecialCombosPressed:controller pressedButtons:flags];
    }
}

-(void) clearButtonFlag:(VoidController*)controller flags:(int)flags
{
    @synchronized(controller) {
        controller.lastButtonFlags &= ~flags;
        [self handleSpecialCombosReleased:controller releasedButtons:flags];
    }
}

-(uint16_t) getActiveGamepadMask
{
    return (_multiController ? _controllerNumbers : 1) | (_oscEnabled ? 1 : 0);
}

-(void) updateFinished:(VoidController*)controller
{
    BOOL exitRequested = NO;
    
    [_controllerStreamLock lock];
    @synchronized(controller) {
        // Handle Start+Select+L1+R1 gamepad quit combo
        if (controller.lastButtonFlags == (PLAY_FLAG | BACK_FLAG | LB_FLAG | RB_FLAG)) {
            controller.lastButtonFlags = 0;
            exitRequested = YES;
        }
        
        // Only send controller events if we successfully reported controller arrival
        if ([self reportControllerArrival:controller]) {
            uint32_t buttonFlags = controller.lastButtonFlags;
            uint8_t leftTrigger = controller.lastLeftTrigger;
            uint8_t rightTrigger = controller.lastRightTrigger;
            int16_t leftStickX = controller.lastLeftStickX;
            int16_t leftStickY = controller.lastLeftStickY;
            int16_t rightStickX = controller.lastRightStickX;
            int16_t rightStickY = controller.lastRightStickY;
            
            // If this is merged with another controller, combine the inputs
            if (controller.mergedWithController) {
                buttonFlags |= controller.mergedWithController.lastButtonFlags;
                leftTrigger = MAX(leftTrigger, controller.mergedWithController.lastLeftTrigger);
                rightTrigger = MAX(rightTrigger, controller.mergedWithController.lastRightTrigger);
                leftStickX = MAX_MAGNITUDE(leftStickX, controller.mergedWithController.lastLeftStickX);
                leftStickY = MAX_MAGNITUDE(leftStickY, controller.mergedWithController.lastLeftStickY);
                rightStickX = MAX_MAGNITUDE(rightStickX, controller.mergedWithController.lastRightStickX);
                rightStickY = MAX_MAGNITUDE(rightStickY, controller.mergedWithController.lastRightStickY);
            }
            
            //NSLog(@"gamepadMask: %@", [self binaryRepresentationOfInteger:buttonFlags]); // we got the pressed OSC buttons here.
            
            // Player 0 is always present for OSC
            LiSendMultiControllerEvent(_multiController ? controller.playerIndex : 0, [self getActiveGamepadMask],
                                       buttonFlags, leftTrigger, rightTrigger,
                                       leftStickX, leftStickY, rightStickX, rightStickY);
        }
    }
    [_controllerStreamLock unlock];
    
    if (exitRequested) {
        // Invoke the delegate callback on the main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_delegate streamExitRequested];
        });
    }
}


- (NSString *)binaryRepresentationOfInteger:(int)number {
    NSMutableString *binaryString = [NSMutableString string];
    int numBits = sizeof(number) * 8;

    for (int i = numBits - 1; i >= 0; i--) {
        [binaryString appendString:((number >> i) & 1) ? @"1" : @"0"];
    }

    return binaryString;
}


+(BOOL) hasKeyboardOrMouse {
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        return GCMouse.mice.count > 0 || GCKeyboard.coalescedKeyboard != nil;
    }
    else {
        return NO;
    }
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

-(void) unregisterControllerCallbacks:(GCController*) controller
{
    if (controller != NULL) {
        controller.controllerPausedHandler = NULL;
        
        if (controller.extendedGamepad != NULL) {
            // Re-enable system gestures on the gamepad buttons now
            if (@available(iOS 14.0, tvOS 14.0, *)) {
                for (GCControllerElement* element in controller.physicalInputProfile.allElements) {
                    element.preferredSystemGestureState = GCSystemGestureStateEnabled;
                }
            }
            
            controller.extendedGamepad.valueChangedHandler = NULL;
        }
    }
}

-(void) initializeControllerHaptics:(VoidController*) controller
{
    controller.lowFreqMotor = [HapticContext createContextForLowFreqMotor:controller.gamepad];
    controller.highFreqMotor = [HapticContext createContextForHighFreqMotor:controller.gamepad];
    controller.leftTriggerMotor = [HapticContext createContextForLeftTrigger:controller.gamepad];
    controller.rightTriggerMotor = [HapticContext createContextForRightTrigger:controller.gamepad];
}

-(void) cleanupControllerHaptics:(VoidController*) controller
{
    if (@available(iOS 14.5, tvOS 14.5, *)) {
        if ([controller.gamepad.extendedGamepad isKindOfClass:[GCDualSenseGamepad class]]) {
            GCDualSenseGamepad* dualSense = (GCDualSenseGamepad*)controller.gamepad.extendedGamepad;
            [dualSense.leftTrigger setModeOff];
            [dualSense.rightTrigger setModeOff];
        }
    }

    [controller.lowFreqMotor cleanup];
    [controller.highFreqMotor cleanup];
    [controller.leftTriggerMotor cleanup];
    [controller.rightTriggerMotor cleanup];
}

-(void) cleanupControllerMotion:(VoidController*) controller
{
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        // Stop sensor sampling timers
        [controller.gyroTimer invalidate];
        [controller.accelTimer invalidate];
        
        // Disable motion sensors if they require manual activation
        if (controller.gamepad && controller.gamepad.motion && controller.gamepad.motion.sensorsRequireManualActivation) {
            controller.gamepad.motion.sensorsActive = NO;
        }
    }
}

-(void) initializeControllerBattery:(VoidController*) controller
{
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        if (controller.gamepad.battery) {
            // Poll for updated battery status every 30 seconds
            controller.batteryTimer = [NSTimer scheduledTimerWithTimeInterval:30 repeats:YES block:^(NSTimer *timer) {
                if ((GCDeviceBatteryState)controller.lastBatteryState != controller.gamepad.battery.batteryState ||
                    controller.lastBatteryLevel != controller.gamepad.battery.batteryLevel) {
                    uint8_t batteryState;
                    
                    switch (controller.gamepad.battery.batteryState) {
                        case GCDeviceBatteryStateFull:
                            batteryState = LI_BATTERY_STATE_FULL;
                            break;
                        case GCDeviceBatteryStateCharging:
                            batteryState = LI_BATTERY_STATE_CHARGING;
                            break;
                        case GCDeviceBatteryStateDischarging:
                            batteryState = LI_BATTERY_STATE_DISCHARGING;
                            break;
                        case GCDeviceBatteryStateUnknown:
                        default:
                            batteryState = LI_BATTERY_STATE_UNKNOWN;
                            break;
                    }
                    
                    LiSendControllerBatteryEvent(controller.playerIndex, batteryState, (uint8_t)(controller.gamepad.battery.batteryLevel * 100));
                    
                    controller.lastBatteryState = (ControllerDeviceBatteryState)controller.gamepad.battery.batteryState;
                    controller.lastBatteryLevel = controller.gamepad.battery.batteryLevel;
                }
            }];
            
            // Fire the timer immediately to send the initial battery state
            [controller.batteryTimer fire];
        }
    }
}

-(void) cleanupControllerBattery:(VoidController*) controller
{
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        [controller.batteryTimer invalidate];
    }
}

-(BOOL) reportControllerArrival:(VoidController*) voidController
{
    // Only report arrival once
    if (voidController.reportedArrival) {
        return YES;
    }
    
    /*
    for(OnScreenWidgetView* widget in OnScreenWidgetView.mapping.allValues) {
        if(widget.isFolder && widget.parentSequence<0 && widget.autoDockIdleDuration>0) {
            [widget restartAutoDockCountdown];
        }
    }
     */
    
    uint8_t type = LI_CTYPE_UNKNOWN;
    uint16_t capabilities = 0;
    uint32_t supportedButtonFlags = 0;
    
    GCController *controller = voidController.gamepad;
    if (controller) {
        // This is a physical controller with a corresponding GCController object
        
        [_delegate controllerArrivalWithPlayerIndex:voidController.playerIndex];
        
        // Start is always present
        supportedButtonFlags |= PLAY_FLAG;
        
        // Detect buttons present in the GCExtendedGamepad profile
        if (controller.extendedGamepad.dpad) {
            supportedButtonFlags |= UP_FLAG | DOWN_FLAG | LEFT_FLAG | RIGHT_FLAG;
        }
        if (controller.extendedGamepad.leftShoulder) {
            supportedButtonFlags |= LB_FLAG;
        }
        if (controller.extendedGamepad.rightShoulder) {
            supportedButtonFlags |= RB_FLAG;
        }
        if (@available(iOS 13.0, tvOS 13.0, *)) {
            if (controller.extendedGamepad.buttonOptions) {
                supportedButtonFlags |= BACK_FLAG;
            }
        }
        if (@available(iOS 14.0, tvOS 14.0, *)) {
            if (controller.extendedGamepad.buttonHome) {
                supportedButtonFlags |= SPECIAL_FLAG;
            }
        }
        if (controller.extendedGamepad.buttonA) {
            supportedButtonFlags |= A_FLAG;
        }
        if (controller.extendedGamepad.buttonB) {
            supportedButtonFlags |= B_FLAG;
        }
        if (controller.extendedGamepad.buttonX) {
            supportedButtonFlags |= X_FLAG;
        }
        if (controller.extendedGamepad.buttonY) {
            supportedButtonFlags |= Y_FLAG;
        }
        if (@available(iOS 12.1, tvOS 12.1, *)) {
            if (controller.extendedGamepad.leftThumbstickButton) {
                supportedButtonFlags |= LS_CLK_FLAG;
            }
            if (controller.extendedGamepad.rightThumbstickButton) {
                supportedButtonFlags |= RS_CLK_FLAG;
            }
        }
        
        if (@available(iOS 14.0, tvOS 14.0, *)) {
            // Xbox One/Series controller
            if (controller.physicalInputProfile.buttons[GCInputXboxPaddleOne]) {
                supportedButtonFlags |= PADDLE1_FLAG;
            }
            if (controller.physicalInputProfile.buttons[GCInputXboxPaddleTwo]) {
                supportedButtonFlags |= PADDLE2_FLAG;
            }
            if (controller.physicalInputProfile.buttons[GCInputXboxPaddleThree]) {
                supportedButtonFlags |= PADDLE3_FLAG;
            }
            if (controller.physicalInputProfile.buttons[GCInputXboxPaddleFour]) {
                supportedButtonFlags |= PADDLE4_FLAG;
            }
            if (@available(iOS 15.0, tvOS 15.0, *)) {
                if (controller.physicalInputProfile.buttons[GCInputButtonShare]) {
                    supportedButtonFlags |= MISC_FLAG;
                }
            }
            
            // DualShock/DualSense controller
            if (controller.physicalInputProfile.buttons[GCInputDualShockTouchpadButton]) {
                supportedButtonFlags |= TOUCHPAD_FLAG;
            }
            if (controller.physicalInputProfile.dpads[GCInputDualShockTouchpadOne]) {
                capabilities |= LI_CCAP_TOUCHPAD;
            }
            
            // LI_CTYPE_UNKNOWN for option "Both"
            if(voidController.playerIndex == 0){
                type = _streamConfig.emulatedControllerType == ControllerEmulationXboxAndPs ? LI_CTYPE_PS : _streamConfig.emulatedControllerType;
                if(type == ControllerEmulationPsEnhancedHaptic) type = ControllerEmulationPs;
            }
            
            if(voidController.playerIndex == 1 && _streamConfig.emulatedControllerType == LI_CTYPE_UNKNOWN){
                type = LI_CTYPE_XBOX;
            }
            
            if(voidController.playerIndex >= 1 && _streamConfig.emulatedControllerType != LI_CTYPE_UNKNOWN){
                if ([controller.extendedGamepad isKindOfClass:[GCXboxGamepad class]]) {
                    type = LI_CTYPE_XBOX;
                }
                if ([controller.extendedGamepad isKindOfClass:[GCDualShockGamepad class]]) {
                    type = LI_CTYPE_PS;
                }
                
                if (@available(iOS 14.5, tvOS 14.5, *)) {
                    if ([controller.extendedGamepad isKindOfClass:[GCDualSenseGamepad class]]) {
                        type = LI_CTYPE_PS;
                        capabilities |= LI_CCAP_DS5_HAPTICS_PCM;
                    }
                }
            }
                        
#if !TARGET_OS_TV
            if ([_kishiRumbler isTargetController:controller]) {
                capabilities |= LI_CCAP_RUMBLE;
            }
#endif
            // Detect supported haptics localities
            if (controller.haptics) {
                if ([controller.haptics.supportedLocalities containsObject:GCHapticsLocalityHandles]) {
                    capabilities |= LI_CCAP_RUMBLE;
                }
                if ([controller.haptics.supportedLocalities containsObject:GCHapticsLocalityTriggers]) {
                    capabilities |= LI_CCAP_TRIGGER_RUMBLE;
                }
            }
            
            // Detect supported motion sensors
            if (controller.motion) {
                if (controller.motion.hasGravityAndUserAcceleration) {
                    capabilities |= LI_CCAP_ACCEL;
                }
                if (controller.motion.hasRotationRate) {
                    capabilities |= LI_CCAP_GYRO;
                }
            }

            
            
            // Detect RGB LED support
            if (controller.light) {
                capabilities |= LI_CCAP_RGB_LED;
            }
            
            // Detect battery support
            if (controller.battery) {
                capabilities |= LI_CCAP_BATTERY_STATE;
            }
            
            bool controllerLacksGyro = (capabilities & LI_CCAP_GYRO) == 0;
            if((_streamConfig.emulatedControllerType == ControllerEmulationPs || _streamConfig.emulatedControllerType == ControllerEmulationPsEnhancedHaptic)
               && (_gyroMode == AlwaysDevice || (_gyroMode == GyroModeAuto && controllerLacksGyro)))
            {
                type = LI_CTYPE_PS;
                capabilities |= LI_CCAP_GYRO | LI_CCAP_ACCEL;
            }
        }
    }
    else {
        // This is a virtual controller corresponding to our OSC
        // set osc to PS to utilize built-in gyro when "both" is selected
        type = _streamConfig.emulatedControllerType == LI_CTYPE_UNKNOWN ? LI_CTYPE_PS : _streamConfig.emulatedControllerType;
        if(type == ControllerEmulationPsEnhancedHaptic) type = LI_CTYPE_PS;
        /*
        if (_streamConfig.gyroMode != GyroModeOff) {
            type = LI_CTYPE_PS;
            capabilities = LI_CCAP_GYRO | LI_CCAP_ACCEL;
        }
        else {
            type = LI_CTYPE_XBOX;
            capabilities = 0;
        }
         */


        // Set the standard supported buttons for the virtual controller.
        supportedButtonFlags =
            PLAY_FLAG | BACK_FLAG | UP_FLAG | DOWN_FLAG | LEFT_FLAG | RIGHT_FLAG |
            LB_FLAG | RB_FLAG | LS_CLK_FLAG | RS_CLK_FLAG | A_FLAG | B_FLAG | X_FLAG | Y_FLAG;
    }

    // Report the new controller to the host
    // NB: This will fail if the connection hasn't been fully established yet
    // and we will try again later.
    if (LiSendControllerArrivalEvent(controller.playerIndex,
                                     [self getActiveGamepadMask],
                                     type,
                                     supportedButtonFlags,
                                     capabilities) != 0) {
        return NO;
    }
    
    // Begin polling for battery status
    [self initializeControllerBattery:voidController];
    
    // Remember that we've reported arrival already
    voidController.reportedArrival = YES;
    return YES;
}

-(void) handleControllerTouchpad:(VoidController*)controller touch:(GCControllerDirectionPad*)touch index:(int)index
{
    controller_touch_context_t context = index == 0 ? controller.primaryTouch : controller.secondaryTouch;
    
    // This magic is courtesy of SDL
    float normalizedX = (1.0f + touch.xAxis.value) * 0.5f;
    float normalizedY = 1.0f - (1.0f + touch.yAxis.value) * 0.5f;
    
    // If we went from a touch to no touch, generate a touch up event
    if ((context.lastX || context.lastY) && (!touch.xAxis.value && !touch.yAxis.value)) {
        LiSendControllerTouchEvent(controller.playerIndex, LI_TOUCH_EVENT_UP, index, normalizedX, normalizedY, 1.0f);
    }
    else if (touch.xAxis.value || touch.yAxis.value) {
        // If we went from no touch to a touch, generate a touch down event
        if (!context.lastX && !context.lastY) {
            LiSendControllerTouchEvent(controller.playerIndex, LI_TOUCH_EVENT_DOWN, index, normalizedX, normalizedY, 1.0f);
        }
        else if (context.lastX != touch.xAxis.value || context.lastY != touch.yAxis.value) {
            // Otherwise it's just a move
            LiSendControllerTouchEvent(controller.playerIndex, LI_TOUCH_EVENT_MOVE, index, normalizedX, normalizedY, 1.0f);
        }
    }
    
    // We have to assign the whole struct because this is a property rather than a standard
    // field that we could modify through a pointer.
    if (index == 0) {
        controller.primaryTouch = (controller_touch_context_t) {
            touch.xAxis.value,
            touch.yAxis.value
        };
    }
    else {
        controller.secondaryTouch = (controller_touch_context_t) {
            touch.xAxis.value,
            touch.yAxis.value
        };
    }
}

double rc_expo(double x, double expo) {
    if (x == 0.0) return 0.0;

    double ax = fabs(x);
    double y = pow(ax, expo);

    return x > 0 ? y : -y;
}


- (bool)useMotionHandler{
    return tempSettings.gyroMode.intValue == GyroModeOff
    || tempSettings.gyroMode.intValue == AlwaysDevice;
}

- (void)switchMotionControlOnOffByControllerButton{
    self->_gyroEnabledFlag = self->_gyroEnabledFlag && self->_controllerGyroSwitchEnabled;
    if([self useMotionHandler]){
        if(self->_gyroEnabledFlag) [self->motionHandler startMotionControlByControllerButton];
        else [self->motionHandler stopMotionUpdateWithInterruptNoneGyroInput:false];
    }
    self->_gyroEnabledFlag = self->_gyroEnabledFlag || !self->_controllerGyroSwitchEnabled;
}

- (void)sendNavigationButtonPress {
    if(!ControllerUtil.primaryGCController) return;
    if(@available(iOS 13.0, *)) if(ControllerNavigator.controllerMouseEnabled) return;
    VoidController* voidController = [self->_voidControllers objectForKey:@(ControllerUtil.primaryGCController.playerIndex)];
    int radialMenuButton = ControllerElementNull;
    if (@available(iOS 13.0, *)) radialMenuButton = ControllerNavigator.radialMenuButton;
    [self setButtonFlag:voidController flags:(int)radialMenuButton];
    [self updateFinished:voidController];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.03*NSEC_PER_SEC), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self clearButtonFlag:voidController flags:radialMenuButton];
        [self updateFinished:voidController];
    });
}


- (void) listenToGCController:(GCController*) controller {
    /*
    if(self->_swapABXYButtons){
        switch (self->_controllerMouseLeftButton) {
            case ControllerElementA:
                self->_controllerMouseLeftButton = ControllerElementB;
                break;
            case ControllerElementB:
                self->_controllerMouseLeftButton = ControllerElementA;
                break;
            case ControllerElementX:
                self->_controllerMouseLeftButton = ControllerElementY;
                break;
            case ControllerElementY:
                self->_controllerMouseLeftButton = ControllerElementX;
                break;
            default:
                break;
        }
        switch (self->_controllerMouseRightButton) {
            case ControllerElementA:
                self->_controllerMouseRightButton = ControllerElementB;
                break;
            case ControllerElementB:
                self->_controllerMouseRightButton = ControllerElementA;
                break;
            case ControllerElementX:
                self->_controllerMouseRightButton = ControllerElementY;
                break;
            case ControllerElementY:
                self->_controllerMouseRightButton = ControllerElementX;
                break;
            default:
                break;
        }
    }
     */
    
    __block ControllerElement radialMenuButton = ControllerElementNull;
    __block bool controllerNavigatorEnabled = false;
    
    [ControllerUtil listenWithController:controller swapABXY:self->_swapABXYButtons handler:^(NSDictionary * elementDict, GCExtendedGamepad * gamepad, GCControllerElement * element) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
            VoidController* voidController = [self->_voidControllers objectForKey:[NSNumber numberWithInteger:gamepad.controller.playerIndex]];
            short leftStickX, leftStickY;
            short rightStickX, rightStickY;
            unsigned char leftTrigger, rightTrigger;
            
            if (@available(iOS 13.0, *)){
                radialMenuButton = ControllerNavigator.radialMenuButton;
                controllerNavigatorEnabled = ControllerNavigator.enabled;
            }
            
            for(NSNumber* elementFlagId in elementDict){
                GCControllerElement * element = (GCControllerElement *)elementDict[elementFlagId];
                if ([element isKindOfClass:[GCControllerButtonInput class]]) {
                    GCControllerButtonInput* button = (GCControllerButtonInput *)element;
                    if(controllerNavigatorEnabled && voidController.playerIndex==0 && elementFlagId.intValue == radialMenuButton){
                        if(!button.pressed){
                            // [self sendNavigationButtonPress:voidController];
                        }
                    }

                    // controller switch buttons
                    if(true){
                        if(button.pressed){
                            if (elementFlagId.intValue == self->_controllerGyroSwitchToggle
                                && !self->_controllerGyroSwitchTogglePressed) {
                                self->_controllerGyroSwitchTogglePressed = true;
                                
                                self->_gyroEnabledFlag = !self->_gyroEnabledFlag;
                                [self switchMotionControlOnOffByControllerButton];
                            }
                            if (elementFlagId.intValue == self->_controllerGyroSwitchHold
                                && !self->_controllerGyroSwitchHoldPressed) {
                                self->_controllerGyroSwitchHoldPressed = true;
                                
                                self->_gyroEnabledFlag = !self->_reverseHoldButton;
                                [self switchMotionControlOnOffByControllerButton];
                            }
                        }
                        else{
                            if (elementFlagId.intValue == self->_controllerGyroSwitchToggle
                                && self->_controllerGyroSwitchTogglePressed) {
                                self->_controllerGyroSwitchTogglePressed = false;
                            }
                            if (elementFlagId.intValue == self->_controllerGyroSwitchHold
                                && self->_controllerGyroSwitchHoldPressed) {
                                self->_controllerGyroSwitchHoldPressed = false;
                                
                                self->_gyroEnabledFlag = self->_reverseHoldButton;
                                [self switchMotionControlOnOffByControllerButton];
                            }
                        }
                    }
                    
                    if(controller != ControllerUtil.primaryGCController || elementFlagId.intValue!=radialMenuButton || !controllerNavigatorEnabled) UPDATE_BUTTON_FLAG(voidController, elementFlagId.intValue, button.pressed);
                }
            }
            
            CGFloat leftStickXRaw = gamepad.leftThumbstick.xAxis.value * self->stickMaxOffset;
            CGFloat leftStickYRaw = gamepad.leftThumbstick.yAxis.value * self->stickMaxOffset;
            
            CGFloat rightStickXRaw = gamepad.rightThumbstick.xAxis.value * self->stickMaxOffset;
            CGFloat rightStickYRaw = gamepad.rightThumbstick.yAxis.value * self->stickMaxOffset;
            
            CGVector leftStickOffset = [ControllerUtil compensatedWithOffsetVector:CGVectorMake(leftStickXRaw, leftStickYRaw) minOffset:self->_leftStickMinOffset circulate:false];
            
            CGVector rightStickOffset = [ControllerUtil compensatedWithOffsetVector:CGVectorMake(rightStickXRaw, rightStickYRaw) minOffset:self->_rightStickMinOffset circulate:false];
            
            leftStickX = leftStickOffset.dx;
            leftStickY = leftStickOffset.dy;
            
            rightStickX = rightStickOffset.dx;
            rightStickY = rightStickOffset.dy;

            /*
             if(self->oscProfile.mapGyroTo!=mapGyroToControllerStick
             ||!self->oscProfile.rollToLeftStick) [self updateLeftStick:voidController x:leftStickX y:leftStickY];
             */
            
            if([self useMotionHandler]
               && self->motionHandler.motionControlStarted
               && self->oscProfile.mapGyroTo==mapGyroToControllerStick
               && self->oscProfile.yawPitchToRightStick
               && self->_gyroEnabledFlag
               ) {
                [self->motionHandler mixPhysicalRightStickAndGyroInputWithX:rightStickX y:rightStickY];
            }
            else [self updateRightStick: voidController.playerIndex==0?self->_oscController:voidController x:rightStickX y:rightStickY];
            
            if([self useMotionHandler]
               && self->motionHandler.motionControlStarted
               && self->oscProfile.mapGyroTo==mapGyroToControllerStick
               && self->oscProfile.rollToLeftStick
               && self->_gyroEnabledFlag
               ) [self->motionHandler mixPhysicalLeftStickAndGyroInputWithX:leftStickX y:leftStickY];
            else [self updateLeftStick: voidController.playerIndex==0?self->_oscController:voidController x:leftStickX y:leftStickY];
            
            leftTrigger = gamepad.leftTrigger.value * 0xFF;
            rightTrigger = gamepad.rightTrigger.value * 0xFF;
            [self updateTriggers:voidController left:leftTrigger right:rightTrigger];
            
            [self updateFinished:voidController];
            
            if (@available(iOS 14.0, *)) {
                if (gamepad.controller.physicalInputProfile.dpads[GCInputDualShockTouchpadOne]) {
                    [self handleControllerTouchpad:voidController
                                             touch:gamepad.controller.physicalInputProfile.dpads[GCInputDualShockTouchpadOne]
                                             index:0];
                }
                if (gamepad.controller.physicalInputProfile.dpads[GCInputDualShockTouchpadTwo]) {
                    [self handleControllerTouchpad:voidController
                                             touch:gamepad.controller.physicalInputProfile.dpads[GCInputDualShockTouchpadTwo]
                                             index:1];
                }
            }
        });
    }];
}

-(void) reinitiatePrimaryController {
    if(@available(iOS 13.0, *)){
        if(ControllerNavigator.controllerMouseEnabled){
            [ControllerNavigator startControllerMouse];
            return;
        }
        if(ControllerNavigator.radialMenuView) return;
    }
    if(![StreamFrameViewController sharedInstance]) return;
    MainFrameViewController* mainFrameVC =(MainFrameViewController* )ControllerUtil.delegate;
    if(mainFrameVC.settingsExpandedInStreamView) return;
    [ControllerUtil stopListeningPrimaryControllerWithStopListenToRadialMenuButton:true];
    if (@available(iOS 13.0, *)) [ControllerNavigator listenToRadialMenuButton];
    [self listenToGCController: ControllerUtil.primaryGCController];
    if (@available(iOS 13.0, *)){
        NSLog(@"ControllerUtil setUINavigationDelegate %f",CACurrentMediaTime());
        [ControllerNavigator setStreamFrameVCAsUINavigationDelegate];
    }
}

-(void) registerControllerCallbacks:(GCController*) controller
{
    if (controller != NULL) {
        // iOS 13 allows the Start button to behave like a normal button, however
        // older MFi controllers can send an instant down+up event for the start button
        // which means the button will not be down long enough to register on the PC.
        // To work around this issue, use the old controllerPausedHandler if the controller
        // doesn't have a Select button (which indicates it probably doesn't have a proper
        // Start button either).
        BOOL useLegacyPausedHandler = YES;
        if (@available(iOS 13.0, tvOS 13.0, *)) {
            if (controller.extendedGamepad != nil &&
                controller.extendedGamepad.buttonOptions != nil) {
                useLegacyPausedHandler = NO;
            }
        }
        
        if (useLegacyPausedHandler) {
            controller.controllerPausedHandler = ^(GCController *controller) {
                VoidController* voidController = [self->_voidControllers objectForKey:[NSNumber numberWithInteger:controller.playerIndex]];
                
                // Get off the main thread
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                    [self setButtonFlag:voidController flags:PLAY_FLAG];
                    [self updateFinished:voidController];
                    
                    // Pause for 100 ms
                    usleep(100 * 1000);
                    
                    [self clearButtonFlag:voidController flags:PLAY_FLAG];
                    [self updateFinished:voidController];
                });
            };
        }
        
        if (controller.extendedGamepad != NULL) {
            // Disable system gestures on the gamepad to avoid interfering
            // with in-game controller actions
            
            if (@available(iOS 14.0, tvOS 14.0, *)) {
                for (GCControllerElement* element in controller.physicalInputProfile.allElements) {
                    element.preferredSystemGestureState = GCSystemGestureStateDisabled;
                }
            }
            
            if(controller == ControllerUtil.primaryGCController){
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1*NSEC_PER_SEC), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    [self reinitiatePrimaryController];
                });
            }
            else [self listenToGCController:controller];
        }
    } else {
        Log(LOG_W, @"Tried to register controller callbacks on NULL controller");
    }
}

-(void) unregisterMouseCallbacks:(GCMouse*)mouse API_AVAILABLE(ios(14.0)) {
    mouse.mouseInput.mouseMovedHandler = nil;
    
    mouse.mouseInput.leftButton.pressedChangedHandler = nil;
    mouse.mouseInput.middleButton.pressedChangedHandler = nil;
    mouse.mouseInput.rightButton.pressedChangedHandler = nil;
    
    for (GCControllerButtonInput* auxButton in mouse.mouseInput.auxiliaryButtons) {
        auxButton.pressedChangedHandler = nil;
    }
    
#if TARGET_OS_TV
    mouse.mouseInput.scroll.xAxis.valueChangedHandler = nil;
    mouse.mouseInput.scroll.yAxis.valueChangedHandler = nil;
#endif
}

-(void) registerMouseCallbacks:(GCMouse*) mouse API_AVAILABLE(ios(14.0)) {
    if (_captureMouse){
        mouse.mouseInput.mouseMovedHandler = ^(GCMouseInput * _Nonnull mouse, float deltaX, float deltaY) {
            self->accumulatedDeltaX += deltaX / MOUSE_SPEED_DIVISOR;
            self->accumulatedDeltaY += -deltaY / MOUSE_SPEED_DIVISOR;
            
            short truncatedDeltaX = (short)self->accumulatedDeltaX;
            short truncatedDeltaY = (short)self->accumulatedDeltaY;
            
            if (truncatedDeltaX != 0 || truncatedDeltaY != 0) {
                LiSendMouseMoveEvent(truncatedDeltaX, truncatedDeltaY);
                
                self->accumulatedDeltaX -= truncatedDeltaX;
                self->accumulatedDeltaY -= truncatedDeltaY;
            }
        };
    } else {
        mouse.mouseInput.mouseMovedHandler = nil;
    }

    
    mouse.mouseInput.leftButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        LiSendMouseButtonEvent(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_LEFT);
    };
    mouse.mouseInput.middleButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        LiSendMouseButtonEvent(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_MIDDLE);
    };
    mouse.mouseInput.rightButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        LiSendMouseButtonEvent(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
    };
    
    if (mouse.mouseInput.auxiliaryButtons != nil) {
        if (mouse.mouseInput.auxiliaryButtons.count >= 1) {
            mouse.mouseInput.auxiliaryButtons[0].pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
                LiSendMouseButtonEvent(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_X1);
            };
        }
        if (mouse.mouseInput.auxiliaryButtons.count >= 2) {
            mouse.mouseInput.auxiliaryButtons[1].pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
                LiSendMouseButtonEvent(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, BUTTON_X2);
            };
        }
    }
    
    // We use UIPanGestureRecognizer on iPadOS because it allows us to distinguish
    // between discrete and continuous scroll events and also works around a bug
    // in iPadOS 15 where discrete scroll events are dropped. tvOS only supports
    // GCMouse for mice, so we will have to just use it and hope for the best.
#if TARGET_OS_TV
    mouse.mouseInput.scroll.xAxis.valueChangedHandler = ^(GCControllerAxisInput * _Nonnull axis, float value) {
        self->accumulatedScrollX += value;
        
        short truncatedScrollX = (short)self->accumulatedScrollX;
        
        if (truncatedScrollX != 0) {
            // Direction is reversed from vertical scrolling
            LiSendHighResHScrollEvent(-truncatedScrollX * 20);
            
            self->accumulatedScrollX -= truncatedScrollX;
        }
    };
    mouse.mouseInput.scroll.yAxis.valueChangedHandler = ^(GCControllerAxisInput * _Nonnull axis, float value) {
        self->accumulatedScrollY += value;
        
        short truncatedScrollY = (short)self->accumulatedScrollY;
        
        if (truncatedScrollY != 0) {
            LiSendHighResScrollEvent(truncatedScrollY * 20);
            
            self->accumulatedScrollY -= truncatedScrollY;
        }
    };
#endif
}

-(void) updateAutoOnScreenControlMode
{
    // Auto on-screen control support may not be enabled
    if (_osc == NULL) {
        return;
    }
    
    OnScreenControlsLevel level = OnScreenControlsLevelFull;
    
    // We currently stop after the first controller we find.
    // Maybe we'll want to change that logic later.
    for (int i = 0; i < [[GCController controllers] count]; i++) {
        GCController *controller = [GCController controllers][i];
        
        if (controller != NULL) {
            if (controller.extendedGamepad != NULL) {
                level = OnScreenControlsLevelAutoGCExtendedGamepad;
                if (@available(iOS 12.1, tvOS 12.1, *)) {
                    if (controller.extendedGamepad.leftThumbstickButton != nil &&
                        controller.extendedGamepad.rightThumbstickButton != nil) {
                        level = OnScreenControlsLevelAutoGCExtendedGamepadWithStickButtons;
                        if (@available(iOS 13.0, tvOS 13.0, *)) {
                            if (controller.extendedGamepad.buttonOptions != nil) {
                                // Has L3/R3 and Select, so we can show nothing :)
                                level = OnScreenControlsLevelOff;
                            }
                        }
                    }
                }
                break;
            }
        }
    }
    
    // If we didn't find a gamepad present and we have a keyboard or mouse, turn
    // the on-screen controls off to get the overlays out of the way.
    if (level == OnScreenControlsLevelFull && [ControllerSupport hasKeyboardOrMouse]) {
        level = OnScreenControlsLevelOff;
        
        // Ensure the virtual gamepad disappears to avoid confusing some games.
        // If the mouse and keyboard disconnect later, it will reappear when the
        // first OSC input is received.
        LiSendMultiControllerEvent(0, 0, 0, 0, 0, 0, 0, 0, 0);
    }
    
    [_osc setLevel:level];
}

-(void) initAutoOnScreenControlMode:(OnScreenControls*)osc
{
    _osc = osc;
    
    [self updateAutoOnScreenControlMode];
}

-(VoidController* )controllerHasBeenAssignedDeprecated:(GCController*)controller{
    if(controller.playerIndex == 0) return nil;
    if(controller.playerIndex > 0){
            for(VoidController* voidController in _voidControllers){
                if(voidController.gamepad == controller) return voidController;
            }
    }
    return nil;
}


- (void)updateVoidController:(VoidController* )voidController withGCController:(GCController* )controller{
    //voidController.playerIndex = controller.playerIndex == -1 ? 0 : (uint8_t) controller.playerIndex;
    voidController.motionTypes = [[NSMutableSet alloc] init];
    voidController.supportedEmulationFlags = EMULATING_SPECIAL | EMULATING_SELECT;
    voidController.gamepad = controller;
#if !TARGET_OS_TV
    voidController.hardware = [_gameSirG8MFiRumbler isTargetController:controller] ? ControllerHardwareG8PlusMFi : ControllerHardwareGeneric;
#else
    voidController.hardware = ControllerHardwareGeneric;
#endif
    voidController.hasAccelerometer = NO;
    voidController.hasGyroscope = NO;

    
    if([ControllerUtil hasControllerAccelerometer:voidController.gamepad]){
        [voidController.motionTypes addObject:@(LI_MOTION_TYPE_ACCEL)];
        voidController.hasAccelerometer = YES;
        voidController.reportRateHz = 120;
    }
    if (@available(iOS 14.0, *)) {
        if(voidController.gamepad.motion.hasRotationRate) {
            [voidController.motionTypes addObject:@(LI_MOTION_TYPE_GYRO)];
            voidController.hasGyroscope = YES;
            voidController.reportRateHz = 120;
        }
    }

    // Only player 0 shares state with the OSC.
    if (voidController.playerIndex == 0) {
        voidController.mergedWithController = _oscController;
        _oscController.mergedWithController = voidController;
    }
    else {
        voidController.mergedWithController = nil;
        if (_oscController.mergedWithController == voidController) {
            _oscController.mergedWithController = nil;
        }
    }
    
    if (@available(iOS 13.0, tvOS 13.0, *)) {
        if (controller.extendedGamepad != nil &&
            controller.extendedGamepad.buttonOptions != nil) {
            // Disable select button emulation since we have a physical select button
            voidController.supportedEmulationFlags &= ~EMULATING_SELECT;
        }
    }
    
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        if (controller.extendedGamepad != nil &&
            controller.extendedGamepad.buttonHome != nil) {
            // Disable special button emulation since we have a physical special button
            voidController.supportedEmulationFlags &= ~EMULATING_SPECIAL;
        }
    }
    
    // Prepare controller haptics for use
    [self initializeControllerHaptics:voidController];
}

-(VoidController* )assignController:(GCController*)controller {
    NSLog(@"run assignController");

    bool newGCControllerArrival = ![ControllerUtil.activeStreamingGCControllers containsObject:controller];
    
    if(!newGCControllerArrival){
        VoidController* voidController = [_voidControllers objectForKey:@(controller.playerIndex)];
        if(!voidController) {
            voidController = [[VoidController alloc] init];
        }
        [self updateVoidController:voidController withGCController:controller];
        [_voidControllers setObject:voidController forKey:[NSNumber numberWithInteger:voidController.playerIndex]];
        return voidController;
    }
    
    // extenal controller start from playerIndex 1 for option "Both"
    int startPlayIndex = _streamConfig.emulatedControllerType == LI_CTYPE_UNKNOWN ? 1 : 0;
    
    for (int i = startPlayIndex; i < 4; i++) {
        if (!(_controllerNumbers & (1 << i))) {
            _controllerNumbers |= (1 << i);
            
            VoidController* voidController = [[VoidController alloc] init];


            [ControllerUtil.activeStreamingGCControllers addObject:controller];
            controller.playerIndex = i;
            voidController.playerIndex = i;
            [self updateVoidController:voidController withGCController:controller];
            
            [_voidControllers setObject:voidController forKey:[NSNumber numberWithInteger:controller.playerIndex]];
            
            Log(LOG_I, @"Assigning controller index: %d", i);
            
            return voidController;
            
        }
    }
    
    return nil;
}

-(VoidController*) getOscController {
    return _oscController;
}

+(bool) isSupportedGamepad:(GCController*) controller {
    return controller.extendedGamepad != nil;
}

#pragma clang diagnostic pop

+(int) getGamepadCount {
    int count = 0;
    
    for (GCController* controller in [GCController controllers]) {
        if ([ControllerSupport isSupportedGamepad:controller]) {
            count++;
        }
    }
    
    return count;
}

+(int) getConnectedGamepadMask:(StreamConfiguration*)streamConfig {
    int mask = 0;
    
    if (streamConfig.multiController) {
        int i = 0;
        for (GCController* controller in [GCController controllers]) {
            if ([ControllerSupport isSupportedGamepad:controller]) {
                mask |= 1 << i++;
            }
        }
    }
    else {
        // Some games don't deal with having controller reconnected
        // properly so always report controller 1 if not in MC mode
        mask = 0x1;
    }
    
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* settings = [dataMan getSettings];
    OnScreenControlsLevel level = (OnScreenControlsLevel)[settings.onscreenControls integerValue];
    
    // Even if no gamepads are present, we will always count one if OSC is enabled,
    // or it's set to auto and no keyboard or mouse is present. Absolute touch mode
    // disables the OSC.
    if (level != OnScreenControlsLevelOff && (![ControllerSupport hasKeyboardOrMouse] || level != OnScreenControlsLevelAuto) && (settings.touchMode.intValue == RelativeTouch)) {
        mask |= 0x1;
    }
    
    return mask;
}

-(NSUInteger) getConnectedGamepadCount
{
    return _voidControllers.count;
}

- (void)assignControllers{
    for (GCController* controller in [GCController controllers]) {
        NSLog(@"controller count: iterating");
        
        if ([ControllerSupport isSupportedGamepad:controller]) {
            NSLog(@"controller count: is supported,is contained by dict: %d", [ControllerUtil.activeStreamingGCControllers containsObject:controller]);
                NSLog(@"controller obj +1 in dic");
                [self assignController:controller];
                NSLog(@"controller obj num in dict: %lu", (unsigned long)_voidControllers.allValues.count);
                [self registerControllerCallbacks:controller];
            // Note: We cannot report controller arrival to the host here,
            // because the connection has not been established yet.play
        }
    }
    NSLog(@"device gyro codes,update gyroMode: %d, controller count: %lu", _gyroMode, (unsigned long)_voidControllers.count);
}

- (void)updateCommonConfig:(StreamConfiguration* )streamConfig{
    _streamConfig = streamConfig;
    _multiController = streamConfig.multiController;
    _swapABXYButtons = streamConfig.swapABXYButtons;

    _oscController.playerIndex = 0;

    oscProfile = [oscProfileMan getSelectedProfile];
    motionHandler = [MotionHandler sharedWithProfile:oscProfile];
    DataManager* dataMan = [[DataManager alloc] init];
    tempSettings = [dataMan getSettings];

    _oscEnabled = _oscEnabled || (OnScreenControlsLevel)[tempSettings.onscreenControls integerValue] != OnScreenControlsLevelOff || streamConfig.gyroMode != GyroModeOff;
    _gyroSensitivity = tempSettings.gyroSensitivity.floatValue;
    
    if (@available(iOS 13.0, *)) {
        _controllerNavigationEnabled = ControllerNavigator.enabled;
        [ControllerNavigator configureControllerMouseWith:tempSettings];
    }
    
    _controllerGyroSwitchEnabled = oscProfile.controllerGyroSwitchMode != ControllerGyroSwitchDisabled;
    _gyroSwitchMode = oscProfile.controllerGyroSwitchMode;
    // _gyroSwitchMode = ControllerGyroSwitchHoldDownToActivate;
    _controllerGyroSwitchToggle = oscProfile.controllerGyroSwitchToggle;
    _controllerGyroSwitchHold = oscProfile.controllerGyroSwitchHold;
    _reverseHoldButton = oscProfile.reverseGyroHoldButton;
    _controllerGyroSwitchTogglePressed = false;
    _controllerGyroSwitchHoldPressed = false;
    
    stickMaxOffset = 0x7FFE;
    _leftStickMinOffset = oscProfile.physicalLeftStickMinOffset;
    _rightStickMinOffset = oscProfile.physicalRightStickMinOffset;

    // if(oscProfile.controllerGyroSwitchMode == ControllerGyroSwitchDisabled && ![self useMotionHandler]) _gyroEnabledFlag = false;
    _gyroEnabledFlag = false;
    
    // if(![self useMotionHandler]) [self->motionHandler stopMotionUpdateWithInterruptNoneGyroInput:false];
    [self->motionHandler stopMotionUpdateWithInterruptNoneGyroInput:false];
}

- (void)resetGyroInputForController:(VoidController* )voidController{
    if(voidController.hasAccelerometer) LiSendControllerMotionEvent((uint8_t)voidController.controllerNumber,LI_MOTION_TYPE_ACCEL,0,0,0);
    if(voidController.hasGyroscope) LiSendControllerMotionEvent((uint8_t)voidController.controllerNumber,LI_MOTION_TYPE_GYRO,0,0,0);
    if (@available(iOS 14.0, *)) {
        voidController.gamepad.motion.sensorsActive = false;
    }
}

- (void)stopTimerForAllControllers{
    [self stopTimerForController:_oscController];
    for(VoidController* controller in _voidControllers.allValues){
        [self stopTimerForController:controller];
    }
}

- (void)updateControllerSupport:(StreamConfiguration*)streamConfig delegate:(id<ControllerSupportDelegate>)delegate {
    NSLog(@"update config call");
    
    _gyroMode = streamConfig.gyroMode;

    [self updateCommonConfig:streamConfig];
    
    Log(LOG_I, @"Number of supported controllers connected: %d", [ControllerSupport getGamepadCount]);
    Log(LOG_I, @"Multi-controller: %d", _multiController);
    
    [self applyGyroModeSetting];
    
    [self assignControllers];
    
    NSLog(@"controllerNumbers: %d", _controllerNumbers);

    for(VoidController* controller in _voidControllers.allValues){
        NSLog(@"controller obj in dict: %@", controller);
    }
    
    if([self psGyroEnabledInSetting]) [self updateFinished:_oscController];
}

-(id)initWithConfig:(StreamConfiguration*)streamConfig delegate:(id<ControllerSupportDelegate>)delegate
{
    self = [super init];
    if (self) {
        VLSharedControllerSupport = self;
    }
    
    NSLog(@"controller support init");
        
    _delegate = delegate;
    _controllerStreamLock = [[NSLock alloc] init];
    _voidControllers = [[NSMutableDictionary alloc] init];
    [ControllerUtil.activeStreamingGCControllers removeAllObjects];
    _controllerNumbers = 0;
#if !TARGET_OS_TV
    _gameSirG8MFiRumbler = [[GameSirG8MFiRumbler alloc] init];
    _kishiRumbler = [[KishiV3ProXLRumbler alloc] init];
#endif
    
    _captureMouse = (streamConfig.localMousePointerMode == 0);
    if (@available(iOS 14.0, tvOS 14.0, *)) {
            for (GCMouse* mouse in [GCMouse mice]) {
                [self registerMouseCallbacks:mouse];
            }
        }
    
    _controllerConnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidConnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
    Log(LOG_I, @"Controller connected!");
    
    GCController* controller = note.object;
    
    if (![ControllerSupport isSupportedGamepad:controller]) {
        // Ignore micro gamepads and motion controllers
        return;
    }
    
    //[self->_activeGCControllers addObject:controller];
    VoidController* voidController = [self assignController:controller];
        if (voidController) {
            // Register callbacks on the new controller
            [self registerControllerCallbacks:controller];
            
            // Report the controller arrival to the host if we're connected
            [self reportControllerArrival:voidController];
            
            // Re-evaluate the on-screen control mode
            //[self updateAutoOnScreenControlMode];
            if((self->_gyroMode == GyroModeAuto && [self externalControllersHaveGyro]) || self->_gyroMode == AlwaysController){
                [self stopTimerForController:self->_oscController];
                [self updateTimerStateForController:voidController];
            }
            
            // Notify the delegate
            [self->_delegate gamepadPresenceChanged];
        }
}];
    
    _controllerDisconnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidDisconnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        Log(LOG_I, @"Controller disconnected!");
        
        GCController* controller = note.object;
        
        if (![ControllerSupport isSupportedGamepad:controller]) {
            // Ignore micro gamepads and motion controllers
            return;
        }
        
        [self unregisterControllerCallbacks:controller];
        
        if([ControllerUtil.activeStreamingGCControllers containsObject:controller]){
            [ControllerUtil.activeStreamingGCControllers removeObject:controller];
            self->_controllerNumbers &= ~(1 << controller.playerIndex);
        }
        Log(LOG_I, @"Unassigning controller index: %ld", (long)controller.playerIndex);
        
        VoidController* voidController = [self->_voidControllers objectForKey:[NSNumber numberWithInteger:controller.playerIndex]];
        if (voidController) {
#if !TARGET_OS_TV
            if ([self->_kishiRumbler isTargetController:controller]) {
                [self->_kishiRumbler stopAndClose];
            }
            if ([self->_gameSirG8MFiRumbler isTargetController:controller]) {
                [self->_gameSirG8MFiRumbler stopAndClose];
            }
#endif
            [self stopTimerForController:voidController];
            
            // Stop haptics on this controller
            [self cleanupControllerHaptics:voidController];
            
            // Stop motion reports on this controller
            [self cleanupControllerMotion:voidController];
            
            // Stop battery reports on this controller
            [self cleanupControllerBattery:voidController];
            
            // Disassociate this controller from any controllers merged with it
            if (voidController.mergedWithController) {
                if(voidController.mergedWithController.mergedWithController == voidController) voidController.mergedWithController.mergedWithController = nil;
            }
            
            // Inform the server of the updated active gamepads before removing this controller
            [self updateFinished:voidController];
            
            // Re-evaluate the on-screen control mode
            //[self updateAutoOnScreenControlMode];
            
            [self->_voidControllers removeObjectForKey:@(controller.playerIndex)];
            
            if((self->_voidControllers.allValues.count == 0 || ![self externalControllersHaveGyro]) && self->_gyroMode == GyroModeAuto) [self updateTimerStateForController:self->_oscController];
            
            // Notify the delegate
            [self->_delegate gamepadPresenceChanged];
        }
    }];
    
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        
        _mouseConnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCMouseDidConnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            Log(LOG_I, @"Mouse connected!");
            
            GCMouse* mouse = note.object;
            
            // Register for mouse events
            [self registerMouseCallbacks: mouse];
            
            // Re-evaluate the on-screen control mode
            [self updateAutoOnScreenControlMode];
            
            // Notify the delegate
            [self->_delegate mousePresenceChanged];
            [self->_delegate mouseConnected];
        }];
        _mouseDisconnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCMouseDidDisconnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            Log(LOG_I, @"Mouse disconnected!");
            
            GCMouse* mouse = note.object;
            
            // Unregister for mouse events
            [self unregisterMouseCallbacks: mouse];
            
            // Re-evaluate the on-screen control mode
            [self updateAutoOnScreenControlMode];
            
            // Notify the delegate
            [self->_delegate mousePresenceChanged];
        }];
        _keyboardConnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCKeyboardDidConnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            Log(LOG_I, @"Keyboard connected!");
            
            [self->_delegate keyboardConnected];
            
            // Re-evaluate the on-screen control mode
            [self updateAutoOnScreenControlMode];
        }];
        _keyboardDisconnectObserver = [[NSNotificationCenter defaultCenter] addObserverForName:GCKeyboardDidDisconnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            Log(LOG_I, @"Keyboard disconnected!");
            
            // Re-evaluate the on-screen control mode
            [self updateAutoOnScreenControlMode];
        }];
        //for(Controller* controller in _controllers) [self updateTimerStateForController:controller];
    }
    

    
    _oscController = [[VoidController alloc] init];
    [self initializeControllerHaptics:_oscController];
    _gyroMode = AlwaysDevice;

    // _controllerMouseEnabledFlag = false;
    
    _gyroEnabledFlag = false;
    oscProfileMan = [OSCProfilesManager sharedManager:CGRectZero];

    [self updateCommonConfig:streamConfig];
    
    for(VoidController* voidController in _voidControllers.allValues){
        NSLog(@"stop external controller timer %@", voidController);
        [self stopTimerForController:voidController];
    }
    [self updateTimerStateForController:_oscController];

    [self assignControllers];
    
    _shallDisableGyroHotSwitch = streamConfig.gyroMode == GyroModeOff && _voidControllers.allValues.count == 0;
    NSLog(@"shallDisableGyroHotSwitch %d", _shallDisableGyroHotSwitch);
    
    
    return self;
}

-(bool)externalControllersHaveGyro{
    for(VoidController* voidController in _voidControllers.allValues){
        if(voidController.hasGyroscope || voidController.hasAccelerometer) return true;
    }
    return false;
}

-(bool)psGyroEnabledInSetting {
    uint8_t emulation = tempSettings.emulatedControllerType.intValue;
    return (emulation == ControllerEmulationPs
            || emulation == ControllerEmulationPsEnhancedHaptic
            || emulation == ControllerEmulationXboxAndPs)
            && tempSettings.gyroMode.intValue != GyroModeOff;
}

-(void)connectionEstablished {
    for (VoidController* voidController in _voidControllers.allValues) {
        if(voidController.playerIndex != 0) [self updateFinished:voidController];
    }
    
    //if (_oscEnabled
    //  || (tempSettings.emulatedControllerType.intValue == LI_CTYPE_PS && tempSettings.gyroMode != GyroModeOff)) {
    if ([self psGyroEnabledInSetting]) {
        [self setButtonFlag:self->_oscController flags:A_FLAG];
        [self updateFinished:self->_oscController];
        [self clearButtonFlag:self->_oscController flags:A_FLAG];
        [self updateFinished:self->_oscController];
    }
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        self->_gyroMode = self->_streamConfig.gyroMode;
        
        [self applyGyroModeSetting];
    });
}

-(void)stopTimerForController:(VoidController* )voidController{
    [self resetGyroInputForController:voidController];
    if (@available(iOS 14.0, *)) {
        //NSLog(@"stop controller obj: %@, hasAcc %d, hasGyro %d", voidController, voidController.hasAccelerometer, voidController.hasGyroscope);
        // if(voidController.hasAccelerometer){
            [voidController.accelTimer invalidate];
            voidController.accelTimer = nil;
        // }
        // if(voidController.hasGyroscope){
            [voidController.gyroTimer invalidate];
            voidController.gyroTimer = nil;
        // }
    }
}

- (void)applyGyroModeSetting {
    // Stop all timers to ensure a clean slate before applying the new setting.
    [self stopTimerForAllControllers];

    _gyroEnabledFlag = [self psGyroEnabledInSetting];
    switch(_gyroMode) {
        case AlwaysController:
            // Activate timers only for physical controllers.
            for (VoidController* voidController in _voidControllers.allValues) {
                if(voidController == _oscController) break;
                [self updateTimerStateForController:voidController];
            }
            break;

        case GyroModeAuto:
            // Prefer physical controller gyros if they exist.
            if ([self externalControllersHaveGyro]) {
                for (VoidController* voidController in _voidControllers.allValues) {
                    [self updateTimerStateForController:voidController];
                }
            } else {
                // Otherwise, fall back to the device gyro.
                [self updateTimerStateForController:self->_oscController];
            }
            break;

        case AlwaysDevice:
            // Always start the device gyro in this mode.
            [self updateTimerStateForController:self->_oscController];
            break;
            
        case GyroModeOff:
            // Do nothing, all timers are already stopped.
            break;
    }
}

- (void)updateTimerStateForOsc{
    [self updateTimerStateForController:self->_oscController];
}

-(void) cleanup
{
    [ControllerUtil stopAllDualSenseHaptics];
#if !TARGET_OS_TV
    [_gameSirG8MFiRumbler invalidate];
    [_kishiRumbler invalidate];
#endif

    if (VLSharedControllerSupport == self) {
        VLSharedControllerSupport = nil;
    }

    [[NSNotificationCenter defaultCenter] removeObserver:_controllerConnectObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:_controllerDisconnectObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:_mouseConnectObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:_mouseDisconnectObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:_keyboardConnectObserver];
    [[NSNotificationCenter defaultCenter] removeObserver:_keyboardDisconnectObserver];
    
    _controllerConnectObserver = nil;
    _controllerDisconnectObserver = nil;
    _mouseConnectObserver = nil;
    _mouseDisconnectObserver = nil;
    _keyboardConnectObserver = nil;
    _keyboardDisconnectObserver = nil;
    
    _controllerNumbers = 0;
    
    [self stopTimerForController:_oscController];
    for (VoidController* controller in [_voidControllers allValues]) {
        [self stopTimerForController:controller];
        [self cleanupControllerHaptics:controller];
        [self cleanupControllerMotion:controller];
        [self cleanupControllerBattery:controller];
    }
    [_voidControllers removeAllObjects];
    
    #if !TARGET_OS_TV
        [self cleanupControllerMotion:_oscController];
        [_oscController.motionManager stopDeviceMotionUpdates];
    #endif
    
    for (GCController* controller in [GCController controllers]) {
        if ([ControllerSupport isSupportedGamepad:controller]) {
            [self unregisterControllerCallbacks:controller];
        }
    }
    
    if (@available(iOS 14.0, tvOS 14.0, *)) {
        for (GCMouse* mouse in [GCMouse mice]) {
            [self unregisterMouseCallbacks:mouse];
        }
    }
}


- (void) dealloc
{
    if (VLSharedControllerSupport == self) {
        VLSharedControllerSupport = nil;
    }
}

@end

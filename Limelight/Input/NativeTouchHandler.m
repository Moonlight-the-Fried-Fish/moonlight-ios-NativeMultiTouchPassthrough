//
//  NativeTouchHandler.m
//  Moonlight
//
//  Created by Admin on 2024/6/16.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "NativeTouchHandler.h"
#import "NativeTouchPointer.h"
#import "StreamView.h"
#import "DataManager.h"

#include <Limelight.h>



@implementation NativeTouchHandler {
    StreamView* streamView;
    bool activateCoordSelector;
}


- (id)initWith:(StreamView*)view and:(TemporarySettings*)settings{
    self = [self init];
    self->streamView = view;
    activateCoordSelector = (settings.pointerVelocityModeDivider.floatValue != 1.0);
    [NativeTouchPointer setPointerVelocityDivider:settings.pointerVelocityModeDivider.floatValue];
    [NativeTouchPointer setPointerVelocityFactor:settings.touchPointerVelocityFactor.floatValue];
    [NativeTouchPointer initContextWith:streamView];
    
    return self;
}


- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    
#if !TARGET_OS_TV
    if (@available(iOS 13.4, *)) {
            for (UITouch* touch in touches) [self handleUITouch:touch index:0];// Native touch (absoluteTouch) first!
            return;
        }
#endif
    }



- (void)sendTouchEvent:(UITouch*)event touchType:(uint8_t)touchType{
    CGPoint targetCoords;
    if(activateCoordSelector && event.phase == UITouchPhaseMoved) targetCoords = [NativeTouchPointer selectCoordsFor:event]; // coordinates of touch pointer replaced to relative ones here.
    else targetCoords = [event locationInView:streamView];
    CGPoint location = [streamView adjustCoordinatesForVideoArea:targetCoords];
    CGSize videoSize = [streamView getVideoAreaSize];
    LiSendTouchEvent(touchType,[NativeTouchPointer retrievePointerIdFromDict:event],location.x / videoSize.width, location.y / videoSize.height,(event.force / event.maximumPossibleForce) / sin(event.altitudeAngle),0.0f, 0.0f,[streamView getRotationFromAzimuthAngle:[event azimuthAngleInView:streamView]]);
}


- (void)handleUITouch:(UITouch*)event index:(int)index{
    uint8_t type;
    //BOOL pointerVelocityScaleEnabled = (settings.pointerVelocityModeDivider.floatValue != 1.0); // when the divider is 1.0, means 0% of screen shall pass velocity-scaled pointer to sunshine.
    // NSLog(@"handleUITouch %ld,%d",(long)event.phase,(uint32_t)event);
//#define LI_TOUCH_EVENT_HOVER       0x00
//#define LI_TOUCH_EVENT_DOWN        0x01
//#define LI_TOUCH_EVENT_UP          0x02
//#define LI_TOUCH_EVENT_MOVE        0x03
//#define LI_TOUCH_EVENT_CANCEL      0x04
//#define LI_TOUCH_EVENT_BUTTON_ONLY 0x05
//#define LI_TOUCH_EVENT_HOVER_LEAVE 0x06
//#define LI_TOUCH_EVENT_CANCEL_ALL  0x07
//#define LI_ROT_UNKNOWN 0xFFFF
    
//    UITouchPhaseBegan,             // whenever a finger touches the surface.
//    UITouchPhaseMoved,             // whenever a finger moves on the surface.
//    UITouchPhaseStationary,        // whenever a finger is touching the surface but hasn't moved since the previous event.
//    UITouchPhaseEnded,             // whenever a finger leaves the surface.
//    UITouchPhaseCancelled,         // whenever a touch doesn't end but we need to stop tracking (e.g. putting device to face)
//    UITouchPhaseRegionEntered   API_AVAILABLE(ios(13.4), tvos(13.4)) API_UNAVAILABLE(watchos),  // whenever a touch is entering the region of a user interface
//    UITouchPhaseRegionMoved     API_AVAILABLE(ios(13.4), tvos(13.4)) API_UNAVAILABLE(watchos),  // when a touch is inside the region of a user interface, but hasn’t yet made contact or left the region
//    UITouchPhaseRegionExited    API_AVAILABLE(ios(13.4), tvos(13.4))
    
    switch (event.phase) {
        case UITouchPhaseBegan://开始触摸
            type = LI_TOUCH_EVENT_DOWN;
            [NativeTouchPointer populatePointerId:event]; //获取并记录pointerId
            if(activateCoordSelector) [NativeTouchPointer populatePointerObjIntoDict:event];
            break;
        case UITouchPhaseMoved://移动
        case UITouchPhaseStationary:
            type = LI_TOUCH_EVENT_MOVE;
            if(activateCoordSelector) [NativeTouchPointer updatePointerObjInDict:event];
            break;
        case UITouchPhaseEnded://触摸结束
            type = LI_TOUCH_EVENT_UP;
            [self sendTouchEvent:event touchType:type]; //先发送,再删除
            [NativeTouchPointer removePointerId:event]; //删除pointerId
            if(activateCoordSelector) [NativeTouchPointer removePointerObjFromDict:event];
            return;
        case UITouchPhaseCancelled://触摸取消
            type = LI_TOUCH_EVENT_CANCEL;
            [self sendTouchEvent:event touchType:type]; //先发送,再删除
            [NativeTouchPointer removePointerId:event]; //删除pointerId
            if(activateCoordSelector) [NativeTouchPointer removePointerObjFromDict:event];
            return;
        case UITouchPhaseRegionEntered://停留
        case UITouchPhaseRegionMoved://停留
            type = LI_TOUCH_EVENT_HOVER;
            break;
        default:
            return;
    }
    [self sendTouchEvent:event touchType:type];
}


- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
#if !TARGET_OS_TV
    if (@available(iOS 13.4, *)) {
        for (UITouch* touch in touches) [self handleUITouch:touch index:0];// Native touch (absoluteTouch) first!
        return;
        // NSLog(@"touchesMoved - allTouches %lu, pointerSet count %lu",[[event allTouches] count], [pointerIdSet count]);
    }
#endif
}


- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
#if !TARGET_OS_TV
    if (@available(iOS 13.4, *)) {
        for (UITouch* touch in touches) [self handleUITouch:touch index:0];// Native touch (absoluteTouch) first!
        return;
        // NSLog(@"touchesEnded - allTouches %lu, pointerSet count %lu",[[event allTouches] count], [pointerIdSet count]);
    }
#endif
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
#if !TARGET_OS_TV
    if (@available(iOS 13.4, *)) {
            for (UITouch* touch in touches) [self handleUITouch:touch index:0];// Native touch (absoluteTouch) first!
            return;
    }
        // NSLog(@"touchesCancelled - allTouches %lu, pointerSet count %lu",[[event allTouches] count], [pointerIdSet count]);
#endif
}



@end

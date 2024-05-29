//
//  NativeTouchHandler.m
//  Moonlight
//
//  Created by ZWM on 2024/5/14.
//  Copyright © 2024 Moonlight Game Streaming Project. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "NativeTouchHandler.h"
#include <Limelight.h>


// Use a Dictionary to store UITouch object's memory address as key, and pointerId as value,字典存放UITouch对象地址和pointerId映射关系
// pointerId will be generated from electronic noise, by arc4_random, pointerId,由随机噪声生成
// Use a NSSet store pointerId, for quick repeition inquiry, NSSet存放活跃的pointerId合集,用于快速查找,以防重复.
static NSMutableDictionary *pointerIdDict; //pointerId Dict for native touch.
static NSMutableSet<NSNumber *> *pointerIdSet; //pointerIdSet for native touch.
static NSMutableDictionary *pointerDict;

static CGFloat pointerVelocityFactor = 0.7;
static CGFloat pointerVelocityDivider = 0.5;
static CGFloat pointerVelocityDividerLocation;

StreamView *streamView;

@implementation TouchPointer{
    CGPoint initialPoint;
    CGPoint latestPoint;
    CGPoint previousPoint;
    CGPoint latestRelativePoint;
    CGPoint previousRelativePoint;
    CGFloat velocityX;
    CGFloat velocityY;
}

+ (void)setPointerVelocityDivider:(CGFloat)dividerLocation{
    pointerVelocityDivider = dividerLocation;
}

+ (void)setPointerVelocityFactor:(CGFloat)velocityFactor{
    pointerVelocityFactor = velocityFactor;
}


- (instancetype)initWith:(UITouch *)touch{
        self = [self init];
        self->initialPoint = [touch locationInView:streamView];
        self->latestPoint = self->initialPoint;
        self->latestRelativePoint = self->initialPoint;
        return self;
    }

- (void)updatePointerCoords:(UITouch *)touch{
    previousPoint = latestPoint;
    latestPoint = [touch locationInView:streamView];
    if (pointerVelocityFactor != 1.0f){
        velocityX = latestPoint.x - previousPoint.x;
        velocityY = latestPoint.y - previousPoint.y;
        previousRelativePoint = latestRelativePoint;
        latestRelativePoint.x = previousRelativePoint.x + pointerVelocityFactor * velocityX;
        latestRelativePoint.y = previousRelativePoint.y + pointerVelocityFactor * velocityY;
    }
}

+ (void)initContextWith:(StreamView *)view{
    streamView = view;
    pointerIdDict = [NSMutableDictionary dictionary];
    pointerIdSet = [NSMutableSet set];
    pointerDict = [NSMutableDictionary dictionary];
    pointerVelocityDividerLocation = CGRectGetHeight([[UIScreen mainScreen] bounds]) * pointerVelocityDivider;
}

+ (void)populatePointerObjIntoDict:(UITouch*)touch{
    [pointerDict setObject:[[TouchPointer alloc] initWith:touch] forKey:@((uint64_t)touch)];
}

+ (void)removePointerObjFromDict:(UITouch*)touch{
    uint64_t eventAddrValue = (uint64_t)touch;
    TouchPointer* pointer = [pointerDict objectForKey:@(eventAddrValue)];
    if(pointer != nil){
        [pointerDict removeObjectForKey:@(eventAddrValue)];
    }

}

+ (void)updatePointerObjInDict:(UITouch *)touch{
    [[pointerDict objectForKey:@((uint64_t)touch)] updatePointerCoords:touch];
}


+ (CGPoint)selectCoordsFor:(UITouch *)touch{
    TouchPointer *pointer = [pointerDict objectForKey:@((uint64_t)touch)];
    if((pointer -> initialPoint).x > pointerVelocityDividerLocation){  //if first contact coords locates on the right side of divider.
        return pointer->latestRelativePoint;
    }
    return [touch locationInView:streamView];
}



// 随机生成pointerId并填入NSDict和NSSet
// generate & populate pointerId into NSDict & NSSet, called in UITouchPhaseBegan
+ (void)populatePointerId:(UITouch*)touch{
    uint64_t eventAddrValue = (uint64_t)touch;
    uint32_t randomPointerId = arc4random_uniform(UINT32_MAX); // generate pointerId from eletronic noise.
    while(true){
        if([pointerIdSet containsObject:@(randomPointerId)]) randomPointerId = arc4random_uniform(UINT32_MAX); // in case of new pointerId collides with existing ones, generate again.
        else{ // populate pointerId into NSDict & NSSet.
            [pointerIdDict setObject:@(randomPointerId) forKey:@(eventAddrValue)];
            [pointerIdSet addObject:@(randomPointerId)];
            return;
        }
    }
}



// remove pointerId in UITouchPhaseEnded condition
+ (void)removePointerId:(UITouch*)touch{
    uint64_t eventAddrValue = (uint64_t)touch;
    NSNumber* pointerIdObj = [pointerIdDict objectForKey:@(eventAddrValue)];
    if(pointerIdObj != nil){
        [pointerIdSet removeObject:pointerIdObj];
        [pointerIdDict removeObjectForKey:@(eventAddrValue)];
    }
}

// 从字典中获取UITouch事件对应的pointerId
// call this only when NSDcit & NSSet is up-to-date.
+ (uint32_t) retrievePointerIdFromDict:(UITouch*)touch{
    return [[pointerIdDict objectForKey:@((uint64_t)touch)] unsignedIntValue];
}



@end

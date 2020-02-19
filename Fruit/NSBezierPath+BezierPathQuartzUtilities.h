//
//  NSBezierPath+BezierPathQuartzUtilities.h
//  Voltage
//
//  Created by Pedro Paulo de Amorim on 17/02/2020.
//  Copyright © 2020 T-Pro. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@interface NSBezierPath (BezierPathQuartzUtilities)

- (CGPathRef)quartzPath;

@end

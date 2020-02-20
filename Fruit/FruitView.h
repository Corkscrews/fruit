//
//  VoltageView.h
//  Voltage
//
//  Created by Pedro Paulo de Amorim on 17/02/2020.
//  Copyright © 2020 T-Pro. All rights reserved.
//

#import <ScreenSaver/ScreenSaver.h>
#import <AppKit/AppKit.h>
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

@interface FruitView : ScreenSaverView
{
  NSBezierPath *background;
  NSBezierPath *foreground;
  NSBezierPath *fruit;
  NSBezierPath *leaf;

  NSBezierPath *green;
  NSMutableArray<NSBezierPath *> *colorsPath;
  NSMutableArray<NSColor *> *colorsForPath;

  CAShapeLayer *maskBackgroundLayer;
  CGFloat heightOfBars;

  NSMutableArray<CAShapeLayer *> *lineLayers;

  int totalLines;
}

@end

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
  NSBezierPath *fruit;
  NSBezierPath *leaf;

  NSMutableArray<NSBezierPath *> *colorsPath;
  NSMutableArray<NSColor *> *colorsForPath;

  CAShapeLayer *maskBackgroundLayer;
  CGFloat heightOfBars;

  NSMutableArray<CAShapeLayer *> *lineLayers;

  int visibleLinesCount;
  int totalLines;
}

@end

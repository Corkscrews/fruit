//
//  VoltageView.m
//  Voltage
//
//  Created by Pedro Paulo de Amorim on 17/02/2020.
//  Copyright © 2020 T-Pro. All rights reserved.
//

#import "FruitView.h"
#import <Fruit-Swift.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <NSBezierPath+BezierPathQuartzUtilities.h>

@implementation FruitView

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview
{
  self = [super initWithFrame:frame isPreview:isPreview];
  if (self) {
    [self setAnimationTimeInterval:1/30.0];
  }

  fruit = [BuildLogo buildFruit];
  leaf = [BuildLogo buildLeaf];

  CGFloat scale = 2.0f;

  CGFloat x = fruit.bounds.size.width;
  CGFloat y = fruit.bounds.size.height;

  CGFloat middleX = frame.size.width/2;
  middleX -= x * scale;

  CGFloat middleY = frame.size.height/2;
  middleY -= y * scale;

  NSAffineTransform* xfm = RotationTransform(M_PI, NSMakePoint(x, y));
  NSAffineTransform* xm = TransformTranslation(NSMakePoint(middleX, middleY));
  NSAffineTransform* sm = ScaleTranslation(scale);

  NSBezierPath* copyFruit = [fruit copy];
  [copyFruit transformUsingAffineTransform:xfm];
  [copyFruit transformUsingAffineTransform:sm];
  [copyFruit transformUsingAffineTransform:xm];
  fruit = copyFruit;

  NSBezierPath* copyLeaf = [leaf copy];
  [copyLeaf transformUsingAffineTransform:xfm];
  [copyLeaf transformUsingAffineTransform:sm];
  [copyLeaf transformUsingAffineTransform:xm];
  leaf = copyLeaf;


  background = [NSBezierPath bezierPath];
  [background moveToPoint:NSMakePoint(0.0, 0.0)];
  [background lineToPoint:NSMakePoint(frame.size.width, 0)];
  [background lineToPoint:NSMakePoint(frame.size.width, frame.size.height)];
  [background lineToPoint:NSMakePoint(0, frame.size.height)];
  [background closePath];

  foreground = [NSBezierPath bezierPath];
  [foreground moveToPoint:NSMakePoint(0.0, 0.0)];
  [foreground lineToPoint:NSMakePoint(frame.size.width, 0)];
  [foreground lineToPoint:NSMakePoint(frame.size.width, frame.size.height)];
  [foreground lineToPoint:NSMakePoint(0, frame.size.height)];
  [foreground closePath];

  CGFloat middleYYY = frame.size.height/2;
  CGFloat widthD = fruit.bounds.size.width * scale;
  CGFloat finalX = middleX + widthD;

  colorsPath = [NSMutableArray new];
  colorsForPath = [NSMutableArray new];

  CGFloat lastY = middleYYY - fruit.bounds.size.height;
  CGFloat heightOfBars = (fruit.bounds.size.height)/6;

  lastY += heightOfBars + 18; //offset

//  [NSColor colorWithSRGBRed:<#(CGFloat)#> green:<#(CGFloat)#> blue:<#(CGFloat)#> alpha:<#(CGFloat)#>]

  NSArray *colorArray = [[NSArray alloc] initWithObjects:
                         [NSColor colorWithSRGBRed:67.0/255.0 green:156.0/255.0 blue:214.0/255.0 alpha:1.0],
                         [NSColor colorWithSRGBRed:139.0/255.0 green:69.0/255.0 blue:147.0/255.0 alpha:1.0],
                         [NSColor colorWithSRGBRed:207.0/255.0 green:72.0/255.0 blue:69.0/255.0 alpha:1.0],
                         [NSColor colorWithSRGBRed:231.0/255.0 green:135.0/255.0 blue:59.0/255.0 alpha:1.0],
                         [NSColor colorWithSRGBRed:243.0/255.0 green:185.0/255.0 blue:75.0/255.0 alpha:1.0],
                         [NSColor colorWithSRGBRed:120.0/255.0 green:184.0/255.0 blue:86.0/255.0 alpha:1.0],
                         nil];

  for (int i = 0; i <= 5; i++)
  {

    NSBezierPath *path = [NSBezierPath bezierPath];
    [path moveToPoint:NSMakePoint(middleX, lastY)];
    [path lineToPoint:NSMakePoint(finalX, lastY)];
    [path lineToPoint:NSMakePoint(finalX, lastY + heightOfBars)];
    [path lineToPoint:NSMakePoint(middleX, lastY + heightOfBars)];
    [path closePath];

    [colorsPath addObject:path];

    [colorsForPath addObject:colorArray[i]];

    lastY += heightOfBars;
  }

  return self;
}

NSAffineTransform *RotationTransform(const CGFloat angle, const NSPoint cp)
{
  NSAffineTransform* xfm = [NSAffineTransform transform];
  [xfm translateXBy:cp.x yBy:cp.y];
  [xfm rotateByRadians:angle];
  [xfm scaleXBy:-1.0 yBy:1.0];
  [xfm translateXBy:-cp.x yBy:-cp.y];
  return xfm;
}

NSAffineTransform *TransformTranslation(const NSPoint cp)
{
  NSAffineTransform* xfm = [NSAffineTransform transform];
  [xfm translateXBy:cp.x yBy:cp.y];
  return xfm;
}

NSAffineTransform *ScaleTranslation(const CGFloat angle)
{
  NSAffineTransform* xfm = [NSAffineTransform transform];
  [xfm scaleXBy:angle yBy:angle];
  return xfm;
}

- (void)startAnimation
{
  [super startAnimation];
}

- (void)stopAnimation
{
  [super stopAnimation];
}

- (void)drawRect:(NSRect)rect
{
  [super drawRect:rect];

  CGPathRef quartzBackgroundPath = [background quartzPath];
  CAShapeLayer *maskBackgroundLayer = [CAShapeLayer layer];
  maskBackgroundLayer.fillColor = [colorsForPath[colorsForPath.count - 1] CGColor];
  maskBackgroundLayer.frame = self.frame;
  maskBackgroundLayer.path = quartzBackgroundPath;
  CGPathRelease(quartzBackgroundPath);

  for (int i = 0; i <= 5; i++)
  {
    CGPathRef quartzgreenPath = [colorsPath[i] quartzPath];
    CAShapeLayer *maskGreenLayer = [CAShapeLayer layer];
    maskGreenLayer.fillColor = [colorsForPath[i] CGColor];
    maskGreenLayer.frame = self.frame;
    maskGreenLayer.path = quartzgreenPath;
    CGPathRelease(quartzgreenPath);

    [maskBackgroundLayer addSublayer:maskGreenLayer];
  }

  [self.layer addSublayer:maskBackgroundLayer];

  CGPathRef quartzLeafPath = [leaf quartzPath];
  CAShapeLayer *maskLeafLayer = [CAShapeLayer layer];
  maskLeafLayer.frame = self.frame;
  maskLeafLayer.path = quartzLeafPath;
  maskLeafLayer.allowsEdgeAntialiasing = YES;

  CGPathRef quartzFruitPath = [fruit quartzPath];
  CAShapeLayer *maskFruitLayer = [CAShapeLayer layer];
  maskFruitLayer.frame = self.frame;
  maskFruitLayer.path = quartzFruitPath;
  maskFruitLayer.allowsEdgeAntialiasing = YES;

  [maskFruitLayer addSublayer:maskLeafLayer];
  maskBackgroundLayer.mask = maskFruitLayer;

  CGPathRelease(quartzFruitPath);
  CGPathRelease(quartzLeafPath);

  [[NSColor blackColor] set];
  [foreground fill];

}

- (NSColor *)random
{
  CGFloat hue = ( arc4random() % 256 / 256.0 );  //  0.0 to 1.0
  CGFloat saturation = ( arc4random() % 128 / 256.0 ) + 0.5;  //  0.5 to 1.0, away from white
  CGFloat brightness = ( arc4random() % 128 / 256.0 ) + 0.5;  //  0.5 to 1.0, away from black
  return [NSColor colorWithHue:hue saturation:saturation brightness:brightness alpha:1];
}

- (void)animateOneFrame
{
//  [self setNeedsDisplay:YES];
  return;
}

- (BOOL)hasConfigureSheet
{
  return NO;
}

- (NSWindow*)configureSheet
{
  return nil;
}

@end

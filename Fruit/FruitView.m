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
  heightOfBars = (fruit.bounds.size.height)/6;

//  lastY += heightOfBars + 18; //offset

  NSArray *colorArray = [[NSArray alloc] initWithObjects:
                         [NSColor colorWithSRGBRed:67.0/255.0 green:156.0/255.0 blue:214.0/255.0 alpha:1.0], //BLUE
                         [NSColor colorWithSRGBRed:139.0/255.0 green:69.0/255.0 blue:147.0/255.0 alpha:1.0], //PURPLE
                         [NSColor colorWithSRGBRed:207.0/255.0 green:72.0/255.0 blue:69.0/255.0 alpha:1.0], //RED
                         [NSColor colorWithSRGBRed:231.0/255.0 green:135.0/255.0 blue:59.0/255.0 alpha:1.0], //ORANGE
                         [NSColor colorWithSRGBRed:243.0/255.0 green:185.0/255.0 blue:75.0/255.0 alpha:1.0], //YELLOW
                         [NSColor colorWithSRGBRed:120.0/255.0 green:184.0/255.0 blue:86.0/255.0 alpha:1.0], //GREEN
                         [NSColor colorWithSRGBRed:67.0/255.0 green:156.0/255.0 blue:214.0/255.0 alpha:1.0], //BLUE
                         [NSColor colorWithSRGBRed:139.0/255.0 green:69.0/255.0 blue:147.0/255.0 alpha:1.0], //PURPLE
                         [NSColor colorWithSRGBRed:207.0/255.0 green:72.0/255.0 blue:69.0/255.0 alpha:1.0], //RED
                         [NSColor colorWithSRGBRed:231.0/255.0 green:135.0/255.0 blue:59.0/255.0 alpha:1.0], //ORANGE
                         [NSColor colorWithSRGBRed:243.0/255.0 green:185.0/255.0 blue:75.0/255.0 alpha:1.0], //YELLOW
                         [NSColor colorWithSRGBRed:120.0/255.0 green:184.0/255.0 blue:86.0/255.0 alpha:1.0], //GREEN
                         nil];

  totalLines = 11;

  for (int i = 0; i <= totalLines; i++)
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

  if (maskBackgroundLayer == NULL) {

    CGPathRef quartzBackgroundPath = [background quartzPath];
    maskBackgroundLayer = [CAShapeLayer layer];
    maskBackgroundLayer.fillColor = [[NSColor blackColor] CGColor];
    maskBackgroundLayer.frame = self.frame;
    maskBackgroundLayer.path = quartzBackgroundPath;
    CGPathRelease(quartzBackgroundPath);

    lineLayers = [NSMutableArray new];

    for (int i = 0; i <= totalLines; i++)
    {
      NSBezierPath *path = colorsPath[i];
      CGPathRef quartzLinePath = [path quartzPath];
      CAShapeLayer *maskLineLayer = [CAShapeLayer layer];
      maskLineLayer.fillColor = [colorsForPath[i] CGColor];
      maskLineLayer.frame = self.frame;
      maskLineLayer.path = quartzLinePath;
      CGPathRelease(quartzLinePath);

      [maskBackgroundLayer addSublayer:maskLineLayer];
      [lineLayers addObject:maskLineLayer];
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

    [self add];

  }
//
//  CGPathRelease(quartzFruitPath);
//  CGPathRelease(quartzLeafPath);
//
//  [[NSColor blackColor] set];
//  [foreground fill];

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

- (void)startA:(CAShapeLayer *)layer
          from:(NSBezierPath *)from
            to:(NSBezierPath *)to
         block:(nullable void (^)(void))block
{

  if (block != NULL) {
    [CATransaction begin];
  }

  CABasicAnimation* a = [CABasicAnimation animationWithKeyPath:@"path"];
  [a setDuration:3.0f];
  [a setFromValue:(id)[from quartzPath]];
  [a setToValue:(id)[to quartzPath]];

  if (block != NULL) {
    [CATransaction setCompletionBlock:block];
  }

  CGPathRef quartzBackgroundPath = [to quartzPath];
  layer.path = quartzBackgroundPath;
  CGPathRelease(quartzBackgroundPath);

  [layer addAnimation:a forKey:@"path"];

  if (block != NULL) {
    [CATransaction commit];
  }
}

- (void)add
{
  NSAffineTransform* sm = TransformTranslation(NSMakePoint(0, heightOfBars));

  for (int i = 0; i <= totalLines; i++)
  {
    CAShapeLayer *maskLineLayer = lineLayers[i];
    NSBezierPath* from = colorsPath[i];
    NSBezierPath* to = [colorsPath[i] copy];
    [to transformUsingAffineTransform:sm];

    if (i == totalLines) {
      [self reorder];
      [self foo];

      [self startA:maskLineLayer from:from to:to block:NULL];
//      [self startA:maskLineLayer from:from to:to block:^{
//        [self add];
//      }];

      double delayInSeconds = 3.0;
      dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
      dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
        [self add];
      });

      return;
    }

    [self startA:maskLineLayer from:from to:to block:NULL];
  }

}

- (void)reorder
{

  NSArray* origin = [colorsForPath copy];

  colorsForPath[0] = origin[11];
  colorsForPath[1] = origin[0];
  colorsForPath[2] = origin[1];
  colorsForPath[3] = origin[2];
  colorsForPath[4] = origin[3];
  colorsForPath[5] = origin[4];
  colorsForPath[6] = origin[5];
  colorsForPath[7] = origin[6];
  colorsForPath[8] = origin[7];
  colorsForPath[9] = origin[8];
  colorsForPath[10] = origin[9];
  colorsForPath[11] = origin[10];

}

- (void)foo
{
  for (int i = 0; i <= totalLines; i++)
  {
    CAShapeLayer *maskLineLayer = lineLayers[i];
    maskLineLayer.fillColor = [colorsForPath[i] CGColor];
  }
}

@end

//
//  APLCompositionDebugView.m
//  AVCompositionDebugViewer
//
//  Created by Jonathan Lott on 5/20/18.
//

#import "APLCompositionDebugView.h"

#if TARGET_OS_OSX
enum { kLeftInsetToMatchTimeSlider = 70, kRightInsetToMatchTimeSlider = 35, kLeftMarginInset = 4};
enum { kBannerHeight = 20, kIdealRowHeight = 40, kGapAfterRows = 4 };

@interface APLCompositionTrackSegmentInfo : NSObject
{

@public
    CMTimeRange timeRange;
    BOOL        empty;
    NSString    *mediaType;
    NSString    *description;
}
@end

@interface FlippedView : NSClipView
@end

@implementation FlippedView

- (BOOL)isFlipped {
    return NO;
}

@end
@implementation APLCompositionTrackSegmentInfo

- (void)dealloc
{
    mediaType = nil;
    description = nil;
}

@end

@interface APLVideoCompositionStageInfo : NSObject
{
@public
    CMTimeRange  timeRange;
    NSArray         *layerNames; // for videoComposition only
    NSDictionary *opacityRamps;
}
@end

@implementation APLVideoCompositionStageInfo

- (void)dealloc
{
    layerNames = nil;
    opacityRamps = nil;
}

@end

@interface APLCompositionDebugView  ()
{
    CAShapeLayer *timeMarkerWhiteLineLayer;
    CAShapeLayer *timeMarkerRedBandLayer;
}
@property (strong) IBOutlet NSLayoutConstraint *heightConstraint;
@end

@implementation APLCompositionDebugView

- (id)initWithFrame:(NSRect)frameRect
{
    if (self = [super initWithFrame:frameRect]) {
        // intialization
    }
    
    return self;
}

- (void)awakeFromNib
{
    [self setWantsLayer:YES]; // Layer-backed view
    drawingLayer = self.layer;
    drawingLayer.backgroundColor = [[NSColor darkGrayColor] CGColor];
}

- (void)dealloc
{
    drawingLayer = nil;
}

- (void)updateConstraints {
    [super updateConstraints];
}

#pragma mark Value harvesting

- (void)synchronizeToComposition:(AVComposition *)composition videoComposition:(AVVideoComposition *)videoComposition audioMix:(AVAudioMix *)audioMix
{
    compositionTracks = nil;
    audioMixTracks = nil;
    videoCompositionStages = nil;
    
    duration = CMTimeMake(1, 1); // avoid division by zero later
    if (composition) {
        NSMutableArray *tracks = [[NSMutableArray alloc] init];
        for (AVCompositionTrack *t in composition.tracks) {
            NSMutableArray *segments = [[NSMutableArray alloc] init];
            for (AVCompositionTrackSegment *s in t.segments) {
                APLCompositionTrackSegmentInfo *segment = [[APLCompositionTrackSegmentInfo alloc] init] ;
                if (s.isEmpty)
                    segment->timeRange = s.timeMapping.target; // only used for duration
                else
                    segment->timeRange = s.timeMapping.source; // assumes non-scaled edit
                segment->empty = s.isEmpty;
                segment->mediaType = t.mediaType;
                if (! segment->empty) {
                    NSMutableString *description = [[NSMutableString alloc] init];
                    [description appendFormat:@"%1.1f - %1.1f: \"%@\" ", CMTimeGetSeconds(segment->timeRange.start), CMTimeGetSeconds(CMTimeRangeGetEnd(segment->timeRange)), [s.sourceURL lastPathComponent]];
                    if ([segment->mediaType isEqual:AVMediaTypeVideo])
                        [description appendString:@"(v)"];
                    else if ([segment->mediaType isEqual:AVMediaTypeAudio])
                        [description appendString:@"(a)"];
                    else
                        [description appendFormat:@"('%@')", segment->mediaType];
                    
                    if(videoComposition.instructions.count > 0) {
                        long ciCount = 0;
                        long liCount = 0;
                        for(AVVideoCompositionInstruction* instruction in videoComposition.instructions) {
                            for(AVVideoCompositionLayerInstruction* layerInstruction in instruction.layerInstructions) {
                                if([layerInstruction trackID] == t.trackID) {
                                    ciCount++;
                                    liCount++;
                                }
                            }
                        }
                        if(ciCount) {
                            [description appendFormat:@"ci: %ld", ciCount];
                        }
                        if(liCount) {
                            [description appendFormat:@"li: %ld", liCount];
                        }
                    }
                    segment->description = description;
                }
                [segments addObject:segment];
            }
            
            [tracks addObject:segments];
        }
        
        compositionTracks = tracks;
        duration = CMTimeMaximum(duration, composition.duration);
    }
    
    if (audioMix) {
        NSMutableArray *mixTracks = [[NSMutableArray alloc] init];
        for (AVAudioMixInputParameters *input in audioMix.inputParameters) {
            NSMutableArray *ramp = [[NSMutableArray alloc] init];
            CMTime startTime = kCMTimeZero;
            float startVolume, endVolume = 1.0;
            CMTimeRange timeRange;
            while ([input getVolumeRampForTime:startTime startVolume:&startVolume endVolume:&endVolume timeRange:&timeRange]) {
                if (CMTIME_COMPARE_INLINE(startTime, ==, kCMTimeZero) && CMTIME_COMPARE_INLINE(timeRange.start, >, kCMTimeZero)) {
                    [ramp addObject:[NSValue valueWithPoint:NSMakePoint(0, 1.0)]];
                    [ramp addObject:[NSValue valueWithPoint:NSMakePoint(CMTimeGetSeconds(timeRange.start), 1.0)]];
                }
                [ramp addObject:[NSValue valueWithPoint:NSMakePoint(CMTimeGetSeconds(timeRange.start), startVolume)]];
                [ramp addObject:[NSValue valueWithPoint:NSMakePoint(CMTimeGetSeconds(CMTimeRangeGetEnd(timeRange)), endVolume)]];
                startTime = CMTimeRangeGetEnd(timeRange);
            }
            if (CMTIME_COMPARE_INLINE(startTime, <, duration))
                [ramp addObject:[NSValue valueWithPoint:NSMakePoint(CMTimeGetSeconds(duration), endVolume)]];
            [mixTracks addObject:ramp];
        }
        audioMixTracks = mixTracks;
    }
    
    if (videoComposition) {
        NSMutableArray *stages = [[NSMutableArray alloc] init];
        for (AVVideoCompositionInstruction *instruction in videoComposition.instructions) {
            APLVideoCompositionStageInfo *stage = [[APLVideoCompositionStageInfo alloc] init];
            stage->timeRange = instruction.timeRange;
            NSMutableDictionary *rampsDictionary = [[NSMutableDictionary alloc] init];
            
//            if ([instruction isKindOfClass:[AVVideoCompositionInstruction class]]) {
//                NSMutableArray *layerNames = [[NSMutableArray alloc] init];
//                for (AVVideoCompositionLayerInstruction *layerInstruction in instruction.layerInstructions) {
//                    NSMutableArray *ramp = [[NSMutableArray alloc] init];
//                    CMTime startTime = kCMTimeZero;
//                    float startOpacity, endOpacity = 1.0;
//                    CMTimeRange timeRange;
//                    while ([layerInstruction getOpacityRampForTime:startTime startOpacity:&startOpacity endOpacity:&endOpacity timeRange:&timeRange]) {
//                        if (CMTIME_COMPARE_INLINE(startTime, ==, kCMTimeZero) && CMTIME_COMPARE_INLINE(timeRange.start, >, kCMTimeZero)) {
//                            [ramp addObject:[NSValue valueWithPoint:NSMakePoint(CMTimeGetSeconds(timeRange.start), startOpacity)]];
//                        }
//                        [ramp addObject:[NSValue valueWithPoint:NSMakePoint(CMTimeGetSeconds(CMTimeRangeGetEnd(timeRange)), endOpacity)]];
//                        startTime = CMTimeRangeGetEnd(timeRange);
//                    }
//
//                    NSString *name = [NSString stringWithFormat:@"%d", layerInstruction.trackID];
//                    [layerNames addObject:name];
//                    [rampsDictionary setObject:ramp forKey:name];
//                }
                
//                if ([layerNames count] > 1) {
//                    stage->opacityRamps = rampsDictionary;
//                }
                stage->layerNames = @[@"Instruction"];
                
//            }

          [stages addObject:stage];
        }
        videoCompositionStages = stages;
    }
    
    
    int numBanners = (compositionTracks != nil) + (audioMixTracks != nil) + (videoCompositionStages != nil);
    int numRows = (int)[compositionTracks count] + (int)[audioMixTracks count] + (videoCompositionStages != nil);
    
    CGFloat totalBannerHeight = numBanners * (kBannerHeight + kGapAfterRows);
    CGFloat totalHeight = totalBannerHeight + (numRows * (kIdealRowHeight + kGapAfterRows));
    self.translatesAutoresizingMaskIntoConstraints = FALSE;
    [self.heightConstraint setConstant:MAX(totalHeight, self.bounds.size.height)];
    [self setNeedsUpdateConstraints:YES];
    [self setNeedsDisplay:YES];
    
    [drawingLayer setNeedsDisplay];
}

#pragma mark View drawing

- (void)willMoveToSuperview:(NSView *)newSuperview
{
    drawingLayer.frame = self.bounds;
    [drawingLayer setNeedsDisplay];
}

- (void)viewWillDisappear:(BOOL)animated
{
    drawingLayer.delegate = nil;
}

- (void)drawRect:(NSRect)rect
{
    CGContextRef context = [[NSGraphicsContext currentContext] graphicsPort];
    rect = CGRectInset(self.bounds, kLeftMarginInset, 4.0);
    
    NSMutableParagraphStyle *style = [[NSParagraphStyle defaultParagraphStyle] mutableCopy];
    [style setAlignment:NSCenterTextAlignment];
    
    NSDictionary *textAttributes = [NSDictionary dictionaryWithObjectsAndKeys:[NSColor whiteColor], NSForegroundColorAttributeName, style, NSParagraphStyleAttributeName, nil];
    
    int numBanners = (compositionTracks != nil) + (audioMixTracks != nil) + (videoCompositionStages != nil);
    int numRows = (int)[compositionTracks count] + (int)[audioMixTracks count] + (videoCompositionStages != nil);
    
    CGFloat totalBannerHeight = numBanners * (kBannerHeight + kGapAfterRows);
    CGFloat rowHeight = kIdealRowHeight;
    if ( numRows > 0 ) {
        CGFloat maxRowHeight = (rect.size.height - totalBannerHeight) / numRows;
        rowHeight = MIN( rowHeight, maxRowHeight );
    }
    
    CGFloat runningTop = rect.size.height - 15;
    CGRect bannerRect = rect;
    bannerRect.size.height = kBannerHeight;
    bannerRect.origin.y = runningTop;
    
    CGRect rowRect = rect;
    rowRect.size.height = rowHeight;
    
    rowRect.origin.x += kLeftInsetToMatchTimeSlider;
    rowRect.size.width -= (kLeftInsetToMatchTimeSlider + kRightInsetToMatchTimeSlider);
    compositionRectWidth = rowRect.size.width;
    
    scaledDurationToWidth = compositionRectWidth / CMTimeGetSeconds(duration);
    
    if (compositionTracks) {
        bannerRect.origin.y = runningTop;
        CGContextSetRGBFillColor(context, 0.00, 0.00, 0.00, 1.00); // black
        [[NSString stringWithFormat:@"AVComposition"] drawInRect:bannerRect withAttributes:[NSDictionary dictionaryWithObjectsAndKeys:[NSColor whiteColor], NSForegroundColorAttributeName, nil]];
        
        runningTop -= bannerRect.size.height;
        
        for (NSArray *track in compositionTracks) {
            rowRect.origin.y = runningTop;
            CGRect segmentRect = rowRect;
            for (APLCompositionTrackSegmentInfo *segment in track) {
                segmentRect.size.width = CMTimeGetSeconds(segment->timeRange.duration) * scaledDurationToWidth;
                
                if (segment->empty) {
                    CGContextSetRGBFillColor(context, 1.00, 1.00, 1.00, 0.3); // white
                    [[NSString stringWithFormat:@"empty"] drawInRect:segmentRect withAttributes:textAttributes];
                }
                else {
                    if ([segment->mediaType isEqual:AVMediaTypeVideo]) {
                        CGContextSetRGBFillColor(context, 0.00, 0.36, 0.36, 1.00); // blue-green
                        CGContextSetRGBStrokeColor(context, 0.00, 0.50, 0.50, 1.00); // brigher blue-green
                    }
                    else {
                        CGContextSetRGBFillColor(context, 0.00, 0.24, 0.36, 1.00); // bluer-green
                        CGContextSetRGBStrokeColor(context, 0.00, 0.33, 0.60, 1.00); // brigher bluer-green
                    }
                    CGContextSetLineWidth(context, 2.0);
                    CGContextAddRect(context, CGRectInset(segmentRect, 3.0, 3.0));
                    CGContextDrawPath(context, kCGPathFillStroke);
                    
                    CGContextSetRGBFillColor(context, 0.00, 0.00, 0.00, 1.00); // white
                    NSString* description = [NSString stringWithFormat:@"%@", segment->description];
                    CGRect textRect = [description boundingRectWithSize:CGSizeMake(segmentRect.size.width, CGFLOAT_MAX) options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading attributes:textAttributes];
                    textRect.origin.x = segmentRect.origin.x;
                    textRect.origin.y = segmentRect.origin.y;
                    [description drawInRect:segmentRect withAttributes:textAttributes];
                }
                
                segmentRect.origin.x += segmentRect.size.width;
            }
            
            runningTop -= rowRect.size.height;
        }
        runningTop -= kGapAfterRows;
    }
    
    if (videoCompositionStages) {
        bannerRect.origin.y = runningTop;
        CGContextSetRGBFillColor(context, 0.00, 0.00, 0.00, 1.00); // white
        [[NSString stringWithFormat:@"AVVideoComposition"] drawInRect:bannerRect withAttributes:[NSDictionary dictionaryWithObjectsAndKeys:[NSColor whiteColor], NSForegroundColorAttributeName,nil]];
        runningTop -= bannerRect.size.height;
        
        rowRect.origin.y = runningTop;
        CGRect stageRect = rowRect;
        for (APLVideoCompositionStageInfo *stage in videoCompositionStages) {
            stageRect.origin.x = [self horizontalPositionForTime:stage->timeRange.start];
            stageRect.size.width = CMTimeGetSeconds(stage->timeRange.duration) * scaledDurationToWidth;
            
            CGFloat layerCount = [stage->layerNames count];
            CGRect layerRect = stageRect;
//            if (layerCount > 0)
//                layerRect.size.height /= layerCount;
            
            if (layerCount > 1)
                layerRect.origin.y += layerRect.size.height;
            
            for (NSString *layerName in stage->layerNames) {
                if ([layerName intValue] % 2 == 1) {
                    CGContextSetRGBFillColor(context, 0.55, 0.02, 0.02, 1.00); // darker red
                    CGContextSetRGBStrokeColor(context, 0.87, 0.10, 0.10, 1.00); // brighter red
                }
                else {
                    CGContextSetRGBFillColor(context, 0.00, 0.40, 0.76, 1.00); // darker blue
                    CGContextSetRGBStrokeColor(context, 0.00, 0.67, 1.00, 1.00); // brighter blue
                }
                CGContextSetLineWidth(context, 2.0);
                CGContextAddRect(context, CGRectInset(layerRect, 3.0, 1.0));
                CGContextDrawPath(context, kCGPathFillStroke);
                
                // (if there are two layers, the first should ideally have a gradient fill.)
                
                CGContextSetRGBFillColor(context, 0.00, 0.00, 0.00, 1.00); // white
                [[NSString stringWithFormat:@"%@", layerName] drawInRect:layerRect withAttributes:textAttributes];
                
                // Draw the opacity ramps for each layer as per the layerInstructions
                NSArray *rampArray = [stage->opacityRamps objectForKey:layerName];
                
                if ([rampArray count] > 0) {
                    CGRect rampRect = layerRect;
                    rampRect.size.width = CMTimeGetSeconds(duration) * scaledDurationToWidth;
                    rampRect = CGRectInset(rampRect, 3.0, 3.0);
                    
                    CGContextBeginPath(context);
                    CGContextSetRGBStrokeColor(context, 0.95, 0.68, 0.09, 1.00); // yellow
                    CGContextSetLineWidth(context, 2.0);
                    BOOL firstPoint = YES;
                    
                    for (NSValue *pointValue in rampArray) {
                        CGPoint timeVolumePoint = [pointValue pointValue];
                        CGPoint pointInRow;
                        
                        pointInRow.x = [self horizontalPositionForTime:CMTimeMakeWithSeconds(timeVolumePoint.x, 1)] - 3.0;
                        pointInRow.y = rampRect.origin.y - ( 0.9 - 0.8 * timeVolumePoint.y ) * rampRect.size.height + rampRect.size.height;
                        
                        pointInRow.x = MAX(pointInRow.x, CGRectGetMinX(rampRect));
                        pointInRow.x = MIN(pointInRow.x, CGRectGetMaxX(rampRect));
                        
                        if (firstPoint) {
                            CGContextMoveToPoint(context, pointInRow.x, pointInRow.y);
                            firstPoint = NO;
                        }
                        else {
                            CGContextAddLineToPoint(context, pointInRow.x, pointInRow.y);
                        }
                    }
                    CGContextStrokePath(context);
                }
                
                layerRect.origin.y -= layerRect.size.height;
            }
            
        }
        
        runningTop -= rowRect.size.height;
        runningTop -= kGapAfterRows;
    }
    
    if (audioMixTracks) {
        bannerRect.origin.y = runningTop;
        CGContextSetRGBFillColor(context, 0.00, 0.00, 0.00, 1.00); // white
        [[NSString stringWithFormat:@"AVAudioMix"] drawInRect:bannerRect withAttributes:[NSDictionary dictionaryWithObjectsAndKeys:[NSColor whiteColor], NSForegroundColorAttributeName,nil]];
        runningTop -= bannerRect.size.height;
        
        for (NSArray *mixTrack in audioMixTracks) {
            rowRect.origin.y = runningTop;
            
            CGRect rampRect = rowRect;
            rampRect.size.width = CMTimeGetSeconds(duration) * scaledDurationToWidth;
            rampRect = CGRectInset(rampRect, 3.0, 3.0);
            
            CGContextSetRGBFillColor(context, 0.55, 0.02, 0.02, 1.00); // darker red
            CGContextSetRGBStrokeColor(context, 0.87, 0.10, 0.10, 1.00); // brighter red
            CGContextSetLineWidth(context, 2.0);
            CGContextAddRect(context, rampRect);
            CGContextDrawPath(context, kCGPathFillStroke);
            
            CGContextBeginPath(context);
            CGContextSetRGBStrokeColor(context, 0.95, 0.68, 0.09, 1.00); // yellow
            CGContextSetLineWidth(context, 3.0);
            BOOL firstPoint = YES;
            for (NSValue *pointValue in mixTrack) {
                CGPoint timeVolumePoint = [pointValue pointValue];
                CGPoint pointInRow;
                
                pointInRow.x = rampRect.origin.x + timeVolumePoint.x * scaledDurationToWidth;
                pointInRow.y = rampRect.origin.y - ( 0.9 - 0.8 * timeVolumePoint.y ) * rampRect.size.height + rampRect.size.height;
                
                pointInRow.x = MAX(pointInRow.x, CGRectGetMinX(rampRect));
                pointInRow.x = MIN(pointInRow.x, CGRectGetMaxX(rampRect));
                
                if (firstPoint) {
                    CGContextMoveToPoint(context, pointInRow.x, pointInRow.y);
                    firstPoint = NO;
                }
                else {
                    CGContextAddLineToPoint(context, pointInRow.x, pointInRow.y);
                }
            }
            CGContextStrokePath(context);
            
            runningTop -= rowRect.size.height;
        }
        runningTop -= kGapAfterRows;
    }
    
    if (compositionTracks && self.player && !self.layer.sublayers) {
        NSRect visibleRect = self.layer.bounds;
        NSRect currentTimeRect = visibleRect;
        
        // The red band of the timeMaker will be 7 pixels wide
        currentTimeRect.origin.x = 0;
        currentTimeRect.size.width = 7;
        
        if(!timeMarkerRedBandLayer) {
            timeMarkerRedBandLayer = [CAShapeLayer layer];
            timeMarkerRedBandLayer.frame = currentTimeRect;
            timeMarkerRedBandLayer.position = CGPointMake(rowRect.origin.x, self.bounds.size.height / 2);
            CGPathRef linePath = CGPathCreateWithRect(currentTimeRect, NULL);
            timeMarkerRedBandLayer.fillColor = CGColorCreateGenericRGB(1.0, 0.0, 0.0, 0.5);
            timeMarkerRedBandLayer.path = linePath;
            
            CGPathRelease(linePath);
        }
        
        currentTimeRect.origin.x = 0;
        currentTimeRect.size.width = 1;
        
        if(!timeMarkerWhiteLineLayer) {
            // Position the white line layer of the timeMarker at the center of the red band layer
            timeMarkerWhiteLineLayer = [CAShapeLayer layer];
            timeMarkerWhiteLineLayer.frame = currentTimeRect;
            timeMarkerWhiteLineLayer.position = CGPointMake(3, self.bounds.size.height / 2);
            CGPathRef whiteLinePath = CGPathCreateWithRect(currentTimeRect, NULL);
            timeMarkerWhiteLineLayer.fillColor = CGColorCreateGenericRGB(1.0, 1.0, 1.0, 1.0);
            timeMarkerWhiteLineLayer.path = whiteLinePath;
            
            CGPathRelease(whiteLinePath);
        }
        
        // Add the white line layer to red band layer, by doing so we can only animate the red band layer which in turn animates its sublayers
        [timeMarkerRedBandLayer addSublayer:timeMarkerWhiteLineLayer];
        
        // This scrubbing animation controls the x position of the timeMarker
        // On the left side it is bound to where the first segment rectangle of the composition starts
        // On the right side it is bound to where the last segment rectangle of the composition ends
        // Playback at rate 1.0 would take the timeMarker "duration" time to reach from one end to the other, that is marked as the duration of the animation
        CABasicAnimation *scrubbingAnimation = [CABasicAnimation animationWithKeyPath:@"position.x"];
        scrubbingAnimation.fromValue = [NSNumber numberWithFloat:[self horizontalPositionForTime:kCMTimeZero]];
        scrubbingAnimation.toValue = [NSNumber numberWithFloat:[self horizontalPositionForTime:duration]];
        scrubbingAnimation.removedOnCompletion = NO;
        scrubbingAnimation.beginTime = AVCoreAnimationBeginTimeAtZero;
        scrubbingAnimation.duration = CMTimeGetSeconds(duration);
        scrubbingAnimation.fillMode = kCAFillModeBoth;
        [timeMarkerRedBandLayer addAnimation:scrubbingAnimation forKey:nil];
        
        // We add the red band layer along with the scrubbing animation to a AVSynchronizedLayer to have precise timing information
        AVSynchronizedLayer *syncLayer = [AVSynchronizedLayer synchronizedLayerWithPlayerItem:self.player.currentItem];
        [syncLayer addSublayer:timeMarkerRedBandLayer];
        
        [self.layer addSublayer:syncLayer];
    } else if(timeMarkerRedBandLayer) {
        // update height
        CGRect markerFrame = timeMarkerRedBandLayer.frame;
        CGFloat newHeight = self.layer.bounds.size.height;
        CGFloat diff = newHeight - markerFrame.size.height;
        markerFrame.size.height = newHeight;
        markerFrame.origin.y -= diff;
        timeMarkerRedBandLayer.frame = markerFrame;
//        [timeMarkerRedBandLayer setNeedsLayout];
//        [timeMarkerRedBandLayer layoutIfNeeded];
//        NSLog(@"updating marker frame: { %f,%f,%f,%f }, diff = %f", markerFrame.origin.x, markerFrame.origin.y, markerFrame.size.width, markerFrame.size.height, diff);
    }
}

- (double)horizontalPositionForTime:(CMTime)time
{
    double seconds = 0;
    if (CMTIME_IS_NUMERIC(time) && CMTIME_COMPARE_INLINE(time, >, kCMTimeZero))
        seconds = CMTimeGetSeconds(time);
    
    return seconds * scaledDurationToWidth + kLeftInsetToMatchTimeSlider + kLeftMarginInset;
}

@end
#else
enum { kLeftInsetToMatchTimeSlider = 50, kRightInsetToMatchTimeSlider = 60, kLeftMarginInset = 4};
enum { kBannerHeight = 20, kIdealRowHeight = 36, kGapAfterRows = 4 };

@interface NSString(CompositionViewStringDrawing)
- (void)drawVerticallyCenteredInRect:(CGRect)rect withAttributes:(NSDictionary *)attributes;
@end

@implementation NSString(CompositionViewStringDrawing)
- (void)drawVerticallyCenteredInRect:(CGRect)rect withAttributes:(NSDictionary *)attributes
{
    CGSize size = [self sizeWithAttributes:attributes];
    rect.origin.y += (rect.size.height - size.height) / 2.0;
    [self drawInRect:rect withAttributes:attributes];
}
@end

@interface APLCompositionTrackSegmentInfo : NSObject
{
@public
    CMTimeRange timeRange;
    BOOL        empty;
    NSString    *mediaType;
    NSString    *description;
}
@end

@implementation APLCompositionTrackSegmentInfo

@end

@interface APLVideoCompositionStageInfo : NSObject
{
@public
    CMTimeRange     timeRange;
    NSArray         *layerNames; // for videoComposition only
    NSDictionary *opacityRamps;
}
@end

@implementation APLVideoCompositionStageInfo

@end

@implementation APLCompositionDebugView

- (id)initWithFrame:(CGRect)frame
{
    if (self = [super initWithFrame:frame]) {
        drawingLayer = self.layer;
    }
    
    return self;
}

#pragma mark Value harvesting

- (void)synchronizeToComposition:(AVComposition *)composition videoComposition:(AVVideoComposition *)videoComposition audioMix:(AVAudioMix *)audioMix
{
    compositionTracks = nil;
    audioMixTracks = nil;
    videoCompositionStages = nil;
    
    duration = CMTimeMake(1, 1); // avoid division by zero later
    if (composition) {
        NSMutableArray *tracks = [[NSMutableArray alloc] init];
        for (AVCompositionTrack *t in composition.tracks) {
            NSMutableArray *segments = [[NSMutableArray alloc] init];
            for (AVCompositionTrackSegment *s in t.segments) {
                APLCompositionTrackSegmentInfo *segment = [[APLCompositionTrackSegmentInfo alloc] init] ;
                if (s.isEmpty)
                    segment->timeRange = s.timeMapping.target; // only used for duration
                else
                    segment->timeRange = s.timeMapping.source; // assumes non-scaled edit
                segment->empty = s.isEmpty;
                segment->mediaType = t.mediaType;
                if (! segment->empty) {
                    NSMutableString *description = [[NSMutableString alloc] init];
                    [description appendFormat:@"%1.1f - %1.1f: \"%@\" ", CMTimeGetSeconds(segment->timeRange.start), CMTimeGetSeconds(CMTimeRangeGetEnd(segment->timeRange)), [s.sourceURL lastPathComponent]];
                    if ([segment->mediaType isEqual:AVMediaTypeVideo])
                        [description appendString:@"(v)"];
                    else if ([segment->mediaType isEqual:AVMediaTypeAudio])
                        [description appendString:@"(a)"];
                    else
                        [description appendFormat:@"('%@')", segment->mediaType];
                    segment->description = description;
                }
                [segments addObject:segment];
            }
            
            [tracks addObject:segments];
        }
        
        compositionTracks = tracks;
        duration = CMTimeMaximum(duration, composition.duration);
    }
    
    if (audioMix) {
        NSMutableArray *mixTracks = [[NSMutableArray alloc] init];
        for (AVAudioMixInputParameters *input in audioMix.inputParameters) {
            NSMutableArray *ramp = [[NSMutableArray alloc] init];
            CMTime startTime = kCMTimeZero;
            float startVolume, endVolume = 1.0;
            CMTimeRange timeRange;
            while ([input getVolumeRampForTime:startTime startVolume:&startVolume endVolume:&endVolume timeRange:&timeRange]) {
                if (CMTIME_COMPARE_INLINE(startTime, ==, kCMTimeZero) && CMTIME_COMPARE_INLINE(timeRange.start, >, kCMTimeZero)) {
                    [ramp addObject:[NSValue valueWithCGPoint:CGPointMake(0, 1.0)]];
                    [ramp addObject:[NSValue valueWithCGPoint:CGPointMake(CMTimeGetSeconds(timeRange.start), 1.0)]];
                }
                [ramp addObject:[NSValue valueWithCGPoint:CGPointMake(CMTimeGetSeconds(timeRange.start), startVolume)]];
                [ramp addObject:[NSValue valueWithCGPoint:CGPointMake(CMTimeGetSeconds(CMTimeRangeGetEnd(timeRange)), endVolume)]];
                startTime = CMTimeRangeGetEnd(timeRange);
            }
            if (CMTIME_COMPARE_INLINE(startTime, <, duration))
                [ramp addObject:[NSValue valueWithCGPoint:CGPointMake(CMTimeGetSeconds(duration), endVolume)]];
            [mixTracks addObject:ramp];
        }
        audioMixTracks = mixTracks;
    }
    
    if (videoComposition) {
        NSMutableArray *stages = [[NSMutableArray alloc] init];
        for (AVVideoCompositionInstruction *instruction in videoComposition.instructions) {
            APLVideoCompositionStageInfo *stage = [[APLVideoCompositionStageInfo alloc] init];
            stage->timeRange = instruction.timeRange;
            NSMutableDictionary *rampsDictionary = [[NSMutableDictionary alloc] init];
            
//            if ([instruction isKindOfClass:[AVVideoCompositionInstruction class]]) {
//                NSMutableArray *layerNames = [[NSMutableArray alloc] init];
//                for (AVVideoCompositionLayerInstruction *layerInstruction in instruction.layerInstructions) {
//                    NSMutableArray *ramp = [[NSMutableArray alloc] init];
//                    CMTime startTime = kCMTimeZero;
//                    float startOpacity, endOpacity = 1.0;
//                    CMTimeRange timeRange;
//                    while ([layerInstruction getOpacityRampForTime:startTime startOpacity:&startOpacity endOpacity:&endOpacity timeRange:&timeRange]) {
//                        if (CMTIME_COMPARE_INLINE(startTime, ==, kCMTimeZero) && CMTIME_COMPARE_INLINE(timeRange.start, >, kCMTimeZero)) {
//                            [ramp addObject:[NSValue valueWithCGPoint:CGPointMake(CMTimeGetSeconds(timeRange.start), startOpacity)]];
//                        }
//                        [ramp addObject:[NSValue valueWithCGPoint:CGPointMake(CMTimeGetSeconds(CMTimeRangeGetEnd(timeRange)), endOpacity)]];
//                        startTime = CMTimeRangeGetEnd(timeRange);
//                    }
//
//                    NSString *name = [NSString stringWithFormat:@"%d", layerInstruction.trackID];
//                    [layerNames addObject:name];
//                    [rampsDictionary setObject:ramp forKey:name];
//                }
//
//                if ([layerNames count] > 1) {
//                    stage->opacityRamps = rampsDictionary;
//                }
                
                stage->layerNames = @[@"instruction"];
          [stages addObject:stage];
        }
        videoCompositionStages = stages;
    }
    
    [drawingLayer setNeedsDisplay];
}

#pragma mark View drawing

- (void)willMoveToSuperview:(UIView *)newSuperview
{
    drawingLayer.frame = self.bounds;
    drawingLayer.delegate = self;
    [drawingLayer setNeedsDisplay];
}

- (void)viewWillDisappear:(BOOL)animated
{
    drawingLayer.delegate = nil;
}

- (void)drawRect:(CGRect)rect
{
    CGContextRef context = UIGraphicsGetCurrentContext();
    
    rect = CGRectInset(rect, kLeftMarginInset, 4.0);
    
    NSMutableParagraphStyle *style = [[NSParagraphStyle defaultParagraphStyle] mutableCopy];
    [style setAlignment:NSTextAlignmentCenter];
    
    NSDictionary *textAttributes = [NSDictionary dictionaryWithObjectsAndKeys:[UIColor whiteColor], NSForegroundColorAttributeName, style, NSParagraphStyleAttributeName, nil];
    
    int numBanners = (compositionTracks != nil) + (audioMixTracks != nil) + (videoCompositionStages != nil);
    int numRows = (int)[compositionTracks count] + (int)[audioMixTracks count] + (videoCompositionStages != nil);
    
    CGFloat totalBannerHeight = numBanners * (kBannerHeight + kGapAfterRows);
    CGFloat rowHeight = kIdealRowHeight;
    if ( numRows > 0 ) {
        CGFloat maxRowHeight = (rect.size.height - totalBannerHeight) / numRows;
        rowHeight = MIN( rowHeight, maxRowHeight );
    }
    
    CGFloat runningTop = rect.origin.y;
    CGRect bannerRect = rect;
    bannerRect.size.height = kBannerHeight;
    bannerRect.origin.y = runningTop;
    
    CGRect rowRect = rect;
    rowRect.size.height = rowHeight;
    
    rowRect.origin.x += kLeftInsetToMatchTimeSlider;
    rowRect.size.width -= (kLeftInsetToMatchTimeSlider + kRightInsetToMatchTimeSlider);
    compositionRectWidth = rowRect.size.width;
    
    scaledDurationToWidth = compositionRectWidth / CMTimeGetSeconds(duration);
    
    if (compositionTracks) {
        bannerRect.origin.y = runningTop;
        CGContextSetRGBFillColor(context, 0.00, 0.00, 0.00, 1.00); // black
        [[NSString stringWithFormat:@"AVComposition"] drawInRect:bannerRect withAttributes:[NSDictionary dictionaryWithObjectsAndKeys:[UIColor whiteColor], NSForegroundColorAttributeName, nil]];
        
        runningTop += bannerRect.size.height;
        
        for (NSArray *track in compositionTracks) {
            rowRect.origin.y = runningTop;
            CGRect segmentRect = rowRect;
            for (APLCompositionTrackSegmentInfo *segment in track) {
                segmentRect.size.width = CMTimeGetSeconds(segment->timeRange.duration) * scaledDurationToWidth;
                
                if (segment->empty) {
                    CGContextSetRGBFillColor(context, 0.00, 0.00, 0.00, 1.00); // white
                    [@"Empty" drawVerticallyCenteredInRect:segmentRect withAttributes:textAttributes];
                }
                else {
                    if ([segment->mediaType isEqual:AVMediaTypeVideo]) {
                        CGContextSetRGBFillColor(context, 0.00, 0.36, 0.36, 1.00); // blue-green
                        CGContextSetRGBStrokeColor(context, 0.00, 0.50, 0.50, 1.00); // brigher blue-green
                    }
                    else {
                        CGContextSetRGBFillColor(context, 0.00, 0.24, 0.36, 1.00); // bluer-green
                        CGContextSetRGBStrokeColor(context, 0.00, 0.33, 0.60, 1.00); // brigher bluer-green
                    }
                    CGContextSetLineWidth(context, 2.0);
                    CGContextAddRect(context, CGRectInset(segmentRect, 3.0, 3.0));
                    CGContextDrawPath(context, kCGPathFillStroke);
                    
                    CGContextSetRGBFillColor(context, 0.00, 0.00, 0.00, 1.00); // white
                    [segment->description drawVerticallyCenteredInRect:segmentRect withAttributes:textAttributes];
                }
                
                segmentRect.origin.x += segmentRect.size.width;
            }
            
            runningTop += rowRect.size.height;
        }
        runningTop += kGapAfterRows;
    }
    
    if (videoCompositionStages) {
        bannerRect.origin.y = runningTop;
        CGContextSetRGBFillColor(context, 0.00, 0.00, 0.00, 1.00); // white
        [[NSString stringWithFormat:@"AVVideoComposition"] drawInRect:bannerRect withAttributes:[NSDictionary dictionaryWithObjectsAndKeys:[UIColor whiteColor], NSForegroundColorAttributeName,nil]];
        runningTop += bannerRect.size.height;
        
        rowRect.origin.y = runningTop;
        CGRect stageRect = rowRect;
        for (APLVideoCompositionStageInfo *stage in videoCompositionStages) {
            stageRect.size.width = CMTimeGetSeconds(stage->timeRange.duration) * scaledDurationToWidth;
            
            CGFloat layerCount = [stage->layerNames count];
            CGRect layerRect = stageRect;
            if (layerCount > 0)
                layerRect.size.height /= layerCount;
            
            for (NSString *layerName in stage->layerNames) {
                if ([layerName intValue] % 2 == 1) {
                    CGContextSetRGBFillColor(context, 0.55, 0.02, 0.02, 1.00); // darker red
                    CGContextSetRGBStrokeColor(context, 0.87, 0.10, 0.10, 1.00); // brighter red
                }
                else {
                    CGContextSetRGBFillColor(context, 0.00, 0.40, 0.76, 1.00); // darker blue
                    CGContextSetRGBStrokeColor(context, 0.00, 0.67, 1.00, 1.00); // brighter blue
                }
                CGContextSetLineWidth(context, 2.0);
                CGContextAddRect(context, CGRectInset(layerRect, 3.0, 1.0));
                CGContextDrawPath(context, kCGPathFillStroke);
                
                // (if there are two layers, the first should ideally have a gradient fill.)
                
                CGContextSetRGBFillColor(context, 0.00, 0.00, 0.00, 1.00); // white
                [layerName drawVerticallyCenteredInRect:layerRect withAttributes:textAttributes];
                
                // Draw the opacity ramps for each layer as per the layerInstructions
                NSArray *rampArray = [stage->opacityRamps objectForKey:layerName];
                
                if ([rampArray count] > 0) {
                    CGRect rampRect = layerRect;
                    rampRect.size.width = CMTimeGetSeconds(duration) * scaledDurationToWidth;
                    rampRect = CGRectInset(rampRect, 3.0, 3.0);
                    
                    CGContextBeginPath(context);
                    CGContextSetRGBStrokeColor(context, 0.95, 0.68, 0.09, 1.00); // yellow
                    CGContextSetLineWidth(context, 2.0);
                    BOOL firstPoint = YES;
                    
                    for (NSValue *pointValue in rampArray) {
                        CGPoint timeVolumePoint = [pointValue CGPointValue];
                        CGPoint pointInRow;
                        
                        pointInRow.x = [self horizontalPositionForTime:CMTimeMakeWithSeconds(timeVolumePoint.x, 1)] - 3.0;
                        pointInRow.y = rampRect.origin.y + ( 0.9 - 0.8 * timeVolumePoint.y ) * rampRect.size.height;
                        
                        pointInRow.x = MAX(pointInRow.x, CGRectGetMinX(rampRect));
                        pointInRow.x = MIN(pointInRow.x, CGRectGetMaxX(rampRect));
                        
                        if (firstPoint) {
                            CGContextMoveToPoint(context, pointInRow.x, pointInRow.y);
                            firstPoint = NO;
                        }
                        else {
                            CGContextAddLineToPoint(context, pointInRow.x, pointInRow.y);
                        }
                    }
                    CGContextStrokePath(context);
                }
                
                layerRect.origin.y += layerRect.size.height;
            }
            
            stageRect.origin.x += stageRect.size.width;
        }
        
        runningTop += rowRect.size.height;
        runningTop += kGapAfterRows;
    }
    
    if (audioMixTracks) {
        bannerRect.origin.y = runningTop;
        CGContextSetRGBFillColor(context, 0.00, 0.00, 0.00, 1.00); // white
        [[NSString stringWithFormat:@"AVAudioMix"] drawInRect:bannerRect withAttributes:[NSDictionary dictionaryWithObjectsAndKeys:[UIColor whiteColor], NSForegroundColorAttributeName,nil]];
        runningTop += bannerRect.size.height;
        
        for (NSArray *mixTrack in audioMixTracks) {
            rowRect.origin.y = runningTop;
            
            CGRect rampRect = rowRect;
            rampRect.size.width = CMTimeGetSeconds(duration) * scaledDurationToWidth;
            rampRect = CGRectInset(rampRect, 3.0, 3.0);
            
            CGContextSetRGBFillColor(context, 0.55, 0.02, 0.02, 1.00); // darker red
            CGContextSetRGBStrokeColor(context, 0.87, 0.10, 0.10, 1.00); // brighter red
            CGContextSetLineWidth(context, 2.0);
            CGContextAddRect(context, rampRect);
            CGContextDrawPath(context, kCGPathFillStroke);
            
            CGContextBeginPath(context);
            CGContextSetRGBStrokeColor(context, 0.95, 0.68, 0.09, 1.00); // yellow
            CGContextSetLineWidth(context, 3.0);
            BOOL firstPoint = YES;
            for (NSValue *pointValue in mixTrack) {
                CGPoint timeVolumePoint = [pointValue CGPointValue];
                CGPoint pointInRow;
                
                pointInRow.x = rampRect.origin.x + timeVolumePoint.x * scaledDurationToWidth;
                pointInRow.y = rampRect.origin.y + ( 0.9 - 0.8 * timeVolumePoint.y ) * rampRect.size.height;
                
                pointInRow.x = MAX(pointInRow.x, CGRectGetMinX(rampRect));
                pointInRow.x = MIN(pointInRow.x, CGRectGetMaxX(rampRect));
                
                if (firstPoint) {
                    CGContextMoveToPoint(context, pointInRow.x, pointInRow.y);
                    firstPoint = NO;
                }
                else {
                    CGContextAddLineToPoint(context, pointInRow.x, pointInRow.y);
                }
            }
            CGContextStrokePath(context);
            
            runningTop += rowRect.size.height;
        }
        runningTop += kGapAfterRows;
    }
    
    if (compositionTracks) {
        self.layer.sublayers = nil;
        CGRect visibleRect = self.layer.bounds;
        CGRect currentTimeRect = visibleRect;
        
        // The red band of the timeMaker will be 8 pixels wide
        currentTimeRect.origin.x = 0;
        currentTimeRect.size.width = 8;
        
        CAShapeLayer *timeMarkerRedBandLayer = [CAShapeLayer layer];
        timeMarkerRedBandLayer.frame = currentTimeRect;
        timeMarkerRedBandLayer.position = CGPointMake(rowRect.origin.x, self.bounds.size.height / 2);
        CGPathRef linePath = CGPathCreateWithRect(currentTimeRect, NULL);
        timeMarkerRedBandLayer.fillColor = [[UIColor colorWithRed:1.0 green:0.0 blue:0.0 alpha:0.5] CGColor];
        timeMarkerRedBandLayer.path = linePath;
        
        CGPathRelease(linePath);
        
        currentTimeRect.origin.x = 0;
        currentTimeRect.size.width = 1;
        
        // Position the white line layer of the timeMarker at the center of the red band layer
        CAShapeLayer *timeMarkerWhiteLineLayer = [CAShapeLayer layer];
        timeMarkerWhiteLineLayer.frame = currentTimeRect;
        timeMarkerWhiteLineLayer.position = CGPointMake(4, self.bounds.size.height / 2);
        CGPathRef whiteLinePath = CGPathCreateWithRect(currentTimeRect, NULL);
        timeMarkerWhiteLineLayer.fillColor = [[UIColor colorWithRed:1.0 green:1.0 blue:1.0 alpha:1.0] CGColor];
        timeMarkerWhiteLineLayer.path = whiteLinePath;
        
        CGPathRelease(whiteLinePath);
        
        // Add the white line layer to red band layer, by doing so we can only animate the red band layer which in turn animates its sublayers
        [timeMarkerRedBandLayer addSublayer:timeMarkerWhiteLineLayer];
        
        // This scrubbing animation controls the x position of the timeMarker
        // On the left side it is bound to where the first segment rectangle of the composition starts
        // On the right side it is bound to where the last segment rectangle of the composition ends
        // Playback at rate 1.0 would take the timeMarker "duration" time to reach from one end to the other, that is marked as the duration of the animation
        CABasicAnimation *scrubbingAnimation = [CABasicAnimation animationWithKeyPath:@"position.x"];
        scrubbingAnimation.fromValue = [NSNumber numberWithFloat:[self horizontalPositionForTime:kCMTimeZero]];
        scrubbingAnimation.toValue = [NSNumber numberWithFloat:[self horizontalPositionForTime:duration]];
        scrubbingAnimation.removedOnCompletion = NO;
        scrubbingAnimation.beginTime = AVCoreAnimationBeginTimeAtZero;
        scrubbingAnimation.duration = CMTimeGetSeconds(duration);
        scrubbingAnimation.fillMode = kCAFillModeBoth;
        [timeMarkerRedBandLayer addAnimation:scrubbingAnimation forKey:nil];
        
        // We add the red band layer along with the scrubbing animation to a AVSynchronizedLayer to have precise timing information
        AVSynchronizedLayer *syncLayer = [AVSynchronizedLayer synchronizedLayerWithPlayerItem:self.player.currentItem];
        [syncLayer addSublayer:timeMarkerRedBandLayer];
        
        [self.layer addSublayer:syncLayer];
    }
}

- (double)horizontalPositionForTime:(CMTime)time
{
    double seconds = 0;
    if (CMTIME_IS_NUMERIC(time) && CMTIME_COMPARE_INLINE(time, >, kCMTimeZero))
        seconds = CMTimeGetSeconds(time);
    
    return seconds * scaledDurationToWidth + kLeftInsetToMatchTimeSlider + kLeftMarginInset;
}

@end
#endif

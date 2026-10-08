// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "BetterPlayer.h"
#import <CoreImage/CoreImage.h>
#import <better_player/better_player-Swift.h>

static void* timeRangeContext = &timeRangeContext;
static void* statusContext = &statusContext;
static void* playbackLikelyToKeepUpContext = &playbackLikelyToKeepUpContext;
static void* playbackBufferEmptyContext = &playbackBufferEmptyContext;
static void* playbackBufferFullContext = &playbackBufferFullContext;
static void* presentationSizeContext = &presentationSizeContext;


#if TARGET_OS_IOS
void (^__strong _Nonnull _restoreUserInterfaceForPIPStopCompletionHandler)(BOOL);
API_AVAILABLE(ios(9.0))
AVPictureInPictureController *_pipController;
#endif

static NSString* const kFrameCaptureErrorUnsupported = @"unsupported";
static NSString* const kFrameCaptureErrorProtectedContent = @"protected_content";
static NSString* const kFrameCaptureErrorCopyFailed = @"copy_failed";
static NSString* const kFrameCaptureErrorUnavailable = @"unavailable";
// How long a capture waits for the video output to deliver a frame before giving up.
static const NSTimeInterval kFrameCaptureFrameTimeout = 1.0;
// A cached frame further than this from the playhead is no longer the one on screen.
static const NSTimeInterval kFrameCaptureCachedFrameTolerance = 0.5;
static const CGFloat kFrameCaptureJpegQuality = 0.9;
// Watermark metrics, kept identical to the Android implementation.
static const CGFloat kFrameCaptureWatermarkAlpha = 0.45;
static const CGFloat kFrameCaptureWatermarkMinFontSize = 14;
static const CGFloat kFrameCaptureWatermarkFontRatio = 0.035;

static FlutterError* FrameCaptureError(NSString* code, NSString* message) {
    return [FlutterError errorWithCode:code message:message details:nil];
}

@interface BetterPlayer () <AVPlayerItemOutputPullDelegate> {
    BOOL _frameCaptureEnabled;
    BOOL _isFairPlayProtected;
    AVPlayerItemVideoOutput* _videoOutput;
    AVPlayerItem* _videoOutputItem;
    // Last frame vended by the video output. A Core Foundation object, so it is retained and
    // released by hand.
    CVPixelBufferRef _lastPixelBuffer;
    CMTime _lastPixelBufferTime;
    dispatch_queue_t _captureQueue;
    CIContext* _captureContext;
    // The capture in flight: non-nil reply block from the request until the reply.
    FlutterResult _captureResult;
    NSString* _captureWatermark;
    BOOL _captureAwaitingFrame;
    // Identifies the capture in flight so a late timeout or render of an older one is ignored.
    NSUInteger _captureGeneration;
}
- (CVPixelBufferRef)copyCurrentPixelBuffer CF_RETURNS_RETAINED;
@end

@implementation BetterPlayer
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super init];
    NSAssert(self, @"super init cannot be nil");
    _isInitialized = false;
    _isPlaying = false;
    _disposed = false;
    _player = [[AVPlayer alloc] init];
    _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    ///Fix for loading large videos
    if (@available(iOS 10.0, *)) {
        _player.automaticallyWaitsToMinimizeStalling = false;
    }
    self._observersAdded = false;
    return self;
}

- (nonnull UIView *)view {
    BetterPlayerView *playerView = [[BetterPlayerView alloc] initWithFrame:CGRectZero];
    playerView.player = _player;
    return playerView;
}

- (void)addObservers:(AVPlayerItem*)item {
    if (!self._observersAdded){
        [_player addObserver:self forKeyPath:@"rate" options:0 context:nil];
        [item addObserver:self forKeyPath:@"loadedTimeRanges" options:0 context:timeRangeContext];
        [item addObserver:self forKeyPath:@"status" options:0 context:statusContext];
        [item addObserver:self forKeyPath:@"presentationSize" options:0 context:presentationSizeContext];
        [item addObserver:self
               forKeyPath:@"playbackLikelyToKeepUp"
                  options:0
                  context:playbackLikelyToKeepUpContext];
        [item addObserver:self
               forKeyPath:@"playbackBufferEmpty"
                  options:0
                  context:playbackBufferEmptyContext];
        [item addObserver:self
               forKeyPath:@"playbackBufferFull"
                  options:0
                  context:playbackBufferFullContext];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(itemDidPlayToEndTime:)
                                                     name:AVPlayerItemDidPlayToEndTimeNotification
                                                   object:item];
        self._observersAdded = true;
    }
}

- (void)clear {
    _isInitialized = false;
    _isPlaying = false;
    _disposed = false;
    _failedCount = 0;
    _key = nil;
    [self detachVideoOutput];
    if (_player.currentItem == nil) {
        return;
    }

    if (_player.currentItem == nil) {
        return;
    }

    [self removeObservers];
    AVAsset* asset = [_player.currentItem asset];
    [asset cancelLoading];
}

- (void) removeObservers{
    if (self._observersAdded){
        [_player removeObserver:self forKeyPath:@"rate" context:nil];
        [[_player currentItem] removeObserver:self forKeyPath:@"status" context:statusContext];
        [[_player currentItem] removeObserver:self forKeyPath:@"presentationSize" context:presentationSizeContext];
        [[_player currentItem] removeObserver:self
                                   forKeyPath:@"loadedTimeRanges"
                                      context:timeRangeContext];
        [[_player currentItem] removeObserver:self
                                   forKeyPath:@"playbackLikelyToKeepUp"
                                      context:playbackLikelyToKeepUpContext];
        [[_player currentItem] removeObserver:self
                                   forKeyPath:@"playbackBufferEmpty"
                                      context:playbackBufferEmptyContext];
        [[_player currentItem] removeObserver:self
                                   forKeyPath:@"playbackBufferFull"
                                      context:playbackBufferFullContext];
        [[NSNotificationCenter defaultCenter] removeObserver:self];
        self._observersAdded = false;
    }
}

- (void)itemDidPlayToEndTime:(NSNotification*)notification {
    if (_isLooping) {
        AVPlayerItem* p = [notification object];
        [p seekToTime:kCMTimeZero completionHandler:nil];
    } else {
        if (_eventSink) {
            _eventSink(@{@"event" : @"completed", @"key" : _key});
            [ self removeObservers];

        }
    }
}


static inline CGFloat radiansToDegrees(CGFloat radians) {
    // Input range [-pi, pi] or [-180, 180]
    CGFloat degrees = GLKMathRadiansToDegrees((float)radians);
    if (degrees < 0) {
        // Convert -90 to 270 and -180 to 180
        return degrees + 360;
    }
    // Output degrees in between [0, 360[
    return degrees;
};

- (AVMutableVideoComposition*)getVideoCompositionWithTransform:(CGAffineTransform)transform
                                                     withAsset:(AVAsset*)asset
                                                withVideoTrack:(AVAssetTrack*)videoTrack {
    AVMutableVideoCompositionInstruction* instruction =
    [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    instruction.timeRange = CMTimeRangeMake(kCMTimeZero, [asset duration]);
    AVMutableVideoCompositionLayerInstruction* layerInstruction =
    [AVMutableVideoCompositionLayerInstruction
     videoCompositionLayerInstructionWithAssetTrack:videoTrack];
    [layerInstruction setTransform:_preferredTransform atTime:kCMTimeZero];

    AVMutableVideoComposition* videoComposition = [AVMutableVideoComposition videoComposition];
    instruction.layerInstructions = @[ layerInstruction ];
    videoComposition.instructions = @[ instruction ];

    // If in portrait mode, switch the width and height of the video
    CGFloat width = videoTrack.naturalSize.width;
    CGFloat height = videoTrack.naturalSize.height;
    NSInteger rotationDegrees =
    (NSInteger)round(radiansToDegrees(atan2(_preferredTransform.b, _preferredTransform.a)));
    if (rotationDegrees == 90 || rotationDegrees == 270) {
        width = videoTrack.naturalSize.height;
        height = videoTrack.naturalSize.width;
    }
    videoComposition.renderSize = CGSizeMake(width, height);

    float nominalFrameRate = videoTrack.nominalFrameRate;
    int fps = 30;
    if (nominalFrameRate > 0) {
        fps = (int) ceil(nominalFrameRate);
    }
    videoComposition.frameDuration = CMTimeMake(1, fps);
    
    return videoComposition;
}

- (CGAffineTransform)fixTransform:(AVAssetTrack*)videoTrack {
  CGAffineTransform transform = videoTrack.preferredTransform;
  // TODO(@recastrodiaz): why do we need to do this? Why is the preferredTransform incorrect?
  // At least 2 user videos show a black screen when in portrait mode if we directly use the
  // videoTrack.preferredTransform Setting tx to the height of the video instead of 0, properly
  // displays the video https://github.com/flutter/flutter/issues/17606#issuecomment-413473181
  NSInteger rotationDegrees = (NSInteger)round(radiansToDegrees(atan2(transform.b, transform.a)));
  if (rotationDegrees == 90) {
    transform.tx = videoTrack.naturalSize.height;
    transform.ty = 0;
  } else if (rotationDegrees == 180) {
    transform.tx = videoTrack.naturalSize.width;
    transform.ty = videoTrack.naturalSize.height;
  } else if (rotationDegrees == 270) {
    transform.tx = 0;
    transform.ty = videoTrack.naturalSize.width;
  }
  return transform;
}

- (void)setDataSourceAsset:(NSString*)asset withKey:(NSString*)key withCertificateUrl:(NSString*)certificateUrl withLicenseUrl:(NSString*)licenseUrl cacheKey:(NSString*)cacheKey cacheManager:(CacheManager*)cacheManager overriddenDuration:(int) overriddenDuration{
    NSString* path = [[NSBundle mainBundle] pathForResource:asset ofType:nil];
    return [self setDataSourceURL:[NSURL fileURLWithPath:path] withKey:key withCertificateUrl:certificateUrl withLicenseUrl:(NSString*)licenseUrl withHeaders: @{} withCache: false cacheKey:cacheKey cacheManager:cacheManager overriddenDuration:overriddenDuration videoExtension: nil];
}

- (void)setDataSourceURL:(NSURL*)url withKey:(NSString*)key withCertificateUrl:(NSString*)certificateUrl withLicenseUrl:(NSString*)licenseUrl withHeaders:(NSDictionary*)headers withCache:(BOOL)useCache cacheKey:(NSString*)cacheKey cacheManager:(CacheManager*)cacheManager overriddenDuration:(int) overriddenDuration videoExtension: (NSString*) videoExtension{
    _overriddenDuration = 0;
    _isFairPlayProtected = false;
    if (headers == [NSNull null] || headers == NULL){
        headers = @{};
    }
    
    AVPlayerItem* item;
    if (useCache){
        if (cacheKey == [NSNull null]){
            cacheKey = nil;
        }
        if (videoExtension == [NSNull null]){
            videoExtension = nil;
        }
        
        item = [cacheManager getCachingPlayerItemForNormalPlayback:url cacheKey:cacheKey videoExtension: videoExtension headers:headers];
    } else {
        AVURLAsset* asset = [AVURLAsset URLAssetWithURL:url
                                                options:@{@"AVURLAssetHTTPHeaderFieldsKey" : headers}];
        if (certificateUrl && certificateUrl != [NSNull null] && [certificateUrl length] > 0) {
            NSURL * certificateNSURL = [[NSURL alloc] initWithString: certificateUrl];
            NSURL * licenseNSURL = [[NSURL alloc] initWithString: licenseUrl];
            _loaderDelegate = [[BetterPlayerEzDrmAssetsLoaderDelegate alloc] init:certificateNSURL withLicenseURL:licenseNSURL];
            dispatch_queue_attr_t qos = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_DEFAULT, -1);
            dispatch_queue_t streamQueue = dispatch_queue_create("streamQueue", qos);
            [asset.resourceLoader setDelegate:_loaderDelegate queue:streamQueue];
            _isFairPlayProtected = true;
        }
        item = [AVPlayerItem playerItemWithAsset:asset];
    }

    if (@available(iOS 10.0, *) && overriddenDuration > 0) {
        _overriddenDuration = overriddenDuration;
    }
    return [self setDataSourcePlayerItem:item withKey:key];
}

- (void)setDataSourcePlayerItem:(AVPlayerItem*)item withKey:(NSString*)key{
    _key = key;
    _stalledCount = 0;
    _isStalledCheckStarted = false;
    _playerRate = 1;
    [self detachVideoOutput];
    [_player replaceCurrentItemWithPlayerItem:item];

    AVAsset* asset = [item asset];
    void (^assetCompletionHandler)(void) = ^{
        if ([asset statusOfValueForKey:@"tracks" error:nil] == AVKeyValueStatusLoaded) {
            NSArray* tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
            if ([tracks count] > 0) {
                AVAssetTrack* videoTrack = tracks[0];
                void (^trackCompletionHandler)(void) = ^{
                    if (self->_disposed) return;
                    if ([videoTrack statusOfValueForKey:@"preferredTransform"
                                                  error:nil] == AVKeyValueStatusLoaded) {
                        // Rotate the video by using a videoComposition and the preferredTransform
                        self->_preferredTransform = [self fixTransform:videoTrack];
                        // Note:
                        // https://developer.apple.com/documentation/avfoundation/avplayeritem/1388818-videocomposition
                        // Video composition can only be used with file-based media and is not supported for
                        // use with media served using HTTP Live Streaming.
                        AVMutableVideoComposition* videoComposition =
                        [self getVideoCompositionWithTransform:self->_preferredTransform
                                                     withAsset:asset
                                                withVideoTrack:videoTrack];
                        item.videoComposition = videoComposition;
                    }
                };
                [videoTrack loadValuesAsynchronouslyForKeys:@[ @"preferredTransform" ]
                                          completionHandler:trackCompletionHandler];
            }
        }
    };

    [asset loadValuesAsynchronouslyForKeys:@[ @"tracks" ] completionHandler:assetCompletionHandler];
    [self addObservers:item];
}

-(void)handleStalled {
    if (_isStalledCheckStarted){
        return;
    }
   _isStalledCheckStarted = true;
    [self startStalledCheck];
}

-(void)startStalledCheck{
    if (_player.currentItem.playbackLikelyToKeepUp ||
        [self availableDuration] - CMTimeGetSeconds(_player.currentItem.currentTime) > 10.0) {
        [self play];
    } else {
        _stalledCount++;
        if (_stalledCount > 60){
            if (_eventSink != nil) {
                _eventSink([FlutterError
                        errorWithCode:@"VideoError"
                        message:@"Failed to load video: playback stalled"
                        details:nil]);
            }
            return;
        }
        [self performSelector:@selector(startStalledCheck) withObject:nil afterDelay:1];

    }
}

- (NSTimeInterval) availableDuration
{
    NSArray *loadedTimeRanges = [[_player currentItem] loadedTimeRanges];
    if (loadedTimeRanges.count > 0){
        CMTimeRange timeRange = [[loadedTimeRanges objectAtIndex:0] CMTimeRangeValue];
        Float64 startSeconds = CMTimeGetSeconds(timeRange.start);
        Float64 durationSeconds = CMTimeGetSeconds(timeRange.duration);
        NSTimeInterval result = startSeconds + durationSeconds;
        return result;
    } else {
        return 0;
    }

}

- (void)observeValueForKeyPath:(NSString*)path
                      ofObject:(id)object
                        change:(NSDictionary*)change
                       context:(void*)context {

    if ([path isEqualToString:@"rate"]) {
        if (@available(iOS 10.0, *)) {
            if (_pipController.pictureInPictureActive == true){
                if (_lastAvPlayerTimeControlStatus != [NSNull null] && _lastAvPlayerTimeControlStatus == _player.timeControlStatus){
                    return;
                }

                if (_player.timeControlStatus == AVPlayerTimeControlStatusPaused){
                    _lastAvPlayerTimeControlStatus = _player.timeControlStatus;
                    if (_eventSink != nil) {
                      _eventSink(@{@"event" : @"pause"});
                    }
                    return;

                }
                if (_player.timeControlStatus == AVPlayerTimeControlStatusPlaying){
                    _lastAvPlayerTimeControlStatus = _player.timeControlStatus;
                    if (_eventSink != nil) {
                      _eventSink(@{@"event" : @"play"});
                    }
                }
            }
        }

        if (_player.rate == 0 && //if player rate dropped to 0
            CMTIME_COMPARE_INLINE(_player.currentItem.currentTime, >, kCMTimeZero) && //if video was started
            CMTIME_COMPARE_INLINE(_player.currentItem.currentTime, <, _player.currentItem.duration) && //but not yet finished
            _isPlaying) { //instance variable to handle overall state (changed to YES when user triggers playback)
            [self handleStalled];
        }
    }

    if (context == timeRangeContext) {
        if (_eventSink != nil) {
            NSMutableArray<NSArray<NSNumber*>*>* values = [[NSMutableArray alloc] init];
            for (NSValue* rangeValue in [object loadedTimeRanges]) {
                CMTimeRange range = [rangeValue CMTimeRangeValue];
                int64_t start = [BetterPlayerTimeUtils FLTCMTimeToMillis:(range.start)];
                int64_t end = start + [BetterPlayerTimeUtils FLTCMTimeToMillis:(range.duration)];
                if (!CMTIME_IS_INVALID(_player.currentItem.forwardPlaybackEndTime)) {
                    int64_t endTime = [BetterPlayerTimeUtils FLTCMTimeToMillis:(_player.currentItem.forwardPlaybackEndTime)];
                    if (end > endTime){
                        end = endTime;
                    }
                }

                [values addObject:@[ @(start), @(end) ]];
            }
            _eventSink(@{@"event" : @"bufferingUpdate", @"values" : values, @"key" : _key});
        }
    }
    else if (context == presentationSizeContext){
        [self onReadyToPlay];
    }

    else if (context == statusContext) {
        AVPlayerItem* item = (AVPlayerItem*)object;
        switch (item.status) {
            case AVPlayerItemStatusFailed:
                NSLog(@"Failed to load video:");
                NSLog(item.error.debugDescription);

                if (_eventSink != nil) {
                    _eventSink([FlutterError
                                errorWithCode:@"VideoError"
                                message:[@"Failed to load video: "
                                         stringByAppendingString:[item.error localizedDescription]]
                                details:nil]);
                }
                break;
            case AVPlayerItemStatusUnknown:
                break;
            case AVPlayerItemStatusReadyToPlay:
                [self onReadyToPlay];
                break;
        }
    } else if (context == playbackLikelyToKeepUpContext) {
        if ([[_player currentItem] isPlaybackLikelyToKeepUp]) {
            [self updatePlayingState];
            if (_eventSink != nil) {
                _eventSink(@{@"event" : @"bufferingEnd", @"key" : _key});
            }
        }
    } else if (context == playbackBufferEmptyContext) {
        if (_eventSink != nil) {
            _eventSink(@{@"event" : @"bufferingStart", @"key" : _key});
        }
    } else if (context == playbackBufferFullContext) {
        if (_eventSink != nil) {
            _eventSink(@{@"event" : @"bufferingEnd", @"key" : _key});
        }
    }
}

- (void)updatePlayingState {
    if (!_isInitialized || !_key) {
        return;
    }
    if (!self._observersAdded){
        [self addObservers:[_player currentItem]];
    }

    if (_isPlaying) {
        if (@available(iOS 10.0, *)) {
            [_player playImmediatelyAtRate:1.0];
            _player.rate = _playerRate;
        } else {
            [_player play];
            _player.rate = _playerRate;
        }
    } else {
        [_player pause];
    }
}

- (void)onReadyToPlay {
    if (_eventSink && !_isInitialized && _key) {
        if (!_player.currentItem) {
            return;
        }
        if (_player.status != AVPlayerStatusReadyToPlay) {
            return;
        }

        CGSize size = [_player currentItem].presentationSize;
        CGFloat width = size.width;
        CGFloat height = size.height;


        AVAsset *asset = _player.currentItem.asset;
        bool onlyAudio =  [[asset tracksWithMediaType:AVMediaTypeVideo] count] == 0;

        // The player has not yet initialized.
        if (!onlyAudio && height == CGSizeZero.height && width == CGSizeZero.width) {
            return;
        }
        const BOOL isLive = CMTIME_IS_INDEFINITE([_player currentItem].duration);
        // The player may be initialized but still needs to determine the duration.
        if (isLive == false && [self duration] == 0) {
            return;
        }

        //Fix from https://github.com/flutter/flutter/issues/66413
        AVPlayerItemTrack *track = [self.player currentItem].tracks.firstObject;
        CGSize naturalSize = track.assetTrack.naturalSize;
        CGAffineTransform prefTrans = track.assetTrack.preferredTransform;
        CGSize realSize = CGSizeApplyAffineTransform(naturalSize, prefTrans);

        int64_t duration = [BetterPlayerTimeUtils FLTCMTimeToMillis:(_player.currentItem.asset.duration)];
        if (_overriddenDuration > 0 && duration > _overriddenDuration){
            _player.currentItem.forwardPlaybackEndTime = CMTimeMake(_overriddenDuration/1000, 1);
        }

        _isInitialized = true;
        [self attachVideoOutputIfNeeded];
        [self updatePlayingState];
        _eventSink(@{
            @"event" : @"initialized",
            @"duration" : @([self duration]),
            @"width" : @(fabs(realSize.width) ? : width),
            @"height" : @(fabs(realSize.height) ? : height),
            @"key" : _key
        });
    }
}

- (void)play {
    _stalledCount = 0;
    _isStalledCheckStarted = false;
    _isPlaying = true;
    [self updatePlayingState];
}

- (void)pause {
    _isPlaying = false;
    [self updatePlayingState];
}

- (int64_t)position {
    return [BetterPlayerTimeUtils FLTCMTimeToMillis:([_player currentTime])];
}

- (int64_t)absolutePosition {
    return [BetterPlayerTimeUtils FLTNSTimeIntervalToMillis:([[[_player currentItem] currentDate] timeIntervalSince1970])];
}

- (int64_t)duration {
    CMTime time;
    if (@available(iOS 13, *)) {
        time =  [[_player currentItem] duration];
    } else {
        time =  [[[_player currentItem] asset] duration];
    }
    if (!CMTIME_IS_INVALID(_player.currentItem.forwardPlaybackEndTime)) {
        time = [[_player currentItem] forwardPlaybackEndTime];
    }

    return [BetterPlayerTimeUtils FLTCMTimeToMillis:(time)];
}

- (void)seekTo:(int)location {
    ///When player is playing, pause video, seek to new position and start again. This will prevent issues with seekbar jumps.
    bool wasPlaying = _isPlaying;
    if (wasPlaying){
        [_player pause];
    }

    [_player seekToTime:CMTimeMake(location, 1000)
        toleranceBefore:kCMTimeZero
         toleranceAfter:kCMTimeZero
      completionHandler:^(BOOL finished){
        if (wasPlaying){
            _player.rate = _playerRate;
        }
    }];
}

- (void)setIsLooping:(bool)isLooping {
    _isLooping = isLooping;
}

- (void)setVolume:(double)volume {
    _player.volume = (float)((volume < 0.0) ? 0.0 : ((volume > 1.0) ? 1.0 : volume));
}

- (void)setSpeed:(double)speed result:(FlutterResult)result {
    if (speed == 1.0 || speed == 0.0) {
        _playerRate = 1;
        result(nil);
    } else if (speed < 0 || speed > 2.0) {
        result([FlutterError errorWithCode:@"unsupported_speed"
                                   message:@"Speed must be >= 0.0 and <= 2.0"
                                   details:nil]);
  } else if ((speed > 1.0) || (speed < 1.0)) { _playerRate = speed; result(nil); } else {

        if (speed > 1.0) {
            result([FlutterError errorWithCode:@"unsupported_fast_forward"
                                       message:@"This video cannot be played fast forward"
                                       details:nil]);
        } else {
            result([FlutterError errorWithCode:@"unsupported_slow_forward"
                                       message:@"This video cannot be played slow forward"
                                       details:nil]);
        }
    }

    if (_isPlaying){
        _player.rate = _playerRate;
    }
}


- (void)setTrackParameters:(int) width: (int) height: (int)bitrate {
    _player.currentItem.preferredPeakBitRate = bitrate;
    if (@available(iOS 11.0, *)) {
        if (width == 0 && height == 0){
            _player.currentItem.preferredMaximumResolution = CGSizeZero;
        } else {
            _player.currentItem.preferredMaximumResolution = CGSizeMake(width, height);
        }
    }
}

- (void)setPictureInPicture:(BOOL)pictureInPicture
{
    self._pictureInPicture = pictureInPicture;
    if (@available(iOS 9.0, *)) {
        if (_pipController && self._pictureInPicture && ![_pipController isPictureInPictureActive]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [_pipController startPictureInPicture];
            });
        } else if (_pipController && !self._pictureInPicture && [_pipController isPictureInPictureActive]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [_pipController stopPictureInPicture];
            });
        } else {
            // Fallback on earlier versions
        } }
}

#if TARGET_OS_IOS
- (void)setRestoreUserInterfaceForPIPStopCompletionHandler:(BOOL)restore
{
    if (_restoreUserInterfaceForPIPStopCompletionHandler != NULL) {
        _restoreUserInterfaceForPIPStopCompletionHandler(restore);
        _restoreUserInterfaceForPIPStopCompletionHandler = NULL;
    }
}

- (void)setupPipController {
    if (@available(iOS 9.0, *)) {
        [[AVAudioSession sharedInstance] setActive: YES error: nil];
        [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
        if (!_pipController && self._playerLayer && [AVPictureInPictureController isPictureInPictureSupported]) {
            _pipController = [[AVPictureInPictureController alloc] initWithPlayerLayer:self._playerLayer];
            _pipController.delegate = self;
        }
    } else {
        // Fallback on earlier versions
    }
}

- (void) enablePictureInPicture: (CGRect) frame{
    [self disablePictureInPicture];
    [self usePlayerLayer:frame];
}

- (void)usePlayerLayer: (CGRect) frame
{
    if( _player )
    {
        // Create new controller passing reference to the AVPlayerLayer
        self._playerLayer = [AVPlayerLayer playerLayerWithPlayer:_player];
        UIViewController* vc = [[[UIApplication sharedApplication] keyWindow] rootViewController];
        self._playerLayer.frame = frame;
        self._playerLayer.needsDisplayOnBoundsChange = YES;
        //  [self._playerLayer addObserver:self forKeyPath:readyForDisplayKeyPath options:NSKeyValueObservingOptionNew context:nil];
        [vc.view.layer addSublayer:self._playerLayer];
        vc.view.layer.needsDisplayOnBoundsChange = YES;
        if (@available(iOS 9.0, *)) {
            _pipController = NULL;
        }
        [self setupPipController];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self setPictureInPicture:true];
        });
    }
}

- (void)disablePictureInPicture
{
    [self setPictureInPicture:true];
    if (__playerLayer){
        [self._playerLayer removeFromSuperlayer];
        self._playerLayer = nil;
        if (_eventSink != nil) {
            _eventSink(@{@"event" : @"pipStop"});
        }
    }
}
#endif

#if TARGET_OS_IOS
- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController  API_AVAILABLE(ios(9.0)){
    [self disablePictureInPicture];
}

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController  API_AVAILABLE(ios(9.0)){
    if (_eventSink != nil) {
        _eventSink(@{@"event" : @"pipStart"});
    }
}

- (void)pictureInPictureControllerWillStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController  API_AVAILABLE(ios(9.0)){

}

- (void)pictureInPictureControllerWillStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {

}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController failedToStartPictureInPictureWithError:(NSError *)error {

}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completionHandler {
    [self setRestoreUserInterfaceForPIPStopCompletionHandler: true];
}

- (void) setAudioTrack:(NSString*) name index:(int) index{
    AVMediaSelectionGroup *audioSelectionGroup = [[[_player currentItem] asset] mediaSelectionGroupForMediaCharacteristic: AVMediaCharacteristicAudible];
    NSArray* options = audioSelectionGroup.options;


    for (int audioTrackIndex = 0; audioTrackIndex < [options count]; audioTrackIndex++) {
        AVMediaSelectionOption* option = [options objectAtIndex:audioTrackIndex];
        NSArray *metaDatas = [AVMetadataItem metadataItemsFromArray:option.commonMetadata withKey:@"title" keySpace:@"comn"];
        if (metaDatas.count > 0) {
            NSString *title = ((AVMetadataItem*)[metaDatas objectAtIndex:0]).stringValue;
            if ([name compare:title] == NSOrderedSame && audioTrackIndex == index ){
                [[_player currentItem] selectMediaOption:option inMediaSelectionGroup: audioSelectionGroup];
            }
        }

    }

}

- (void)setMixWithOthers:(bool)mixWithOthers {
  if (mixWithOthers) {
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                     withOptions:AVAudioSessionCategoryOptionMixWithOthers
                                           error:nil];
  } else {
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
  }
}


#endif

- (FlutterError* _Nullable)onCancelWithArguments:(id _Nullable)arguments {
    _eventSink = nil;
    return nil;
}

- (FlutterError* _Nullable)onListenWithArguments:(id _Nullable)arguments
                                       eventSink:(nonnull FlutterEventSink)events {
    _eventSink = events;
    // TODO(@recastrodiaz): remove the line below when the race condition is resolved:
    // https://github.com/flutter/flutter/issues/21483
    // This line ensures the 'initialized' event is sent when the event
    // 'AVPlayerItemStatusReadyToPlay' fires before _eventSink is set (this function
    // onListenWithArguments is called)
    [self onReadyToPlay];
    return nil;
}

/// This method allows you to dispose without touching the event channel.  This
/// is useful for the case where the Engine is in the process of deconstruction
/// so the channel is going to die or is already dead.
- (void)disposeSansEventChannel {
    @try{
        [self clear];
    }
    @catch(NSException *exception) {
        NSLog(exception.debugDescription);
    }
}

- (void)dispose {
    [self pause];
    [self disposeSansEventChannel];
    [_eventChannel setStreamHandler:nil];
    [self disablePictureInPicture];
    [self setPictureInPicture:false];
    _disposed = true;
}

#pragma mark - Frame capture

- (void)dealloc {
    CVPixelBufferRelease(_lastPixelBuffer);
}

- (void)setFrameCaptureEnabled:(BOOL)enabled {
    _frameCaptureEnabled = enabled;
    if (enabled) {
        [self attachVideoOutputIfNeeded];
    } else {
        [self detachVideoOutput];
    }
}

- (void)attachVideoOutputIfNeeded {
    AVPlayerItem* item = _player.currentItem;
    if (!_frameCaptureEnabled || _videoOutput != nil || !_isInitialized || item == nil) {
        return;
    }
    // No pixel buffer attributes: the output vends frames in the decoder's native format.
    // Asking for BGRA would convert every decoded frame for as long as the output stays
    // attached, while a capture only ever needs one of them.
    _videoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:nil];
    [_videoOutput setDelegate:self queue:dispatch_get_main_queue()];
    [item addOutput:_videoOutput];
    _videoOutputItem = item;
}

/// Safe to call when nothing is attached. The enabled flag is left alone so the next item
/// gets an output again.
- (void)detachVideoOutput {
    [self finishCapture:_captureGeneration
              withValue:FrameCaptureError(kFrameCaptureErrorUnavailable,
                                          @"The video changed before the frame was captured")];
    if (_videoOutput != nil) {
        [_videoOutput setDelegate:nil queue:NULL];
        if ([_videoOutputItem.outputs containsObject:_videoOutput]) {
            [_videoOutputItem removeOutput:_videoOutput];
        }
        _videoOutput = nil;
        _videoOutputItem = nil;
    }
    [self cachePixelBuffer:NULL displayTime:kCMTimeInvalid];
}

- (void)captureFrameWithWatermark:(NSString*)watermarkText result:(FlutterResult)result {
    FlutterError* guardError = [self frameCaptureGuardError];
    if (guardError != nil) {
        result(guardError);
        return;
    }
    NSUInteger generation = ++_captureGeneration;
    _captureResult = result;
    _captureWatermark = [BetterPlayer drawableWatermark:watermarkText];

    CVPixelBufferRef pixelBuffer = [self copyCurrentPixelBuffer];
    if (pixelBuffer != NULL) {
        [self renderPixelBuffer:pixelBuffer forCapture:generation];
        CVPixelBufferRelease(pixelBuffer);
    } else {
        [self awaitFrameForCapture:generation];
    }
}

- (FlutterError*)frameCaptureGuardError {
    if (_disposed || _player.currentItem == nil) {
        return FrameCaptureError(kFrameCaptureErrorUnavailable, @"The player has no video");
    }
    if (!_frameCaptureEnabled) {
        return FrameCaptureError(kFrameCaptureErrorUnsupported,
                                 @"Frame capture is not enabled for this player");
    }
    if (_videoOutput == nil) {
        return FrameCaptureError(kFrameCaptureErrorUnavailable, @"The video is not ready yet");
    }
    // While the video plays on an AirPlay device it is not decoded locally, so the output
    // has no frames to give.
    if (_player.isExternalPlaybackActive) {
        return FrameCaptureError(kFrameCaptureErrorUnavailable,
                                 @"The video is playing on an external device");
    }
    if (_captureResult != nil) {
        return FrameCaptureError(kFrameCaptureErrorUnavailable,
                                 @"A frame capture is already in progress");
    }
    return nil;
}

/// The channel delivers a missing watermark as nil or NSNull, and blank text draws nothing.
+ (NSString*)drawableWatermark:(id)watermarkText {
    if (![watermarkText isKindOfClass:[NSString class]]) {
        return nil;
    }
    NSCharacterSet* blank = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    return [watermarkText stringByTrimmingCharactersInSet:blank].length > 0 ? watermarkText : nil;
}

/// Returns the frame at the playhead, retained for the caller, or NULL when the output has
/// none to give yet.
- (CVPixelBufferRef)copyCurrentPixelBuffer {
    CMTime itemTime = [_videoOutput itemTimeForHostTime:CACurrentMediaTime()];
    if (!CMTIME_IS_NUMERIC(itemTime)) {
        itemTime = _player.currentItem.currentTime;
    }
    // Not gated on hasNewPixelBufferForItemTime: it only reports frames that were not vended
    // yet, which says nothing about whether a frame is on screen.
    CMTime displayTime = kCMTimeInvalid;
    CVPixelBufferRef pixelBuffer = [_videoOutput copyPixelBufferForItemTime:itemTime
                                                         itemTimeForDisplay:&displayTime];
    if (pixelBuffer != NULL) {
        [self cachePixelBuffer:pixelBuffer
                   displayTime:CMTIME_IS_NUMERIC(displayTime) ? displayTime : itemTime];
        return pixelBuffer;
    }
    // The output hands each frame out only once, so NULL also means "you already have it":
    // a second capture while paused ends up here. The cached frame is still the one on screen
    // as long as the playhead has not moved away from it.
    if (_lastPixelBuffer != NULL && CMTIME_IS_NUMERIC(itemTime) &&
        fabs(CMTimeGetSeconds(CMTimeSubtract(itemTime, _lastPixelBufferTime))) <=
            kFrameCaptureCachedFrameTolerance) {
        return CVPixelBufferRetain(_lastPixelBuffer);
    }
    return NULL;
}

- (void)cachePixelBuffer:(CVPixelBufferRef)pixelBuffer displayTime:(CMTime)displayTime {
    CVPixelBufferRetain(pixelBuffer);
    CVPixelBufferRelease(_lastPixelBuffer);
    _lastPixelBuffer = pixelBuffer;
    _lastPixelBufferTime = displayTime;
}

- (void)awaitFrameForCapture:(NSUInteger)generation {
    _captureAwaitingFrame = YES;
    [_videoOutput requestNotificationOfMediaDataChangeWithAdvanceInterval:0];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kFrameCaptureFrameTimeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf frameWaitDidTimeOutForCapture:generation];
    });
}

- (void)outputMediaDataWillChange:(AVPlayerItemOutput*)sender {
    if (sender != _videoOutput || !_captureAwaitingFrame) {
        return;
    }
    CVPixelBufferRef pixelBuffer = [self copyCurrentPixelBuffer];
    if (pixelBuffer == NULL) {
        // Still nothing to copy: the timeout makes the last attempt.
        return;
    }
    [self renderPixelBuffer:pixelBuffer forCapture:_captureGeneration];
    CVPixelBufferRelease(pixelBuffer);
}

- (void)frameWaitDidTimeOutForCapture:(NSUInteger)generation {
    // That capture already got its frame or was failed, possibly with a newer one waiting now.
    if (generation != _captureGeneration || !_captureAwaitingFrame) {
        return;
    }
    CVPixelBufferRef pixelBuffer = [self copyCurrentPixelBuffer];
    if (pixelBuffer != NULL) {
        [self renderPixelBuffer:pixelBuffer forCapture:generation];
        CVPixelBufferRelease(pixelBuffer);
        return;
    }
    // FairPlay frames are never exposed to the app, so for such a source this is the cause.
    FlutterError* error = _isFairPlayProtected
        ? FrameCaptureError(kFrameCaptureErrorProtectedContent, @"The video is protected")
        : FrameCaptureError(kFrameCaptureErrorUnavailable, @"No video frame is available");
    [self finishCapture:generation withValue:error];
}

/// Preferred transform to apply to the frames of the current item, identity when they are
/// already upright.
- (CGAffineTransform)frameCaptureOrientation {
    // A video composition (file based media) renders the frames upright. Without one, which
    // is always the case for HLS, the output vends them the way they were encoded.
    if (_videoOutputItem.videoComposition != nil) {
        return CGAffineTransformIdentity;
    }
    for (AVPlayerItemTrack* track in _videoOutputItem.tracks) {
        AVAssetTrack* assetTrack = track.assetTrack;
        if ([assetTrack.mediaType isEqualToString:AVMediaTypeVideo]) {
            return assetTrack.preferredTransform;
        }
    }
    return CGAffineTransformIdentity;
}

- (dispatch_queue_t)captureQueue {
    if (_captureQueue == nil) {
        // Utility QoS so encoding a screenshot never competes with playback or the UI.
        dispatch_queue_attr_t attributes =
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        _captureQueue = dispatch_queue_create("better_player.frame_capture", attributes);
    }
    return _captureQueue;
}

/// Converts and encodes the frame off the main thread. The background block deliberately
/// does not reference self, so the player can never be released on the capture queue.
- (void)renderPixelBuffer:(CVPixelBufferRef)pixelBuffer forCapture:(NSUInteger)generation {
    _captureAwaitingFrame = NO;
    CGAffineTransform orientation = [self frameCaptureOrientation];
    NSString* watermark = _captureWatermark;
    CIContext* existingContext = _captureContext;
    __weak typeof(self) weakSelf = self;
    // Blocks do not retain Core Foundation objects, the buffer has to be kept alive for the hop.
    CVPixelBufferRetain(pixelBuffer);
    dispatch_async([self captureQueue], ^{
        // Building a context is expensive, so it happens here on first use and the context is
        // handed back to be reused. Intermediates of a one-off frame are not worth caching.
        CIContext* context = existingContext
            ?: [CIContext contextWithOptions:@{kCIContextCacheIntermediates : @NO}];
        NSData* jpegData = [BetterPlayer jpegDataFromPixelBuffer:pixelBuffer
                                                     orientation:orientation
                                                       watermark:watermark
                                                         context:context];
        CVPixelBufferRelease(pixelBuffer);
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf didRenderJpegData:jpegData withContext:context forCapture:generation];
        });
    });
}

- (void)didRenderJpegData:(NSData*)jpegData
              withContext:(CIContext*)context
               forCapture:(NSUInteger)generation {
    _captureContext = context;
    if (jpegData == nil) {
        [self finishCapture:generation
                  withValue:FrameCaptureError(kFrameCaptureErrorCopyFailed,
                                              @"The video frame could not be encoded")];
        return;
    }
    [self finishCapture:generation
              withValue:[FlutterStandardTypedData typedDataWithBytes:jpegData]];
}

/// Replies to the capture in flight exactly once; a call for a capture that already got its
/// reply does nothing.
- (void)finishCapture:(NSUInteger)generation withValue:(id)value {
    if (generation != _captureGeneration || _captureResult == nil) {
        return;
    }
    FlutterResult result = _captureResult;
    _captureResult = nil;
    _captureWatermark = nil;
    _captureAwaitingFrame = NO;
    result(value);
}

+ (NSData*)jpegDataFromPixelBuffer:(CVPixelBufferRef)pixelBuffer
                       orientation:(CGAffineTransform)orientation
                         watermark:(NSString*)watermark
                           context:(CIContext*)context {
    NSData* jpegData = nil;
    @autoreleasepool {
        UIImage* frame = [self frameImageFromPixelBuffer:pixelBuffer
                                             orientation:orientation
                                                 context:context];
        if (frame != nil) {
            UIImage* image = [self imageByDrawingWatermark:watermark overFrame:frame];
            jpegData = UIImageJPEGRepresentation(image, kFrameCaptureJpegQuality);
        }
    }
    return jpegData;
}

+ (UIImage*)frameImageFromPixelBuffer:(CVPixelBufferRef)pixelBuffer
                          orientation:(CGAffineTransform)orientation
                              context:(CIContext*)context {
    CIImage* image = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    if (image != nil && !CGAffineTransformIsIdentity(orientation)) {
        // The preferred transform is defined for a top-left origin while Core Image uses a
        // bottom-left one, hence the mirrored rotation terms. Its translation is dropped:
        // the result is moved back to the origin instead.
        image = [image imageByApplyingTransform:CGAffineTransformMake(orientation.a,
                                                                      -orientation.b,
                                                                      -orientation.c,
                                                                      orientation.d, 0, 0)];
        image = [image imageByApplyingTransform:
                 CGAffineTransformMakeTranslation(-image.extent.origin.x, -image.extent.origin.y)];
    }
    if (image == nil || CGRectIsEmpty(image.extent) || CGRectIsInfinite(image.extent)) {
        return nil;
    }
    CGImageRef cgImage = [context createCGImage:image fromRect:image.extent];
    if (cgImage == NULL) {
        return nil;
    }
    UIImage* frame = [UIImage imageWithCGImage:cgImage];
    CGImageRelease(cgImage);
    return frame;
}

+ (UIImage*)imageByDrawingWatermark:(NSString*)watermark overFrame:(UIImage*)frame {
    UIGraphicsImageRendererFormat* format = [UIGraphicsImageRendererFormat defaultFormat];
    // Scale 1 keeps the result at the video's pixel size instead of the screen's scale.
    format.scale = 1;
    format.opaque = YES;
    if (@available(iOS 12.0, *)) {
        // A wide colour backing store would only double the memory of an 8 bit JPEG.
        format.preferredRange = UIGraphicsImageRendererFormatRangeStandard;
    }
    CGRect bounds = CGRectMake(0, 0, frame.size.width, frame.size.height);
    UIGraphicsImageRenderer* renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:bounds.size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext* rendererContext) {
        [frame drawInRect:bounds];
        [self drawWatermark:watermark inRect:bounds];
    }];
}

+ (void)drawWatermark:(NSString*)watermark inRect:(CGRect)bounds {
    if (watermark == nil) {
        return;
    }
    CGFloat fontSize = MAX(kFrameCaptureWatermarkMinFontSize,
                           kFrameCaptureWatermarkFontRatio *
                               MIN(bounds.size.width, bounds.size.height));
    NSShadow* shadow = [[NSShadow alloc] init];
    shadow.shadowColor = [UIColor colorWithWhite:0 alpha:kFrameCaptureWatermarkAlpha];
    shadow.shadowBlurRadius = fontSize / 8;
    shadow.shadowOffset = CGSizeZero;
    NSDictionary* attributes = @{
        NSFontAttributeName : [UIFont systemFontOfSize:fontSize],
        NSForegroundColorAttributeName : [UIColor colorWithWhite:1
                                                           alpha:kFrameCaptureWatermarkAlpha],
        NSShadowAttributeName : shadow
    };
    CGSize textSize = [watermark sizeWithAttributes:attributes];
    [watermark drawAtPoint:CGPointMake(CGRectGetMidX(bounds) - textSize.width / 2,
                                       CGRectGetMidY(bounds) - textSize.height / 2)
            withAttributes:attributes];
}

@end

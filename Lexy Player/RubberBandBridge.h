#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C wrapper around RubberBandStretcher (real-time, R3/Finer engine).
/// Exposes a simple push/pull interface suitable for use from an AVAudioSourceNode render callback.
@interface RBProcessor : NSObject

/// @param sampleRate   The sample rate of the audio (e.g. 44100, 48000).
/// @param channels     Number of channels (1 = mono, 2 = stereo).
- (instancetype)initWithSampleRate:(double)sampleRate channels:(NSUInteger)channels;

/// Time ratio: output_duration / input_duration.
/// 1.0 = original speed, 2.0 = half speed (twice as long), 0.5 = double speed.
@property (nonatomic) double timeRatio;

/// Pitch scale: output_frequency / input_frequency.
/// 1.0 = no pitch change, 2.0 = one octave up, ~0.5 = one octave down.
/// Use pow(2, semitones/12) to convert from semitones.
@property (nonatomic) double pitchScale;

/// Reset internal state (call when seeking or loading a new file).
- (void)reset;

/// Number of input frames the stretcher would like before it can produce output.
/// Feed at least this many frames via -processLeft:right:frames:isFinal:.
@property (nonatomic, readonly) NSInteger samplesRequired;

/// Number of output frames ready to retrieve.
@property (nonatomic, readonly) NSInteger available;

/// Push interleaved or planar stereo frames into the stretcher.
/// @param left    Pointer to left-channel samples (non-null).
/// @param right   Pointer to right-channel samples (may equal left for mono).
/// @param frames  Number of frames to process.
/// @param isFinal YES if this is the last block of the stream.
- (void)processLeft:(const float *)left
              right:(const float *)right
             frames:(NSInteger)frames
            isFinal:(BOOL)isFinal;

/// Pull output frames from the stretcher.
/// @param left      Destination buffer for left channel.
/// @param right     Destination buffer for right channel (may equal left for mono).
/// @param maxFrames Maximum number of frames to retrieve.
/// @return          Actual number of frames written.
- (NSInteger)retrieveLeft:(float *)left
                    right:(float *)right
                maxFrames:(NSInteger)maxFrames;

@end

NS_ASSUME_NONNULL_END

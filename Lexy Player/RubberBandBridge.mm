#import "RubberBandBridge.h"
#include "RubberBand/rubberband/RubberBandStretcher.h"
#include <memory>

using RubberBand::RubberBandStretcher;

@implementation RBProcessor {
    std::unique_ptr<RubberBandStretcher> _stretcher;
    NSUInteger _channels;
}

- (instancetype)initWithSampleRate:(double)sampleRate channels:(NSUInteger)channels {
    self = [super init];
    if (self) {
        _channels = channels;

        // Real-time mode + R3 (Finer) engine for highest quality pitch-preserving
        // time-stretching. R3 needs more CPU than R2 but sounds significantly better
        // for music. Toggling masterTempo switches pitchScale between "locked" and
        // "vinyl" (tracks the time ratio).
        RubberBandStretcher::Options opts =
            RubberBandStretcher::OptionProcessRealTime |
            RubberBandStretcher::OptionEngineFiner;

        _stretcher = std::make_unique<RubberBandStretcher>(
            (size_t)sampleRate,
            (size_t)channels,
            opts,
            1.0,   // initial time ratio
            1.0    // initial pitch scale
        );

        // Prime the stretcher — it needs a few ms of silence before audio
        // to fill its internal latency pipeline in real-time mode.
        _stretcher->setMaxProcessSize(4096);
    }
    return self;
}

// MARK: - Properties

- (double)timeRatio { return _stretcher->getTimeRatio(); }
- (void)setTimeRatio:(double)ratio {
    _stretcher->setTimeRatio(ratio > 0.0 ? ratio : 1.0);
}

- (double)pitchScale { return _stretcher->getPitchScale(); }
- (void)setPitchScale:(double)scale {
    _stretcher->setPitchScale(scale > 0.0 ? scale : 1.0);
}

// MARK: - Control

- (void)reset {
    _stretcher->reset();
}

- (NSInteger)samplesRequired {
    return (NSInteger)_stretcher->getSamplesRequired();
}

- (NSInteger)available {
    return (NSInteger)_stretcher->available();
}

// MARK: - Push / Pull

- (void)processLeft:(const float *)left
              right:(const float *)right
             frames:(NSInteger)frames
            isFinal:(BOOL)isFinal {
    if (_channels == 1) {
        const float *bufs[1] = { left };
        _stretcher->process(bufs, (size_t)frames, isFinal == YES);
    } else {
        const float *bufs[2] = { left, right };
        _stretcher->process(bufs, (size_t)frames, isFinal == YES);
    }
}

- (NSInteger)retrieveLeft:(float *)left
                    right:(float *)right
                maxFrames:(NSInteger)maxFrames {
    if (_channels == 1) {
        float *bufs[1] = { left };
        return (NSInteger)_stretcher->retrieve(bufs, (size_t)maxFrames);
    } else {
        float *bufs[2] = { left, right };
        return (NSInteger)_stretcher->retrieve(bufs, (size_t)maxFrames);
    }
}

@end

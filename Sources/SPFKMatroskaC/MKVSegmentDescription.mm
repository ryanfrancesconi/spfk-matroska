// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi

#import "MKVDescription+Internal.h"

@implementation MKVSegmentDescription

- (instancetype)initWithDocType:(NSString *)docType
                           info:(const mkvparser::SegmentInfo *)info
                         tracks:(NSArray<MKVTrackDescription *> *)tracks {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _docType = [docType copy];
    _tracks = [tracks copy];
    _title = MKVStringOrNil(info->GetTitleAsUTF8());
    _muxingApp = MKVStringOrNil(info->GetMuxingAppAsUTF8());
    _writingApp = MKVStringOrNil(info->GetWritingAppAsUTF8());
    _timecodeScale = info->GetTimeCodeScale();

    // The parser returns -1 for a file that states no Duration, which live captures legitimately
    // do. Normalized to 0 so "unknown" has one spelling rather than two.
    const long long duration = info->GetDuration();
    _durationNanoseconds = duration < 0 ? 0 : duration;

    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<MKVSegmentDescription %@ %lldns tracks:%lu>",
                                      _docType, _durationNanoseconds,
                                      (unsigned long)_tracks.count];
}

@end

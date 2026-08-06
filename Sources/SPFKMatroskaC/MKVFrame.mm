// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi

#import "MKVDescription+Internal.h"

@implementation MKVFrame

- (instancetype)initWithTrackNumber:(long long)trackNumber
                               data:(NSData *)data
               timestampNanoseconds:(long long)timestampNanoseconds
                durationNanoseconds:(long long)durationNanoseconds
                         isKeyframe:(BOOL)isKeyframe {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _trackNumber = trackNumber;
    _data = [data copy];
    _timestampNanoseconds = timestampNanoseconds;
    _durationNanoseconds = durationNanoseconds;
    _isKeyframe = isKeyframe;

    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<MKVFrame track:%lld %lldns %lu bytes%@>", _trackNumber,
                                      _timestampNanoseconds, (unsigned long)_data.length,
                                      _isKeyframe ? @" key" : @""];
}

@end

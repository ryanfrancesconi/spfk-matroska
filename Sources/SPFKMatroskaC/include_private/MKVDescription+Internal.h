// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi

// ObjC++ -- names mkvparser types, so it can only be imported from a .mm.

#import <Foundation/Foundation.h>

#import "MKVDemuxer.h"
#import "MKVFrame.h"
#import "MKVSegmentDescription.h"
#import "MKVTrackDescription.h"

#import <mkvparser/mkvparser.h>

NS_ASSUME_NONNULL_BEGIN

/// Converts a parser-owned C string, which is NULL for any element the file omits.
NSString *_Nullable MKVStringOrNil(const char *_Nullable value);

NSError *MKVMakeError(MKVError code, NSURL *url, NSString *reason);

/// Builds the description for an already-parsed segment. Shared so opening a file for frames and
/// opening it for headers cannot drift into reporting different things about the same file.
MKVSegmentDescription *_Nullable MKVMakeSegmentDescription(mkvparser::Segment *segment,
                                                           NSString *docType,
                                                           NSURL *url,
                                                           NSError **error);

@interface MKVTrackDescription ()
- (instancetype)initWithTrack:(const mkvparser::Track *)track;
@end

@interface MKVSegmentDescription ()
- (instancetype)initWithDocType:(NSString *)docType
                           info:(const mkvparser::SegmentInfo *)info
                         tracks:(NSArray<MKVTrackDescription *> *)tracks;
@end

@interface MKVFrame ()
- (instancetype)initWithTrackNumber:(long long)trackNumber
                               data:(NSData *)data
               timestampNanoseconds:(long long)timestampNanoseconds
                durationNanoseconds:(long long)durationNanoseconds
                         isKeyframe:(BOOL)isKeyframe;
@end

NS_ASSUME_NONNULL_END

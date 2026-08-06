// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi

#import <Foundation/Foundation.h>

#import "MKVSegmentDescription.h"

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const MKVErrorDomain;

typedef NS_ERROR_ENUM(MKVErrorDomain, MKVError) {
    /// The file could not be opened for reading.
    MKVErrorUnreadableFile = 1,
    /// No valid EBML header -- the file is not Matroska or WebM at all.
    MKVErrorNotMatroska = 2,
    /// An EBML header is present but the segment headers are malformed.
    MKVErrorMalformedSegment = 3,
    /// Headers parsed, but the file declares no tracks.
    MKVErrorNoTracks = 4,
};

/// Reads Matroska and WebM containers.
///
/// This demuxes and does not decode -- it hands back track descriptions and, later, compressed
/// frames. Decoding is VideoToolbox's job and shipping a decoder is a standing non-goal; see
/// `plans/matroska-demuxer.md`.
@interface MKVDemuxer : NSObject

/// Parses the EBML and segment headers, stopping at the first cluster. Cheap: it reads the front
/// of the file, not the frame data.
+ (nullable MKVSegmentDescription *)readSegmentDescriptionAtURL:(NSURL *)url
                                                          error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

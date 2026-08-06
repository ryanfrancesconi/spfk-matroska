// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi

#import "MKVDemuxer.h"
#import "MKVDescription+Internal.h"
#import <mkvparser/mkvreader.h>
#import <memory>

NSErrorDomain const MKVErrorDomain = @"com.spongefork.matroska";

NSError *MKVMakeError(MKVError code, NSURL *url, NSString *reason) {
    return [NSError errorWithDomain:MKVErrorDomain
                               code:code
                           userInfo:@{
                               NSLocalizedDescriptionKey : reason,
                               NSURLErrorKey : url,
                           }];
}

MKVSegmentDescription *_Nullable MKVMakeSegmentDescription(mkvparser::Segment *segment,
                                                           NSString *docType,
                                                           NSURL *url,
                                                           NSError **error) {
    const mkvparser::SegmentInfo *info = segment->GetInfo();

    if (info == nullptr) {
        if (error != nullptr) {
            *error = MKVMakeError(MKVErrorMalformedSegment, url, @"Segment states no info.");
        }
        return nil;
    }

    const mkvparser::Tracks *tracks = segment->GetTracks();
    const unsigned long trackCount = tracks == nullptr ? 0 : tracks->GetTracksCount();

    if (trackCount == 0) {
        if (error != nullptr) {
            *error = MKVMakeError(MKVErrorNoTracks, url, @"The file declares no tracks.");
        }
        return nil;
    }

    NSMutableArray<MKVTrackDescription *> *descriptions = [NSMutableArray arrayWithCapacity:trackCount];

    for (unsigned long index = 0; index < trackCount; index++) {
        const mkvparser::Track *track = tracks->GetTrackByIndex(index);

        // A TrackEntry the parser could not build comes back null while its siblings stay valid,
        // so skip it rather than failing the whole file.
        if (track == nullptr) {
            continue;
        }

        [descriptions addObject:[[MKVTrackDescription alloc] initWithTrack:track]];
    }

    return [[MKVSegmentDescription alloc] initWithDocType:docType info:info tracks:descriptions];
}

@implementation MKVDemuxer

+ (nullable MKVSegmentDescription *)readSegmentDescriptionAtURL:(NSURL *)url error:(NSError **)error {
    mkvparser::MkvReader reader;

    if (reader.Open(url.fileSystemRepresentation) != 0) {
        if (error != nullptr) {
            *error = MKVMakeError(MKVErrorUnreadableFile, url, @"Could not open the file.");
        }
        return nil;
    }

    mkvparser::EBMLHeader header;
    long long position = 0;

    if (header.Parse(&reader, position) < 0) {
        if (error != nullptr) {
            *error = MKVMakeError(MKVErrorNotMatroska, url, @"Not a Matroska or WebM file.");
        }
        return nil;
    }

    NSString *docType = MKVStringOrNil(header.m_docType) ?: @"matroska";

    mkvparser::Segment *rawSegment = nullptr;

    // Returns nonzero on failure, and only assigns the out parameter on success.
    if (mkvparser::Segment::CreateInstance(&reader, position, rawSegment) != 0 || rawSegment == nullptr) {
        if (error != nullptr) {
            *error = MKVMakeError(MKVErrorMalformedSegment, url, @"No readable segment.");
        }
        return nil;
    }

    std::unique_ptr<mkvparser::Segment> segment(rawSegment);

    // Stops at the first cluster, so this reads the front of the file rather than the frame data.
    if (segment->ParseHeaders() < 0) {
        if (error != nullptr) {
            *error = MKVMakeError(MKVErrorMalformedSegment, url, @"Malformed segment headers.");
        }
        return nil;
    }

    return MKVMakeSegmentDescription(segment.get(), docType, url, error);
}

@end

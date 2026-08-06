// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi

#import "MKVFrameReader.h"
#import "MKVDescription+Internal.h"
#import <mkvparser/mkvreader.h>
#import <common/webmids.h>

@interface MKVFrameReader ()
@property (nonatomic, readwrite, nullable) NSError *failure;
@end

@implementation MKVFrameReader {
    // The reader must outlive the segment, which holds a borrowed pointer to it.
    mkvparser::MkvReader *_reader;
    mkvparser::Segment *_segment;

    // Walk position: the cluster being read, the entry within it, and the frame within that entry's
    // block. A block can carry several frames through lacing, which is why the index is needed.
    const mkvparser::Cluster *_cluster;
    const mkvparser::BlockEntry *_blockEntry;
    int _frameIndex;

    BOOL _finished;
    NSURL *_url;
    NSDictionary<NSNumber *, NSNumber *> *_defaultDurations;
}

- (nullable instancetype)initWithURL:(NSURL *)url error:(NSError **)error {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    _url = url;
    _reader = new mkvparser::MkvReader();

    if (_reader->Open(url.fileSystemRepresentation) != 0) {
        if (error != nullptr) {
            *error = MKVMakeError(MKVErrorUnreadableFile, url, @"Could not open the file.");
        }
        return nil;
    }

    mkvparser::EBMLHeader header;
    long long position = 0;

    if (header.Parse(_reader, position) < 0) {
        if (error != nullptr) {
            *error = MKVMakeError(MKVErrorNotMatroska, url, @"Not a Matroska or WebM file.");
        }
        return nil;
    }

    NSString *docType = MKVStringOrNil(header.m_docType) ?: @"matroska";

    mkvparser::Segment *rawSegment = nullptr;

    if (mkvparser::Segment::CreateInstance(_reader, position, rawSegment) != 0 || rawSegment == nullptr) {
        if (error != nullptr) {
            *error = MKVMakeError(MKVErrorMalformedSegment, url, @"No readable segment.");
        }
        return nil;
    }

    _segment = rawSegment;

    if (_segment->ParseHeaders() < 0) {
        if (error != nullptr) {
            *error = MKVMakeError(MKVErrorMalformedSegment, url, @"Malformed segment headers.");
        }
        return nil;
    }

    MKVSegmentDescription *description = MKVMakeSegmentDescription(_segment, docType, url, error);

    if (description == nil) {
        return nil;
    }

    _segmentDescription = description;

    // Cached because a frame's duration comes from its track, and looking it up per frame would
    // walk the track list for every one of them.
    NSMutableDictionary<NSNumber *, NSNumber *> *durations = [NSMutableDictionary dictionary];

    for (MKVTrackDescription *track in description.tracks) {
        durations[@(track.number)] = @(track.defaultDuration);
    }

    _defaultDurations = durations;

    return self;
}

- (void)dealloc {
    // Segment first: it borrows the reader.
    delete _segment;
    delete _reader;
}

/// The cluster after `current`, or the first when `current` is null, loading from the file only as
/// far as needed. Returns null at a clean end (``_finished``) or on failure (``failure``).
- (const mkvparser::Cluster *)clusterAfter:(const mkvparser::Cluster *)current {
    while (true) {
        const mkvparser::Cluster *next =
            (current == nullptr) ? _segment->GetFirst() : _segment->GetNext(current);

        if (next != nullptr && !next->EOS()) {
            return next;
        }

        // EOS here means "not loaded yet", not necessarily end of file -- the parser hands back the
        // EOS sentinel and expects the caller to load more if it wants more.
        if (_segment->DoneParsing()) {
            _finished = YES;
            return nullptr;
        }

        const unsigned long countBefore = _segment->GetCount();

        long long position = 0;
        long length = 0;

        if (_segment->LoadCluster(position, length) < 0) {
            self.failure = MKVMakeError(MKVErrorMalformedSegment, _url, @"Failed to load a cluster.");
            return nullptr;
        }

        // A load that adds no cluster and does not report done would spin forever, which is what a
        // truncated file produces. Treat it as the end rather than hanging.
        if (_segment->GetCount() == countBefore) {
            _finished = YES;
            return nullptr;
        }
    }
}

/// The Cues index, parsing it on demand.
///
/// `ParseHeaders` stops at the first cluster and the Cues element is written at the *end* of the
/// file, so the segment has no index until someone asks for it -- the SeekHead is the only thing
/// pointing at it, and following that entry is what turns a seek from a scan into a lookup.
- (nullable const mkvparser::Cues *)loadCues {
    if (const mkvparser::Cues *cues = _segment->GetCues()) {
        return cues;
    }

    const mkvparser::SeekHead *seekHead = _segment->GetSeekHead();

    if (seekHead == nullptr) {
        return nullptr;
    }

    for (int index = 0; index < seekHead->GetCount(); index++) {
        const mkvparser::SeekHead::Entry *entry = seekHead->GetEntry(index);

        if (entry == nullptr || entry->id != libwebm::kMkvCues) {
            continue;
        }

        long long position = 0;
        long length = 0;

        if (_segment->ParseCues(entry->pos, position, length) < 0) {
            return nullptr;
        }

        return _segment->GetCues();
    }

    return nullptr;
}

- (BOOL)seekToTimeNanoseconds:(long long)timeNanoseconds
                  trackNumber:(long long)trackNumber
                        error:(NSError **)error {
    const mkvparser::Tracks *tracks = _segment->GetTracks();
    const mkvparser::Track *track = tracks == nullptr ? nullptr : tracks->GetTrackByNumber((long)trackNumber);

    if (track == nullptr) {
        if (error != nullptr) {
            *error = MKVMakeError(MKVErrorNoTracks, _url, @"No such track.");
        }
        return NO;
    }

    const mkvparser::Cues *cues = [self loadCues];

    if (cues == nullptr) {
        if (error != nullptr) {
            *error = MKVMakeError(MKVErrorNoSeekIndex, _url, @"The file carries no Cues index.");
        }
        return NO;
    }

    // Cue points load lazily; a lookup against a partially loaded index silently finds the wrong
    // keyframe, so the whole index is read before searching it.
    while (!cues->DoneParsing()) {
        cues->LoadCuePoint();
    }

    const mkvparser::CuePoint *cuePoint = nullptr;
    const mkvparser::CuePoint::TrackPosition *trackPosition = nullptr;

    if (!cues->Find(timeNanoseconds, track, cuePoint, trackPosition) || cuePoint == nullptr ||
        trackPosition == nullptr) {
        if (error != nullptr) {
            *error = MKVMakeError(MKVErrorNoSeekIndex, _url, @"No cue point for that time.");
        }
        return NO;
    }

    const mkvparser::BlockEntry *entry = cues->GetBlock(cuePoint, trackPosition);

    if (entry == nullptr || entry->EOS()) {
        if (error != nullptr) {
            *error = MKVMakeError(MKVErrorMalformedSegment, _url, @"The cue point names no block.");
        }
        return NO;
    }

    _cluster = entry->GetCluster();
    _blockEntry = entry;
    _frameIndex = 0;
    _finished = NO;
    self.failure = nil;

    return YES;
}

- (nullable MKVFrame *)nextFrame {
    if (_segment == nullptr || _finished || self.failure != nil) {
        return nil;
    }

    while (true) {
        if (_blockEntry == nullptr) {
            const mkvparser::Cluster *next = [self clusterAfter:_cluster];

            if (next == nullptr) {
                return nil;
            }

            _cluster = next;

            const mkvparser::BlockEntry *entry = nullptr;

            if (_cluster->GetFirst(entry) < 0) {
                self.failure = MKVMakeError(MKVErrorMalformedSegment, _url, @"Failed to read a cluster.");
                return nil;
            }

            // An empty cluster is legal; move on rather than treating it as the end.
            if (entry == nullptr || entry->EOS()) {
                continue;
            }

            _blockEntry = entry;
            _frameIndex = 0;
        }

        const mkvparser::Block *block = _blockEntry->GetBlock();

        if (block == nullptr || _frameIndex >= block->GetFrameCount()) {
            const mkvparser::BlockEntry *next = nullptr;

            if (_cluster->GetNext(_blockEntry, next) < 0) {
                self.failure = MKVMakeError(MKVErrorMalformedSegment, _url, @"Failed to advance a cluster.");
                return nil;
            }

            // Null moves the walk to the next cluster on the following pass.
            _blockEntry = (next != nullptr && !next->EOS()) ? next : nullptr;
            _frameIndex = 0;
            continue;
        }

        const mkvparser::Block::Frame &frame = block->GetFrame(_frameIndex);
        _frameIndex++;

        NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)frame.len];

        if (data == nil) {
            self.failure = MKVMakeError(MKVErrorMalformedSegment, _url, @"Frame length is not readable.");
            return nil;
        }

        if (frame.Read(_reader, (unsigned char *)data.mutableBytes) < 0) {
            self.failure = MKVMakeError(MKVErrorMalformedSegment, _url, @"Failed to read frame data.");
            return nil;
        }

        const long long trackNumber = block->GetTrackNumber();

        return [[MKVFrame alloc] initWithTrackNumber:trackNumber
                                                data:data
                                timestampNanoseconds:block->GetTime(_cluster)
                                 durationNanoseconds:_defaultDurations[@(trackNumber)].longLongValue
                                          isKeyframe:block->IsKey()];
    }
}

@end

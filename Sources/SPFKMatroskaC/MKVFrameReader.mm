// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi

#import "MKVFrameReader.h"
#import "MKVDescription+Internal.h"
#import <mkvparser/mkvreader.h>
#import <common/webmids.h>

@interface MKVFrameReader ()
@property (nonatomic, readwrite, nullable) NSError *failure;
@end

/// How many SeekHead elements deep to follow before giving up. Two levels is the shape real files
/// have; the cap exists so a file whose SeekHeads point at each other cannot loop.
static const int MKVMaxSeekHeadDepth = 4;

/// The segment-relative position of the `Cues` element reachable from the SeekHead at
/// `seekHeadOffset`, or -1.
///
/// libwebm keeps only the **first** SeekHead and its `Parse` never follows an entry that names
/// another one, so a file written in the usual two-level form -- a small SeekHead at the head of
/// the file naming a second one at the tail, which names Cues -- looks to it like a file with no
/// index at all. Walking the chain here rather than patching the vendored parser keeps
/// `spfk-mkvparser` a clean mirror of upstream.
///
/// Reads through mkvparser's own EBML primitives, so this is a traversal rather than a second
/// implementation of the format.
static long long MKVCuesOffsetInSeekHead(mkvparser::Segment *segment,
                                         long long seekHeadOffset,
                                         int depth) {
    if (segment == nullptr || seekHeadOffset < 0 || depth > MKVMaxSeekHeadDepth) {
        return -1;
    }

    mkvparser::IMkvReader *reader = segment->m_pReader;
    const long long segmentStop = (segment->m_size < 0) ? -1 : segment->m_start + segment->m_size;

    long long pos = segment->m_start + seekHeadOffset;

    if (segmentStop >= 0 && pos >= segmentStop) {
        return -1;
    }

    long long id = 0;
    long long size = 0;

    if (mkvparser::ParseElementHeader(reader, pos, segmentStop, id, size) < 0 ||
        id != libwebm::kMkvSeekHead) {
        return -1;
    }

    const long long stop = pos + size;

    // Cues wins over a nested SeekHead, so the whole level is read before recursing rather than
    // descending at the first SeekHead entry -- a file naming both would otherwise take the long
    // way around to the same place.
    long long nestedOffset = -1;

    while (pos < stop) {
        long long entryID = 0;
        long long entrySize = 0;

        if (mkvparser::ParseElementHeader(reader, pos, stop, entryID, entrySize) < 0) {
            return -1;
        }

        const long long entryStop = pos + entrySize;

        if (entryID == libwebm::kMkvSeek) {
            long long targetID = -1;
            long long targetOffset = -1;
            long long field = pos;

            while (field < entryStop) {
                long long fieldID = 0;
                long long fieldSize = 0;

                if (mkvparser::ParseElementHeader(reader, field, entryStop, fieldID, fieldSize) < 0) {
                    return -1;
                }

                if (fieldID == libwebm::kMkvSeekID) {
                    long length = 0;
                    targetID = mkvparser::ReadID(reader, field, length);
                } else if (fieldID == libwebm::kMkvSeekPosition) {
                    targetOffset = mkvparser::UnserializeUInt(reader, field, fieldSize);
                }

                field += fieldSize;
            }

            if (targetID == libwebm::kMkvCues && targetOffset >= 0) {
                return targetOffset;
            }

            // Never revisit the level being read, which is what a self-referential entry asks for.
            if (targetID == libwebm::kMkvSeekHead && targetOffset >= 0 && targetOffset != seekHeadOffset) {
                nestedOffset = targetOffset;
            }
        }

        pos = entryStop;
    }

    return (nestedOffset >= 0) ? MKVCuesOffsetInSeekHead(segment, nestedOffset, depth + 1) : -1;
}

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
///
/// The already-parsed SeekHead is checked first because it costs nothing; a file that names Cues
/// only through a nested SeekHead needs the chain walked, which is what ``MKVCuesOffsetInSeekHead``
/// does.
- (nullable const mkvparser::Cues *)loadCues {
    if (const mkvparser::Cues *cues = _segment->GetCues()) {
        return cues;
    }

    const mkvparser::SeekHead *seekHead = _segment->GetSeekHead();

    if (seekHead == nullptr) {
        return nullptr;
    }

    long long cuesOffset = -1;

    for (int index = 0; index < seekHead->GetCount(); index++) {
        const mkvparser::SeekHead::Entry *entry = seekHead->GetEntry(index);

        if (entry != nullptr && entry->id == libwebm::kMkvCues) {
            cuesOffset = entry->pos;
            break;
        }
    }

    if (cuesOffset < 0) {
        cuesOffset = MKVCuesOffsetInSeekHead(_segment, seekHead->m_element_start - _segment->m_start, 0);
    }

    if (cuesOffset < 0) {
        return nullptr;
    }

    long long position = 0;
    long length = 0;

    // A nonzero return means "no Cues here" rather than a malformed file, and `GetCues` answers
    // that the same way, so the result is read rather than the status.
    _segment->ParseCues(cuesOffset, position, length);

    return _segment->GetCues();
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

    // Deliberately not `Cues::Find`. That matches a cue point by time and *then* asks it for the
    // track, so a file whose cue points name one track each -- audio and video alternating -- loses
    // the seek whenever the point nearest the target belongs to the other track. libwebm's own TODO
    // in `mkvparser.cc` describes the same defect. Keeping the track inside the search is the fix,
    // and cue points are in ascending time order, so the last match at or before the target wins.
    const mkvparser::CuePoint *cuePoint = nullptr;
    const mkvparser::CuePoint::TrackPosition *trackPosition = nullptr;

    // A target before the track's first cue point has nothing at or before it; the earliest point
    // naming the track is then the only answer, and is where the track begins anyway.
    const mkvparser::CuePoint *earliestPoint = nullptr;
    const mkvparser::CuePoint::TrackPosition *earliestPosition = nullptr;

    for (const mkvparser::CuePoint *point = cues->GetFirst(); point != nullptr;
         point = cues->GetNext(point)) {
        const mkvparser::CuePoint::TrackPosition *position = point->Find(track);

        if (position == nullptr) {
            continue;
        }

        if (earliestPoint == nullptr) {
            earliestPoint = point;
            earliestPosition = position;
        }

        if (point->GetTime(_segment) > timeNanoseconds) {
            break;
        }

        cuePoint = point;
        trackPosition = position;
    }

    if (cuePoint == nullptr) {
        cuePoint = earliestPoint;
        trackPosition = earliestPosition;
    }

    // No cue point names this track at all, which is the ordinary shape of a file whose Cues index
    // only the video track. Clusters interleave every track, so any track's cue point lands on a
    // cluster carrying this track's frames for the same span -- close enough for the caller to walk
    // the rest. Refusing here instead made every seek a decode from the current position, which on a
    // feature-length file costs seconds.
    BOOL usedForeignTrack = NO;

    if (cuePoint == nullptr) {
        const unsigned long trackCount = tracks->GetTracksCount();

        for (const mkvparser::CuePoint *point = cues->GetFirst(); point != nullptr;
             point = cues->GetNext(point)) {
            const mkvparser::CuePoint::TrackPosition *position = nullptr;

            for (unsigned long index = 0; index < trackCount && position == nullptr; ++index) {
                const mkvparser::Track *candidate = tracks->GetTrackByIndex(index);

                if (candidate != nullptr) {
                    position = point->Find(candidate);
                }
            }

            if (position == nullptr) {
                continue;
            }

            if (earliestPoint == nullptr) {
                earliestPoint = point;
                earliestPosition = position;
            }

            if (point->GetTime(_segment) > timeNanoseconds) {
                break;
            }

            cuePoint = point;
            trackPosition = position;
        }

        if (cuePoint == nullptr) {
            cuePoint = earliestPoint;
            trackPosition = earliestPosition;
        }

        usedForeignTrack = cuePoint != nullptr;
    }

    if (cuePoint == nullptr || trackPosition == nullptr) {
        if (error != nullptr) {
            *error = MKVMakeError(MKVErrorNoSeekIndex, _url, @"No cue point for that time.");
        }
        return NO;
    }

    if (usedForeignTrack) {
        // The cue point describes another track's block, so ask it only for the cluster and start
        // at the beginning of that. `Cues::GetBlock` is not usable here: it matches a block by
        // timecode *and* track within the cluster, which succeeds or fails depending on how the
        // cue's own track happens to be laid out -- on a two-hour file four positions in ten came
        // back empty. Everything in the cluster is at or before the cue point's time, so nothing
        // this track needs is skipped.
        const mkvparser::Cluster *cluster = _segment->FindOrPreloadCluster(trackPosition->m_pos);

        if (cluster == nullptr || cluster->EOS()) {
            if (error != nullptr) {
                *error = MKVMakeError(MKVErrorMalformedSegment, _url, @"The cue point names no cluster.");
            }
            return NO;
        }

        const mkvparser::BlockEntry *first = nullptr;

        if (cluster->GetFirst(first) < 0 || first == nullptr || first->EOS()) {
            if (error != nullptr) {
                *error = MKVMakeError(MKVErrorMalformedSegment, _url, @"The cluster carries no blocks.");
            }
            return NO;
        }

        _cluster = cluster;
        _blockEntry = first;

    } else {
        const mkvparser::BlockEntry *entry = cues->GetBlock(cuePoint, trackPosition);

        if (entry == nullptr || entry->EOS()) {
            if (error != nullptr) {
                *error = MKVMakeError(MKVErrorMalformedSegment, _url, @"The cue point names no block.");
            }
            return NO;
        }

        _cluster = entry->GetCluster();
        _blockEntry = entry;
    }

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

        // Kept before the walk advances: a laced block holds several frames that all share the
        // block's timestamp, and each one's real time is that plus its position in the lace.
        const int laceIndex = _frameIndex;

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
        const long long defaultDuration = _defaultDurations[@(trackNumber)].longLongValue;

        // **Laced frames must be spread across the block's span, not stacked on its timestamp.**
        // Matroska packs several audio frames into one block and stores a single time for it; the
        // rest are implied by the track's `DefaultDuration`, which is what that element is for and
        // why a laced track states one. Handing a renderer eight packets that all claim the same
        // instant is audible as a stutter, and libwebm hands back the block time for every frame,
        // so nothing else would space them.
        long long timestamp = block->GetTime(_cluster);

        if (laceIndex > 0 && defaultDuration > 0) {
            timestamp += (long long)laceIndex * defaultDuration;
        }

        return [[MKVFrame alloc] initWithTrackNumber:trackNumber
                                                data:data
                                timestampNanoseconds:timestamp
                                 durationNanoseconds:defaultDuration
                                          isKeyframe:block->IsKey()];
    }
}

@end

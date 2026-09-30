// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi

#import "MKVFrameReader.h"
#import "MKVDescription+Internal.h"
#import <mkvparser/mkvreader.h>
#import <common/webmids.h>

@interface MKVFrameReader ()
@property (nonatomic, readwrite, nullable) NSError *failure;
@end

/// Whether the segment's declared size runs past the end of the file. libwebm demotes such a
/// segment to unknown size, so its `m_size` cannot answer this.
static BOOL MKVSegmentIsTruncated(mkvparser::Segment *segment, mkvparser::IMkvReader *reader) {
    long long total = 0;
    long long available = 0;

    if (reader->Length(&total, &available) < 0 || total < 0) {
        return NO;
    }

    long long pos = segment->m_element_start;
    long long id = 0;
    long long size = 0;

    if (mkvparser::ParseElementHeader(reader, pos, -1, id, size) < 0) {
        return NO;
    }

    // The Segment ID is four bytes, so what remains before the payload is the size field.
    const long long sizeLength = segment->m_start - segment->m_element_start - 4;
    const long long unknownSize = (1LL << (7 * sizeLength)) - 1;

    return size != unknownSize && segment->m_start + size > total;
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

    // After a seek through another track's cue point, the track whose frames are dropped until its
    // next keyframe, or 0.
    long long _awaitingKeyframeTrack;
    NSDictionary<NSNumber *, NSNumber *> *_defaultDurations;
    NSDictionary<NSNumber *, NSData *> *_strippedHeaders;

    // A truncated file's last cluster, which libwebm reports as empty and so never loads.
    long long _fileLength;
    const mkvparser::Cluster *_partialCluster;
    BOOL _searchedForPartialCluster;
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

    long long available = 0;
    _reader->Length(&_fileLength, &available);
    _isTruncated = MKVSegmentIsTruncated(_segment, _reader);

    // Cached because a frame's duration comes from its track, and looking it up per frame would
    // walk the track list for every one of them.
    NSMutableDictionary<NSNumber *, NSNumber *> *durations = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSData *> *strippedHeaders = [NSMutableDictionary dictionary];

    for (MKVTrackDescription *track in description.tracks) {
        durations[@(track.number)] = @(track.defaultDuration);
        strippedHeaders[@(track.number)] = track.strippedHeader;
    }

    _defaultDurations = durations;
    _strippedHeaders = strippedHeaders;

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
    // The partial cluster is only preloaded, and libwebm cannot step past a preloaded cluster in a
    // segment of unknown size.
    if (current != nullptr && current == _partialCluster) {
        _finished = YES;
        return nullptr;
    }

    while (true) {
        const mkvparser::Cluster *next =
            (current == nullptr) ? _segment->GetFirst() : _segment->GetNext(current);

        if (next != nullptr && !next->EOS()) {
            return next;
        }

        // EOS here means "not loaded yet", not necessarily end of file -- the parser hands back the
        // EOS sentinel and expects the caller to load more if it wants more.
        if (_segment->DoneParsing()) {
            return [self partialClusterOrEnd];
        }

        const unsigned long countBefore = _segment->GetCount();

        long long position = 0;
        long length = 0;

        if (_segment->LoadCluster(position, length) < 0) {
            self.failure = MKVMakeError(MKVErrorMalformedSegment, _url, @"Failed to load a cluster.");
            return nullptr;
        }

        // A load that adds no cluster and does not report done would spin forever. libwebm skips a
        // cluster whose declared end is past the end of the file this way, so that one is found
        // separately.
        if (_segment->GetCount() == countBefore) {
            return [self partialClusterOrEnd];
        }
    }
}

/// The cluster a truncated file stops inside, or null at the end of the walk.
- (const mkvparser::Cluster *)partialClusterOrEnd {
    if (_isTruncated && !_searchedForPartialCluster) {
        _searchedForPartialCluster = YES;
        _partialCluster = [self findPartialCluster];
    }

    if (_partialCluster != nullptr) {
        return _partialCluster;
    }

    _finished = YES;
    return nullptr;
}

/// Scans the segment's element headers for the first cluster after the last one loaded.
/// `ParseElementHeader` checks only the header against the end of the file, so it finds a cluster
/// whose payload runs past it.
- (const mkvparser::Cluster *)findPartialCluster {
    const mkvparser::Cluster *last = _segment->GetLast();
    const long long lastPosition = (last == nullptr || last->EOS()) ? -1 : last->GetPosition();

    long long pos = _segment->m_start;

    while (pos < _fileLength) {
        const long long elementStart = pos;
        long long id = 0;
        long long size = 0;

        if (mkvparser::ParseElementHeader(_reader, pos, _fileLength, id, size) < 0) {
            return nullptr;
        }

        const long long position = elementStart - _segment->m_start;

        if (id == libwebm::kMkvCluster && position > lastPosition) {
            return _segment->FindOrPreloadCluster(position);
        }

        pos += size;
    }

    return nullptr;
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
        // back empty. The cluster starts at or before the chosen cue, which is at or before the
        // target, but need not start on one of this track's keyframes, so the walk skips ahead to
        // the next.
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
    _awaitingKeyframeTrack = usedForeignTrack ? trackNumber : 0;
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
            const long status = _cluster->GetFirst(entry);

            if (status < 0) {
                [self stopWithStatus:status reason:@"Failed to read a cluster."];
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
            const long status = _cluster->GetNext(_blockEntry, next);

            if (status < 0) {
                [self stopWithStatus:status reason:@"Failed to advance a cluster."];
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

        // The block the cut runs through.
        if (_isTruncated && frame.pos + frame.len > _fileLength) {
            _finished = YES;
            return nil;
        }

        const long long trackNumber = block->GetTrackNumber();

        if (trackNumber == _awaitingKeyframeTrack) {
            if (!block->IsKey()) {
                continue;
            }

            _awaitingKeyframeTrack = 0;
        }

        // Header stripping stores every frame without a prefix the track records once.
        NSData *strippedHeader = _strippedHeaders[@(trackNumber)];
        const NSUInteger prefixLength = strippedHeader.length;

        NSMutableData *data = [NSMutableData dataWithLength:prefixLength + (NSUInteger)frame.len];

        if (data == nil) {
            self.failure = MKVMakeError(MKVErrorMalformedSegment, _url, @"Frame length is not readable.");
            return nil;
        }

        if (prefixLength > 0) {
            memcpy(data.mutableBytes, strippedHeader.bytes, prefixLength);
        }

        if (frame.Read(_reader, (unsigned char *)data.mutableBytes + prefixLength) < 0) {
            self.failure = MKVMakeError(MKVErrorMalformedSegment, _url, @"Failed to read frame data.");
            return nil;
        }

        const long long defaultDuration = _defaultDurations[@(trackNumber)].longLongValue;

        // **Laced frames must be spread across the block's span, not stacked on its timestamp.**
        // Matroska packs several audio frames into one block and stores a single time for it; the
        // rest are implied by the track's `DefaultDuration`, which is what that element is for and
        // why a laced track states one. Handing a renderer eight packets that all claim the same
        // instant is audible as a stutter, and libwebm hands back the block time for every frame,
        // so nothing else would space them.
        long long timestamp = block->GetTime(_cluster);

        // libwebm reports -1 both for a time before the segment starts and for one that overflows
        // nanoseconds; only the second is malformed.
        if (timestamp < 0 && block->GetTimeCode(_cluster) >= 0) {
            self.failure = MKVMakeError(MKVErrorMalformedSegment, _url, @"Block time overflows.");
            return nil;
        }

        if (laceIndex > 0 && defaultDuration > 0) {
            long long offset = 0;

            if (__builtin_mul_overflow((long long)laceIndex, defaultDuration, &offset) ||
                __builtin_add_overflow(timestamp, offset, &timestamp)) {
                self.failure = MKVMakeError(MKVErrorMalformedSegment, _url, @"Block time overflows.");
                return nil;
            }
        }

        return [[MKVFrame alloc] initWithTrackNumber:trackNumber
                                                data:data
                                timestampNanoseconds:timestamp
                                 durationNanoseconds:defaultDuration
                                          isKeyframe:block->IsKey()];
    }
}

/// Ends the walk on a parser status: data running out in a truncated file is its clean end, and
/// anything else is a failure.
- (void)stopWithStatus:(long)status reason:(NSString *)reason {
    if (_isTruncated && status == mkvparser::E_BUFFER_NOT_FULL) {
        _finished = YES;
        return;
    }

    self.failure = MKVMakeError(MKVErrorMalformedSegment, _url, reason);
}

@end

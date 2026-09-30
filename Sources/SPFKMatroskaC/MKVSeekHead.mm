// Copyright Ryan Francesconi. All Rights Reserved. Revision History at https://github.com/ryanfrancesconi

#import "MKVDescription+Internal.h"
#import <common/webmids.h>

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
long long MKVCuesOffsetInSeekHead(mkvparser::Segment *segment,
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

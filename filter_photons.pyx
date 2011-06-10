from libc.stdlib cimport *
from libc.stdio cimport *
from cpython cimport bool
from timetag_types cimport *
from timetag_types import *

def filter_by_spans(np.ndarray[StrobeEvent] strobes, np.ndarray[DeltaEvent] deltas):
        cdef size_t chunk_sz = 1024
        cdef unsigned int j = 0
        cdef uint64_t t_off = 0
        cdef np.ndarray[StrobeEvent] chunk
        chunk = np.empty(chunk_sz, dtype=strobe_event_dtype)
        chunks = []

        cdef DeltaEvent* cur_span = &deltas[0]
        for i in range(strobes.shape[0]):
                if strobes[i].time >= (cur_span+1).start_t:
                        if cur_span.state == False:
                                t_off += (cur_span+1).start_t - cur_span.start_t
                        cur_span += 1
                if strobes[i].time >= cur_span.start_t and cur_span.state:
                        chunk[j].time = strobes[i].time - t_off
                        chunk[j].channels = strobes[i].channels
                        j += 1

                        # Start new chunk on filled
                        if j == chunk_sz:
                                chunk = np.empty(chunk_sz, dtype=strobe_event_dtype)
                                chunks.append(chunk)
                                j = 0

        chunks.append(chunk[:j])
        return np.hstack(chunks)

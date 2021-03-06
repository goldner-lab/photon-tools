from libc.stdlib cimport *
from libc.stdio cimport *
from cpython cimport bool
from types cimport *
from ..types import *

DEF ENDIANESS="little"

IF ENDIANESS == "big":
        cdef uint64_t swap_record(uint64_t rec):
                return rec
ELIF ENDIANESS == "little":
        cdef uint64_t swap_record(uint64_t rec):
                cdef uint64_t ret
                cdef uint8_t* a = <uint8_t*> &rec
                cdef uint8_t* b = <uint8_t*> &ret
                b[0] = a[5]
                b[1] = a[4]
                b[2] = a[3]
                b[3] = a[2]
                b[4] = a[1]
                b[5] = a[0]
                return ret
ELSE:
        print 'Invalid ENDIANESS'

def get_strobe_events(f, channel_mask, skip_wraps=1):
        """
        Returns a list of delta channel events. The event is defined by a start
        time past which the state is the given value.

        :type f: :class:`file` or :class:`str` (file name)
        :param f: timetag file
        :type strobe_mask: int
        :param strobe_mask: Logical bitmask of strobe channels of interest
            (e.g. ``1`` selects channel 0, ``5`` selects channels 0 and 2)
        :type skip_wraps: int
        :param skip_wraps: How many timestamp wraparounds to skip at the beginning of the data set.
            This was introduced to work around hardware limitations where
            "stale" records from the end of the previous dataset would appear at the beginning
            of the data stream.
        """
        cdef char* fname
        if isinstance(f, bytes):
                fname = f
        elif isinstance(f, str):
                encoded = f.encode()
                fname = encoded
        else:
                fname = f.name
        cdef FILE* fl = fopen(fname, "r")
        if fl == NULL:
                raise RuntimeError("Couldn't open file")

        if channel_mask > 0xf:
                raise RuntimeError("Invalid channel mask")
        cdef uint64_t mask = channel_mask << 36

        cdef size_t chunk_sz = 1024
        cdef unsigned int j = 0
        cdef uint64_t time_offset = 0

        cdef unsigned int wraps = 0
        cdef uint64_t rec
        cdef unsigned int rec_n = 0
        cdef np.ndarray[StrobeEvent] chunk
        chunk = np.empty(chunk_sz, dtype=strobe_event_dtype)
        chunks = []

        while not feof(fl):
                res = fread(&rec, 6, 1, fl)
                if res != 1: break
                rec = swap_record(rec)
                rec_n += 1

                # Handle timer wraparound
                wrapped = rec & (1ULL<<46) != 0
                wraps += wrapped
                if wraps < skip_wraps:
                        if rec_n > 1024: skip_wraps = 0
                        continue
                elif wrapped and wraps > skip_wraps:
                        time_offset += (1ULL<<36)

                # Record event
                if rec & mask and not (rec & (1ULL << 45)):
                        t = rec & ((1ULL<<36)-1)
                        t += time_offset
                        chunk[j].time = t
                        chunk[j].channels = (rec >> 36) & 0xf
                        j += 1

                        # Start new chunk on filled
                        if j == chunk_sz:
                                chunks.append(chunk)
                                chunk = np.empty(chunk_sz, dtype=strobe_event_dtype)
                                j = 0

        chunks.append(chunk[:j])
        fclose(fl)
        return np.hstack(chunks)

def get_delta_events(f, channel, skip_wraps=1):
        """
        Returns a list of delta channel events. The event is defined by a start
        time past which the state is the given value.

        :type f: :class:`file` or :class:`str` (file name)
        :param f: timetag file
        :type strobe_mask: int
        :param strobe_mask: Logical bitmask of strobe channels of interest
        :type skip_wraps: int
        :param skip_wraps: How many timestamp wraparounds to skip at the beginning of the data set.
            This was introduced to work around hardware limitations where
            "stale" records from the end of the previous dataset would appear at the beginning
            of the data stream.
        """
        cdef char* fname
        if isinstance(f, str):
                fname = f
        else:
                fname = f.name
        cdef FILE* fl = fopen(fname, "r")
        if fl == NULL:
                raise RuntimeError("Couldn't open file")

        cdef size_t chunk_sz = 1024
        cdef unsigned int j = 0
        cdef uint64_t time_offset = 0

        cdef uint64_t t
        cdef bool state = False
        cdef bool last_state = False
        cdef uint64_t last_t = 0

        cdef unsigned int wraps = 0
        cdef uint64_t rec
        cdef unsigned int rec_n = 0
        cdef np.ndarray[DeltaEvent] chunk
        chunk = np.empty(chunk_sz, dtype=delta_event_dtype)
        chunks = [chunk]

        while not feof(fl):
                res = fread(&rec, 6, 1, fl)
                if res != 1: break
                rec = swap_record(rec)
                rec_n += 1

                # Handle timer wraparound
                wrapped = rec & (1ULL<<46) != 0
                if wrapped:
                        wraps += 1

                # Skip wraps
                if wraps <= skip_wraps:
                        if rec_n > 1024: skip_wraps = 0
                        continue
                elif wrapped and wraps > skip_wraps:
                        time_offset += (1ULL<<36)

                # Record event
                state = ((rec>>(36+channel)) & 1) != 0
                if rec & (1ULL << 45) and state != last_state:
                        t = rec & ((1ULL<<36)-1)
                        t += time_offset
                        chunk[j].start_t = last_t
                        chunk[j].state = last_state
                        if last_t != 0: j += 1 # Throw out first span to get correct start time
                        last_t = t
                        last_state = state

                        # Start new chunk on filled
                        if j == chunk_sz:
                                chunks.append(chunk)
                                chunk = np.empty(chunk_sz, dtype=delta_event_dtype)
                                j = 0

        chunk[j].start_t = last_t
        chunk[j].state = last_state
        j += 1
        chunks.append(chunk[:j])
        fclose(fl)
        return np.hstack(chunks)

def get_filtered_strobe_events(f, strobe_mask, delta_channel, skip_wraps=-1,
                               on_offset=0):
        """
        Return the strobe events from any of the channels selected by :arg:`strobe_mask`
        which occur while :arg:`delta_channel` is in the high state.

        For instance, a typical alternating laser excitation analysis may begin by reading
        the four emission-excitation channel timestamps with the following,

        .. code:: python

            on_offset = 460 # about 5 microseconds
            donor_em_donor_exc       = get_filtered_strobe_events(fname, 0x1, 1, on_offset=on_offset)
            donor_em_acceptor_exc    = get_filtered_strobe_events(fname, 0x1, 2, on_offset=on_offset)
            acceptor_em_donor_exc    = get_filtered_strobe_events(fname, 0x2, 1, on_offset=on_offset)
            acceptor_em_acceptor_exc = get_filtered_strobe_events(fname, 0x2, 2, on_offset=on_offset)

        :type f: :class:`file` or :class:`str` (file name)
        :param f: timetag file
        :type strobe_mask: int
        :param strobe_mask: Logical bitmask of strobe channels of interest
        :type delta_channel: int
        :param delta_channel: Delta channel number of interest (first channel is ``0``)
        :type skip_wraps: int
        :param skip_wraps: How many timestamp wraparounds to skip at the beginning of the data set.
            This was introduced to work around hardware limitations where
            "stale" records from the end of the previous dataset would appear at the beginning
            of the data stream.
        :type on_offset: int
        :param on_offset: Dead time after initial delta turn-on. This allows one
            to drop photon arrivals occuring during the transient turn-on interval
            of, say, a slow AOTF. Measured in cycles.
        """
        cdef char* fname
        if isinstance(f, str):
                fname = f
        else:
                fname = f.name
        cdef FILE* fl = fopen(fname, "r")
        if fl == NULL:
                raise RuntimeError("Couldn't open file")

        if strobe_mask > 0xf:
                raise RuntimeError("Invalid channel mask")
        cdef uint64_t mask = strobe_mask << 36

        cdef size_t chunk_sz = 1024
        cdef unsigned int j = 0
        cdef uint64_t time_offset = 0
        cdef bool state = False
        cdef uint64_t on_time = 0

        cdef unsigned int wraps = 0
        cdef uint64_t rec
        cdef unsigned int rec_n = 0
        cdef np.ndarray[StrobeEvent] chunk
        chunk = np.empty(chunk_sz, dtype=strobe_event_dtype)
        chunks = []

        cdef unsigned int last_deltas = 0

        while not feof(fl):
                res = fread(&rec, 6, 1, fl)
                if res != 1: break
                rec = swap_record(rec)
                rec_n += 1

                # Handle timer wraparound
                wrapped = rec & (1ULL<<46) != 0
                wraps += wrapped
                if wraps <= skip_wraps:
                        if rec_n > 1024: skip_wraps = 0
                        continue
                elif wrapped and wraps > skip_wraps:
                        time_offset += (1ULL<<36)

                t = rec & ((1ULL<<36)-1)
                t += time_offset

                if rec & (1ULL << 45):
                        state = ((rec>>(36+delta_channel)) & 1) != 0
                        if state: on_time = t

                # Filter on delta state
                if not state: continue
                if t < on_time + on_offset: continue

                # Record event
                if rec & mask and not (rec & (1ULL << 45)):
                        chunk[j].time = t
                        chunk[j].channels = (rec >> 36) & 0xf
                        j += 1

                        # Start new chunk on filled
                        if j == chunk_sz:
                                chunks.append(chunk)
                                chunk = np.empty(chunk_sz, dtype=strobe_event_dtype)
                                j = 0

        chunks.append(chunk[:j])
        fclose(fl)
        return np.hstack(chunks)


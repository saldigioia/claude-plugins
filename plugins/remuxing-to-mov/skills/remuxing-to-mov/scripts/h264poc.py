#!/usr/bin/env python3
# h264poc.py — H.264 slice-header reader and spec-compliant POC unwrapper.
# LIBRARY: imported, not executed (the CLI over it is scripts/poc-remux.py and
# the census in scripts/poc-remux.sh).
#
# WHY IT EXISTS (measured 2026-08-29). Rung 3-DERIVE refused a 25 GB PAFF
# capture because it could not prove field pairing from TIMESTAMP DELTAS: zero
# of 424,596 adjacent coded pairs differ by one field duration. That
# measurement is true. The inference — "this stream has no field pairing" — is
# false. The fields ARE coded-adjacent and share frame_num; the source simply
# stamps each bottom field a constant three rungs BELOW its own top field.
#
# The evidence that settles it was in the slice headers the rung declined to
# open: field_pic_flag, bottom_field_flag and frame_num state the PAIRING
# outright, and pic_order_cnt_lsb states each picture's DISPLAY POSITION
# outright. A timestamp-delta heuristic is a proxy for both. This module reads
# the direct evidence instead.
#
# NOTHING HERE IS TUNED TO ONE CAPTURE. The predecessor (plugin-doctor's
# workshop copy) hardcoded that file's SPS — 8-bit frame_num, 8-bit POC lsb,
# field-capable, and a 1800/415 tick lattice. Every one of those is parsed
# from the bitstream here, because a constant that happens to be right for one
# source is indistinguishable from a constant that is right.
#
# BOTH STANDARD CARRIAGES ARE READ (1.17.0, and the omission cost a field job).
# H.264 travels two ways and this module understood one of them:
#   * ANNEX-B — start-code delimited, parameter sets in-band. MPEG-TS, .h264.
#   * avcC    — ISO/IEC 14496-15 length-prefixed NALs, parameter sets in the
#               container's extradata (AVCDecoderConfigurationRecord). MKV, MOV,
#               MP4.
# Until 1.17.0 `iter_nals` scanned only for start codes, so on MKV/MOV it
# yielded ZERO NALs and `capability()` answered "no SPS parsed" — total
# blindness, on the identical bitstream. Measured 2026-08-30, one encode, two
# containers: reord.ts parsed 120 of 120 slice headers and reord.mkv parsed 0
# of 120. That is not a POC defect and not a math defect; it is a reader that
# could not see the bytes it was handed, and three rungs sat on top of it.
#
# Scope, stated (Constitution III.2 — a scanner states its jurisdiction):
#   * pic_order_cnt_type 0: fully supported (the broadcast case).
#   * pic_order_cnt_type 2: supported — the spec defines display order to
#     EQUAL decode order for it, so POC is derived from frame_num and the
#     lattice gate is trivially satisfied.
#   * pic_order_cnt_type 1: NOT supported. capability() says so by name; no
#     caller may treat that as "no reordering".
#   * MBAFF (mb_adaptive_frame_field_flag) is read and reported but never
#     paired: MBAFF frames are whole frames already, one sample each.

import collections
import os

# ---------------------------------------------------------------- bit reader

class BitReader:
    """RBSP bit reader: strips emulation-prevention bytes (00 00 03 -> 00 00)."""

    def __init__(self, data):
        out = bytearray()
        i, n = 0, len(data)
        while i < n:
            if i + 2 < n and data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 3:
                out += b"\x00\x00"
                i += 3
            else:
                out.append(data[i])
                i += 1
        self.d = bytes(out)
        self.p = 0

    def u(self, nbits):
        v = 0
        for _ in range(nbits):
            byte = self.p >> 3
            if byte >= len(self.d):
                raise ValueError("out of data")
            v = (v << 1) | ((self.d[byte] >> (7 - (self.p & 7))) & 1)
            self.p += 1
        return v

    def ue(self):
        lead = 0
        while self.u(1) == 0:
            lead += 1
            if lead > 32:
                raise ValueError("bad exp-golomb")
        return 0 if lead == 0 else (1 << lead) - 1 + self.u(lead)

    def se(self):
        k = self.ue()
        return (k + 1) // 2 if k % 2 else -(k // 2)


# ------------------------------------------------------------- NAL iteration

def avcc_length_size(extradata):
    """The NAL length-prefix width an avcC box declares, or 0 when `extradata`
    is not an avcC box at all.

    ZERO IS THE POINT, not 4. ISO/IEC 14496-15 defaults the field to 4 when it
    is unreadable, but a caller threading this value into `iter_nals` needs to
    know the difference between "this container declared 4" and "this container
    declared nothing, because it is Annex-B". Forcing a length-prefixed walk on
    a start-code stream is the mirror image of the bug this whole section
    fixes. Callers that genuinely want the ISO default write
    `avcc_length_size(e) or 4`.
    """
    e = bytes(extradata or b"")
    if len(e) < 7 or e[0] != 1:
        return 0
    return (e[4] & 0x03) + 1


def avcc_param_sets(extradata):
    """The SPS/PPS an avcC box carries, re-emitted as an ANNEX-B buffer that
    `feed_parameter_sets` can read; b"" when `extradata` is not avcC.

    THIS IS WHERE MKV AND MOV KEEP THE PARAMETER SETS. A TS re-sends them in
    band at every IDR, so a reader that only ever looks inside packets works
    there and finds nothing here — the second half of the same blindness.
    A truncated record yields whatever whole sets precede the truncation: a
    partial parameter set is not evidence and is never invented.
    """
    e = bytes(extradata or b"")
    if len(e) < 7 or e[0] != 1:
        return b""
    out = bytearray()
    i = 5
    for count_bits in (0x1F, 0xFF):          # numOfSPS is 5 bits, numOfPPS is 8
        if i >= len(e):
            break
        count = e[i] & count_bits
        i += 1
        for _ in range(count):
            if i + 2 > len(e):
                return bytes(out)
            ln = (e[i] << 8) | e[i + 1]
            i += 2
            if ln <= 0 or i + ln > len(e):
                return bytes(out)
            out += b"\x00\x00\x00\x01" + e[i:i + ln]
            i += ln
    return bytes(out)


def _avcc_nals(buf, nls):
    """The length-prefixed walk: a list of (type, ref_idc, payload_start), or
    None when `buf` is not an avcC buffer with this length size.

    EXACT TILING IS THE DISCRIMINATOR, and it has to be, because the first four
    bytes of an Annex-B buffer can always be read as *some* length. What a
    start-code buffer cannot do is have every subsequent length field land
    exactly on the next one and the last NAL end exactly on the final byte.
    Anything short of that returns None and the Annex-B scan gets the buffer
    instead.
    """
    n = len(buf)
    i = 0
    out = []
    while i + nls <= n:
        ln = 0
        for k in range(nls):
            ln = (ln << 8) | buf[i + k]
        i += nls
        if ln <= 0 or i + ln > n:
            return None
        out.append((buf[i] & 0x1F, (buf[i] >> 5) & 3, i + 1))
        i += ln
    if i != n or not out:
        return None
    return out


def iter_nals(buf, nal_length_size=None):
    """Yield (nal_unit_type, nal_ref_idc, payload_start) over an H.264 buffer in
    EITHER standard carriage — Annex-B start codes, or avcC length prefixes.

    `nal_length_size` is the container's own declared lengthSizeMinusOne+1
    (`avcc_length_size(extradata)`). PASS IT WHERE YOU HAVE IT. The autodetect
    below is the safety net, not the mechanism: it is strong (exact tiling) but
    it is not a proof, and a caller holding the declared value has no reason to
    rely on an inference.
    """
    starts_annexb = (buf[:3] == b"\x00\x00\x01" or buf[:4] == b"\x00\x00\x00\x01")
    if nal_length_size or not starts_annexb:
        for nls in ((nal_length_size,) if nal_length_size else (4, 2, 1, 3)):
            got = _avcc_nals(buf, nls)
            if got is not None:
                for triple in got:
                    yield triple
                return
    n = len(buf)
    i = 0
    while i + 3 < n:
        if buf[i] == 0 and buf[i + 1] == 0:
            if buf[i + 2] == 1:
                start = i + 3
            elif i + 4 < n and buf[i + 2] == 0 and buf[i + 3] == 1:
                start = i + 4
            else:
                i += 1
                continue
            if start < n:
                yield (buf[start] & 0x1F, (buf[start] >> 5) & 3, start + 1)
            i = start + 1
        else:
            i += 1


# ------------------------------------------------------------------ SPS/PPS

SCALING_PROFILES = frozenset(
    (100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135))


def _skip_scaling_list(br, size):
    last = next_ = 8
    for _ in range(size):
        if next_ != 0:
            next_ = (last + br.se() + 256) % 256
        last = next_ if next_ != 0 else last


def parse_sps(payload):
    """Parse an SPS NAL payload (after the 1-byte NAL header) -> dict.

    Every field this module or its callers depend on is read here; nothing is
    assumed. Returns None when the SPS does not parse.
    """
    try:
        br = BitReader(payload)
        profile_idc = br.u(8)
        br.u(8)                                 # constraint flags + reserved
        level_idc = br.u(8)
        sps_id = br.ue()
        chroma_format_idc = 1
        separate_colour_plane_flag = 0
        if profile_idc in SCALING_PROFILES:
            chroma_format_idc = br.ue()
            if chroma_format_idc == 3:
                separate_colour_plane_flag = br.u(1)
            br.ue()                             # bit_depth_luma_minus8
            br.ue()                             # bit_depth_chroma_minus8
            br.u(1)                             # qpprime_y_zero_transform_bypass
            if br.u(1):                         # seq_scaling_matrix_present
                lists = 8 if chroma_format_idc != 3 else 12
                for i in range(lists):
                    if br.u(1):
                        _skip_scaling_list(br, 16 if i < 6 else 64)
        log2_max_frame_num = br.ue() + 4
        poc_type = br.ue()
        log2_max_poc_lsb = 0
        delta_pic_order_always_zero_flag = 0
        offset_for_non_ref_pic = 0
        offset_for_top_to_bottom_field = 0
        offsets_for_ref_frame = []
        if poc_type == 0:
            log2_max_poc_lsb = br.ue() + 4
        elif poc_type == 1:
            delta_pic_order_always_zero_flag = br.u(1)
            offset_for_non_ref_pic = br.se()
            offset_for_top_to_bottom_field = br.se()
            for _ in range(br.ue()):
                offsets_for_ref_frame.append(br.se())
        max_num_ref_frames = br.ue()
        br.u(1)                                 # gaps_in_frame_num_value_allowed
        width_mbs = br.ue() + 1
        height_map_units = br.ue() + 1
        frame_mbs_only_flag = br.u(1)
        mb_adaptive = 0
        if not frame_mbs_only_flag:
            mb_adaptive = br.u(1)
        return {
            "sps_id": sps_id,
            "profile_idc": profile_idc,
            "level_idc": level_idc,
            "chroma_format_idc": chroma_format_idc,
            "separate_colour_plane_flag": separate_colour_plane_flag,
            "log2_max_frame_num": log2_max_frame_num,
            "poc_type": poc_type,
            "log2_max_poc_lsb": log2_max_poc_lsb,
            "max_poc_lsb": (1 << log2_max_poc_lsb) if poc_type == 0 else 0,
            "delta_pic_order_always_zero_flag": delta_pic_order_always_zero_flag,
            "offset_for_non_ref_pic": offset_for_non_ref_pic,
            "offset_for_top_to_bottom_field": offset_for_top_to_bottom_field,
            "offsets_for_ref_frame": offsets_for_ref_frame,
            "max_num_ref_frames": max_num_ref_frames,
            "frame_mbs_only_flag": frame_mbs_only_flag,
            "mb_adaptive_frame_field_flag": mb_adaptive,
            "width": width_mbs * 16,
            "height": height_map_units * 16 * (2 - frame_mbs_only_flag),
        }
    except ValueError:
        return None


def parse_pps(payload):
    """PPS -> {pps_id, sps_id, bottom_field_pic_order_in_frame_present_flag}.

    Only the fields a slice header needs before pic_order_cnt_lsb. The third
    one is read but never used to reach poc_lsb (it gates the field AFTER it);
    it is kept because a caller reading delta_pic_order_cnt_bottom needs it.
    """
    try:
        br = BitReader(payload)
        pps_id = br.ue()
        sps_id = br.ue()
        br.u(1)                                 # entropy_coding_mode_flag
        bottom_present = br.u(1)
        return {"pps_id": pps_id, "sps_id": sps_id,
                "bottom_field_pic_order_in_frame_present_flag": bottom_present}
    except ValueError:
        return None


# -------------------------------------------------------------- slice header

class Parser:
    """Stateful reader: collects SPS/PPS as they appear, parses slice headers.

    ONE parser per stream. SPS/PPS may legitimately be re-sent mid-stream (a TS
    capture re-sends them at every IDR); a changed SPS replaces the old one, so
    a stream that switches parameters mid-file is followed rather than
    misread.

    `nal_length_size` is the container's declared avcC length width — pass
    `avcc_length_size(stream.codec_context.extradata)`; 0/None means Annex-B or
    unknown, and the carriage is then autodetected per buffer. On an MKV/MOV
    source the parameter sets live in that same extradata and NOT in the
    packets, so seed the parser once with `feed_parameter_sets(
    avcc_param_sets(extradata))` or every slice header will parse to None.
    """

    def __init__(self, nal_length_size=None):
        self.sps = {}
        self.pps = {}
        self.sps_changes = 0
        self.unparsed_sps = 0
        self.nal_length_size = nal_length_size or None

    def feed_parameter_sets(self, buf):
        """Collect every SPS/PPS in a buffer. NOT used by parse_slice, which
        collects them inline within its own bounded pass — calling this on a
        whole packet walks the entire essence in Python.

        The extradata path is the exception and is what this is FOR: an avcC
        record is tens of bytes, and `avcc_param_sets` hands it over already
        converted to Annex-B."""
        for ntype, _nri, off in iter_nals(buf):
            if ntype == 7:
                s = parse_sps(buf[off:off + 512])
                if s is None:
                    self.unparsed_sps += 1
                    continue
                old = self.sps.get(s["sps_id"])
                if old is not None and old != s:
                    self.sps_changes += 1
                self.sps[s["sps_id"]] = s
            elif ntype == 8:
                p = parse_pps(buf[off:off + 64])
                if p is not None:
                    self.pps[p["pps_id"]] = p

    def parse_slice(self, buf):
        """First VCL slice of an access unit -> dict, or None.

        Returns None when no VCL NAL parses — the caller must treat that as
        UNKNOWN, never as "not a picture" (EMPTY is not ABSENT).

        ONE bounded forward pass, and the bound is the point. Parameter sets
        precede the slice inside an access unit, so collecting them and
        stopping at the first VCL NAL sees only the first few KB of a packet.
        An earlier draft scanned the WHOLE packet twice — once for parameter
        sets, once for the slice — which on a 23.8 GB video track is a
        byte-by-byte Python walk of the entire essence: measured at over eight
        minutes for a pass that has no reason to read past the slice header.

        NOTE ON avcC: the length-prefixed walk is not early-exitable the way
        the start-code scan is — the only way to the second NAL is past the
        first — but it is a walk over NAL BOUNDARIES, not bytes, so it is
        cheaper than the scan it replaces, not dearer.
        """
        for ntype, nri, off in iter_nals(buf, self.nal_length_size):
            if ntype == 7:
                sps = parse_sps(buf[off:off + 512])
                if sps is None:
                    self.unparsed_sps += 1
                else:
                    old = self.sps.get(sps["sps_id"])
                    if old is not None and old != sps:
                        self.sps_changes += 1
                    self.sps[sps["sps_id"]] = sps
                continue
            if ntype == 8:
                pps = parse_pps(buf[off:off + 64])
                if pps is not None:
                    self.pps[pps["pps_id"]] = pps
                continue
            if ntype not in (1, 5):
                continue
            try:
                br = BitReader(buf[off:off + 96])
                if br.ue() != 0:                # first_mb_in_slice: want the AU's first
                    continue
                slice_type = br.ue()
                pps_id = br.ue()
                pps = self.pps.get(pps_id)
                sps = self.sps.get(pps["sps_id"]) if pps else None
                if sps is None:
                    # a single SPS in scope is the overwhelmingly common case;
                    # using it is better than refusing to read the stream, and
                    # the ambiguity is REPORTED rather than hidden
                    if len(self.sps) == 1:
                        sps = next(iter(self.sps.values()))
                    else:
                        return None
                if sps["separate_colour_plane_flag"]:
                    br.u(2)                     # colour_plane_id
                frame_num = br.u(sps["log2_max_frame_num"])
                field_pic = bottom = 0
                if not sps["frame_mbs_only_flag"]:
                    field_pic = br.u(1)
                    if field_pic:
                        bottom = br.u(1)
                idr_pic_id = None
                if ntype == 5:
                    idr_pic_id = br.ue()
                poc_lsb = None
                if sps["poc_type"] == 0:
                    poc_lsb = br.u(sps["log2_max_poc_lsb"])
                return {"nal": ntype, "nri": nri, "slice_type": slice_type,
                        "pps_id": pps_id, "sps_id": sps["sps_id"],
                        "frame_num": frame_num, "field_pic": field_pic,
                        "bottom": bottom, "poc_lsb": poc_lsb,
                        "idr_pic_id": idr_pic_id, "poc_type": sps["poc_type"],
                        "max_poc_lsb": sps["max_poc_lsb"],
                        "log2_max_frame_num": sps["log2_max_frame_num"]}
            except (ValueError, KeyError, TypeError):
                return None
        return None

    def capability(self):
        """(ok, why) — can this module state a display position for this stream?"""
        if not self.sps:
            return False, "no SPS parsed"
        types = sorted({s["poc_type"] for s in self.sps.values()})
        if types == [0]:
            return True, "-"
        if types == [2]:
            return True, "poc_type=2 (display order equals decode order by spec)"
        if 1 in types:
            return False, ("pic_order_cnt_type=1 is not implemented here — the "
                           "display position cannot be stated, and MUST NOT be "
                           "assumed to be decode order")
        return False, "mixed pic_order_cnt_type %s across SPS" % types


# ----------------------------------------------------------- POC unwrapping

class PocUnwrapper:
    """ITU-T H.264 §8.2.1.1 PicOrderCntMsb tracking, with the IDR reset.

    feed(slice) -> (poc, epoch). `epoch` increments at every IDR, because POC
    restarts there: any `k = POC + C` relation is valid only INSIDE one epoch,
    and a single global C is exactly how the naive version fails.

    IT ALSO INCREMENTS AT AN SPS ACTIVATION THAT CHANGES THE POC PARAMETERS.
    §8.2.1.1 is modular arithmetic under MaxPicOrderCntLsb, so lsb state means
    nothing across a change of modulus — and a broadcast capture spanning a
    program change carries more than one. Measured 2026-08-29 on a 24 GB
    deliverable: unwrapped under a single (wrong) modulus, 215,949 of 216,631
    pictures read off their own declared slot. `scope` counts those
    activations; `epoch` advances on either boundary, so every downstream
    per-epoch relation (the k = POC + C classes) is automatically scoped too.
    """

    def __init__(self):
        self.prev_lsb = 0
        self.prev_msb = 0
        self.epoch = 0
        self.scope = 0
        self._params = None          # (poc_type, max_poc_lsb) in force
        self.frame_num_offset = 0
        self.prev_frame_num = 0

    def _check_scope(self, s):
        """A change of POC parameters opens a new scope: reset the lsb state."""
        params = (s["poc_type"], s["max_poc_lsb"])
        if self._params is not None and params != self._params:
            self.scope += 1
            self.epoch += 1
            self.prev_lsb = 0
            self.prev_msb = 0
            self.frame_num_offset = 0
        self._params = params

    def feed(self, s):
        self._check_scope(s)
        if s["poc_type"] == 2:
            # display order == decode order; a stable increasing counter is the
            # honest POC here
            if s["nal"] == 5:
                self.epoch += 1
                self.frame_num_offset = 0
                self.prev_frame_num = s["frame_num"]
            else:
                mx = 1 << s["log2_max_frame_num"]
                if s["frame_num"] < self.prev_frame_num:
                    self.frame_num_offset += mx
                self.prev_frame_num = s["frame_num"]
            return 2 * (self.frame_num_offset + s["frame_num"]), self.epoch
        if s["poc_lsb"] is None:
            return None, self.epoch
        maxlsb = s["max_poc_lsb"]
        if s["nal"] == 5:                       # IDR: prevMsb = prevLsb = 0
            self.epoch += 1
            self.prev_lsb = 0
            self.prev_msb = 0
        lsb = s["poc_lsb"]
        half = maxlsb // 2
        if lsb < self.prev_lsb and (self.prev_lsb - lsb) >= half:
            msb = self.prev_msb + maxlsb
        elif lsb > self.prev_lsb and (lsb - self.prev_lsb) > half:
            msb = self.prev_msb - maxlsb
        else:
            msb = self.prev_msb
        poc = msb + lsb
        if s["nri"] != 0:                       # reference picture: carry state
            self.prev_lsb = lsb
            self.prev_msb = msb
        return poc, self.epoch


# ------------------------------------------------------------ field pairing

def pair_fields(field_pic, bottom, frame_num):
    """ISO/IEC 14496-15: both fields of a complementary field pair are ONE
    sample. Returns (groups, singles) where groups is a list of coded-index
    lists, in coded order.

    The pairing rule is STRUCTURAL and reads only slice headers:
      * field_pic_flag == 0            -> already a frame, one sample
      * field_pic_flag == 1, bottom 0 -> 1, same frame_num, coded-adjacent
                                       -> ONE sample of the two access units
      * anything else                  -> its own sample, counted as a single

    It deliberately does NOT look at timestamps. The rule this replaces read
    timestamp deltas and inferred structure; on a stream whose bottom fields
    are stamped a constant offset BELOW their tops it concluded "no pairing"
    from 0 of 424,596 — while 208,014 of 208,022 pairs were sitting right
    there in the headers.
    """
    n = len(field_pic)
    groups = []
    singles = 0
    i = 0
    while i < n:
        if field_pic[i] == 0:
            groups.append([i])
            i += 1
        elif (i + 1 < n and field_pic[i] == 1 and bottom[i] == 0
              and field_pic[i + 1] == 1 and bottom[i + 1] == 1
              and frame_num[i + 1] == frame_num[i]):
            groups.append([i, i + 1])
            i += 2
        else:
            groups.append([i])
            singles += 1
            i += 1
    return groups, singles


# ------------------------------------------------ POC units per display rung

def poc_advance(poc, epoch):
    """(A, note) — how many POC units one display rung is worth on this stream.
    MEASURED per epoch, never assumed.

    WHY THIS EXISTS (measured 2026-08-30). H.264 counts pic_order_cnt in
    FIELDS. A field-coded stream codes one picture per field, so POC advances
    ONE per coded picture and one per rung, and `k = POC + C` works directly —
    which is the only class this module had ever been pointed at. A PROGRESSIVE
    stream codes one picture per FRAME, two fields, so POC advances TWO per
    rung while the container's lattice advances one. `RungSolver.vote` records
    `rung - poc`, so on such a stream the key is `-k`: a different value for
    every picture, and every class reads as unanimous at about 1/n. Field
    measurement on the Reading Festival capture: 0.01042 unanimity, 2 votes of
    192, on a file whose display positions the bitstream states exactly.

    THE GUARD IS THE WHOLE DESIGN. A is adopted only when the per-epoch modal
    positive delta of the sorted POC values AGREES across every epoch **and**
    divides EVERY POC value exactly. Either failing yields A = 1 and no
    normalisation at all, because an odd POC divided away is a display position
    invented rather than read — and this rung's entire claim is that it never
    invents one. `note` says which happened, for the caller to announce.
    """
    by_epoch = {}
    n = 0
    for i, p in enumerate(poc):
        if p is None:
            continue
        n += 1
        by_epoch.setdefault(epoch[i] if i < len(epoch) else None, []).append(p)
    if n == 0:
        return 1, "no POC values to measure"
    advances = set()
    for values in by_epoch.values():
        s = sorted(set(values))
        deltas = [s[i] - s[i - 1] for i in range(1, len(s))]
        deltas = [d for d in deltas if d > 0]
        if not deltas:
            continue                       # a one-picture epoch states nothing
        advances.add(collections.Counter(deltas).most_common(1)[0][0])
    if len(advances) != 1:
        return 1, ("the modal POC advance is not consistent across epochs %s — "
                   "not normalising" % sorted(advances))
    a = advances.pop()
    if a <= 1:
        return 1, "POC already advances one unit per rung"
    off = sum(1 for p in poc if p is not None and p % a != 0)
    if off:
        return 1, ("POC advances %d per rung but %d of %d value(s) are not "
                   "divisible by it — not normalising, because an odd POC "
                   "rounded away is a display position invented rather than "
                   "read" % (a, off, n))
    return a, "exact for all %d picture(s)" % n


# ------------------------------------------------- the unanimity bar in force

MIN_AGREE_DEFAULT = 0.999


def resolve_min_agree(default=MIN_AGREE_DEFAULT):
    """(value, note) — the class-unanimity bar in force, and where it came from.

    ONE WRITER for a knob two rungs share (Article IV.1): `poc-remux.py` and
    `derive-dts.py` both solve `k = POC + C` and both used to carry their own
    0.999 literal. RTM_POC_MIN_AGREE overrides it; a value that will not parse,
    or sits outside (0, 1], falls back to the default and SAYS so rather than
    letting a garbage env value quietly decide a timeline repair.

    THERE IS DELIBERATELY NO SUCH KNOB FOR MIN_SAMPLES. This round widens the
    unanimity bar because unanimity is capped at 1 - f on a systematic
    mis-stamp; the sample floor is not capped by anything and stays a constant.
    """
    raw = os.environ.get("RTM_POC_MIN_AGREE")
    if not raw:
        return default, "default"
    try:
        v = float(raw)
    except ValueError:
        return default, "RTM_POC_MIN_AGREE=%r is not a number — using the default" % raw
    if not (0.0 < v <= 1.0):
        return default, "RTM_POC_MIN_AGREE=%r is outside (0,1] — using the default" % raw
    return v, "RTM_POC_MIN_AGREE"


# ------------------------------------------- the POC -> rung constant, per class

class RungSolver:
    """`k = POC + C`, with C constant per (IDR epoch, bottom_field_flag).

    THE PER-PARITY SPLIT IS MANDATORY, and it is the whole reason the naive
    version fails: bottom fields legitimately sit a constant offset below
    their own tops, so a single global C looks non-unanimous and the class is
    thrown away as unproven — on a stream where it is provable to four nines.

    A class is TRUSTED only when it has at least `min_samples` votes and at
    least `min_agree` of them agree. An untrusted class yields no value at
    all; it never falls back to the most popular guess.

    THE UNANIMITY BAR IS A PREDICTION, AND SINCE 1.17.0 IT DOES NOT REFUSE ON
    ITS OWN (Constitution I.3; TIERS.md T3.4). Unanimity is capped at 1 - f on
    a systematic mis-stamp: a stream where a fraction f of pictures carry a
    wrong timestamp CANNOT reach 0.999 however provable its repair is, so the
    bar blocked exactly the class this rung was built for whenever that class
    was systematic rather than sparse. Measured 2026-08-30: f = 0.174, so the
    ceiling was 0.826 and the bar was 0.999 — structurally unreachable.

    So when NO class clears the bar and EVERY class carries at least
    `min_samples` votes, the modal C is offered as PROVISIONAL, loudly, and the
    output gates judge the artifact: `poc-remux.py` refuses unless every frame
    lands on its own slot (a wrong C cannot survive a bijection onto the
    lattice), then asserts DTS monotonic and DTS <= PTS, then runs the whole
    verify suite. That is strictly stronger evidence than the bar it replaces.

    WHAT IS NOT WEAKENED: `min_samples`. A class with too little evidence still
    yields nothing at all, and one class short of the floor withdraws the
    provisional offer for the whole stream — a partial roster is not a roster.
    """

    def __init__(self, min_samples=100, min_agree=0.999):
        self.min_samples = min_samples
        self.min_agree = min_agree
        self.votes = collections.defaultdict(collections.Counter)
        self.C = {}
        self.trusted = set()
        self.provisional = set()
        self.evidence = {}

    def vote(self, epoch, bottom, rung, poc):
        if rung is not None and poc is not None:
            self.votes[(epoch, bottom)][rung - poc] += 1

    def solve(self):
        for key, v in self.votes.items():
            best, cnt = v.most_common(1)[0]
            total = sum(v.values())
            self.C[key] = best
            share = float(cnt) / total if total else 0.0
            self.evidence[key] = (best, cnt, total, share)
            if total >= self.min_samples and share >= self.min_agree:
                self.trusted.add(key)
        if not self.trusted and self.votes and all(
                total >= self.min_samples
                for _c, _cnt, total, _s in self.evidence.values()):
            self.provisional = set(self.evidence)
        return self

    def usable(self):
        """The classes a rung may read a display position from — trusted, or
        provisional under the 1 - f argument above. Empty means refuse."""
        return self.trusted or self.provisional

    def shortfall(self):
        """(worst_share, worst_key) over the provisional classes, for a warning
        that names its own gap rather than gesturing at one. None when nothing
        is provisional."""
        if not self.provisional:
            return None
        key = min(self.provisional, key=lambda k: self.evidence[k][3])
        return self.evidence[key][3], key

    def rung(self, epoch, bottom, poc):
        key = (epoch, bottom)
        if poc is None or (key not in self.trusted and key not in self.provisional):
            return None
        return poc + self.C[key]

    def report(self):
        """One line per class, trusted or not — a rule that never fired must
        say so and on what evidence (Constitution III.2)."""
        rows = []
        for key in sorted(self.evidence):
            c, cnt, total, share = self.evidence[key]
            rows.append("epoch=%d parity=%s C=%d unanimity=%d/%d (%.5f) %s"
                        % (key[0], "bottom" if key[1] else "top", c, cnt,
                           total, share,
                           "TRUSTED" if key in self.trusted else
                           "PROVISIONAL" if key in self.provisional else
                           "untrusted"))
        return rows

"""Parse an xctrace cpu-profile / time-profile XML export into a compact pickle of samples.
Each sample: (time_ns, tid, weight, state, frames) with frames leaf-first as names."""
import sys, pickle
import xml.etree.ElementTree as ET

src, dst = sys.argv[1], sys.argv[2]
ids = {}  # id -> parsed value
def val(el):
    r = el.get('ref')
    if r is not None:
        return ids[r]
    return None

frames_by_id = {}
bins = {}
bt_by_id = {}
samples = []
for ev, el in ET.iterparse(src, events=('end',)):
    tag = el.tag
    if tag == 'binary':
        if el.get('id'):
            bins[el.get('id')] = (el.get('path') or el.get('name') or '?', el.get('load-addr') or '0')
    elif tag == 'frame':
        if el.get('id'):
            b = el.find('binary')
            binfo = ('?', '0')
            if b is not None:
                binfo = bins.get(b.get('id') or b.get('ref'), ('?', '0'))
            frames_by_id[el.get('id')] = (el.get('name') or el.get('addr'), el.get('addr'), binfo[0], binfo[1])
    elif tag in ('tagged-backtrace', 'backtrace'):
        if el.get('id'):
            fr = []
            for f in el.iter('frame'):
                fid = f.get('id') or f.get('ref')
                fr.append(frames_by_id.get(fid, ('?', '0', '?', '0')))
            bt_by_id[el.get('id')] = tuple(fr)
    elif tag == 'row':
        t = el.find('sample-time')
        th = el.find('thread')
        w = el.find('cycle-weight')
        if w is None:
            w = el.find('weight')
        st = el.find('thread-state')
        bt = el.find('tagged-backtrace')
        if bt is None:
            bt = el.find('backtrace')
        def resolve(e, store):
            if e is None: return None
            if e.get('ref'): return store.get(e.get('ref'))
            return store.get(e.get('id'))
        # simple scalar store
        def scal(e):
            if e is None: return None
            if e.get('ref'): return ids.get(e.get('ref'))
            v = e.text
            ids[e.get('id')] = v
            return v
        tval = int(scal(t)) if t is not None else 0
        # thread: id'd element with nested tid
        if th is not None:
            if th.get('ref'):
                tid = ids.get('T' + th.get('ref'))
            else:
                tid = th.get('fmt')
                ids['T' + th.get('id')] = tid
        else:
            tid = None
        wv = scal(w)
        sv = None
        if st is not None:
            if st.get('ref'): sv = ids.get('S' + st.get('ref'))
            else:
                sv = st.get('fmt'); ids['S' + st.get('id')] = sv
        frames = resolve(bt, bt_by_id) or ()
        samples.append((tval, tid, int(wv) if wv else 1, sv, frames))
        el.clear()
pickle.dump(samples, open(dst, 'wb'))
print(len(samples), 'samples;', len(set(s[1] for s in samples)), 'threads')

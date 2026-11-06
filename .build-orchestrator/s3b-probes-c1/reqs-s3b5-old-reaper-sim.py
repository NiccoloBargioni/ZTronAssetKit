# Simulates s3-base's reaper queue (ArraySlice, 64-key batches, 20 attempted per unit, 44 re-inserted at the front):
# reads per key and units equal ReapQueue's (the structural test's metric), only element moves differ.
for n in (1000, 10000, 40000):
    q = list(range(n)); reads = 0; moves = 0; units = 0
    while q:
        batch = q[:64]; reads += len(batch); q = q[len(batch):]
        att = min(20, len(batch)); rest = batch[att:]
        q = rest + q; moves += len(rest) * len(q)
        units += 1
    print(n, 'old reads/key', round(reads / n, 3), 'units', units, 'element moves/key', round(moves / n, 1))

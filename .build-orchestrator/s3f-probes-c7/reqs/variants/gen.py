import sys, pathlib
d = pathlib.Path(sys.argv[1])
head = (d / "EngineJobs.head.swift").read_text()
anchor = "                job = followed\n                verdict = self.spaceBlock(job, ahead: ahead)\n"
def rep(src, old, new):
    assert src.count(old) == 1, (old, src.count(old))
    return src.replace(old, new)
variants = {
    "skipNotFit": rep(head, anchor, anchor + "                if verdict != nil {\n                    continue\n                }\n"),
    "requeueNoAhead": rep(head, anchor, anchor + "                if verdict != nil {\n                    if self.transition(transfer, to: .queued) {\n                        self.enqueue(transfer)\n                        requeues += 1\n                    }\n                    continue\n                }\n"),
    "noLaneRejudge": rep(head, anchor, "                job = followed\n                verdict = nil\n"),
    "gainNoAhead": rep(head, "                if self.requeueSwept(parked, ahead: &ahead) {\n", "                if self.transition(transfer, to: .queued) {\n                    self.enqueue(transfer)\n"),
    "gainNoBound": rep(head, "                guard requeues < Self.readmissionsPerTurn else {\n                    self.scheduleSpaceSweepFollowUp(sweep)\n                    break\n                }\n                if self.requeueSwept(parked, ahead: &ahead) {\n", "                if self.requeueSwept(parked, ahead: &ahead) {\n"),
    "gainParkAnyway": rep(head, "            if self.spaceBlock(parked, ahead: ahead) == nil {\n", "            if false, self.spaceBlock(parked, ahead: ahead) == nil {\n"),
}
for name, src in variants.items():
    (d / f"EngineJobs.{name}.swift").write_text(src)
print("ok", sorted(variants))

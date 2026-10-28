"""Synthetic provenance fixtures only, not power or simulator verification."""
import contextlib
import hashlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('pair_audit', Path(__file__).resolve().parents[1] / 'audit_pair.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class CaptureTests(unittest.TestCase):
    def exercise(self, mode='adaptive_gated', bad_clock=False, bad_netlist=False, stage2=False):
        with tempfile.TemporaryDirectory(prefix='native_pair_capture_') as folder:
            case=Path(folder)
            (case/'activity').mkdir()
            (case/'export/exports').mkdir(parents=True)
            (case/'case_config.txt').write_text(f'mode={mode}\n')
            data=b'fixture netlist'
            (case/'export/exports/post_route.v').write_bytes(data)
            digest='invalid' if bad_netlist else hashlib.sha256(data).hexdigest()
            (case/'activity/input_sha256.txt').write_text(f'{digest}  fixture.v\n')
            slow=mode=='adaptive_gated'
            edges=30000 if slow else 6000000
            (case/'activity/simulation.log').write_text(
                'CAPTURE_START time_ns=10011010000 accepted=1199\n'
                f'CAPTURE_END time_ns=70011010000 duration_ns=60000000000 S1=60 S2={int(stage2)} '
                f'processing_edges={edges} fast_edges={0 if slow else edges}\n'
                f'PASS: sent=8400 accepted=8400 S1=66 S2=0 fast_entries={0 if slow else 1}\n'
                'NATIVE_TCF_START time_ns=10011010000\n'
                'NATIVE_TCF_END time_ns=70011010000 duration_ns=60000000000\n')
            count=12000001 if bad_clock else 12000000
            (case/'activity/activity.tcf').write_text(
                'duration : "6e+13"; unit : "ps";\n'
                f'"source_clk" : "0.5 {count}";\n'
                f'"processing_clk" : "0.5 {2*edges}";\n'
                'instance("stage2_stats_gate") { pin() { '
                f'"O" : "0.0 {0 if slow else 12000000}"; }} }}\n')
            if bad_clock or bad_netlist or stage2:
                with self.assertRaises(AssertionError):
                    audit.capture(case)
                self.assertFalse((case/'activity/config.txt').exists())
            else:
                with contextlib.redirect_stdout(io.StringIO()):
                    audit.capture(case)
                self.assertIn('capture_validation=PASS', (case/'activity/config.txt').read_text())

    def test_gated(self): self.exercise()
    def test_ungated(self): self.exercise(mode='fixed_ungated')
    def test_wrong_clock(self): self.exercise(bad_clock=True)
    def test_changed_netlist(self): self.exercise(bad_netlist=True)
    def test_stage2_active(self): self.exercise(stage2=True)


if __name__=='__main__': unittest.main()

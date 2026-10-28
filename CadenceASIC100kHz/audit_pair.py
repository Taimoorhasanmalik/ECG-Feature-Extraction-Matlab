"""Validate exact native-clock pair captures and report matched routed power."""
import argparse
import hashlib
import gzip
import json
from pathlib import Path
import re


def key_values(path):
    return dict(line.split('=', 1) for line in path.read_text().splitlines() if '=' in line)


def capture(case):
    settings = key_values(case / 'case_config.txt')
    mode = settings['mode']
    assert mode in ('adaptive_gated', 'fixed_ungated')
    directory = case / 'activity'
    log = (directory / 'simulation.log').read_text()
    tcf_path = directory / 'activity.tcf'
    tcf = tcf_path.read_text()
    netlist_digest = hashlib.sha256((case / 'export/exports/post_route.v').read_bytes()).hexdigest()
    assert (directory / 'input_sha256.txt').read_text().splitlines()[0].split()[0] == netlist_digest, 'Captured netlist hash changed'
    start = re.search(r'^CAPTURE_START time_ns=(\d+) accepted=(\d+)$', log, re.M)
    end = re.search(r'^CAPTURE_END time_ns=(\d+) duration_ns=(\d+) S1=(\d+) S2=(\d+) processing_edges=(\d+) fast_edges=(\d+)$', log, re.M)
    passed = re.search(r'^PASS: sent=(\d+) accepted=(\d+) S1=(\d+) S2=(\d+) fast_entries=(\d+)$', log, re.M)
    assert start and end and passed, 'Missing simulation/capture PASS'
    assert int(start[1]) == 10011010000 and int(end[1]) == 70011010000
    assert int(end[2]) == 60000000000 and int(end[3]) == 60 and int(end[4]) == 0
    expected_edges = 30000 if mode == 'adaptive_gated' else 6000000
    assert int(end[5]) == expected_edges
    assert int(end[6]) == (0 if mode == 'adaptive_gated' else expected_edges)
    assert int(passed[1]) == int(passed[2]) == 8400 and int(passed[4]) == 0
    assert int(passed[5]) == (0 if mode == 'adaptive_gated' else 1)
    assert 'NATIVE_TCF_START time_ns=10011010000' in log
    assert 'NATIVE_TCF_END time_ns=70011010000 duration_ns=60000000000' in log
    assert float(re.search(r'duration\s*:\s*"([^"]+)"', tcf)[1]) == 60000000000000
    assert re.search(r'unit\s*:\s*"ps"', tcf)

    def transitions(name):
        values = re.findall(r'"' + re.escape(name) + r'"\s*:\s*"[^"\s]+\s+(\d+)"', tcf)
        assert values and len(set(values)) == 1, f'Missing/ambiguous {name}'
        return int(values[0])

    assert transitions('source_clk') == 12000000
    assert transitions('processing_clk') == expected_edges * 2
    # Synthesis/CTS may eliminate the RTL gated-clock alias. The gate output
    # is a stable named physical boundary in both implementations.
    blocks = re.findall(r'instance\("stage2_stats_gate"\)\s*\{\s*pin\(\)\s*\{([^}]+)\}', tcf)
    assert len(blocks) == 1, 'Missing statistics clock gate'
    stats = re.search(r'"O"\s*:\s*"[^"\s]+\s+(\d+)"', blocks[0])
    assert stats and int(stats[1]) == (0 if mode == 'adaptive_gated' else 12000000)
    digest = hashlib.sha256(tcf_path.read_bytes()).hexdigest()
    audit = {'capture_validation': 'PASS', 'duration_ns': 60000000000,
             'source_transitions': 12000000, 'processing_transitions': expected_edges*2,
             'stage2_stats_transitions': int(stats[1]), 'activity_sha256': digest}
    (directory / 'capture_validation.txt').write_text(''.join(f'{k}={v}\n' for k, v in audit.items()))
    config = {'mode': mode, 'workload': 'normal', 'quick': 0, 'capture_bounded': 1,
              'capture_validation': 'PASS', 'source_hz': 100000,
              'capture_duration_ns': 60000000000, 'activity_level': 'gate', 'no_sdf': 1,
              'clock_profile': 'direct100k_pulse_div200', 'activity_format': 'TCF'}
    (directory / 'config.txt').write_text(''.join(f'{k}={v}\n' for k, v in config.items()))
    print(json.dumps(audit, indent=2))


def case_result(case):
    capture(case)
    reports = case / 'power/reports'
    physical_path = Path((case / 'verification_path.txt').read_text().strip().split(': ', 1)[1])
    physical = json.loads((physical_path / 'verification_verdict.json').read_text())
    assert physical['selected_checks_pass'], 'External physical verification did not pass'
    log = (case / 'power/console.log').read_text()
    provenance = key_values(reports / 'power_provenance.txt')
    assert provenance['rtl_activity'] == 'false'
    routed = Path(provenance['source_routed']).resolve(strict=True)
    routed.relative_to(case.resolve(strict=True))
    assert 'ROUTED POWER REPORT GENERATED; ANNOTATION REVIEW REQUIRED' in log
    parasitics = (reports / 'parasitic_annotation.rpt').read_text()
    complete = re.search(r'\|\s*real net \(complete\)\s*\|\s*(\d+)\s*\|\s*(\d+)\s+100\.00%', parasitics)
    broken = re.search(r'\|\s*real net \(broken\)\s*\|\s*(\d+)', parasitics)
    assert complete and complete[1] == complete[2] and broken and int(broken[1]) == 0, 'Incomplete real-net parasitics'
    coverage = {}
    for label in ('Primary Inputs', 'Flop outputs', 'Total Nets'):
        matches = re.findall(re.escape(label) + r'\s*:\s*(\d+)/(\d+)\s*=\s*([\d.]+)%', log)
        assert matches, f'Missing coverage: {label}'
        found, total, percent = matches[-1]
        assert int(found) == int(total), f'Incomplete {label}: {found}/{total}'
        coverage[label] = [int(found), int(total), float(percent)]
    mode = key_values(case / 'case_config.txt')['mode']
    clocks = (case / 'power/voltus_clocks.txt').read_text()
    expected_processing = 500 if mode == 'adaptive_gated' else 100000
    for name, hz in [('source_100khz', 100000), ('processing_fast', expected_processing)]:
        match = re.search('^' + name + r'\s+(\S+)', clocks, re.M)
        assert match and float(match[1]) == hz, f'Wrong frequency: {name}'
    report = (reports / 'routed_power.rpt').read_text()
    assert 'Power Units = 1mW' in report
    power = {}
    for key, label in [('internal', 'Total Internal Power'), ('switching', 'Total Switching Power'),
                       ('leakage', 'Total Leakage Power'), ('total', 'Total Power')]:
        match = re.search(re.escape(label) + r'\s*:\s*([\d.eE+-]+)', report)
        assert match, label
        power[key + '_uw'] = float(match[1]) * 1000
    power['dynamic_uw'] = power['internal_uw'] + power['switching_uw']
    power['energy_uj'] = power['total_uw'] * 60
    area_values = key_values(routed / 'reports/area_breakdown.txt')
    area = {'non_filler_cell_count': int(area_values['non_filler_cell_count']),
            'non_filler_area_um2': float(area_values['non_filler_cell_area_um2'])}
    timing = {}
    for kind, name in [('setup', 'final.summary.gz'), ('hold', 'final_hold.summary.gz')]:
        summary = gzip.decompress((routed / 'reports/timing' / name).read_bytes()).decode()
        match = re.search(r'WNS \(ns\):\|\s*([\d.+-]+)', summary)
        assert match and float(match[1]) >= 0, f'Unclosed routed {kind} timing'
        timing[kind + '_wns_ns'] = float(match[1])
        for rule in ('max_cap', 'max_tran', 'max_fanout', 'max_length'):
            found = re.search(r'\|\s*' + rule + r'\s*\|\s*(\d+)\s*\(', summary)
            if found:
                assert int(found[1]) == 0, f'Remaining routed {rule} violations'
    result = {'mode': mode, 'power': power, 'coverage': coverage,
              'area': area, 'timing': timing,
              'activity_audit': 'PASS', 'duration_seconds': 60,
              'scope': 'Full routed core, 100 kHz source, 0.9 V / 125 C; functional gate activity without SDF'}
    (case / 'case_result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    return result


def compare(pair):
    gated = case_result(pair / 'adaptive_gated')
    ungated = case_result(pair / 'fixed_ungated')
    streams = []
    pattern = re.compile(r'^RESULT time_ns=\d+ stage2=(\d+) id=(\d+) code=(\d+) measured=(\d+)$', re.M)
    for name in ('adaptive_gated', 'fixed_ungated'):
        records = [tuple(map(int, row)) for row in pattern.findall((pair / name / 'activity/simulation.log').read_text())]
        streams.append(records)
    assert streams[0] == streams[1], 'Classification IDs/codes or measured spans differ'
    total_reduction = 100*(1-gated['power']['total_uw']/ungated['power']['total_uw'])
    dynamic_reduction = 100*(1-gated['power']['dynamic_uw']/ungated['power']['dynamic_uw'])
    lines = ['# Native 100 kHz full-core routed power comparison', '',
             'Same 100 kHz source, 120 Hz input, 60 s synthetic normal workload; 0.9 V / 125 C.', '',
             '| Case | Dynamic (uW) | Leakage (uW) | Total (uW) | Energy (uJ) |', '| --- | ---: | ---: | ---: | ---: |']
    for result in (gated, ungated):
        p = result['power']
        lines.append(f"| {result['mode']} | {p['dynamic_uw']:.6f} | {p['leakage_uw']:.6f} | {p['total_uw']:.6f} | {p['energy_uj']:.6f} |")
    lines += ['', f'Combined frequency-and-gating total-power reduction: {total_reduction:.3f}%.',
              f'Dynamic-power reduction: {dynamic_reduction:.3f}%.',
              f'Matched {len(streams[0])} classification IDs/codes and capture membership; latencies may differ.', '',
              'Includes clock controller, mailbox and routed clock trees. External clock generation is excluded.',
              'Functional gate simulation without SDF: no delay-dependent glitch estimate.',
              'This comparison does not isolate gating alone or establish manufacturing/silicon power.', '']
    lines += ['| Case | Non-filler cells | Cell area (um^2) | Setup WNS (ns) | Hold WNS (ns) |',
              '| --- | ---: | ---: | ---: | ---: |']
    for result in (gated, ungated):
        lines.append(f"| {result['mode']} | {result['area']['non_filler_cell_count']} | "
                     f"{result['area']['non_filler_area_um2']:.3f} | {result['timing']['setup_wns_ns']:.3f} | "
                     f"{result['timing']['hold_wns_ns']:.3f} |")
    lines += ['', 'Non-filler area excludes row fillers and is not pad-inclusive die area.', '']
    (pair / 'comparison.md').write_text('\n'.join(lines))
    print('\n'.join(lines))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=('capture', 'case', 'compare'))
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    {'capture': capture, 'case': case_result, 'compare': compare}[args.action](args.directory.resolve(strict=True))

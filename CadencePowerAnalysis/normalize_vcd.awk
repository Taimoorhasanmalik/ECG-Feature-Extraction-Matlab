# Bound a capture to [start,end), normalize timestamps, and audit its clocks.
# Called by prepare_power_capture.sh. The input VCD is never modified.
function fail(message) {
    print "VCD validation failed: " message > "/dev/stderr"
    bad = 1
    exit 2
}
function scope_path(    i, result) {
    result = scopes[1]
    for (i = 2; i <= depth; i++) result = result "." scopes[i]
    return result
}
function parse_scale(    value, unit) {
    value = scale_text
    gsub(/\$timescale|\$end|[[:space:]]/, "", value)
    unit = value
    sub(/^[0-9]+/, "", unit)
    sub(/[a-z]+$/, "", value)
    if (value !~ /^(1|10|100)$/) fail("unsupported timescale multiplier")
    if (unit == "ps") ns_per_tick = value / 1000
    else if (unit == "ns") ns_per_tick = value + 0
    else if (unit == "us") ns_per_tick = value * 1000
    else fail("expected ps, ns or us timescale")
    limit = duration_ns / ns_per_tick
    if (limit != int(limit)) fail("capture endpoint is not an integer VCD tick")
}
function record_scalar(line,    code, value, key) {
    value = tolower(substr(line, 1, 1))
    code = substr(line, 2)
    gsub(/[[:space:]]/, "", code)
    if (!(code in tracked)) return
    if (value != "0" && value != "1") fail("unknown clock value for VCD identifier " code)
    # Initial dump values establish state; they are not clock transitions.
    # Different clock names can legally alias the same VCD identifier.
    if (elapsed > 0 && previous[code] == "0" && value == "1") {
        if (code == found["source"]) rises["source"]++
        if (code == found["processing"]) rises["processing"]++
        if (code == found["stage2_stats"]) rises["stage2_stats"]++
        if (code == found["mac"]) rises["mac"]++
    }
    if (!(code in previous))
        for (key in found) if (found[key] == code) initialized[key] = 1
    previous[code] = value
}
BEGIN {
    if (duration_ns <= 0 || source_hz <= 0 || expected_processing_edges < 0)
        fail("missing capture duration, source rate or edge count")
    root = "ecg_asic_power_tb.dut"
    wanted[root ".source_clk"] = "source"
    wanted[root ".processing_clk"] = "processing"
    wanted[root ".core.pipeline.s2_stats_clk"] = "stage2_stats"
    wanted[root ".core.pipeline.mac2.gated_clk"] = "mac"
}
{ sub(/\r$/, "") }
!header_done {
    if ($1 == "$timescale") reading_scale = 1
    if (reading_scale) {
        scale_text = scale_text $0
        if ($0 ~ /\$end/) { parse_scale(); reading_scale = 0 }
    }
    if ($1 == "$scope") scopes[++depth] = $3
    if ($1 == "$upscope") depth--
    if ($1 == "$var") {
        # A missing-key lookup inserts an AWK array entry. Check membership
        # first so ordinary data/parameter declarations cannot become clocks.
        path = scope_path() "." $5
        key = (path in wanted) ? wanted[path] : ""
        if (key != "") {
            if ($3 != 1) fail("clock declaration is not scalar: " key)
            if (found[key] && found[key] != $4) fail("duplicate clock: " key)
            found[key] = $4
            tracked[$4] = key
        }
    }
    print
    if ($1 == "$enddefinitions") {
        if (!ns_per_tick) fail("missing timescale")
        for (path in wanted)
            if (!found[wanted[path]]) fail("missing clock declaration: " path)
        header_done = 1
    }
    next
}
/^#[0-9]+[[:space:]]*$/ {
    tick = substr($0, 2) + 0
    if (tick > 9007199254740991) fail("timestamp exceeds exact numeric range")
    if (!seen) {
        origin = tick
        expected_origin = input_normalized ? 0 : capture_start_ns / ns_per_tick
        if (origin != expected_origin) fail("first timestamp disagrees with capture provenance")
        seen = 1
    } else if (tick < last_tick) fail("timestamps are not monotonic")
    last_tick = tick
    elapsed = tick - origin
    if (elapsed >= limit) {
        # Keep an exact end timestamp, but none of its events or dump-off Xs.
        printf "#%.0f\n", limit
        bounded = 1
        exit
    }
    printf "#%.0f\n", elapsed
    next
}
/^[[:space:]]*\$dumpoff([[:space:]]|$)/ {
    fail("dumping stopped before the requested capture endpoint")
}
/^[01xXzZ]/ {
    if (!seen) fail("value changes precede the first timestamp")
    record_scalar($0)
}
{ print }
END {
    if (bad) exit 2
    if (!header_done || !seen || !bounded) fail("VCD does not cover the requested interval")
    for (path in wanted)
        if (!initialized[wanted[path]]) fail("missing initial value: " wanted[path])
    expected_source = source_hz * duration_ns / 1000000000
    if (expected_source != int(expected_source)) fail("capture is not a whole number of source periods")
    if (rises["source"] != expected_source) fail("source-clock rising-edge count mismatch")
    if (rises["processing"] != expected_processing_edges) fail("processing-clock count disagrees with testbench")
    if (mode != "adaptive_gated" && rises["processing"] != duration_ns / 10000)
        fail("fixed processing clock is not 100 kHz")
    if (mode == "adaptive_gated" && workload == "normal" &&
        rises["processing"] != duration_ns / 2000000)
        fail("normal adaptive processing clock is not 500 Hz")
    if (mode != "fixed_ungated" && workload == "normal" && rises["stage2_stats"] != 0)
        fail("Stage 2 statistics clock is not gated during normal operation")
    if (mode == "fixed_ungated" && (rises["stage2_stats"] != rises["processing"] ||
        rises["mac"] != rises["processing"])) fail("ungated clocks do not follow processing clock")
    if (mode != "fixed_ungated" && workload == "normal" && rises["processing"] > 0 &&
        (rises["mac"] == 0 || rises["mac"] >= rises["processing"]))
        fail("expected a working, intermittently gated shared MAC")
    print "capture_validation=PASS" > audit_file
    printf "duration_ns=%.0f\n", duration_ns > audit_file
    printf "vcd_end_tick=%.0f\n", limit > audit_file
    printf "vcd_ns_per_tick=%.9g\n", ns_per_tick > audit_file
    printf "source_rising_edges=%.0f\n", rises["source"] > audit_file
    printf "processing_rising_edges=%.0f\n", rises["processing"] > audit_file
    printf "stage2_stats_rising_edges=%.0f\n", rises["stage2_stats"] > audit_file
    printf "mac_rising_edges=%.0f\n", rises["mac"] > audit_file
    close(audit_file)
}

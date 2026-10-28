# Strict half-open VCD window and clock audit. The raw file is never changed.
function fail(message) { print "Capture rejected: " message > "/dev/stderr"; bad=1; exit 2 }
function scope_path(    i,result) {
    result=scopes[1]
    for(i=2;i<=depth;i++) result=result "." scopes[i]
    return result
}
function parse_scale(    text,unit,multiplier) {
    text=scale_text; gsub(/\$timescale|\$end|[[:space:]]/,"",text)
    unit=text; sub(/^[0-9]+/,"",unit)
    multiplier=text; sub(/[a-z]+$/,"",multiplier)
    if(multiplier !~ /^(1|10|100)$/) fail("invalid timescale multiplier")
    if(unit=="ps") ns_per_tick=multiplier/1000
    else if(unit=="ns") ns_per_tick=multiplier+0
    else if(unit=="us") ns_per_tick=multiplier*1000
    else fail("expected ps, ns or us timescale")
    limit=duration_ns/ns_per_tick
    if(limit!=int(limit)) fail("endpoint is not an integer VCD tick")
}
BEGIN {
    if(duration_ns<=0 || (mode!="gated_500hz" && mode!="ungated_100khz")) fail("invalid capture parameters")
    if(source_hz!=(mode=="gated_500hz" ? 500 : 100000)) fail("wrong source clock")
    root="ecg_direct_power_tb.dut"
    wanted[root ".source_clk"]="source"
    wanted[root ".processing_clk"]="processing"
    wanted[root ".pipeline.s2_stats_clk"]="stage2_stats"
    wanted[root ".pipeline.mac2.gated_clk"]="mac"
    next_progress=10
}
{ sub(/\r$/,"") }
!header_done {
    if($1=="$timescale") reading_scale=1
    if(reading_scale) {
        scale_text=scale_text $0
        if($0~/\$end/) { parse_scale(); reading_scale=0 }
    }
    if($1=="$scope") scopes[++depth]=$3
    if($1=="$upscope") depth--
    if($1=="$var") {
        path=scope_path() "." $5
        # Membership must be checked BEFORE looking up ordinary declarations.
        if(path in wanted) {
            key=wanted[path]
            if($3!=1 || (found[key] && found[key]!=$4)) fail("invalid clock declaration: " path)
            found[key]=$4; tracked[$4]=1
        }
    }
    print
    if($1=="$enddefinitions") {
        if(!ns_per_tick) fail("missing timescale")
        for(path in wanted) if(!found[wanted[path]]) fail("missing clock: " path)
        header_done=1
    }
    next
}
/^#[0-9]+[[:space:]]*$/ {
    tick=substr($0,2)+0
    if(tick>9007199254740991) fail("timestamp exceeds exact numeric range")
    if(!seen) {
        origin=tick; seen=1
        if(origin!=capture_start_ns/ns_per_tick) fail("VCD origin disagrees with capture log")
    } else if(tick<last_tick) fail("nonmonotonic timestamps")
    last_tick=tick; elapsed=tick-origin
    if(elapsed>=limit) {printf "#%.0f\n",limit; bounded=1; exit}
    if(elapsed>=limit*next_progress/100) {
        printf "Capture processing: %d%%\n",int(100*elapsed/limit) > "/dev/stderr"
        fflush("/dev/stderr"); next_progress+=10
    }
    printf "#%.0f\n",elapsed
    next
}
/^[[:space:]]*\$dumpoff([[:space:]]|$)/ { fail("dumping stopped too early") }
/^[01xXzZ]/ {
    if(!seen) fail("values precede initial timestamp")
    value=tolower(substr($0,1,1)); code=substr($0,2); gsub(/[[:space:]]/,"",code)
    if(code in tracked) {
        if(value!="0" && value!="1") fail("unknown monitored clock: " code)
        # Aliased identifiers update every matching clock, not only one name.
        for(key in found) if(found[key]==code) {
            if(elapsed>0 && previous[code]=="0" && value=="1") rises[key]++
            initialized[key]=1
        }
        previous[code]=value
    }
}
{print}
END {
    if(bad) exit 2
    if(!header_done || !seen || !bounded) fail("waveform does not cover measurement")
    for(path in wanted) if(!initialized[wanted[path]]) fail("uninitialized monitored clock")
    expected=duration_ns*source_hz/1000000000
    if(expected!=int(expected) || rises["source"]!=expected || rises["processing"]!=expected ||
        rises["processing"]!=expected_processing_edges) fail("source/processing clock count mismatch")
    if(mode=="gated_500hz") {
        if(rises["stage2_stats"]!=0) fail("Stage 2 statistics not gated")
        if(rises["mac"]<=0 || rises["mac"]>=expected) fail("shared MAC gating/operation mismatch")
    } else if(rises["stage2_stats"]!=expected || rises["mac"]!=expected) fail("ungated clocks must follow source")
    print "capture_validation=PASS" > audit_file
    printf "duration_ns=%.0f\n",duration_ns > audit_file
    printf "vcd_end_tick=%.0f\n",limit > audit_file
    for(key in found) printf "%s_rising_edges=%.0f\n",key,rises[key] > audit_file
    close(audit_file)
    print "Capture processing: 100%" > "/dev/stderr"
}

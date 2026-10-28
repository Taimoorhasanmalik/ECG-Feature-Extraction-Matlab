# Exact bounds from the 100 kHz bench: 100 reset cycles + 10 ms startup,
# 1200 warm-up samples at 120 Hz, then one extra source cycle.
if {![info exists ::env(ECG_PAIR_TCF)]} {error "Set ECG_PAIR_TCF"}
run -absolute 10011010000 ns
puts "NATIVE_TCF_START time_ns=10011010000"
dumptcf -scope ecg_asic_power_tb.dut -output $::env(ECG_PAIR_TCF) \
    -internal -memories -dumpwireasnet -collapse_genblks -timescale ps
run -absolute 70011010000 ns
dumptcf -end
puts "NATIVE_TCF_END time_ns=70011010000 duration_ns=60000000000"
run
exit

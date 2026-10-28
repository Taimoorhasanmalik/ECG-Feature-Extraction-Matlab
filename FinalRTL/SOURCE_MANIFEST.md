# Final RTL source manifest

Snapshot date: 2026-10-11.

The files below were copied from the canonical design without logic changes.
Text equality was checked after normalizing CRLF/LF line endings. SHA-256 values
identify the packaged file bytes. No model databases or trained MAT files are
required by this package.

The 12 files under `rtl/` form the synthesis dependency list in `rtl/files.f`.
Files under `sim/` are simulation-only and are excluded from synthesis.
`sim/two_stage_adaptive_smoke_tb.sv`, Tcl scripts, file lists and documentation
were added for this standalone package; they are not changes to hardware logic.

| Packaged file | Canonical source | Package SHA-256 |
| --- | --- | --- |
| `rtl/basys3_two_stage_adaptive_top.v` | `final_two_stage_design/hardware/rtl/basys3_two_stage_adaptive_top.v` | `167795736fd5c90b276501433500c3afe86019b5376e1c601aab6bd91c27939c` |
| `rtl/two_stage_adaptive_clock_top.v` | `final_two_stage_design/hardware/rtl/two_stage_adaptive_clock_top.v` | `4f76f694d714c4e7f52df755b4b95a09bb16c4ebb6e7935ab3bb1ae5d428e377` |
| `rtl/ecg_adaptive_clock.v` | `final_two_stage_design/hardware/rtl/ecg_adaptive_clock.v` | `4e9879c2586a083bf7e1e0db2d073b507e6148cc7cebdf8f8703233403413687` |
| `rtl/ecg_sample_mailbox.v` | `final_two_stage_design/hardware/rtl/ecg_sample_mailbox.v` | `1d23ba17e2c890fe247a824dbe6751d2e5f7abb1f1adeaf927dcf14e5cb5d76b` |
| `rtl/two_stage_shared_replay_top.v` | `final_two_stage_design/hardware/rtl/two_stage_shared_replay_top.v` | `2da4f449ee0c82a116ed2381f7128b4b9b6a48bb29d2354187d9b73d0750d6f1` |
| `rtl/shared_classifier_mac_q.v` | `final_two_stage_design/hardware/rtl/shared_classifier_mac_q.v` | `8c6553392e46643d2ee594aa5d040a7e8f012bc04c694b750f39a166092668d2` |
| `rtl/stage2_shared_hp1_q29.v` | `final_two_stage_design/hardware/rtl/stage2_shared_hp1_q29.v` | `662529535c3a9a26136f1fc59f826f18ab520cb2e483a96d4ecbf4c1d872f8f2` |
| `rtl/stage2_filter_q29.v` | `final_two_stage_design/hardware/rtl/stage2_filter_q29.v` | `8b821e60f2c9787a3f9a1e7d169fc9ab81dee36b012182ca767adf972908d9a4` |
| `rtl/stage2_classifier_gated_q.v` | `final_two_stage_design/hardware/rtl/stage2_classifier_gated_q.v` | `c9ccec2dee8dbb14794c2233d18931844bcb287a51e0545544405e9e45712d7c` |
| `rtl/01_highpass_iir_filter.v` | `final_two_stage_design/hardware/stage1_hdl/01_highpass_iir_filter.v` | `2f8b93ad82727041cd6bacde2ccc56105a5e2b4a7b98a9e4adac0c5652bfdb4e` |
| `rtl/02_window_sequencer.v` | `final_two_stage_design/hardware/stage1_hdl/02_window_sequencer.v` | `b1d24ea84628408d738cd4dbf3e7d3328fb037a987499bedb97e3c9b50c226e3` |
| `rtl/14_ecg_bram_demo_source.v` | `final_two_stage_design/hardware/stage1_hdl/14_ecg_bram_demo_source.v` | `0830525dc5b22ed59a82836117fa9fdc4158afad9a88cf3fb53f492a2c5cf7bb` |
| `constraints/two_stage_adaptive_basys3.xdc` | `final_two_stage_design/hardware/constraints/two_stage_adaptive_basys3.xdc` | `0d47c5bb4fb59aca7e3135cc8662cacd4199eb296151fedd29b8ff20062e5398` |
| `mem/synthetic_two_stage_demo_q3_8.mem` | `final_two_stage_design/hardware/mem_vectors/synthetic_two_stage_demo_q3_8.mem` | `3d9865af7391430631f4fc5846a5048f5b18c1b1f13b0c2864c75a7dfe651bb1` |
| `sim/clock_primitives_sim.v` | `final_two_stage_design/hardware/tb/BUFGCE.v` | `0620aad33565842f03413d6f7ca555d6e9c76f656c8e527301add337348eb5c9` |
| `sim/adaptive_clock_tb.sv` | `final_two_stage_design/hardware/tb/adaptive_clock_tb.sv` | `14d500ca9b58f6441eb502ba6bb0b4f19163ee7bfedb750401e6030128091748` |

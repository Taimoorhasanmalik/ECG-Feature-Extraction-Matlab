#######################################################
#                                                     
#  Innovus Command Logging File                     
#  Created on Tue Oct 20 17:29:24 2026                
#                                                     
#######################################################

#@(#)CDS: Innovus v25.10-p002_1 (64bit) 04/23/2025 12:43 (Linux 4.18.0-305.el8.x86_64)
#@(#)CDS: NanoRoute 25.10-p002_1 NR250317-0405/25_10-UB (database version 18.20.663) {superthreading v2.20}
#@(#)CDS: AAE 25.10-b008 (64bit) 04/23/2025 (Linux 4.18.0-305.el8.x86_64)
#@(#)CDS: CTE 25.10-b014_1 () Mar 28 2025 03:11:49 ( )
#@(#)CDS: SYNTECH 25.10-b006_1 () Mar 13 2025 03:32:26 ( )
#@(#)CDS: CPE v25.10-b011
#@(#)CDS: IQuantus/TQuantus 24.1.0-s201 (64bit) Thu Mar 20 10:21:58 PDT 2025 (Linux 4.18.0-305.el8.x86_64)

set_global _enable_mmmc_by_default_flow      $CTE::mmmc_default
suppressMessage ENCEXT-2799
getVersion
restoreDesign /home/ec2-user/CadenceASIC100kHz/runs/power_pair_vwGzHG/adaptive_gated/postroute/checkpoints/post_route.enc.dat ecg_asic_power_top
report_area -detail -depth 3 -out_file reports/innovus_postroute_area.rpt
report_area -detail -depth 3 -include_physical -out_file reports/innovus_postroute_area_including_physical.rpt
reportGateCount -level 3 -stdCellOnly -outfile reports/innovus_postroute_gate_count.rpt

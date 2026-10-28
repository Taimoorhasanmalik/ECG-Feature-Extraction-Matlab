`timescale 1ns/1ps
module stage2_reference_tb;
    reg clk=0, resetn=0, sample_valid=0;
    reg signed [31:0] sample_q16_16=0;
    always #5 clk=~clk;
    wire filtered_valid, feature_valid, overflow;
    wire signed [13:0] filtered_q8;
    wire [31:0] window_id;
    wire signed [11:0] f0,f4,f5,f6;
    wire signed [16:0] f1;
    wire signed [8:0] f2,f3;
    wire [82:0] packed_feature={f6,f5,f4,f3,f2,f1,f0};
    stage2_filter_q29 filter_dut (
        .clk(clk),.resetn(resetn),.sample_valid(sample_valid),
        .sample_q16_16(sample_q16_16),.output_valid(filtered_valid),
        .output_q5_8(filtered_q8)
    );
    stage2_features_q features_dut (
        .clk(clk),.resetn(resetn),.sample_valid(filtered_valid),
        .sample_q8(filtered_q8),.features_valid(feature_valid),
        .window_id(window_id),.mean_abs_q3_8(f0),.line_length_q8_8(f1),
        .derivative_zc(f2),.threshold_crossings(f3),
        .local_amp_mean_q3_8(f4),.local_amp_range_q3_8(f5),
        .amp_transition_q3_8(f6),.overflow(overflow)
    );
    reg [31:0] input_mem [0:599];
    reg [13:0] filter_mem [0:599];
    reg [82:0] feature_mem [0:3];
    string vector_dir;
    integer i, pass, phase, input_count, output_count, feature_count;
    initial begin
        if (!$value$plusargs("VECTOR_DIR=%s",vector_dir))
            $fatal(1,"VECTOR_DIR missing");
        $readmemh({vector_dir,"/input.mem"},input_mem);
        $readmemh({vector_dir,"/filter.mem"},filter_mem);
        $readmemh({vector_dir,"/features.mem"},feature_mem);
        for (pass=0;pass<2;pass=pass+1) begin
            resetn=0; sample_valid=0;
            phase=0; input_count=0; output_count=0; feature_count=0;
            repeat (4) @(negedge clk);
            resetn=1;
            for (i=0;i<3000;i=i+1) begin
                @(negedge clk);
                phase=phase+120;
                sample_valid=0;
                if (phase>=500 && input_count<600) begin
                    phase=phase-500;
                    sample_valid=1;
                    sample_q16_16=input_mem[input_count];
                    input_count=input_count+1;
                end
                if (filtered_valid) begin
                    if (output_count>=600 || filtered_q8 !== filter_mem[output_count])
                        $fatal(1,"filter mismatch pass %0d sample %0d got %0d expected %0d",
                            pass,output_count,filtered_q8,$signed(filter_mem[output_count]));
                    output_count=output_count+1;
                end
                if (feature_valid) begin
                    if (feature_count>=4 || window_id!=feature_count ||
                        packed_feature !== feature_mem[feature_count]) begin
                        $display("pass=%0d window=%0d got %h expected %h",pass,window_id,
                            packed_feature,feature_mem[feature_count]);
                        $fatal(1,"feature mismatch");
                    end
                    feature_count=feature_count+1;
                end
                if (overflow) $fatal(1,"overflow");
            end
            if (input_count!=600 || output_count!=600 || feature_count!=4)
                $fatal(1,"counts input=%0d filter=%0d features=%0d",
                    input_count,output_count,feature_count);
        end
        $display("PASS: 2 reset-separated runs of 600 filter samples and 4 exact windows");
        $finish;
    end
endmodule

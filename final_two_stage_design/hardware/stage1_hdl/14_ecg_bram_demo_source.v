`timescale 1ns/1ps

/*
 * ecg_bram_demo_source
 * --------------------
 *
 * Plays a short, real VFDB ECG example from an inferred block ROM at an
 * average sample rate of exactly 120 Hz.  The 500 Hz processing clock is not
 * an integer multiple of 120 Hz, so a phase accumulator alternates the sample
 * interval between 4 and 5 clocks without accumulating timing error.
 *
 * The supplied 1200 x 12-bit initialization fits in one RAMB36 on Artix-7
 * (equivalent to two RAMB18 halves).
 * It is a 10-second segment of VFDB record 419 centered on the first VFL
 * rhythm annotation: five seconds of filter pre-roll followed by five seconds
 * beginning at the annotated transition.  It produces nine overlapping
 * feature windows and seven three-window sequence decisions.
 */

module ecg_bram_demo_source #(
    parameter integer SAMPLE_WIDTH   = 12,
    parameter integer SAMPLE_COUNT   = 1200,
    parameter integer CLOCK_HZ       = 500,
    parameter integer SAMPLE_RATE_HZ = 120,
    parameter         MEMORY_FILE    = "17_bram_demo_input_samples.mem"
) (
    input  wire                           clk,
    input  wire                           resetn,
    input  wire                           enable,

    output reg signed [SAMPLE_WIDTH-1:0] sample_out,
    output reg                            sample_valid,
    output reg                            playback_done
);

    localparam integer ADDRESS_WIDTH = $clog2(SAMPLE_COUNT);
    localparam integer RATE_ACC_WIDTH = $clog2(CLOCK_HZ + SAMPLE_RATE_HZ);

    (* rom_style = "block" *)
    reg signed [SAMPLE_WIDTH-1:0] sample_rom [0:SAMPLE_COUNT-1];

    reg [ADDRESS_WIDTH-1:0] read_address;
    reg [RATE_ACC_WIDTH-1:0] rate_accumulator;

    initial begin
        $readmemh(MEMORY_FILE, sample_rom);
    end

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            sample_out      <= {SAMPLE_WIDTH{1'b0}};
            sample_valid    <= 1'b0;
            playback_done   <= 1'b0;
            read_address    <= {ADDRESS_WIDTH{1'b0}};
            rate_accumulator <= {RATE_ACC_WIDTH{1'b0}};
        end else begin
            sample_valid <= 1'b0;

            if (!enable) begin
                playback_done    <= 1'b0;
                read_address     <= {ADDRESS_WIDTH{1'b0}};
                rate_accumulator <= {RATE_ACC_WIDTH{1'b0}};
            end else if (!playback_done) begin
                if (rate_accumulator >= (CLOCK_HZ - SAMPLE_RATE_HZ)) begin
                    rate_accumulator <=
                        rate_accumulator + SAMPLE_RATE_HZ - CLOCK_HZ;
                    sample_out   <= sample_rom[read_address];
                    sample_valid <= 1'b1;

                    if (read_address == SAMPLE_COUNT - 1) begin
                        playback_done <= 1'b1;
                    end else begin
                        read_address <= read_address + 1'b1;
                    end
                end else begin
                    rate_accumulator <=
                        rate_accumulator + SAMPLE_RATE_HZ;
                end
            end
        end
    end

endmodule

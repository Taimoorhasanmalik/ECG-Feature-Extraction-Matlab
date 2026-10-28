/*
 * Overlapping Window Timing Example
 * ---------------------------------
 *
 * Parameters:
 *
 *   WINDOW_SAMPLES = 4
 *   STEP_SAMPLES   = 2
 *
 * Two accumulator banks are used:
 *
 *   Bit 0 -> Feature Bank 0
 *   Bit 1 -> Feature Bank 1
 *
 * Signal meanings:
 *
 *   window_start[bank]
 *       Asserted when the current sample is the first sample
 *       of a new window assigned to that bank.
 *
 *   feature_bank_enable[bank]
 *       Asserted when the current sample belongs to the window
 *       currently assigned to that bank.
 *
 *   window_end[bank]
 *       Asserted when the current sample is the final sample
 *       of the window assigned to that bank.
 *
 * Expected timing:
 *
 *  Sample | window_start | feature_bank_enable | window_end | Operation
 * --------+--------------+--------------------+------------+----------------------------
 *     0   |     2'b01    |       2'b01        |   2'b00    | Start Window 0 in Bank 0
 *     1   |     2'b00    |       2'b01        |   2'b00    | Update Bank 0
 *     2   |     2'b10    |       2'b11        |   2'b00    | Start Window 1 in Bank 1;
 *         |              |                    |            | update both banks
 *     3   |     2'b00    |       2'b11        |   2'b01    | Final sample of Window 0
 *     4   |     2'b01    |       2'b11        |   2'b00    | Reuse Bank 0 for Window 2;
 *         |              |                    |            | update both banks
 *     5   |     2'b00    |       2'b11        |   2'b10    | Final sample of Window 1
 *
 * Resulting windows:
 *
 *   Window 0, Bank 0: samples 0, 1, 2, 3
 *   Window 1, Bank 1: samples 2, 3, 4, 5
 *   Window 2, Bank 0: samples 4, 5, 6, 7
 *
 * Therefore, each window contains four valid samples and a new
 * window starts every two valid samples, producing 50% overlap.
 *
 * Important:
 *
 *   - The sample identified by window_start is included in the window.
 *   - The sample identified by window_end is also included in the window.
 *   - During an overlapping region, feature_bank_enable is 2'b11,
 *     so the same ECG sample updates both feature accumulator banks.
 *   - Bank 0 and Bank 1 are reused alternately after their previous
 *     windows have completed.
 */
module feature_set #(
    parameter SAMPLE_WIDTH   = 12,
    parameter WINDOW_SAMPLES = 720,
    parameter STEP_SAMPLES   = 360
) (
    input  wire                           clk,
    input  wire                           resetn,
    input  wire                           restart,
    input  wire signed [SAMPLE_WIDTH-1:0] sample_in,
    input  wire                           sample_valid,

    output reg signed [SAMPLE_WIDTH-1:0]  sample_out,
    output reg                            sample_out_valid,

    output reg [31:0]                     sample_index,
    output reg [31:0]                     window_count,

    /*
     * Bit 0 corresponds to Feature Bank 0.
     * Bit 1 corresponds to Feature Bank 1.
     */
    output reg [1:0]                      window_start,
    output reg [1:0]                      window_end,
    output reg [1:0]                      feature_bank_enable,
    output reg [1:0]                      window_active,

    /*
     * Pulses for one clock when a new window is due
     * but neither feature bank is available.
     */
    output reg                            window_overflow
);

    /*
     * Returns the minimum number of bits required
     * to represent values from 0 to value-1.
     */
    function integer clog2;
        input integer value;
    begin
        value = value - 1;

        for (clog2 = 0; value > 0; clog2 = clog2 + 1)
            value = value >> 1;

        if (clog2 < 1)
            clog2 = 1;
    end
    endfunction


    localparam integer STEP_COUNT_WIDTH =
        clog2(STEP_SAMPLES);

    localparam integer WINDOW_COUNTDOWN_WIDTH =
        clog2(WINDOW_SAMPLES);


    localparam [STEP_COUNT_WIDTH-1:0] STEP_LAST =
        STEP_SAMPLES - 1;

    localparam [WINDOW_COUNTDOWN_WIDTH-1:0] WINDOW_RELOAD =
        WINDOW_SAMPLES - 1;

    localparam [WINDOW_COUNTDOWN_WIDTH-1:0] ONE_COUNT =
        {{(WINDOW_COUNTDOWN_WIDTH-1){1'b0}}, 1'b1};


    /*
     * Counts valid samples between consecutive
     * window-start events.
     */
    reg [STEP_COUNT_WIDTH-1:0] step_count;

    /*
     * Each active feature bank has its own remaining
     * sample countdown.
     */
    reg [WINDOW_COUNTDOWN_WIDTH-1:0]
        samples_until_window_end [0:1];


    /*
     * Combinational window-allocation signals.
     */
    wire       new_window_due;
    wire       allocate_bank0;
    wire       allocate_bank1;
    wire       allocation_success;

    wire [1:0] start_mask;
    wire [1:0] end_mask;


    /*
     * A new window is scheduled whenever step_count
     * returns to zero and a valid sample arrives.
     */
    assign new_window_due =
        sample_valid &&
        (restart || step_count == {STEP_COUNT_WIDTH{1'b0}});


    /*
     * Select the first currently unused feature bank.
     */
    assign allocate_bank0 =
        new_window_due &&
        (restart || !window_active[0]);

    assign allocate_bank1 =
        new_window_due &&
        !restart && window_active[0] &&
        !window_active[1];


    assign allocation_success =
        allocate_bank0 ||
        allocate_bank1;


    /*
     * One-hot indication of which bank starts
     * a new window on the current sample.
     */
    assign start_mask = {
        allocate_bank1,
        allocate_bank0
    };


    /*
     * A window ends when its final valid sample arrives.
     *
     * The current sample is still included because
     * feature_bank_enable remains asserted on this cycle.
     */
    assign end_mask[0] =
        sample_valid &&
        !restart && window_active[0] &&
        (samples_until_window_end[0] <= ONE_COUNT);

    assign end_mask[1] =
        sample_valid &&
        !restart && window_active[1] &&
        (samples_until_window_end[1] <= ONE_COUNT);


    always @(posedge clk or negedge resetn) begin

        if (!resetn) begin

            sample_out                  <= {SAMPLE_WIDTH{1'b0}};
            sample_out_valid            <= 1'b0;

            sample_index                <= 32'd0;
            window_count                <= 32'd0;

            window_start                <= 2'b00;
            window_end                  <= 2'b00;
            feature_bank_enable          <= 2'b00;
            window_active               <= 2'b00;
            window_overflow             <= 1'b0;

            step_count                  <=
                {STEP_COUNT_WIDTH{1'b0}};

            samples_until_window_end[0] <=
                {WINDOW_COUNTDOWN_WIDTH{1'b0}};

            samples_until_window_end[1] <=
                {WINDOW_COUNTDOWN_WIDTH{1'b0}};

        end else if (restart) begin
            // Rephase both overlap banks on this very sample if valid.
            // The old partial windows are intentionally discarded.
            sample_out_valid <= sample_valid;
            window_start <= start_mask;
            window_end <= 2'b00;
            feature_bank_enable <= start_mask;
            window_active <= start_mask;
            window_overflow <= 1'b0;
            samples_until_window_end[0] <= sample_valid ? WINDOW_RELOAD : 0;
            samples_until_window_end[1] <= 0;
            step_count <= sample_valid ? {{(STEP_COUNT_WIDTH-1){1'b0}},1'b1} : 0;
            if (sample_valid) begin
                sample_out <= sample_in;
                sample_index <= sample_index + 32'd1;
                window_count <= window_count + 32'd1;
            end
        end else begin

            /*
             * These are one-clock event signals.
             */
            sample_out_valid <= sample_valid;
            window_start     <= start_mask;
            window_end       <= end_mask;

            window_overflow  <=
                new_window_due &&
                !allocation_success;


            if (sample_valid) begin

                /*
                 * Register the incoming ECG sample.
                 */
                sample_out   <= sample_in;
                sample_index <= sample_index + 32'd1;


                /*
                 * Indicate which feature banks must process
                 * the current ECG sample.
                 *
                 * Existing active banks receive the sample.
                 * A bank starting now also receives it.
                 */
                feature_bank_enable <=
                    window_active |
                    start_mask;


                /*
                 * Count only successfully started windows.
                 */
                if (allocation_success)
                    window_count <= window_count + 32'd1;


                /*
                 * Update persistent bank state.
                 *
                 * Started banks become active.
                 * Ending banks become inactive.
                 */
                window_active <=
                    (window_active | start_mask) &
                    ~end_mask;


                /*
                 * Feature Bank 0 countdown.
                 */
                if (end_mask[0]) begin

                    samples_until_window_end[0] <=
                        {WINDOW_COUNTDOWN_WIDTH{1'b0}};

                end else if (window_active[0]) begin

                    samples_until_window_end[0] <=
                        samples_until_window_end[0] -
                        ONE_COUNT;

                end else if (start_mask[0]) begin

                    samples_until_window_end[0] <=
                        WINDOW_RELOAD;

                end


                /*
                 * Feature Bank 1 countdown.
                 */
                if (end_mask[1]) begin

                    samples_until_window_end[1] <=
                        {WINDOW_COUNTDOWN_WIDTH{1'b0}};

                end else if (window_active[1]) begin

                    samples_until_window_end[1] <=
                        samples_until_window_end[1] -
                        ONE_COUNT;

                end else if (start_mask[1]) begin

                    samples_until_window_end[1] <=
                        WINDOW_RELOAD;

                end


                /*
                 * Start a new window every STEP_SAMPLES
                 * valid ECG samples.
                 */
                if (step_count == STEP_LAST) begin

                    step_count <=
                        {STEP_COUNT_WIDTH{1'b0}};

                end else begin

                    step_count <=
                        step_count +
                        {{(STEP_COUNT_WIDTH-1){1'b0}}, 1'b1};

                end

            end else begin

                /*
                 * No valid sample means that no feature
                 * accumulator should update.
                 */
                feature_bank_enable <= 2'b00;

            end
        end
    end

endmodule

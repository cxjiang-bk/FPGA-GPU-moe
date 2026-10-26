// M3 completion capture, external to the unchanged LPU.
// All signals are synchronous to core_clk except asynchronous assertion of
// core_resetn. Host CDC is performed upstream by u_lpu_ctrl_sc.
// Registers in the upstream-decoded 4 KiB window:
//   0x000 STATUS      R/W1C: bit 0 END, bit 1 DONE; event wins over clear.
//   0x004 IRQ_ENABLE  R/W:   bit 0 END, bit 1 DONE; reset 0 (polling mode).
//   0x008 IRQ_PENDING R/O:  STATUS & IRQ_ENABLE, reserved for the M4 bridge.
// Reading never clears status. Only global core_resetn or STATUS W1C clears
// it; the RVCore RUN_CTRL soft reset is deliberately not an input.
module lpu_completion_status (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 core_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME core_clk, ASSOCIATED_BUSIF S_AXI, ASSOCIATED_RESET core_resetn" *)
    input  wire        core_clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 core_resetn RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME core_resetn, POLARITY ACTIVE_LOW" *)
    input  wire        core_resetn,
    input  wire        rvcore_irq,
    input  wire        lpu_done_irq,
    output wire [1:0]  event_status,
    output wire [1:0]  irq_pending,
    output wire        irq_req,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI, PROTOCOL AXI4LITE, ADDR_WIDTH 32, DATA_WIDTH 32, READ_WRITE_MODE READ_WRITE, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1" *)
    input  wire [31:0] s_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWPROT" *)
    input  wire [2:0]  s_axi_awprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *)
    input  wire        s_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *)
    output wire        s_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WDATA" *)
    input  wire [31:0] s_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *)
    input  wire [3:0]  s_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WVALID" *)
    input  wire        s_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WREADY" *)
    output wire        s_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BRESP" *)
    output logic [1:0] s_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BVALID" *)
    output logic      s_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BREADY" *)
    input  wire        s_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *)
    input  wire [31:0] s_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARPROT" *)
    input  wire [2:0]  s_axi_arprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *)
    input  wire        s_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *)
    output wire        s_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RDATA" *)
    output logic [31:0] s_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RRESP" *)
    output logic [1:0] s_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RVALID" *)
    output logic      s_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RREADY" *)
    input  wire        s_axi_rready
);
    localparam logic [11:0] STATUS = 12'h000;
    localparam logic [11:0] IRQ_ENABLE = 12'h004;
    localparam logic [11:0] IRQ_PENDING = 12'h008;
    logic [1:0] sticky, enable_bits;
    logic aw_pending, w_pending;
    logic [11:0] held_addr;
    logic [31:0] held_data;
    logic [3:0] held_strb;

    // Accept AW and W independently, including W before AW. One buffered
    // transaction per channel; do not accept another until B is consumed.
    assign s_axi_awready = core_resetn && !aw_pending && !s_axi_bvalid;
    assign s_axi_wready  = core_resetn && !w_pending && !s_axi_bvalid;
    assign s_axi_arready = core_resetn && !s_axi_rvalid;
    wire aw_take = s_axi_awvalid && s_axi_awready;
    wire w_take = s_axi_wvalid && s_axi_wready;
    wire commit_write = !s_axi_bvalid && (aw_pending || aw_take) && (w_pending || w_take);
    // Upper address bits are decoded by SmartConnect. Decode ALL 12 window
    // bits here, including alignment, so unsupported offsets do not alias.
    wire [11:0] write_addr = aw_pending ? held_addr : s_axi_awaddr[11:0];
    wire [31:0] write_data = w_pending ? held_data : s_axi_wdata;
    wire [3:0] write_strb = w_pending ? held_strb : s_axi_wstrb;
    wire [1:0] clear_bits = (commit_write && write_addr == STATUS && write_strb[0])
                           ? write_data[1:0] : 2'b00;
    wire [1:0] events = {lpu_done_irq, rvcore_irq};
    assign event_status = sticky;
    assign irq_pending = sticky & enable_bits;
    assign irq_req = |irq_pending;

    always_ff @(posedge core_clk or negedge core_resetn) begin
        if (!core_resetn) begin
            sticky <= 2'b00;
            enable_bits <= 2'b00;
            aw_pending <= 1'b0;
            w_pending <= 1'b0;
            held_addr <= '0;
            held_data <= '0;
            held_strb <= '0;
            s_axi_bvalid <= 1'b0;
            s_axi_bresp <= 2'b00;
        end else begin
            // Capture events even while AXI is stalled or IRQ is masked.
            sticky <= (sticky & ~clear_bits) | events;
            if (aw_take) begin
                aw_pending <= 1'b1;
                held_addr <= s_axi_awaddr[11:0];
            end
            if (w_take) begin
                w_pending <= 1'b1;
                held_data <= s_axi_wdata;
                held_strb <= s_axi_wstrb;
            end
            if (commit_write) begin
                aw_pending <= 1'b0;
                w_pending <= 1'b0;
                s_axi_bvalid <= 1'b1;
                s_axi_bresp <= 2'b00;
                case (write_addr)
                    STATUS: begin end // W1C applied exactly once above.
                    IRQ_ENABLE: if (write_strb[0]) enable_bits <= write_data[1:0];
                    default: s_axi_bresp <= 2'b10; // SLVERR, no side effects.
                endcase
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    // Return the pre-edge snapshot on an AR handshake. An event coincident
    // with this handshake is visible in the next read. Stalled R is stable.
    always_ff @(posedge core_clk or negedge core_resetn) begin
        if (!core_resetn) begin
            s_axi_rvalid <= 1'b0;
            s_axi_rdata <= '0;
            s_axi_rresp <= 2'b00;
        end else if (s_axi_arvalid && s_axi_arready) begin
            s_axi_rvalid <= 1'b1;
            s_axi_rresp <= 2'b00;
            case (s_axi_araddr[11:0])
                STATUS:      s_axi_rdata <= {30'b0, sticky};
                IRQ_ENABLE:  s_axi_rdata <= {30'b0, enable_bits};
                IRQ_PENDING: s_axi_rdata <= {30'b0, irq_pending};
                default: begin
                    s_axi_rdata <= '0;
                    s_axi_rresp <= 2'b10;
                end
            endcase
        end else if (s_axi_rvalid && s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
        end
    end
    // AWPROT/ARPROT do not change register behavior in this trusted control
    // window; access protection, if required, belongs to the platform.
endmodule

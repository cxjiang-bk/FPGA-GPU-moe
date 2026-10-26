// Correctness-first bridge: one pending request per native port, one AXI transaction.
// Native A/B/SW addresses are 32-bit WORD addresses; AXI addresses are BYTE addresses.
// No protocol state is discarded by a core/task reset. rst is a platform reset only.
module otpu_mem_axi (
  input logic clk, rst, clear_error,
  input logic a_req, a_we,
  input logic [31:0] a_addr, a_wdata,
  input logic [3:0] a_be,
  output logic a_rdy, a_rvalid,
  output logic [255:0] a_rdata,
  input logic b_req, b_we, b_tag,
  input logic [31:0] b_addr,
  input logic [1023:0] b_wdata,
  input logic [31:0] b_wmask,
  output logic b_rdy, b_rvalid, b_rtag,
  output logic [1023:0] b_rdata,
  input logic sw_req,
  input logic [31:0] sw_addr, sw_wdata,
  input logic [3:0] sw_be,
  output logic sw_rdy, rd_idle, wr_idle,
  output logic [31:0] error_code,
  output logic [63:0] read_bytes, write_bytes,
  output logic [31:0] m_axi_awaddr,
  output logic [7:0] m_axi_awlen,
  output logic [2:0] m_axi_awsize,
  output logic [1:0] m_axi_awburst,
  output logic m_axi_awvalid,
  input logic m_axi_awready,
  output logic [1023:0] m_axi_wdata,
  output logic [127:0] m_axi_wstrb,
  output logic m_axi_wlast, m_axi_wvalid,
  input logic m_axi_wready,
  input logic [1:0] m_axi_bresp,
  input logic m_axi_bvalid,
  output logic m_axi_bready,
  output logic [31:0] m_axi_araddr,
  output logic [7:0] m_axi_arlen,
  output logic [2:0] m_axi_arsize,
  output logic [1:0] m_axi_arburst,
  output logic m_axi_arvalid,
  input logic m_axi_arready,
  input logic [1023:0] m_axi_rdata,
  input logic [1:0] m_axi_rresp,
  input logic m_axi_rlast, m_axi_rvalid,
  output logic m_axi_rready
);
  typedef enum logic [1:0] {IDLE, R_ADDR, R_DATA, W_RESP} state_t;
  state_t state;
  logic av, bv, sv, awe, bwe, btag;
  logic [31:0] aa, ba, sa, ad, sd, bm;
  logic [3:0] am, sm;
  logic [1023:0] bd;
  logic [1:0] next_port, chosen, owner;
  logic [63:0] arrival_clock, arrival [3], oldest;
  wire [2:0] pending = {sv, bv, av};
  wire [2:0] is_write = {1'b1, bwe, awe};
  logic found, active_tag, aw_sent, w_sent;
  logic [1:0] line;
  logic [31:0] address_hold;
  logic [1023:0] data_hold;
  logic [127:0] mask_hold;
  logic [31:0] selected_addr, selected_scalar;
  logic [3:0] selected_mask;
  logic selected_write, malformed;

  // Ready depends only on registered queue occupancy, never on this cycle's req.
  assign a_rdy = !av && !rst;
  assign b_rdy = !bv && !rst;
  assign sw_rdy = !sv && !rst;
  assign rd_idle = !(av && !awe) && !(bv && !bwe) &&
                   state != R_ADDR && state != R_DATA && !a_rvalid && !b_rvalid;
  assign wr_idle = !(av && awe) && !(bv && bwe) && !sv && state != W_RESP;

  always_comb begin
    chosen = 0; found = 0; oldest = '1;
    for (int i = 0; i < 3; i++) begin
      // Preserve cross-port memory dependencies after the core retires a store.
      // Equal-cycle independent requests use write-first, then rotating port priority.
      if (pending[(int'(next_port)+i)%3] && (!found || arrival[(int'(next_port)+i)%3] < oldest ||
          (arrival[(int'(next_port)+i)%3] == oldest && is_write[(int'(next_port)+i)%3] && !is_write[chosen]))) begin
        chosen = 2'((int'(next_port)+i)%3); found = 1; oldest = arrival[(int'(next_port)+i)%3];
      end
    end
    selected_addr = chosen == 0 ? aa : chosen == 1 ? ba : sa;
    selected_scalar = chosen == 0 ? ad : sd;
    selected_mask = chosen == 0 ? am : sm;
    selected_write = chosen == 0 ? awe : chosen == 1 ? bwe : 1'b1;
    // Word addresses above 2^30 exceed the core's 4 GiB byte-address window.
    malformed = selected_addr[31:30] != 0 || (chosen == 1 && selected_addr[4:0] != 0);
  end

  assign m_axi_awaddr = address_hold;
  assign m_axi_awlen = 0;
  assign m_axi_awsize = 7; // one 128-byte beat on the 1024-bit core AXI bus
  assign m_axi_awburst = 1;
  assign m_axi_awvalid = state == W_RESP && !aw_sent;
  assign m_axi_wdata = data_hold;
  assign m_axi_wstrb = mask_hold;
  assign m_axi_wlast = 1;
  assign m_axi_wvalid = state == W_RESP && !w_sent;
  assign m_axi_bready = state == W_RESP && aw_sent && w_sent;
  assign m_axi_araddr = address_hold;
  assign m_axi_arlen = 0;
  assign m_axi_arsize = 7;
  assign m_axi_arburst = 1;
  assign m_axi_arvalid = state == R_ADDR;
  assign m_axi_rready = state == R_DATA;

  always_ff @(posedge clk) begin
    if (rst) begin
      state <= IDLE; av <= 0; bv <= 0; sv <= 0; next_port <= 0;
      a_rvalid <= 0; b_rvalid <= 0; b_rtag <= 0;
      a_rdata <= 0; b_rdata <= 0; error_code <= 0;
      read_bytes <= 0; write_bytes <= 0;
      address_hold <= 0; data_hold <= 0; mask_hold <= 0;
      aw_sent <= 0; w_sent <= 0; owner <= 0; line <= 0; active_tag <= 0;
      arrival_clock <= 0;
      for (int i = 0; i < 3; i++) arrival[i] <= 0;
    end else begin
      arrival_clock <= arrival_clock + 1;
      a_rvalid <= 0; b_rvalid <= 0;
      if (clear_error && state == IDLE && !av && !bv && !sv) error_code <= 0;
      if (a_req && a_rdy) begin
        av <= 1; aa <= a_addr; ad <= a_wdata; am <= a_be; awe <= a_we; arrival[0] <= arrival_clock;
      end
      if (b_req && b_rdy) begin
        bv <= 1; ba <= b_addr; bd <= b_wdata; bm <= b_wmask; bwe <= b_we; btag <= b_tag; arrival[1] <= arrival_clock;
      end
      if (sw_req && sw_rdy) begin
        sv <= 1; sa <= sw_addr; sd <= sw_wdata; sm <= sw_be; arrival[2] <= arrival_clock;
      end
      case (state)
        IDLE: if (found) begin
          case (chosen)
            0: av <= 0;
            1: bv <= 0;
            2: sv <= 0;
          endcase
          next_port <= chosen == 2 ? 0 : chosen + 1;
          owner <= chosen; line <= selected_addr[4:3]; active_tag <= btag;
          address_hold <= {selected_addr[29:5], 7'b0};
          if (malformed) begin
            if (error_code == 0) error_code <= 1;
            if (!selected_write && chosen == 0) begin a_rvalid <= 1; a_rdata <= 0; end
            if (!selected_write && chosen == 1) begin
              b_rvalid <= 1; b_rdata <= 0; b_rtag <= btag;
            end
          end else if (selected_write) begin
            state <= W_RESP; aw_sent <= 0; w_sent <= 0;
            if (chosen == 1) begin
              data_hold <= bd;
              for (int j = 0; j < 32; j++) mask_hold[4*j +: 4] <= {4{bm[j]}};
            end else begin
              data_hold <= 1024'(selected_scalar) << (32 * selected_addr[4:0]);
              mask_hold <= 128'(selected_mask) << (4 * selected_addr[4:0]);
            end
          end else state <= R_ADDR;
        end
        R_ADDR: if (m_axi_arready) state <= R_DATA;
        R_DATA: if (m_axi_rvalid) begin
          if (error_code == 0 && m_axi_rresp != 0) error_code <= 2;
          if (!m_axi_rlast) begin
            if (error_code == 0) error_code <= 4;
          end else begin
            state <= IDLE; read_bytes <= read_bytes + 128;
            if (owner == 0) begin
              a_rvalid <= 1;
              a_rdata <= m_axi_rresp == 0 ? m_axi_rdata[256*line +: 256] : '0;
            end else begin
              b_rvalid <= 1; b_rtag <= active_tag;
              b_rdata <= m_axi_rresp == 0 ? m_axi_rdata : '0;
            end
          end
        end
        W_RESP: begin
          if (m_axi_awvalid && m_axi_awready) aw_sent <= 1;
          if (m_axi_wvalid && m_axi_wready) w_sent <= 1;
          if (m_axi_bvalid && m_axi_bready) begin
            state <= IDLE; write_bytes <= write_bytes + 64'($countones(mask_hold));
            if (error_code == 0 && m_axi_bresp != 0) error_code <= 3;
          end
        end
        default: state <= IDLE;
      endcase
    end
  end
endmodule

// Portable compute/control subsystem. The board wrapper remaps logical AXI addresses.
module v80_opentpu_core (
  input logic clk, rst,
  input logic [11:0] s_axi_awaddr, s_axi_araddr,
  input logic s_axi_awvalid, s_axi_wvalid, s_axi_bready, s_axi_arvalid, s_axi_rready,
  input logic [31:0] s_axi_wdata,
  input logic [3:0] s_axi_wstrb,
  output logic s_axi_awready, s_axi_wready, s_axi_bvalid, s_axi_arready, s_axi_rvalid,
  output logic [1:0] s_axi_bresp, s_axi_rresp,
  output logic [31:0] s_axi_rdata,
  output logic [31:0] m_axi_awaddr, m_axi_araddr,
  output logic [7:0] m_axi_awlen, m_axi_arlen,
  output logic [2:0] m_axi_awsize, m_axi_arsize,
  output logic [1:0] m_axi_awburst, m_axi_arburst,
  output logic m_axi_awvalid, m_axi_wlast, m_axi_wvalid, m_axi_bready, m_axi_arvalid, m_axi_rready,
  output logic [1023:0] m_axi_wdata,
  output logic [127:0] m_axi_wstrb,
  input logic m_axi_awready, m_axi_wready, m_axi_bvalid, m_axi_arready, m_axi_rlast, m_axi_rvalid,
  input logic [1:0] m_axi_bresp, m_axi_rresp,
  input logic [1023:0] m_axi_rdata
);
  import otpu_pkg::*;
  import v80_config_pkg::*;
  logic core_reset, ld_start, clear_bridge_error, ld_busy, halted, core_error, wait_to, a_inval;
  logic [31:0] ld_addr, ld_n, rinit [8], icount;
  logic a_req, a_we, a_rdy, a_rvalid, b_req, b_tag, b_we, b_par, b_rdy, b_rvalid, b_rtag;
  logic [31:0] a_addr, a_wdata, b_addr, b_wmask;
  logic [3:0] a_be, sw_be;
  logic [255:0] a_rdata;
  logic [1023:0] b_wdata, b_rdata;
  logic sw_req, sw_rdy, rd_idle, wr_idle;
  logic [31:0] sw_addr, sw_wdata, bridge_error;
  logic [63:0] read_bytes, write_bytes;
  logic coll_req, coll_ack, coll_gnt_local, coll_error;
  cmd_t coll_cmd [1];
  logic [0:0][7:0] coll_ren;
  logic [0:0][7:0][31:0] coll_raddr, coll_rdata;
  logic [7:0] coll_wen;
  logic [7:0][31:0] coll_waddr, coll_wdata;
  perf_t pf;
  wire quiescent = rd_idle && wr_idle && !a_req && !b_req && !sw_req && !a_rvalid && !b_rvalid;

  otpu_slice #(.SID(0), .S(1), .D(CFG_D), .MCOLS(CFG_MCOLS), .ACT_BLOCKS(CFG_ACT_BLOCKS),
    .ACT_ROWS(CFG_ACT_ROWS), .TMEM_WORDS(CFG_TMEM_WORDS), .IMEM_WORDS(CFG_IMEM_WORDS),
    .FIFO_DEPTH(CFG_FIFO_DEPTH), .LANES(CFG_LANES), .WIN(CFG_WIN), .RPB(CFG_RPB), .WPB(CFG_WPB),
    .MXU_IMPL(CFG_MXU_IMPL), .MXU_CL(CFG_MXU_CL), .MXU_E(CFG_MXU_E), .VPU_CL(CFG_VPU_CL),
    .ULANES(CFG_ULANES), .PQ_WIN(CFG_PQ_WIN), .HAS_DSTEP(0), .TMEM_IMPL(0), .TMEM_PMP(0), .SEQ_WC(0)) slice (
    .clk, .clk_f(1'b0), .sys_rst(rst), .rst(core_reset), .rinit, .ld_start, .ld_addr, .ld_n, .ld_busy,
    .a_rdy, .b_rdy, .sw_rdy, .wr_idle, .rd_idle,
    .a_req, .a_we, .a_addr, .a_wdata, .a_be, .sw_req, .sw_addr, .sw_wdata, .sw_be,
    .a_rvalid, .a_rdata, .b_req, .b_tag, .b_we, .b_wmask, .b_wdata, .b_addr, .b_par,
    .b_rvalid, .b_rtag, .b_rdata, .coll_req, .coll_cmd(coll_cmd[0]), .coll_ack,
    .coll_ren(coll_ren[0]), .coll_raddr(coll_raddr[0]), .coll_rdata(coll_rdata[0]),
    .coll_wen, .coll_waddr, .coll_wdata, .coll_gnt_local, .coll_gnt(coll_gnt_local),
    .halted, .error(core_error), .wait_to, .a_inval, .icount, .pf, .dump(1'b0));
  otpu_coll_bar #(.S(1), .LANES(CFG_LANES)) collective (
    .clk, .rst(core_reset), .req(coll_req), .cmds(coll_cmd), .gnt(coll_gnt_local), .ack(coll_ack),
    .r_en(coll_ren), .r_addr(coll_raddr), .r_data(coll_rdata),
    .w_en(coll_wen), .w_addr(coll_waddr), .w_data(coll_wdata), .gerr(coll_error));
  v80_control #(.ARCH_HASH(CFG_ARCH_HASH), .PLATFORM_ID(CFG_PLATFORM),
    .MAX_INSTRUCTIONS(CFG_IMEM_WORDS/8)) control (
    .clk, .rst, .s_axi_awaddr, .s_axi_araddr, .s_axi_awvalid, .s_axi_wvalid, .s_axi_bready,
    .s_axi_arvalid, .s_axi_rready, .s_axi_wdata, .s_axi_wstrb,
    .s_axi_awready, .s_axi_wready, .s_axi_bvalid, .s_axi_arready, .s_axi_rvalid,
    .s_axi_bresp, .s_axi_rresp, .s_axi_rdata, .core_reset, .ld_start, .clear_bridge_error,
    .ld_addr, .ld_n, .rinit, .ld_busy, .halted,
    .core_error(core_error || coll_error || wait_to), .quiescent, .bridge_error, .icount,
    .read_bytes, .write_bytes);
  otpu_mem_axi bridge (
    .clk, .rst, .clear_error(clear_bridge_error),
    .a_req, .a_we, .a_addr, .a_wdata, .a_be, .a_rdy, .a_rvalid, .a_rdata,
    .b_req, .b_we, .b_tag, .b_addr, .b_wdata, .b_wmask, .b_rdy, .b_rvalid, .b_rtag, .b_rdata,
    .sw_req, .sw_addr, .sw_wdata, .sw_be, .sw_rdy, .rd_idle, .wr_idle,
    .error_code(bridge_error), .read_bytes, .write_bytes,
    .m_axi_awaddr, .m_axi_awlen, .m_axi_awsize, .m_axi_awburst, .m_axi_awvalid, .m_axi_awready,
    .m_axi_wdata, .m_axi_wstrb, .m_axi_wlast, .m_axi_wvalid, .m_axi_wready,
    .m_axi_bresp, .m_axi_bvalid, .m_axi_bready,
    .m_axi_araddr, .m_axi_arlen, .m_axi_arsize, .m_axi_arburst, .m_axi_arvalid, .m_axi_arready,
    .m_axi_rdata, .m_axi_rresp, .m_axi_rlast, .m_axi_rvalid, .m_axi_rready);
endmodule

// Fixed 4 GiB logical-to-HBM address mapping with transparent AXI4 channels.
// Logical 0x00000000..0xFFFFFFFF -> physical 0x4000000000..0x40FFFFFFFF.
// Only AWADDR and ARADDR change; all other signals pass through unchanged.
// Both sides belong to the same clock domain. No clock, reset, state or CDC.
// The system guarantees that input addresses are within the logical 4 GiB.
// S_ADDR_WIDTH: 40 for LPU M_AXI, 32 for RV_I_AXI/RV_D_AXI/RV_U_AXI.
// DATA_WIDTH: 1024 for M_AXI, 512 for RV_I/RV_D, 32 for RV_U.
// All width parameters are positive; S_ADDR_WIDTH >= 32 and DATA_WIDTH % 8 == 0.
// For interfaces without IDs, use ID_WIDTH=1 and tie request IDs to zero.
// Tie unused USER/attribute inputs to their interface-defined constants.
// For a read-only path, tie AWVALID/WVALID low and leave write outputs unused.
module axi_hbm_addr_remap #(
    parameter int unsigned S_ADDR_WIDTH = 32,
    parameter int unsigned DATA_WIDTH   = 1024,
    parameter int unsigned ID_WIDTH     = 8,
    parameter int unsigned AWUSER_WIDTH = 1,
    parameter int unsigned WUSER_WIDTH  = 1,
    parameter int unsigned BUSER_WIDTH  = 1,
    parameter int unsigned ARUSER_WIDTH = 1,
    parameter int unsigned RUSER_WIDTH  = 1
) (
    // Upstream AXI4 slave interface: write address channel.
    input  wire [ID_WIDTH-1:0]     s_axi_awid,
    input  wire [S_ADDR_WIDTH-1:0] s_axi_awaddr,
    input  wire [7:0]              s_axi_awlen,
    input  wire [2:0]              s_axi_awsize,
    input  wire [1:0]              s_axi_awburst,
    input  wire                    s_axi_awlock,
    input  wire [3:0]              s_axi_awcache,
    input  wire [2:0]              s_axi_awprot,
    input  wire [3:0]              s_axi_awqos,
    input  wire [3:0]              s_axi_awregion,
    input  wire [AWUSER_WIDTH-1:0] s_axi_awuser,
    input  wire                    s_axi_awvalid,
    output wire                    s_axi_awready,

    // Upstream write data channel.
    input  wire [DATA_WIDTH-1:0]   s_axi_wdata,
    input  wire [DATA_WIDTH/8-1:0] s_axi_wstrb,
    input  wire                    s_axi_wlast,
    input  wire [WUSER_WIDTH-1:0]  s_axi_wuser,
    input  wire                    s_axi_wvalid,
    output wire                    s_axi_wready,

    // Upstream write response channel.
    output wire [ID_WIDTH-1:0]     s_axi_bid,
    output wire [1:0]              s_axi_bresp,
    output wire [BUSER_WIDTH-1:0]  s_axi_buser,
    output wire                    s_axi_bvalid,
    input  wire                    s_axi_bready,

    // Upstream read address channel.
    input  wire [ID_WIDTH-1:0]     s_axi_arid,
    input  wire [S_ADDR_WIDTH-1:0] s_axi_araddr,
    input  wire [7:0]              s_axi_arlen,
    input  wire [2:0]              s_axi_arsize,
    input  wire [1:0]              s_axi_arburst,
    input  wire                    s_axi_arlock,
    input  wire [3:0]              s_axi_arcache,
    input  wire [2:0]              s_axi_arprot,
    input  wire [3:0]              s_axi_arqos,
    input  wire [3:0]              s_axi_arregion,
    input  wire [ARUSER_WIDTH-1:0] s_axi_aruser,
    input  wire                    s_axi_arvalid,
    output wire                    s_axi_arready,

    // Upstream read data channel.
    output wire [ID_WIDTH-1:0]     s_axi_rid,
    output wire [DATA_WIDTH-1:0]   s_axi_rdata,
    output wire [1:0]              s_axi_rresp,
    output wire                    s_axi_rlast,
    output wire [RUSER_WIDTH-1:0]  s_axi_ruser,
    output wire                    s_axi_rvalid,
    input  wire                    s_axi_rready,

    // Downstream AXI4 master interface: write address channel.
    output wire [ID_WIDTH-1:0]     m_axi_awid,
    output wire [39:0]             m_axi_awaddr,
    output wire [7:0]              m_axi_awlen,
    output wire [2:0]              m_axi_awsize,
    output wire [1:0]              m_axi_awburst,
    output wire                    m_axi_awlock,
    output wire [3:0]              m_axi_awcache,
    output wire [2:0]              m_axi_awprot,
    output wire [3:0]              m_axi_awqos,
    output wire [3:0]              m_axi_awregion,
    output wire [AWUSER_WIDTH-1:0] m_axi_awuser,
    output wire                    m_axi_awvalid,
    input  wire                    m_axi_awready,

    // Downstream write data channel.
    output wire [DATA_WIDTH-1:0]   m_axi_wdata,
    output wire [DATA_WIDTH/8-1:0] m_axi_wstrb,
    output wire                    m_axi_wlast,
    output wire [WUSER_WIDTH-1:0]  m_axi_wuser,
    output wire                    m_axi_wvalid,
    input  wire                    m_axi_wready,

    // Downstream write response channel.
    input  wire [ID_WIDTH-1:0]     m_axi_bid,
    input  wire [1:0]              m_axi_bresp,
    input  wire [BUSER_WIDTH-1:0]  m_axi_buser,
    input  wire                    m_axi_bvalid,
    output wire                    m_axi_bready,

    // Downstream read address channel.
    output wire [ID_WIDTH-1:0]     m_axi_arid,
    output wire [39:0]             m_axi_araddr,
    output wire [7:0]              m_axi_arlen,
    output wire [2:0]              m_axi_arsize,
    output wire [1:0]              m_axi_arburst,
    output wire                    m_axi_arlock,
    output wire [3:0]              m_axi_arcache,
    output wire [2:0]              m_axi_arprot,
    output wire [3:0]              m_axi_arqos,
    output wire [3:0]              m_axi_arregion,
    output wire [ARUSER_WIDTH-1:0] m_axi_aruser,
    output wire                    m_axi_arvalid,
    input  wire                    m_axi_arready,

    // Downstream read data channel.
    input  wire [ID_WIDTH-1:0]     m_axi_rid,
    input  wire [DATA_WIDTH-1:0]   m_axi_rdata,
    input  wire [1:0]              m_axi_rresp,
    input  wire                    m_axi_rlast,
    input  wire [RUSER_WIDTH-1:0]  m_axi_ruser,
    input  wire                    m_axi_rvalid,
    output wire                    m_axi_rready
);

    // AW: replace the address prefix; preserve all request attributes.
    assign m_axi_awid     = s_axi_awid;
    assign m_axi_awaddr   = {8'h40, s_axi_awaddr[31:0]};
    assign m_axi_awlen    = s_axi_awlen;
    assign m_axi_awsize   = s_axi_awsize;
    assign m_axi_awburst  = s_axi_awburst;
    assign m_axi_awlock   = s_axi_awlock;
    assign m_axi_awcache  = s_axi_awcache;
    assign m_axi_awprot   = s_axi_awprot;
    assign m_axi_awqos    = s_axi_awqos;
    assign m_axi_awregion = s_axi_awregion;
    assign m_axi_awuser   = s_axi_awuser;
    assign m_axi_awvalid  = s_axi_awvalid;
    assign s_axi_awready  = m_axi_awready;

    // W: data flows downstream; backpressure flows upstream.
    assign m_axi_wdata    = s_axi_wdata;
    assign m_axi_wstrb    = s_axi_wstrb;
    assign m_axi_wlast    = s_axi_wlast;
    assign m_axi_wuser    = s_axi_wuser;
    assign m_axi_wvalid   = s_axi_wvalid;
    assign s_axi_wready   = m_axi_wready;

    // B: response flows upstream; backpressure flows downstream.
    assign s_axi_bid      = m_axi_bid;
    assign s_axi_bresp    = m_axi_bresp;
    assign s_axi_buser    = m_axi_buser;
    assign s_axi_bvalid   = m_axi_bvalid;
    assign m_axi_bready   = s_axi_bready;

    // AR: apply the same mapping as AW.
    assign m_axi_arid     = s_axi_arid;
    assign m_axi_araddr   = {8'h40, s_axi_araddr[31:0]};
    assign m_axi_arlen    = s_axi_arlen;
    assign m_axi_arsize   = s_axi_arsize;
    assign m_axi_arburst  = s_axi_arburst;
    assign m_axi_arlock   = s_axi_arlock;
    assign m_axi_arcache  = s_axi_arcache;
    assign m_axi_arprot   = s_axi_arprot;
    assign m_axi_arqos    = s_axi_arqos;
    assign m_axi_arregion = s_axi_arregion;
    assign m_axi_aruser   = s_axi_aruser;
    assign m_axi_arvalid  = s_axi_arvalid;
    assign s_axi_arready  = m_axi_arready;

    // R: data/response flow upstream; backpressure flows downstream.
    assign s_axi_rid      = m_axi_rid;
    assign s_axi_rdata    = m_axi_rdata;
    assign s_axi_rresp    = m_axi_rresp;
    assign s_axi_rlast    = m_axi_rlast;
    assign s_axi_ruser    = m_axi_ruser;
    assign s_axi_rvalid   = m_axi_rvalid;
    assign m_axi_rready   = s_axi_rready;

endmodule

// Simulation-only single-beat AXI model with independent AW/W stalls and delayed responses.
module axi_memory_model #(
  parameter int MEM_BYTES = 8 << 20,
  parameter bit WRAP_ADDRESS = 0
) (
  input logic clk, rst, allow_r, allow_b,
  input logic [1:0] inject_rresp, inject_bresp,
  input logic inject_extra_read,
  input logic [31:0] awaddr, araddr,
  input logic [7:0] awlen, arlen,
  input logic [2:0] awsize, arsize,
  input logic [1:0] awburst, arburst,
  input logic awvalid, wlast, wvalid, bready, arvalid, rready,
  input logic [1023:0] wdata,
  input logic [127:0] wstrb,
  output logic awready, wready, bvalid, arready, rlast, rvalid,
  output logic [1:0] bresp, rresp,
  output logic [1023:0] rdata,
  output logic [31:0] last_araddr,
  output int read_transactions, write_transactions
);
  byte unsigned mem [MEM_BYTES];
  logic [31:0] random_state;
  logic have_aw, have_w, read_pending, extra;
  logic [31:0] write_address, read_address;
  logic [1023:0] write_data;
  logic [127:0] write_mask;
  int read_delay, write_delay;
  string image;
  int fd, loaded, seed = 23;
  initial begin
    for (int i = 0; i < MEM_BYTES; i++) mem[i] = 0;
    if ($value$plusargs("image=%s", image)) begin
      fd = $fopen(image, "rb");
      if (fd == 0) $fatal(1, "cannot open %s", image);
      loaded = $fread(mem, fd); $fclose(fd);
      $display("BFM_IMAGE bytes=%0d", loaded);
    end
    if ($value$plusargs("seed=%d", seed)) begin end
  end
  function automatic int index_of(input logic [31:0] addr, input int offset);
    if (!WRAP_ADDRESS && (64'(addr) + offset >= MEM_BYTES))
      $fatal(1, "AXI model address out of range: %h + %0d", addr, offset);
    return int'((64'(addr) + offset) % MEM_BYTES);
  endfunction
  assign awready = !rst && !have_aw && !bvalid && random_state[0];
  assign wready = !rst && !have_w && !bvalid && random_state[3];
  assign arready = !rst && !read_pending && !rvalid && random_state[7];
  always_ff @(posedge clk) begin
    if (rst) begin
      random_state <= 32'(seed) | 1;
      have_aw <= 0; have_w <= 0; read_pending <= 0; extra <= 0;
      rvalid <= 0; bvalid <= 0; rlast <= 1; rdata <= 0; rresp <= 0; bresp <= 0;
      read_delay <= 0; write_delay <= 0; last_araddr <= 0;
      read_transactions <= 0; write_transactions <= 0;
    end else begin
      random_state <= (random_state ^ (random_state << 13)) ^
                      ((random_state ^ (random_state << 13)) >> 17) ^
                      (((random_state ^ (random_state << 13)) ^
                        ((random_state ^ (random_state << 13)) >> 17)) << 5);
      if (awvalid && awready) begin
        if (awlen != 0 || awsize != 7 || awburst != 1 || awaddr[6:0] != 0)
          $fatal(1, "unexpected AW shape");
        have_aw <= 1; write_address <= awaddr; write_delay <= 4 + int'(random_state[6:4]);
      end
      if (wvalid && wready) begin
        if (!wlast) $fatal(1, "expected single W beat");
        have_w <= 1; write_data <= wdata; write_mask <= wstrb;
      end
      if (have_aw && have_w && !bvalid) begin
        if (write_delay > 0) write_delay <= write_delay - 1;
        else if (allow_b) begin
          for (int i = 0; i < 128; i++)
            if (write_mask[i]) mem[index_of(write_address, i)] <= write_data[8*i +: 8];
          bvalid <= 1; bresp <= inject_bresp;
          write_transactions <= write_transactions + 1;
        end
      end
      if (bvalid && bready) begin bvalid <= 0; have_aw <= 0; have_w <= 0; end
      if (arvalid && arready) begin
        if (arlen != 0 || arsize != 7 || arburst != 1 || araddr[6:0] != 0)
          $fatal(1, "unexpected AR shape");
        last_araddr <= araddr; read_address <= araddr; read_pending <= 1;
        read_delay <= 3 + int'(random_state[12:9]); extra <= inject_extra_read;
        read_transactions <= read_transactions + 1;
      end
      if (read_pending && !rvalid) begin
        if (read_delay > 0) read_delay <= read_delay - 1;
        else if (allow_r) begin
          rvalid <= 1; rlast <= !extra; rresp <= inject_rresp;
          for (int i = 0; i < 128; i++) rdata[8*i +: 8] <= mem[index_of(read_address, i)];
          read_pending <= 0;
        end
      end
      if (rvalid && rready) begin
        rvalid <= 0;
        if (!rlast) begin read_pending <= 1; extra <= 0; read_delay <= 2; end
      end
    end
  end
endmodule

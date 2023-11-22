// Copyright (C) 2022 Intel Corporation
// SPDX-License-Identifier: MIT

`include "ofs_plat_if.vh"

// import dma_pkg::*;

//
// Copy engine top-level. Take in a pair of AXI-MM interfaces, one for CSRs and
// one for reading and writing host memory.
//
// This engine can be instantiated either from a full-PIM system using
// ofs_plat_afu() or from a hybrid design in which the PIM host channel
// mapping is created by the AFU.
//

module dma_top #(
    parameter NUM_LOCAL_MEM_BANKS = 1
)(
    // CSR interface (MMIO on the host)
    ofs_plat_axi_mem_lite_if.to_source mmio64_to_afu,

    // Host memory (DMA)
    ofs_plat_axi_mem_if.to_sink host_mem,
    ofs_plat_axi_mem_if.to_sink ddr_mem[NUM_LOCAL_MEM_BANKS]
);

    // Each interface names its associated clock and reset.
    logic clk;
    assign clk = host_mem.clk;
    logic reset_n;
    assign reset_n = host_mem.reset_n;

    // Maximum number of copy commands in flight. This is exposed in a CSR. It
    // is the host's responsibility not to exceed. The host can track completions
    // by requesting interrupts.
    localparam MAX_REQS_IN_FLIGHT = 32;

    // ====================================================================
    //
    // CSR (MMIO) manager. Handle all MMIO reads and writes from the host
    // and output copy commands.
    //
    // ====================================================================

    dma_pkg::t_dma_csr_map dma_csr_map; //RO
    dma_pkg::t_dma_csr_status dma_csr_status;
    dma_pkg::t_dma_csr_status dma_status;
    dma_pkg::t_dma_descriptor dma_descriptor;
    logic descriptor_fifo_rdack;
    logic descriptor_fifo_not_empty;
    logic descriptor_fifo_not_full;

    always_comb begin
       dma_csr_status = dma_status;
       dma_csr_status.descriptor_buffer_empty = descriptor_fifo_not_empty;
       dma_csr_status.descriptor_buffer_full = descriptor_fifo_not_full;
    end

    csr_mgr #(
        .MAX_REQS_IN_FLIGHT(MAX_REQS_IN_FLIGHT),
        // Maximum burst length is dictated by the size of the field in
        // the AXI-MM host_mem. The PIM will map AXI-MM bursts to legal
        // host channel bursts, including guaranteeing to satisfy any
        // necessary address alignment.
        .MAX_BURST_CNT(1 << host_mem.BURST_CNT_WIDTH_)
    ) csr_mgr_inst (
        .mmio64_to_afu,
        .dma_csr_map,
        .dma_csr_status
    );

    ofs_plat_prim_fifo_bram #(
      .N_DATA_BITS  ($bits(dma_pkg::t_dma_descriptor)),
      .N_ENTRIES    (dma_pkg::DMA_DESCRIPTOR_FIFO_DEPTH)
    ) descriptor_fifo (
      .clk,
      .reset_n,

      .enq_data(dma_csr_map.descriptor),
      .enq_en(dma_csr_map.descriptor.descriptor_control.go),
      .notFull(descriptor_fifo_not_full),
      .almostFull(),

      .first(dma_descriptor),
      //.deq_en(descriptor_fifo_rdack),
      .deq_en(1'b0),
      .notEmpty(descriptor_fifo_not_empty)
    );


    // ====================================================================
    //
    // Read engine
    //
    // ====================================================================

    // Declare a copy of the host memory read interface. The read ports
    // will be connected to the read engine and the write ports unused.
    // This will split the read channels from the write channels but keep
    // a single interface type.  Do this for each host/ddr read/write
    ofs_plat_axi_mem_if #(
        // Copy the configuration from host_mem
        `OFS_PLAT_AXI_MEM_IF_REPLICATE_PARAMS(host_mem)
    ) dest_mem();


     ofs_plat_axi_mem_if #(
        // Copy the configuration from ddr_mem
        `OFS_PLAT_AXI_MEM_IF_REPLICATE_PARAMS(ddr_mem[0])
     ) src_mem();

    // > RP For testing
    genvar b;
    generate
        for (b = 1; b < NUM_LOCAL_MEM_BANKS; b = b + 1)
        begin : mb
          assign ddr_mem[b].awvalid = 'b0;
          assign ddr_mem[b].wvalid = 'b0;
          assign ddr_mem[b].arvalid = 'b0;
          assign ddr_mem[b].bready = 'b1;
          assign ddr_mem[b].rready = 'b1;
        end
    endgenerate
    // < RP For testing
    
    dma_axi_mm_mux #(
        .NUM_LOCAL_MEM_BANKS (NUM_LOCAL_MEM_BANKS)
    )(
        .mode (dma_descriptor.descriptor_control.mode),
        .src_mem,
        .dest_mem,
        .host_mem,
        .ddr_mem
    );
   
    dma_engine #(
        .MAX_REQS_IN_FLIGHT(MAX_REQS_IN_FLIGHT)
    ) dma_engine_inst (
        .clk,
        .reset_n,
        .src_mem,
        .dest_mem,
        .descriptor_fifo_rdack,
        .descriptor (dma_descriptor),

        // Commands
        .csr_control (dma_csr_map.control),
        .csr_status  (dma_status)
    );


endmodule

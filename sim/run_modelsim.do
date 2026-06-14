# ModelSim simulation script for RTL8019AS ethernet controller

# Create work library
if {[file exists work]} {
    vdel -lib work -all
}
vlib work

# Compile source files
vlog ../rtl/ethernet.v
vlog ethernet_tb.v

# Start simulation
vsim -t ps work.ethernet_tb

# Add waves
add wave -group "Clock/Reset" /ethernet_tb/clk /ethernet_tb/reset
add wave -group "CPU Interface" /ethernet_tb/cpu_addr /ethernet_tb/cpu_data_in /ethernet_tb/cpu_data_out
add wave -group "CPU Control" /ethernet_tb/cpu_rd /ethernet_tb/cpu_hwr /ethernet_tb/cpu_lwr /ethernet_tb/cpu_uds /ethernet_tb/cpu_lds
add wave -group "Ethernet Selects" /ethernet_tb/sel_ethernet /ethernet_tb/sel_ethernet_shm /ethernet_tb/ethernet_base
add wave -group "Control" /ethernet_tb/dtack_eth /ethernet_tb/eth_irq
add wave -group "Internal Registers" /ethernet_tb/dut/cr_register /ethernet_tb/dut/isr_register /ethernet_tb/dut/imr_register /ethernet_tb/dut/dcr_register
add wave -group "DMA Registers" /ethernet_tb/dut/remote_dma_addr /ethernet_tb/dut/remote_byte_count
add wave -group "DMA Handshake" /ethernet_tb/eth_dma_req /ethernet_tb/eth_dma_write /ethernet_tb/eth_dma_addr /ethernet_tb/eth_dma_wdata /ethernet_tb/eth_dma_uds /ethernet_tb/eth_dma_lds /ethernet_tb/eth_dma_ready /ethernet_tb/eth_dma_rdata
add wave -group "Address Decode" /ethernet_tb/dut/is_register_access /ethernet_tb/dut/is_data_port_access /ethernet_tb/dut/register_select

# Configure wave window
configure wave -namecolwidth 200
configure wave -valuecolwidth 80
configure wave -justifyvalue left

# Run simulation
run 2000ns

# Zoom to fit
wave zoom full

echo "RTL8019AS Ethernet Controller Simulation Complete"
echo "Check console output for test results"

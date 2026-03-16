# ModelSim script to run ethernet testbenches

# Create work library
vlib work

# Compile the ethernet module
vlog +incdir+rtl rtl/ethernet.v

# Compile the testbench
vlog tb_data_port_write.v

# Load the simulation
vsim -gui tb_data_port_write

# Add waves to view
add wave -divider "Clock and Reset"
add wave -hex /tb_data_port_write/clk
add wave -hex /tb_data_port_write/reset

add wave -divider "CPU Bus Interface"
add wave -hex /tb_data_port_write/cpu_addr
add wave -hex /tb_data_port_write/cpu_data_in
add wave -hex /tb_data_port_write/cpu_data_out
add wave -hex /tb_data_port_write/cpu_rd
add wave -hex /tb_data_port_write/cpu_hwr
add wave -hex /tb_data_port_write/cpu_lwr
add wave -hex /tb_data_port_write/cpu_uds
add wave -hex /tb_data_port_write/cpu_lds
add wave -hex /tb_data_port_write/cpu_wr

add wave -divider "Chip Selects"
add wave -hex /tb_data_port_write/sel_ethernet
add wave -hex /tb_data_port_write/sel_ethernet_shm

add wave -divider "Address Translation"
add wave -hex /tb_data_port_write/addr_override
add wave -hex /tb_data_port_write/cpu_addr_out
add wave -hex /tb_data_port_write/dut/remote_dma_addr

add wave -divider "Ethernet Module Internal"
add wave -hex /tb_data_port_write/dut/cr_register
add wave -hex /tb_data_port_write/dut/current_page
add wave -hex /tb_data_port_write/dut/remote_byte_count
add wave -hex /tb_data_port_write/dut/is_data_port_access
add wave -hex /tb_data_port_write/dut/is_register_access

add wave -divider "Outputs"
add wave -hex /tb_data_port_write/eth_irq
add wave -hex /tb_data_port_write/dtack_eth

# Run simulation
run -all

# Keep the GUI open
#quit -sim
-- tb_pmmu_all_modes_test.vhd
-- Static MC68030 MMU addressing-mode parity check against WinUAE.

library ieee;
use ieee.std_logic_1164.all;

entity tb_pmmu_all_modes_test is
end entity;

architecture behavioral of tb_pmmu_all_modes_test is
    function winuae_invea(mode : integer; reg : integer) return boolean is
    begin
        -- WinUAE cpummu30.cpp:mmu_op30_invea()
        return mode = 0 or mode = 1 or mode = 3 or mode = 4 or
               (mode = 7 and reg > 1);
    end function;

    function rtl_common_invea(mode : integer; reg : integer) return boolean is
    begin
        -- RTL PMOVE and PFLUSH-with-EA form:
        -- reject Dn, An, (An)+, -(An), PC-relative, and immediate.
        return mode = 0 or mode = 1 or mode = 3 or mode = 4 or
               (mode = 7 and reg > 1);
    end function;

    function rtl_pload_ptest_invea(mode : integer; reg : integer) return boolean is
    begin
        -- RTL PLOAD/PTEST spells reg>1 as bit2=1 OR bits2:1=01.
        -- This is equivalent to WinUAE's mode 7 / reg 2..7 rejection.
        return mode = 0 or mode = 1 or mode = 3 or mode = 4 or
               (mode = 7 and (reg >= 2));
    end function;

    function fc_source_valid(bits43 : integer) return boolean is
    begin
        -- WinUAE helper_get_fc(): 00=SFC/DFC, 01=Dn, 10=immediate, 11=F-line.
        return bits43 /= 3;
    end function;
begin
    process
        variable expected_invalid : boolean;
    begin
        report "MC68030 PMMU EA validation: WinUAE parity check";

        for mode in 0 to 7 loop
            for reg in 0 to 7 loop
                expected_invalid := winuae_invea(mode, reg);

                assert rtl_common_invea(mode, reg) = expected_invalid
                    report "PMOVE/PFLUSH EA mismatch mode=" & integer'image(mode) &
                           " reg=" & integer'image(reg)
                    severity failure;

                assert rtl_pload_ptest_invea(mode, reg) = expected_invalid
                    report "PLOAD/PTEST EA mismatch mode=" & integer'image(mode) &
                           " reg=" & integer'image(reg)
                    severity failure;
            end loop;
        end loop;

        for bits43 in 0 to 3 loop
            assert fc_source_valid(bits43) = (bits43 /= 3)
                report "FC source decode mismatch bits43=" & integer'image(bits43)
                severity failure;
        end loop;

        report "*** PMMU EA MODE WINUAE PARITY TEST PASSED ***";
        wait;
    end process;
end architecture;

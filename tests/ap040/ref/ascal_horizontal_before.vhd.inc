--------------------------------------------------------------------------------
-- AVALON SCALER
--------------------------------------------------------------------------------
-- TEMLIB 2018 - 2020
--------------------------------------------------------------------------------
-- This code can be freely distributed and used for any purpose, but, if you
-- find any bug, or want to suggest an enhancement, you ought to send a mail
-- to info@temlib.org.
--------------------------------------------------------------------------------

-- Frozen HSCAL divider/fraction stages from eefc5367.
-- Pipelined 8 bits non-restoring divider. Cycle 1
			dir_v:=x"000";
			div_v:=to_unsigned(o_hacc * 256,21);

			div_v:=div_v-to_unsigned(o_hsize*256,21);
			dir_v(11):=NOT div_v(20);
			IF div_v(20)='0' THEN
				div_v:=div_v-to_unsigned(o_hsize*128,21);
			ELSE
				div_v:=div_v+to_unsigned(o_hsize*128,21);
			END IF;
			dir_v(10):=NOT div_v(20);

			o_div(0)<=div_v;
			o_dir(0)<=dir_v;

			-- Cycle 2
			div_v:=o_div(0);
			dir_v:=o_dir(0);
			IF div_v(20)='0' THEN
				div_v:=div_v-to_unsigned(o_hsize*64,21);
			ELSE
				div_v:=div_v+to_unsigned(o_hsize*64,21);
			END IF;
			dir_v( 9):=NOT div_v(20);

			IF div_v(20)='0' THEN
				div_v:=div_v-to_unsigned(o_hsize*32,21);
			ELSE
				div_v:=div_v+to_unsigned(o_hsize*32,21);
			END IF;
			dir_v( 8):=NOT div_v(20);

			o_div(1)<=div_v;
			o_dir(1)<=dir_v;

			-- Cycle 3
			div_v:=o_div(1);
			dir_v:=o_dir(1);
			IF FRAC>4 THEN
				IF div_v(20)='0' THEN
					div_v:=div_v-to_unsigned(o_hsize*16,21);
				ELSE
					div_v:=div_v+to_unsigned(o_hsize*16,21);
				END IF;
				dir_v(7):=NOT div_v(20);

				IF div_v(20)='0' THEN
					div_v:=div_v-to_unsigned(o_hsize*8,21);
				ELSE
					div_v:=div_v+to_unsigned(o_hsize*8,21);
				END IF;
				dir_v(6):=NOT div_v(20);
			END IF;
			o_div(2)<=div_v;
			o_dir(2)<=dir_v;

			div_v:=o_div(2);
			dir_v:=o_dir(2);
			IF FRAC>6 THEN
				IF div_v(20)='0' THEN
					div_v:=div_v-to_unsigned(o_hsize*4,21);
				ELSE
					div_v:=div_v+to_unsigned(o_hsize*4,21);
				END IF;
				dir_v(5):=NOT div_v(20);

				IF div_v(20)='0' THEN
					div_v:=div_v-to_unsigned(o_hsize*2,21);
				ELSE
					div_v:=div_v+to_unsigned(o_hsize*2,21);
				END IF;
				dir_v(4):=NOT div_v(20);
			END IF;

			-----------------------------------
			o_hfrac(1)<=dir_v;
			o_hfrac(2 TO 9) <= o_hfrac(1 TO 8);

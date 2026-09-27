--------------------------------------------------------------------------------
-- AVALON SCALER
--------------------------------------------------------------------------------
-- TEMLIB 2018 - 2020
--------------------------------------------------------------------------------
-- This code can be freely distributed and used for any purpose, but, if you
-- find any bug, or want to suggest an enhancement, you ought to send a mail
-- to info@temlib.org.
--------------------------------------------------------------------------------

-- Frozen VSCAL edge selection stages from eefc5367.
-- CYCLE 8
				IF to_integer(o_vacpt)>o_ivsize THEN
					IF fracnn_v = '0' THEN
						o_vpixq_pre<=(o_vpix_outer(0), o_vpix_inner(5), o_vpix_inner(5), o_vpix_inner(5));
					ELSE
						o_vpixq_pre<=(o_vpix_outer(0), o_vpix_outer(1), o_vpix_outer(1), o_vpix_outer(1));
					END IF;
				ELSIF to_integer(o_vacpt)=o_ivsize THEN
					IF fracnn_v = '0' THEN
						o_vpixq_pre<=(o_vpix_outer(0), o_vpix_inner(5), o_vpix_outer(1), o_vpix_outer(1));
					ELSE
						o_vpixq_pre<=(o_vpix_outer(0), o_vpix_outer(1), o_vpix_inner(5), o_vpix_inner(5));
					END IF;
				ELSE
					IF fracnn_v = '0' THEN
						o_vpixq_pre<=(o_vpix_outer(0), o_vpix_inner(5), o_vpix_outer(1), o_vpix_outer(2));
					ELSE
						o_vpixq_pre<=(o_vpix_outer(0), o_vpix_outer(1), o_vpix_inner(5), o_vpix_outer(2));
					END IF;
				END IF;

				-- CYCLE 9
				o_vpixq<=o_vpixq_pre;

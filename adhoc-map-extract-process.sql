WITH -- 0. PARAMETERS - Change date here for ad-hoc runs
extract_parameters AS (
    SELECT '2025-12-12'::DATE AS extract_date -- Change date to desired day
),
-- 1. Phase derivation (P2 vs P3)
claim_phase AS (
    SELECT
        pc.id AS claim_id,
        pc.claim_jsonb,
        pc.claim_jsonb->>'macId' AS mac_id,
        CASE
            WHEN ppr_latest.claim_id IS NOT NULL THEN 'P3'
            ELSE 'P2'
        END AS phase_value
    FROM professional_claim pc
    CROSS JOIN extract_parameters ep
    LEFT JOIN LATERAL (
        SELECT ppr.claim_id
        FROM professional_claim_payment_response ppr
        WHERE ppr.claim_id = pc.id
        ORDER BY ppr.created_at DESC
        LIMIT 1
    ) ppr_latest ON TRUE
    WHERE pc.claim_jsonb->>'macId' IS NOT NULL
      AND pc.claim_jsonb->>'receiptDate' = TO_CHAR(ep.extract_date, 'YYYY-MM-DD')
),
-- 2. MAC dimension
mac AS (
    SELECT DISTINCT
        cp.mac_id,
        cp.phase_value
    FROM claim_phase cp
),
-- 3. Calculate aggregates for trailer
mac_totals AS (
    SELECT
        cp.mac_id,
        cp.phase_value,
        COUNT(*) AS total_claim_headers,
        SUM(jsonb_array_length(cp.claim_jsonb->'serviceLines')) AS total_claim_lines
    FROM claim_phase cp
    GROUP BY cp.mac_id, cp.phase_value
),
claim_key AS (
    SELECT
        cp.claim_id,
        cp.mac_id,
        cp.phase_value,
        LPAD(COALESCE(cp.claim_jsonb->>'planCode', '0'), 2, '0') AS idr_plan,
        LPAD(COALESCE(cp.claim_jsonb->>'internalControlNumber', '0'), 13, '0') AS idr_icn
    FROM claim_phase cp
    WHERE cp.mac_id IS NOT NULL
),
payment AS (
    SELECT
        ppr.claim_id,
        -- Top-level
        (ppr.payment_response_json->>'interestRate')::numeric(10,5)      AS interest_rate,
        (ppr.payment_response_json->>'interestDaysOver')::int            AS interest_days_over,
        -- Bene check
        ppr.payment_response_json->'beneCheck'->>'checkNumber'           AS bene_exchk_num,
        ppr.payment_response_json->'beneCheck'->>'checkStatus'           AS bene_chk_status,
        (ppr.payment_response_json->'beneCheck'->>'claimAmount')::numeric(9,2) AS bene_check_amt,
        ppr.payment_response_json->'beneCheck'->>'beneHicNumber'         AS hic,
        ppr.payment_response_json->'beneCheck'->>'checkIssueDate'        AS bene_status_date,
        ppr.payment_response_json->'beneCheck'->>'checkStatusDate'       AS bene_last_updt_dt,
        (ppr.payment_response_json->'beneCheck'->>'claimInterestAmount')::numeric(9,2) AS bene_int_amt,
        (ppr.payment_response_json->'beneCheck'->>'claimRecoupmentAmount')::numeric(9,2) AS bene_offset,
        (ppr.payment_response_json->'beneCheck'->>'couldNotBeForwarded')::boolean AS bene_dnf_flg,
        ppr.payment_response_json->'beneCheck'->>'higlasClaimCheckNumber' AS bene_ext_eob,
        -- Provider check
        ppr.payment_response_json->'providerCheck'->>'checkNumber'       AS prov_exchk_num,
        ppr.payment_response_json->'providerCheck'->>'checkStatus'       AS prov_chk_status,
        (ppr.payment_response_json->'providerCheck'->>'claimAmount')::numeric(9,2) AS prov_check_amt,
        ppr.payment_response_json->'providerCheck'->>'checkStatusDate'   AS prov_last_updt_dt,
        ppr.payment_response_json->'providerCheck'->>'checkIssueDate'    AS prov_status_date,
        (ppr.payment_response_json->'providerCheck'->>'claimInterestAmount')::numeric(9,2) AS prov_int_amt,
        (ppr.payment_response_json->'providerCheck'->>'claimRecoupmentAmount')::numeric(9,2) AS prov_offset,
        (ppr.payment_response_json->'providerCheck'->>'couldNotBeForwarded')::boolean AS prov_dnf_flg,
        ppr.payment_response_json->'providerCheck'->>'higlasClaimCheckNumber' AS prov_ext_eob
    FROM professional_claim_payment_response ppr
),
-- 4. Build file sections
file_header AS (
    SELECT
        mp.mac_id,
        mp.phase_value AS phase,
        'FILE_HEADER' AS record_type,
        1 AS record_sequence,
        NULL::INTEGER AS claim_sequence,
        NULL::INTEGER AS line_sequence,
        (
            RPAD('MAP', 3)                        -- 1–3   System ID
         || RPAD('H', 1)                          -- 4     Record Type
         || RPAD(mp.phase_value, 2)               -- 5–6   Phase
         || LPAD(mp.mac_id::text, 5, '0')         -- 7–11  Workload ID
         || LPAD(mp.mac_id::text, 5, '0')         -- 12–16 MAC ID
         || TO_CHAR(ep.extract_date, 'YYYYMMDD')  -- 17–24 Extract Cycle Date
         || RPAD('D', 1)                          -- 25    File Type
         || RPAD('', 8)                           -- 26–33 Replacement Create Date
         || RPAD('20250106', 8)                   -- 34–41 Copybook Version
        ) AS record_content
    FROM (
        SELECT DISTINCT
            cp.mac_id,
            cp.phase_value
        FROM claim_phase cp
    ) mp
    CROSS JOIN extract_parameters ep
),
claim_header AS (
    SELECT
        pc.claim_jsonb->>'macId' AS mac_id,
        cp.phase_value AS phase,
        'CLAIM_HEADER' AS record_type,
        ROW_NUMBER() OVER (
            PARTITION BY pc.claim_jsonb->>'macId', cp.phase_value
            ORDER BY pc.id
        ) * 1000 + 1000 AS record_sequence,
        ROW_NUMBER() OVER (
            PARTITION BY pc.claim_jsonb->>'macId', cp.phase_value
            ORDER BY pc.id
        ) AS claim_sequence,
        NULL::INTEGER AS line_sequence,
        pc.claim_jsonb->>'internalControlNumber' AS icn,
        pc.id AS claim_id,
        (
            RPAD('B', 1, ' ') || -- 1-1: :P:IDR-CLM-HD-CONTR-TYPE
            RPAD('00', 2, ' ') || -- 2-3: :P:IDR-CLM-HD-REC-TYPE
            LPAD(
                COALESCE(
                    pc.claim_jsonb->>'planCode',
                    '0'
                ),
                2,
                '0'
            ) || -- 4-5: :P:IDR-CLM-HD-PLAN
            LPAD(
                COALESCE(
                    pc.claim_jsonb->>'internalControlNumber',
                    '0'
                ),
                13,
                '0'
            ) || -- 6-18: :P:IDR-CLM-HD-ICN-NBR
            RPAD(
                COALESCE(
                    pc.claim_jsonb->>'macId',
                    ''
                ),
                5,
                ' '
            ) || -- 19-23: :P:IDR-CONTR-ID
            LPAD(
                COALESCE(
                    jsonb_array_length(pc.claim_jsonb->'serviceLines')::text,
                    '0'
                ),
                2,
                '0'
            ) || -- 24-25: :P:IDR-DTL-CNT
            RPAD(
                COALESCE(ppr.payment_response_json->'beneCheck'->>'beneHicNumber', ''),
                12,
                ' '
            ) || -- 26-37: :P:IDR-HIC
            RPAD('', 1, ' ') || -- 38-38: :P:IDR-CLAIM-TYPE
            RPAD('', 1, ' ') || -- 39-39: :P:IDR-ASSIGNMENT
            RPAD(
                COALESCE(
                    pc.claim_jsonb->>'beneficiaryLastName',
                    ''
                ),
                6,
                ' '
            ) || -- 40-45: :P:IDR-BENE-LAST-1-6
            RPAD(
                COALESCE(
                    pc.claim_jsonb->>'beneficiaryFirstName',
                    ''
                ),
                1,
                ' '
            ) || -- 46-46: :P:IDR-BENE-FIRST-INIT
            RPAD('', 1, ' ') || -- 47-47: :P:IDR-BENE-MID-INIT
            RPAD(
                COALESCE(
                    pc.claim_jsonb->>'beneficiaryGender',
                    ''
                ),
                1,
                ' '
            ) || -- 48-48: :P:IDR-BENE-SEX
            RPAD('', 1, ' ') || -- 49-49: :P:IDR-STATUS-CODE
            LPAD(
                REPLACE(COALESCE(ppr.payment_response_json->'beneCheck'->>'checkIssueDate', '0'), '-', ''),
                8,
                '0'
            ) ||	-- 50-57: :P:IDR-STATUS-DATE
            LPAD('', 9, '0') ||	-- 58-66: :P:IDR-BENE-INCHK-NUM
            LPAD(
                COALESCE(ppr.payment_response_json->'beneCheck'->>'checkNumber', ''),
                9,
                '0'
            ) ||	-- 67-75: :P:IDR-BENE-EXCHK-NUM
            RPAD('', 2, ' ') ||	-- 76-77: :P:IDR-CAC-CODE
            RPAD(
                COALESCE(pc.claim_jsonb->>'billingProviderNpi', ''),
                10,
                ' '
            ) || -- 78-87: :P:IDR-BILL-PROV-NPI
            RPAD('', 10, ' ') || -- 88-97: :P:IDR-BILL-PROV-NUM
            RPAD(
                COALESCE(pc.claim_jsonb->>'billingProviderEin', ''),
                10,
                ' '
            ) || -- 98-107: :P:IDR-BILL-PROV-EI
            RPAD(
                COALESCE(pc.claim_jsonb->>'billingProviderTinType', ''),
                2,
                ' '
            ) || -- 108-109: :P:IDR-BILL-PROV-TYPE
            RPAD('', 2, ' ') || -- 110-111: :P:IDR-BILL-PROV-SPEC
            RPAD('', 1, ' ') || -- 112-112: :P:IDR-BILL-PROV-GROUP-IND
            RPAD('', 2, ' ') || -- 113-114: :P:IDR-BILL-PROV-PRICE-SPEC
            RPAD('', 2, ' ') || -- 115-116: :P:IDR-BILL-PROV-COUNTY
            RPAD('', 2, ' ') || -- 117-118: :P:IDR-BILL-PROV-LOC
                        RPAD(
                CASE
                    WHEN COALESCE(
                            pc.claim_jsonb->'diagnosisCodes'->>0
                        ) IS NULL THEN ' '
                    WHEN COALESCE(
                            pc.claim_jsonb->'diagnosisCodes'->>0
                        ) ~ '^[A-TV-Z]' THEN '0'   -- ICD-10
                    ELSE '9'                      -- ICD-9
                END,
                1,
                ' '
            ) || -- 119-119: :P:IDR-DIAG-ICD-TYPE
            RPAD(
                COALESCE(
                    pc.claim_jsonb->'diagnosisCodes'->>0,
                    ''
                ),
                7,
                ' '
            ) || -- 120-126: :P:IDR-DIAG-CODE
                        RPAD(
                CASE
                    WHEN COALESCE(
                            pc.claim_jsonb->'diagnosisCodes'->>0
                        ) IS NULL THEN ' '
                    WHEN LENGTH(COALESCE(pc.claim_jsonb->'diagnosisCodes'->>0, '')) >= 7 THEN '0'  -- ICD-10 (7 char)
                    ELSE '9'  -- ICD-9 (5-6 char)
                END,
                1,
                ' '
            ) || -- 127-127: :P:IDR-DIAG-ICD-TYPE
            RPAD(
                COALESCE(
                    pc.claim_jsonb->'diagnosisCodes'->>0,
                    ''
                ),
                7,
                ' '
            ) || -- 128-134: :P:IDR-DIAG-CODE
            RPAD('', 3, ' ') || -- 135-137: :P:IDR-HDR-EOMB-MSG
            LPAD('', 3, '0') || -- 138-140: :P:IDR-HDR-AUDIT
            RPAD('', 1, ' ') || -- 141-141: :P:IDR-HDR-AUDIT-IND
            RPAD('', 7, ' ') || -- 142-148: :P:IDR-BENE-PAID
            LPAD(
                COALESCE(
                    (ppr.payment_response_json->'beneCheck'->>'claimAmount')::numeric::text,
                    '0'
                ),
                7,
                '0'
            ) || -- 149-155: :P:IDR-BENE-CHECK-AMT
            LPAD(
                COALESCE(
                    (ppr.payment_response_json->'beneCheck'->>'claimRecoupmentAmount')::numeric::text,
                    '0'
                ),
                7,
                '0'
            ) || -- 156-162: :P:IDR-BENE-OFFSET
            RPAD('', 9, ' ') || -- 163-171: :P:IDR-PROV-INCHK-NUM
            RPAD(
                COALESCE(ppr.payment_response_json->'providerCheck'->>'checkStatus', ''),
                2,
                ' '
            ) || -- 172-178: :P:IDR-PROV-CHECK-AMT
            LPAD(
                COALESCE(
                    (ppr.payment_response_json->'providerCheck'->>'claimInterestAmount')::numeric::text,
                    '0'
                ),
                7,
                '0'
            ) || -- 179-185: :P:IDR-PROV-OFFSET
            LPAD(
                COALESCE(ppr.payment_response_json->'providerCheck'->>'checkNumber', ''),
                9,
                '0'
            ) || -- 186-194: :P:IDR-PROV-EXCHK-NUM
            RPAD('', 4, ' ') || -- 195-198: :P:IDR-CLERK
            RPAD(
                COALESCE(pc.claim_jsonb->>'totalAllowedAmount', ''),
                7,
                ' '
            ) || -- 199-205: :P:IDR-TOT-ALLOWED
            RPAD(
                COALESCE(pc.claim_jsonb->>'totalCoinsuranceAmount', ''),
                7,
                ' '
            ) || -- 206-212: :P:IDR-COINSURANCE
            RPAD(
                COALESCE(pc.claim_jsonb->>'appliedToDeductibleAmount', ''),
                7,
                ' '
            ) || -- 213-219: :P:IDR-DEDUCTIBLE
            RPAD('', 1, ' ') || -- 220-220: :P:IDR-BILL-PROV-STATUS-CD
            RPAD('', 1, ' ') || -- 221-221: Filler
            RPAD('', 1, ' ') || -- 222-222: :P:IDR-DOC-IND
            RPAD('', 1, ' ') || -- 223-223: :P:IDR-GROUP-IND
            RPAD('', 1, ' ') || -- 224-224: :P:IDR-EGHP-STATUS
            RPAD('', 9, ' ') || -- 225-233: :P:IDR-PAYER-ID
            RPAD('', 9, ' ') || -- 234-242: :P:IDR-PAYER-ID2
            RPAD('', 9, ' ') || -- 243-251: :P:IDR-PAYER-ID3
            RPAD('', 9, ' ') || -- 252-260: :P:IDR-PAYER-ID4
            RPAD('', 9, ' ') || -- 261-269: :P:IDR-PAYER-ID5
            LPAD(
                COALESCE(pc.claim_jsonb->>'totalBilledAmount', ''),
                7,
                ' '
            ) || -- 270-276: :P:IDR-TOT-BILLED-AMT
            LPAD(
                REPLACE(
                    COALESCE(pc.claim_jsonb->>'serviceStartDate', '0'),
                    '-',
                    ''
                ),
                8,
                '0'
            ) || -- 277-284: :P:IDR-HHDR-FROM-DOS (MMDDYYYY)
            LPAD(
                REPLACE(
                    COALESCE(pc.claim_jsonb->>'serviceEndDate', '0'),
                    '-',
                    ''
                ),
                8,
                '0'
            ) || -- 285-292: :P:IDR-HDR-TO-DOS (MMDDYYYY)
            RPAD('', 1, ' ') || -- 293-293: :P:IDR-MSP-REPROCESS
            LPAD(
                REPLACE(
                    COALESCE(pc.claim_jsonb->>'receiptDate', '0'),
                    '-',
                    ''
                ),
                8,
                '0'
            ) || -- 294-301: :P:IDR-CLAIM-RECEIPT-DATE (CCYYMMDD)
            RPAD('', 1, ' ') || -- 302-302: :P:IDR-CLM-LEVEL-IND
            RPAD(
                COALESCE(pc.claim_jsonb->>'providerTaxonomyCode', ''),
                50,
                ' '
            ) || -- 303-352: :P:IDR-HDR-PROV-TAXONOMY
            RPAD('', 50, ' ') || -- 353-402: :P:IDR-REND-PROV-TAXONOMY
            RPAD('', 2, ' ') || -- 403-404: :P:IDR-FPS-MODEL
            RPAD('', 3, ' ') || -- 405-407: :P:IDR-FPS-CARC
            RPAD('', 5, ' ') || -- 408-412: :P:IDR-FPS-RARC
            RPAD('', 5, ' ') || -- 413-417: :P:IDR-FPS-MSN-1
            RPAD('', 5, ' ') || -- 418-422: :P:IDR-FPS-MSN-2
            LPAD('', 8, '0') || -- 423-430: :P:IDR-HIST-RESTORE-DATE
            LPAD(cp.phase_value, 4, '0') || -- 431-434: :P:IDR-PHASE-SEQ-NUM
            RPAD('', 9, ' ') || -- 435-443: Filler
            RPAD('', 1, ' ') || -- 444-444: :P:IDR-ADDRESSEE-CODE
            LPAD('', 8, '0') || -- 445-452: :P:IDR-INITIAL-LTR-DATE
            RPAD('', 2, ' ') || -- 453-454: :P:IDR-ADS-DTL-NUM
            LPAD('', 3, '0') || -- 455-457: :P:IDR-ADS-MSG
            RPAD('', 2, ' ') || -- 458-459: :P:IDR-ADS-DTL-NUM
            LPAD('', 3, '0') || -- 460-462: :P:IDR-ADS-MSG
            RPAD('', 2, ' ') || -- 463-464: :P:IDR-ADS-DTL-NUM
            LPAD('', 3, '0') || -- 465-467: :P:IDR-ADS-MSG
            RPAD('', 2, ' ') || -- 468-469: :P:IDR-ADS-DTL-NUM
            LPAD('', 3, '0') || -- 470-472: :P:IDR-ADS-MSG
            RPAD('', 2, ' ') || -- 473-474: :P:IDR-ADS-DTL-NUM
            LPAD('', 3, '0') || -- 475-477: :P:IDR-ADS-MSG
            RPAD('', 2, ' ') || -- 478-479: :P:IDR-ADS-DTL-NUM
            LPAD('', 3, '0') || -- 480-482: :P:IDR-ADS-MSG
            RPAD('', 1, ' ') || -- 483-483: :P:IDR-ADDRESSEE-CODE
            LPAD('', 8, '0') || -- 484-491: :P:IDR-INITIAL-LTR-DATE
            RPAD('', 2, ' ') || -- 492-493: :P:IDR-ADS-DTL-NUM
            LPAD('', 3, '0') || -- 494-496: :P:IDR-ADS-MSG
            RPAD('', 2, ' ') || -- 497-498: :P:IDR-ADS-DTL-NUM
            LPAD('', 3, '0') || -- 499-501: :P:IDR-ADS-MSG
            RPAD('', 2, ' ') || -- 502-503: :P:IDR-ADS-DTL-NUM
            LPAD('', 3, '0') || -- 504-506: :P:IDR-ADS-MSG
            RPAD('', 2, ' ') || -- 507-508: :P:IDR-ADS-DTL-NUM
            LPAD('', 3, '0') || -- 509-511: :P:IDR-ADS-MSG
            RPAD('', 2, ' ') || -- 512-513: :P:IDR-ADS-DTL-NUM
            LPAD('', 3, '0') || -- 514-516: :P:IDR-ADS-MSG
            RPAD('', 2, ' ') || -- 517-518: :P:IDR-ADS-DTL-NUM
            LPAD('', 3, '0') || -- 519-521: :P:IDR-ADS-MSG
            RPAD('', 1, ' ') || -- 522-522: :P:IDR-ADDRESSEE-CODE
            LPAD('', 8, '0') || -- 523-530: :P:IDR-INITIAL-LTR-DATE
            RPAD('', 2, ' ') || -- 531-532: :P:IDR-ADS-DTL-NUM
            LPAD('', 3, '0') || -- 533-535: :P:IDR-ADS-MSG
            RPAD('', 2, ' ') || -- 536-537: :P:IDR-ADS-DTL-NUM
            LPAD('', 3, '0') || -- 538-540: :P:IDR-ADS-MSG
            RPAD('', 2, ' ') || -- 541-542: :P:IDR-ADS-DTL-NUM
            LPAD('', 3, '0') || -- 543-545: :P:IDR-ADS-MSG
            RPAD('', 2, ' ') || -- 546-547: :P:IDR-ADS-DTL-NUM
            LPAD('', 3, '0') || -- 548-550: :P:IDR-ADS-MSG
            RPAD('', 2, ' ') || -- 551-552: :P:IDR-ADS-DTL-NUM
            LPAD('', 3, '0') || -- 553-555: :P:IDR-ADS-MSG
            RPAD('', 2, ' ') || -- 556-557: :P:IDR-ADS-DTL-NUM
            LPAD('', 3, '0') || -- 558-560: :P:IDR-ADS-MSG
            RPAD('', 1, ' ') || -- 561-561: :P:IDR-ADDRESSEE-CODE
            LPAD('', 8, '0') || -- 562-569: :P:IDR-INITIAL-LTR-DATE
            RPAD('', 2, ' ') || -- 570-571: :P:IDR-ADS-DTL-NUM
            LPAD('', 3, '0') || -- 572-574: :P:IDR-ADS-MSG
            RPAD('', 2, ' ') || -- 575-576: :P:IDR-ADS-DTL-NUM
            LPAD('', 3, '0') || -- 577-579: :P:IDR-ADS-MSG
            RPAD('', 2, ' ') || -- 580-581: :P:IDR-ADS-DTL-NUM
            LPAD('', 3, '0') || -- 582-584: :P:IDR-ADS-MSG
            RPAD('', 2, ' ') || -- 585-586: :P:IDR-ADS-DTL-NUM
            LPAD('', 3, '0') || -- 587-589: :P:IDR-ADS-MSG
            RPAD('', 2, ' ') || -- 590-591: :P:IDR-ADS-DTL-NUM
            LPAD('', 3, '0') || -- 592-594: :P:IDR-ADS-MSG
            RPAD('', 2, ' ') || -- 595-596: :P:IDR-ADS-DTL-NUM
            LPAD('', 3, '0') || -- 597-599: :P:IDR-ADS-MSG
            RPAD('', 10, ' ') || -- 600-609: :P:IDR-EXT-PROV-NUM
            LPAD('', 11, '0') || -- 610-620: :P:IDR-ACN
            LPAD('', 11, '0') || -- 621-631: :P:IDR-ACN
            LPAD('', 11, '0') || -- 632-642: :P:IDR-ACN
            LPAD('', 11, '0') || -- 643-653: :P:IDR-ACN
            LPAD('', 11, '0') || -- 654-664: :P:IDR-SUP-ACN
            LPAD('', 11, '0') || -- 665-675: :P:IDR-SUP-ACN
            LPAD('', 11, '0') || -- 676-686: :P:IDR-SUP-ACN
            LPAD('', 11, '0') || -- 687-697: :P:IDR-SUP-ACN
            LPAD('', 8, '0') || -- 698-705: :P:IDR-HIC-CHG-DATE
            RPAD('', 4, ' ') || -- 706-709: :P:IDR-HIC-CHG-CLERK
            RPAD('', 12, ' ') || -- 710-721: :P:IDR-HIC-XREF-NUM
            RPAD('', 1, ' ') || -- 722-722: :P:IDR-HIC-CHG-IND
            RPAD('', 1, ' ') || -- 723-723: :P:IDR-HIC-CHG-HBACK
            LPAD(
                COALESCE((ppr.payment_response_json->'beneCheck'->>'claimInterestAmount')::numeric::text, '0'),
                7,
                '0'
            ) || -- 724-730: :P:IDR-BENE-INT-AMT
            LPAD(
                COALESCE((ppr.payment_response_json->'providerCheck'->>'claimInterestAmount')::numeric::text, '0'),
                7,
                '0'
            ) || -- 731-737: :P:IDR-PROV-INT-AMT
            LPAD(
                COALESCE((ppr.payment_response_json->>'interestRate')::numeric::text, '0'),
                5,
                '0'
            ) || -- 738-742: :P:IDR-INT-RATE
            LPAD(
                COALESCE((ppr.payment_response_json->>'interestDaysOver')::int::text, '0'),
                3,
                '0'
            ) || -- 743-745: :P:IDR-CPT-DAYS
            RPAD('', 1, ' ') || -- 746-746: :P:IDR-CLEAN-DIRTY-IND
            RPAD('', 1, ' ') || -- 747-747: :P:IDR-PAR-PROV-IND
            RPAD('', 1, ' ') || -- 748-748: :P: IDR-CPT-SUPPRESS-CHK
            LPAD('', 3, '0') || -- 749-751: :P:IDR-J-AUDIT-NUM
            RPAD('', 1, ' ') || -- 752-752: :P:IDR-J-AUDIT-IND
            RPAD('', 1, ' ') || -- 753-753: :P:IDR-J-AUDIT-DISP
            LPAD('', 3, '0') || -- 754-756: :P:IDR-J-AUDIT-NUM
            RPAD('', 1, ' ') || -- 757-757: :P:IDR-J-AUDIT-IND
            RPAD('', 1, ' ') || -- 758-758: :P:IDR-J-AUDIT-DISP
            LPAD('', 3, '0') || -- 759-761: :P:IDR-J-AUDIT-NUM
            RPAD('', 1, ' ') || -- 762-762: :P:IDR-J-AUDIT-IND
            RPAD('', 1, ' ') || -- 763-763: :P:IDR-J-AUDIT-DISP
            LPAD('', 3, '0') || -- 764-766: :P:IDR-J-AUDIT-NUM
            RPAD('', 1, ' ') || -- 767-767: :P:IDR-J-AUDIT-IND
            RPAD('', 1, ' ') || -- 768-768: :P:IDR-J-AUDIT-DISP
            LPAD('', 3, '0') || -- 769-771: :P:IDR-J-AUDIT-NUM
            RPAD('', 1, ' ') || -- 772-772: :P:IDR-J-AUDIT-IND
            RPAD('', 1, ' ') || -- 773-773: :P:IDR-J-AUDIT-DISP
            LPAD('', 3, '0') || -- 774-776: :P:IDR-J-AUDIT-NUM
            RPAD('', 1, ' ') || -- 777-777: :P:IDR-J-AUDIT-IND
            RPAD('', 1, ' ') || -- 778-778: :P:IDR-J-AUDIT-DISP
            LPAD('', 3, '0') || -- 779-781: :P:IDR-J-AUDIT-NUM
            RPAD('', 1, ' ') || -- 782-782: :P:IDR-J-AUDIT-IND
            RPAD('', 1, ' ') || -- 783-783: :P:IDR-J-AUDIT-DISP
            LPAD('', 3, '0') || -- 784-786: :P:IDR-J-AUDIT-NUM
            RPAD('', 1, ' ') || -- 787-787: :P:IDR-J-AUDIT-IND
            RPAD('', 1, ' ') || -- 788-788: :P:IDR-J-AUDIT-DISP
            LPAD('', 3, '0') || -- 789-791: :P:IDR-J-AUDIT-NUM
            RPAD('', 1, ' ') || -- 792-792: :P:IDR-J-AUDIT-IND
            RPAD('', 1, ' ') || -- 793-793: :P:IDR-J-AUDIT-DISP
            LPAD('', 3, '0') || -- 794-796: :P:IDR-J-AUDIT-NUM
            RPAD('', 1, ' ') || -- 797-797: :P:IDR-J-AUDIT-IND
            RPAD('', 1, ' ') || -- 798-798: :P:IDR-J-AUDIT-DISP
            LPAD('', 3, '0') || -- 799-801: :P:IDR-J-AUDIT-NUM
            RPAD('', 1, ' ') || -- 802-802: :P:IDR-J-AUDIT-IND
            RPAD('', 1, ' ') || -- 803-803: :P:IDR-J-AUDIT-DISP
            LPAD('', 3, '0') || -- 804-806: :P:IDR-J-AUDIT-NUM
            RPAD('', 1, ' ') || -- 807-807: :P:IDR-J-AUDIT-IND
            RPAD('', 1, ' ') || -- 808-808: :P:IDR-J-AUDIT-DISP
            LPAD('', 5, '0') || -- 809-813: :P:IDR-SPLIT-PAY-SUPP
            RPAD('', 9, ' ') || -- 814-822: :P:IDR-J-BPROV-TIN
            RPAD('', 1, ' ') || -- 823-823: :P:IDR-J-BPROV-TIN-IND
            RPAD('', 10, ' ') || -- 824-833: :P:IDR-J-CPO-NPI
            RPAD(
                COALESCE(pc.claim_jsonb->>'referringProviderNpi', ''),
                10,
                ' '
            ) || -- 834-843: :P:IDR-J-REFERRING-PROV-NPI
            RPAD('', 10, ' ') || -- 844-853: :P:IDR-J-FAC-PROV-NPI
            RPAD('', 10, ' ') || -- 854-863: :P:IDR-J-FAC-PROV-NUM
            RPAD('', 2, ' ') || -- 864-865: :P:IDR-J-FAC-PROV-LOCALITY
            RPAD('', 2, ' ') || -- 866-867: :P:IDR-J-FAC-PROV-TYPE
            RPAD('', 2, ' ') || -- 868-869: :P:IDR-J-FAC-PROV-SPEC
            RPAD('', 1, ' ') || -- 870-870: :P:IDR-J-FAC-PROV-STATUS
            RPAD('', 2, ' ') || -- 871-872: :P:IDR-J-FAC-PROV-PRSP
            RPAD('', 2, ' ') || -- 873-874: :P:IDR-J-FAC-PROV-CNTY
            RPAD('', 1, ' ') || -- 875: :P:IDR-J-OVER-DENY-TO-SUSP
            RPAD('', 1, ' ') || -- 876: :P:IDR-J-OVER-LISTED-AUDIT
            RPAD('', 1, ' ') || -- 877: :P:IDR-J-OVER-DUP-EDITS
            RPAD('', 1, ' ') || -- 878: :P:IDR-J-OVER-MEDPOL-LIMIT
            LPAD('', 3, '0') || -- 879-881: :P:IDR-J-MPA-OVR-AUDIT
            RPAD('', 1, ' ') || -- 882-882: :P:IDR-J-MPA-OVR-IND
            LPAD('', 7, '0') || -- 883-889: :P:IDR-J-REM-PROV-PAY
            RPAD('', 3, ' ') || -- 890-892: :P:IDR-J-EOMB-NUM
            RPAD('', 3, ' ') || -- 893-895: :P:IDR-J-EOMB-NUM
            RPAD('', 3, ' ') || -- 896-898: :P:IDR-J-EOMB-NUM
            RPAD('', 3, ' ') || -- 899-901: :P:IDR-J-EOMB-NUM
            RPAD('', 10, ' ') || -- 902-911: :P:IDR--J-REFERRING-PROV-UPIN
            RPAD('', 15, ' ') || -- 912-926: :P:IDR-J-COMP-NUM
            RPAD('', 10, ' ') || -- 927-936: :P:IDR-J-CLIA-NUM
            RPAD('', 1, ' ') || -- 937-937: :P:IDR-J-BILL-PROV-FLAG
            RPAD('', 1, ' ') || -- 938-938: :P:IDR-J-FAC-PROV-FLAG
            RPAD('', 2, ' ') || -- 939-940: Filler
            RPAD('', 14, ' ') || -- 941-954: :P:IDR-J-PEER-REV-ORG
            RPAD('', 15, ' ') || -- 955-969: :P:IDR-J-MED-COMP-NUM
            RPAD('', 5, ' ') || -- 970-974: :P:IDR-J-MED-INS-NUM
            RPAD('', 1, ' ') || -- 975-975: :P:IDR-J-MED-SIGNATURE
            RPAD('', 8, ' ') || -- 976-983: :P:IDR-J-DIAG-3-12 :P:IDR-J-DIAG-ICD-TYPE (1) :P:IDR-J-DIAG-CODE (7)
            RPAD('', 8, ' ') || -- 984-991: :P:IDR-J-DIAG-3-12 :P:IDR-J-DIAG-ICD-TYPE (1) :P:IDR-J-DIAG-CODE (7)
            RPAD('', 8, ' ') || -- 992-999: :P:IDR-J-DIAG-3-12 :P:IDR-J-DIAG-ICD-TYPE (1) :P:IDR-J-DIAG-CODE (7)
            RPAD('', 8, ' ') || -- 1000-1007: :P:IDR-J-DIAG-3-12 :P:IDR-J-DIAG-ICD-TYPE :P:IDR-J-DIAG-CODE
            RPAD('', 8, ' ') || -- 1008-1015: :P:IDR-J-DIAG-3-12 :P:IDR-J-DIAG-ICD-TYPE :P:IDR-J-DIAG-CODE
            RPAD('', 8, ' ') || -- 1016-1023: :P:IDR-J-DIAG-3-12 :P:IDR-J-DIAG-ICD-TYPE :P:IDR-J-DIAG-CODE
            RPAD('', 8, ' ') || -- 1024-1031: :P:IDR-J-DIAG-3-12 :P:IDR-J-DIAG-ICD-TYPE :P:IDR-J-DIAG-CODE
            RPAD('', 8, ' ') || -- 1032-1039: :P:IDR-J-DIAG-3-12 :P:IDR-J-DIAG-ICD-TYPE :P:IDR-J-DIAG-CODE
            RPAD('', 8, ' ') || -- 1040-1047: :P:IDR-J-DIAG-3-12 :P:IDR-J-DIAG-ICD-TYPE :P:IDR-J-DIAG-CODE
            RPAD('', 8, ' ') || -- 1048-1055: :P:IDR-J-DIAG-3-12 :P:IDR-J-DIAG-ICD-TYPE :P:IDR-J-DIAG-CODE
            RPAD('', 1, ' ') || -- 1056-1056: :P:IDR-J-SUPR-IND
            RPAD('', 1, ' ') || -- 1057-1057: :P: J-MASS-ADJ-TYPE
            RPAD('', 1, ' ') || -- 1058-1058: :P:IDR-J-XOVR-CLAIM-TYPE
            RPAD('', 1, ' ') || -- 1059-1059: :P:IDR-J-CWF-PROV-SAN-IND
            RPAD('', 8, ' ') || -- 1060-1067: :P:IDR-J-CLIN-TRIAL-NBR
            RPAD('', 2, ' ') || -- 1068-1069: :P:IDR-J-935-ADJ-IND
            RPAD('', 1, ' ') || -- 1070-1070: :P:IDR-J-CLM-MSP-ACTION-CODE
            RPAD('', 5, ' ') || -- 1071-1075: :P:IDR-J-ORDERING-PROV-NAME
            RPAD(
                COALESCE(pc.claim_jsonb->>'billingProviderPtan', ''),
                10,
                ' '
            ) || -- 1076-1085: :P:IDR-J-ORDERING-PROV-NUMB
            LPAD('', 8, '0') || -- 1086-1093: :P:IDR-J-APPEAL-DATE
            LPAD('', 8, '0') || -- 1094-1101: :P:IDR-J-XICN-RECEIPT-DATE
            RPAD('', 2, ' ') || -- 1102-1103: :P:IDR-J-PWK-COUNT
            RPAD('', 2, ' ') || -- 1104-1105: :P:IDR-J-DEMO2
            RPAD('', 2, ' ') || -- 1106-1107: :P:IDR-J-DEMO3
            RPAD('', 2, ' ') || -- 1108-1109: :P:IDR-J-DEMO4
            RPAD('', 7, ' ') || -- 1110-1116: :P:IDR-J-IDE-NUM
            RPAD('', 1, ' ') || -- 1117-1117: :P:IDR-J-FILLER
            RPAD('', 4, ' ') || -- 1118-1121: :P:IDR-LOC-CLERK
            RPAD('', 3, ' ') || -- 1122-1124: :P:IDR-LOC-CODE
            LPAD('', 8, '0') || -- 1125-1132: :P:IDR-LOC-DATE
            RPAD('', 1, ' ') || -- 1133-1133: :P:IDR-LOC-ACTV-CODE
            RPAD('', 4, ' ') || -- 1134-1137: :P:IDR-LOC-CLERK
            RPAD('', 3, ' ') || -- 1138-1140: :P:IDR-LOC-CODE
            LPAD('', 8, '0') || -- 1141-1148: :P:IDR-LOC-DATE
            RPAD('', 1, ' ') || -- 1149-1149: :P:IDR-LLOC-ACTV-CODE
            RPAD('', 4, ' ') || -- 1150-1153: :P:IDR-LOC-CLERK
            RPAD('', 3, ' ') || -- 1154-1156: :P:IDR-LOC-CODE
            LPAD('', 8, '0') || -- 1157-1164: :P:IDR-LOC-DATE
            RPAD('', 1, ' ') || -- 1165-1165: :P:IDR-LOC-ACTV-CODE
            RPAD('', 4, ' ') || -- 1166-1169: :P:IDR-LOC-CLERK
            RPAD('', 3, ' ') || -- 1170-1172: :P:IDR-LOC-CODE
            LPAD('', 8, '0') || -- 1173-1180: :P:IDR-LOC-DATE
            RPAD('', 1, ' ') || -- 1181-1181: :P:IDR-LOC-ACTV-CODE
            RPAD('', 4, ' ') || -- 1182-1185: :P:IDR-LOC-CLERK
            RPAD('', 3, ' ') || -- 1186-1188: :P:IDR-LOC-CODE
            LPAD('', 8, '0') || -- 1189-1196: :P:IDR-LOC-DATE
            RPAD('', 1, ' ') || -- 1197-1197: :P:IDR-LOC-ACTV-CODE
            RPAD('', 4, ' ') || -- 1198-1201: :P:IDR-LOC-CLERK
            RPAD('', 3, ' ') || -- 1202-1204: :P:IDR-LOC-CODE
            LPAD('', 8, '0') || -- 1205-1212: :P:IDR-LOC-DATE
            RPAD('', 1, ' ') || -- 1213-1213: :P:IDR-LOC-ACTV-CODE
            RPAD('', 4, ' ') || -- 1214-1217: :P:IDR-LOC-CLERK
            RPAD('', 3, ' ') || -- 1218-1220: :P:IDR-LOC-CODE
            LPAD('', 8, '0') || -- 1221-1228: :P:IDR-LOC-DATE
            RPAD('', 1, ' ') || -- 1229-1229: :P:IDR-LOC-ACTV-CODE
            RPAD('', 4, ' ') || -- 1230-1233: :P:IDR-LOC-CLERK
            RPAD('', 3, ' ') || -- 1234-1236: :P:IDR-LOC-CODE
            LPAD('', 8, '0') || -- 1237-1244: :P:IDR-LOC-DATE
            RPAD('', 1, ' ') || -- 1245-1245: :P:IDR-LOC-ACTV-CODE
            RPAD('', 4, ' ') || -- 1246-1249: :P:IDR-LOC-CLERK
            RPAD('', 3, ' ') || -- 1250-1252: :P:IDR-LOC-CODE
            LPAD('', 8, '0') || -- 1253-1260: :P:IDR-LOC-DATE
            RPAD('', 1, ' ') || -- 1261-1261: :P:IDR-LOC-ACTV-CODE
            RPAD('', 4, ' ') || -- 1262-1265: :P:IDR-LOC-CLERK
            RPAD('', 3, ' ') || -- 1266-1268: :P:IDR-LOC-CODE
            LPAD('', 8, '0') || -- 1269-1276: :P:IDR-LOC-DATE
            RPAD('', 1, ' ') || -- 1277-1277: :P:IDR-LOC-ACTV-CODE
            RPAD('', 4, ' ') || -- 1278-1281: :P:IDR-LOC-CLERK
            RPAD('', 3, ' ') || -- 1282-1284: :P:IDR-LOC-CODE
            LPAD('', 8, '0') || -- 1285-1292: :P:IDR-LOC-DATE
            RPAD('', 1, ' ') || -- 1293-1293: :P:IDR-LOC-ACTV-CODE
            RPAD('', 3, ' ') || -- 1294-1296: :P:IDR-N-MSP-TYPE-GROUP
            RPAD('', 7, ' ') || -- 1297-1303: :P:IDR-N-MSP-ALLOWED
            LPAD('', 7, '0') || -- 1304-1310: :P:IDR-N-MSP-PAID
            RPAD('', 1, ' ') || -- 1311-1311: :P:IDR-N-MSP-PAY-LVL
            RPAD('', 1, ' ') || -- 1312-1312: :P:IDR-P-REP-PAYEE-TYPE
            RPAD('', 22, ' ') || -- 1313-1334: :P:IDR-P-REP-PAYEE-NAME
            LPAD('', 8, '0') || -- 1335-1342: :P:IDR-CWF-QUERY-DATE
            RPAD('', 1, ' ') || -- 1343-1343: :P:IDR-CWF-QUERY-CODE
            LPAD('', 8, '0') || -- 1344-1351: :P:IDR-CWF-QUERY-DATE
            RPAD('', 1, ' ') || -- 1352-1352: :P:IDR-CWF-QUERY-CODE
            LPAD('', 8, '0') || -- 1353-1360: :P:IDR-CWF-QUERY-DATE
            RPAD('', 1, ' ') || -- 1361-1361: :P:IDR-CWF-QUERY-CODE
            LPAD('', 8, '0') || -- 1362-1369: :P:IDR-CWF-QUERY-DATE
            RPAD('', 1, ' ') || -- 1370-1370: :P:IDR-CWF-QUERY-CODE
            LPAD('', 8, '0') || -- 1371-1378: :P:IDR-CWF-RESPONSE-DATE
            RPAD('', 2, ' ') || -- 1379-1380: :P:IDR-CWF-RESPONSE-CODE
            RPAD('', 2, ' ') || -- 1381-1382: :P:IDR-CWF-RESP-TRL-CODE
            LPAD('', 1, '0') || -- 1383-1383: :P:IDR-BLOOD-DED-REMAIN
            LPAD(
                COALESCE(
                    pc.claim_jsonb->>'regularDeductibleAmountMet',
                    '0'
                ),
                5,
                '0'
            ) || -- 1384-1388: :P:IDR-REG-DED-REMAIN
            LPAD('', 7, '0') || -- 1389-1395: :P:IDR-PSYCH-BAL-REMAIN
            LPAD('', 7, '0') || -- 1396-1402: :P:IDR-PHY-OCC-THER-REM
            RPAD('', 1, ' ') || -- 1403-1403: :P:IDR-PHY-OCC-THER-IND
            LPAD('', 5, '0') || -- 1404-1408: :P:IDR-CASH-DED-APPLIED
            RPAD('', 4, ' ') || -- 1409-1412: :P:IDR-CWF-RESP-ERR-CD1
            RPAD('', 4, ' ') || -- 1413-1416: :P:IDR-CWF-RESP-ERR-CD2
            RPAD('', 4, ' ') || -- 1417-1420: :P:IDR-CWF-RESP-ERR-CD3
            RPAD('', 4, ' ') || -- 1421-1424: :P:IDR-CWF-RESP-ERR-CD4
            LPAD('', 8, '0') || -- 1425-1432: :P:IDR-CWF-RESPONSE-DATE
            RPAD('', 2, ' ') || -- 1433-1434: :P:IDR-CWF-RESPONSE-CODE
            RPAD('', 2, ' ') || -- 1435-1436: :P:IDR-CWF-RESP-TRL-CODE
            LPAD('', 1, '0') || -- 1437-1437: :P:IDR-BLOOD-DED-REMAIN
            LPAD('', 5, '0') || -- 1438-1442: :P:IDR-REG-DED-REMAIN
            LPAD('', 7, '0') || -- 1443-1449: :P:IDR-PSYCH-BAL-REMAIN
            LPAD('', 7, '0') || -- 1450-1456: :P:IDR-PHY-OCC-THER-REM
            RPAD('', 1, ' ') || -- 1457-1457: :P:IDR-PHY-OCC-THER-IND
            LPAD('', 5, '0') || -- 1458-1462: :P:IDR-CASH-DED-APPLIED
            RPAD('', 4, ' ') || -- 1463-1466: :P:IDR--CWF-RESP-ERR-CD1
            RPAD('', 4, ' ') || -- 1467-1470: :P:IDR-CWF-RESP-ERR-CD2
            RPAD('', 4, ' ') || -- 1471-1474: :P:IDR-CWF-RESP-ERR-CD3
            RPAD('', 4, ' ') || -- 1475-1478: :P:IDR-CWF-RESP-ERR-CD4
            LPAD('', 8, '0') || -- 1479-1486: :P:IDR-CWF-RESPONSE-DATE
            RPAD('', 2, ' ') || -- 1487-1488: :P:IDR-CWF-RESPONSE-CODE
            RPAD('', 2, ' ') || -- 1489-1490: :P:IDR-CWF-RESP-TRL-CODE
            LPAD('', 1, '0') || -- 1491-1491: :P:IDR-BLOOD-DED-REMAIN
            LPAD('', 5, '0') || -- 1492-1496: :P:IDR-REG-DED-REMAIN
            LPAD('', 7, '0') || -- 1497-1503: :P:IDR-PSYCH-BAL-REMAIN
            LPAD('', 7, '0') || -- 1504-1510: :P:IDR-PHY-OCC-THER-REM
            RPAD('', 1, ' ') || -- 1511-1511: :P:IDR-PHY-OCC-THER-IND
            LPAD('', 5, '0') || -- 1512-1516: :P:IDR-CASH-DED-APPLIED
            RPAD('', 4, ' ') || -- 1517-1520: :P:IDR-CWF-RESP-ERR-CD1
            RPAD('', 4, ' ') || -- 1521-1524: :P:IDR-CWF-RESP-ERR-CD2
            RPAD('', 4, ' ') || -- 1525-1528: :P:IDR-CWF-RESP-ERR-CD3
            RPAD('', 4, ' ') || -- 1529-1532: :P:IDR-CWF-RESP-ERR-CD4
            LPAD('', 8, '0') || -- 1533-1540: :P:IDR-CWF-RESPONSE-DATE
            RPAD('', 2, ' ') || -- 1541-1542: :P:IDR-CWF-RESPONSE-CODE
            RPAD('', 2, ' ') || -- 1543-1544: :P:IDR-CWF-RESP-TRL-CODE
            LPAD('', 1, '0') || -- 1545-1545: :P:IDR-BLOOD-DED-REMAIN
            LPAD('', 5, '0') || -- 1546-1550: :P:IDR-REG-DED-REMAIN
            LPAD('', 7, '0') || -- 1551-1557: :P:IDR-PSYCH-BAL-REMAIN
            LPAD('', 7, '0') || -- 1558-1564: :P:IDR-PHY-OCC-THER-REM
            RPAD('', 1, ' ') || -- 1565-1565: :P:IDR-PHY-OCC-THER-IND
            LPAD('', 5, '0') || -- 1566-1570: :P:IDR-CASH-DED-APPLIED
            RPAD('', 4, ' ') || -- 1571-1574: :P:IDR-CWF-RESP-ERR-CD1
            RPAD('', 4, ' ') || -- 1575-1578: :P:IDR-CWF-RESP-ERR-CD2
            RPAD('', 4, ' ') || -- 1579-1582: :P:IDR-CWF-RESP-ERR-CD3
            RPAD('', 4, ' ') || -- 1583-1586: :P:IDR-CWF-RESP-ERR-CD4
            RPAD(
                COALESCE(ppr.payment_response_json->'beneCheck'->>'checkStatus', ''),
                2,
                ' '
            ) || -- 1587-1588: :P:IDR-CURR-BENE-CHK-STAT
            RPAD(
                COALESCE(ppr.payment_response_json->'providerCheck'->>'checkStatus', ''),
                2,
                ' '
            ) || -- 1589-1590: :P:IDR-CURR-PROV-CHK-STAT
            LPAD(
                REPLACE(
                    COALESCE(ppr.payment_response_json->'beneCheck'->>'checkIssueDate', '0'),
                    '-',
                    ''
                ),
                8,
                '0'
            ) || -- 1591-1598: :P:IDR-LAST-BENE-UPDT-DT
            LPAD(
                REPLACE(
                    COALESCE(ppr.payment_response_json->'providerCheck'->>'checkStatusDate', '0'),
                    '-',
                    ''
                ),
                8,
                '0'
            ) || -- 1599-1606: :P:IDR-LAST-PROV-UPDT-DT
            RPAD('', 3, ' ') || -- 1607-1609: :P:IDR-U-MED-ADVISOR
            LPAD('', 8, '0') || -- 1610-1617: :P:IDR-U-MICRO-INDEX
            RPAD('', 1, ' ') || -- 1618-1618: :P:IDR-U-CLM-ADJ-ACT-CD
            LPAD('', 11, '0') || -- 1619-1629: :P:IDR-U-BENE-RESP-AMT
            RPAD('', 1, ' ') || -- 1630-1630: FILLER
            RPAD('', 6, ' ') || -- 1631-1636: :P:IDR-U-XOVER-COMP-NAME
            RPAD('', 1, ' ') || -- 1637-1637: :P:IDR-U-SPLIT-REASON
            LPAD('', 8, '0') || -- 1638-1645: :P:IDR-U-MSN-NOTICE-DT
            RPAD('', 4, ' ') || -- 1646-1649: :P:IDR-U-GDX-RULE-NUM
            LPAD('', 8, '0') || -- 1650-1657: :P:IDR-U-GDX-RULE-DATE
            RPAD('', 4, ' ') || -- 1658-1661: :P:IDR-U-GDX-RULE-NUM
            LPAD('', 8, '0') || -- 1662-1669: :P:IDR-U-GDX-RULE-DATE
            RPAD('', 4, ' ') || -- 1670-1673: :P:IDR-U-GDX-RULE-NUM
            LPAD('', 8, '0') || -- 1674-1681: :P:IDR-U-GDX-RULE-DATE
            RPAD('', 4, ' ') || -- 1682-1685: :P:IDR-U-GDX-RULE-NUM
            LPAD('', 8, '0') || -- 1686-1693: :P:IDR-U-GDX-RULE-DATE
            RPAD('', 4, ' ') || -- 1694-1697: :P:IDR-U-GDX-RULE-NUM
            LPAD('', 8, '0') || -- 1698-1705: :P:IDR-U-GDX-RULE-DATE
            RPAD('', 4, ' ') || -- 1706-1709: :P:IDR-U-GDX-RULE-NUM
            LPAD('', 8, '0') || -- 1710-1717: :P:IDR-U-GDX-RULE-DATE
            LPAD('', 7, '0') || -- 1718-1724: :P:IDR-U-OTAF-AMT
            RPAD('', 1, ' ') || -- 1725-1725: :P:IDR-U-MSP-MASS-ADJ-FLAG
            RPAD('', 6, ' ') || -- 1726-1731: :P:IDR-U-XOVER-COMP-ID-2
            RPAD('', 6, ' ') || -- 1732-1737: :P:IDR-U-XOVER-COMP-ID-3
            RPAD('', 6, ' ') || -- 1738-1743: :P:IDR-U-XOVER-COMP-ID-4
            RPAD('', 6, ' ') || -- 1744-1749: :P:IDR-U-XOVER-COMP-ID-5
            RPAD('', 1, ' ') || -- 1750-1750: :P:IDR-U-PHYSICIAN-SIGN-FLG
            RPAD('', 1, ' ') || -- 1751-1751: :P:IDR-U-BENE-SIGN-FLG
            LPAD('', 8, '0') || -- 1752-1759: :P:IDR-U-CHIRO-XRAY-DATE
            LPAD('', 8, '0') || -- 1760-1767: :P:IDR-U-CHIRO-INIT-TREAT
            RPAD('', 6, ' ') || -- 1768-1773: :P:IDR-U-UPIN
            RPAD('', 1, ' ') || -- 1774-1774: :P:IDR-U-NAME-SUBMISSION
            RPAD('', 1, ' ') || -- 1775-1775: :P:IDR-U-PURCH-DIAG-FLG
            RPAD('', 1, ' ') || -- 1776-1776: :P:IDR-U-HOME-EKG-TRACE-FLG
            RPAD('', 1, ' ') || -- 1777-1777: :P:IDR-U-FAC-PROV-IND
            LPAD('', 8, '0') || -- 1778-1785: :P:IDR-U-BENE-CHK-DATE
            LPAD('', 8, '0') || -- 1786-1793: :P:IDR-U-PROV-CHK-DATE
            RPAD(
                COALESCE(pc.claim_jsonb->>'submitterId', ''),
                10,
                ' '
            ) || -- 1794-1803: :P:EMC-U-SUBMITTER-ID
            RPAD('', 4, ' ') || -- 1804-1807: :P:IDR-U-CARRIER-APPL-CODE
            RPAD('', 9, ' ') || -- 1808-1816: :P:IDR-U-CHOICES-PLAN
            RPAD('', 2, ' ') || -- 1817-1818: :P:IDR-U-DEMO-NUMBER
            RPAD('', 10, ' ') || -- 1819-1828: :P:IDR-U-DEMO-PROV-NPI
            RPAD('', 10, ' ') || -- 1829-1838: :P:IDR-U-DEMO-PROVIDER
            RPAD('', 10, ' ') || -- 1839-1848: :P:IDR-U-SUPER-NPI
            RPAD(
                COALESCE(pc.claim_jsonb->>'internalControlNumber', ''),
                15,
                ' '
            ) || -- 1849-1863: :P:IDR-U-OLD-CWF-ICN
            RPAD(
                COALESCE(pc.claim_jsonb->>'patientControlNumber', ''),
                15,
                ' '
            ) || -- 1864-1878: :P:IDR-U-PATIENT-ACCT-N-OLD
            RPAD('', 17, ' ') || -- 1879-1895: :P:IDR-U-PATIENT-ACCT-N
            RPAD('', 1, ' ') || -- 1896-1896: :P:IDR-U-BENE-NAME-CORR-FLG
            RPAD('', 12, ' ') || -- 1897-1908: :P:IDR-U-FCADJ-PREV-HIC
            RPAD('', 10, ' ') || -- 1909-1918: :P:IDR-U-FCADJ-BIL-NPI
            RPAD('', 10, ' ') || -- 1919-1928: :P:IDR-U-FCADJ-BIL-PROV
            RPAD('', 1, ' ') || -- 1929-1929: :P:IDR-U-FCADJ-PREV-ASSGN
            LPAD('', 7, '0') || -- 1930-1936: :P:IDR-U-FCADJ-PROV-INT
            LPAD('', 7, '0') || -- 1937-1943: :P:IDR-U-FCADJ-BENE-INT
            LPAD('', 8, '0') || -- 1944-1951: :P:IDR-U-ORIG-RECEIPT-DATE
            RPAD('', 3, ' ') || -- 1952-1954: :P:IDR-U-DELETE-RSN-CODE
            LPAD('', 13, '0') || -- 1955-1967: :P:IDR-U-CASE-TRACK-CCN
            RPAD(
            CASE
                WHEN (ppr.payment_response_json->'beneCheck'->>'couldNotBeForwarded')::boolean THEN 'Y'
                ELSE 'N'
            END,
            1,
            ' '
            ) || -- 1968-1968: :P:IDR-U-BENE-DNF-FLG
            RPAD(
            CASE
                WHEN (ppr.payment_response_json->'providerCheck'->>'couldNotBeForwarded')::boolean THEN 'Y'
                ELSE 'N'
            END,
            1,
            ' '
            ) || -- 1969-1969: :P:IDR-U-PROV-DNF-FLG
            RPAD('', 1, ' ') || -- 1970-1970: FILLER
            RPAD('', 8, ' ') || -- 1971-1978: :P:IDR-U-HPSA-RPT-DT-CYMD
            RPAD('', 4, ' ') || -- 1979-1982: :P:IDR-U-CWF-ERR-CD
            RPAD('', 1, ' ') || -- 1983-1983: :P:IDR-U-CWF-OVRD-CD
            RPAD('', 1, ' ') || -- 1984-1984: :P:IDR-U-CWF-SRC-IND(1)
            RPAD('', 4, ' ') || -- 1985-1988: :P:IDR-U-CWF-ERR-CD
            RPAD('', 1, ' ') || -- 1989-1989: :P:IDR-U-CWF-OVRD-CD
            RPAD('', 1, ' ') || -- 1990-1990: :P:IDR-U-CWF-SRC-IND(2)
            RPAD('', 4, ' ') || -- 1991-1994: :P:IDR-U-CWF-ERR-CD
            RPAD('', 1, ' ') || -- 1995-1995: :P:IDR-U-CWF-OVRD-CD
            RPAD('', 1, ' ') || -- 1996-1996: :P:IDR-U-CWF-SRC-IND(3)
            RPAD('', 4, ' ') || -- 1997-2000: :P:IDR-U-CWF-ERR-CD
            RPAD('', 1, ' ') || -- 2001-2001: :P:IDR-U-CWF-OVRD-CD
            RPAD('', 1, ' ') || -- 2002-2002: :P:IDR-U-CWF-SRC-IND(4)
            RPAD('', 4, ' ') || -- 2003-2006: :P:IDR-U-CWF-ERR-CD
            RPAD('', 1, ' ') || -- 2007-2007: :P:IDR-U-CWF-OVRD-CD
            RPAD('', 1, ' ') || -- 2008-2008: :P:IDR-U-CWF-SRC-IND(5)
            RPAD('', 2, ' ') || -- 2009-2010: :P:IDR-U-BILL-PROV-STATE
            RPAD('', 9, ' ') || -- 2011-2019: :P:IDR-U-BILL-PROV-ZIP
            RPAD('', 2, ' ') || -- 2020-2021: :P:IDR-U-UNSOL-RESP-TYPE
            RPAD('', 3, ' ') || -- 2022-2024: :P:IDR-U-REPORT-CODE
            RPAD('', 1, ' ') || -- 2025-2025: :P:IDR-U-HIGLAS-REPORT-IND
            LPAD('', 8, '0') || -- 2026-2033: :P:IDR-U-LAST-SEEN-DATE
            RPAD('', 2, ' ') || -- 2034-2035: :P:IDR-U-OVERPAY-REASON
            RPAD('', 2, ' ') || -- 2036-2037: :P:IDR-U-DISCOV-REASON
            RPAD('', 1, ' ') || -- 2038-2038: :P:IDR-HDR-RES-PAY-IND
            RPAD('', 12, ' ') || -- 2039-2050: :P:IDR-U-SUB-BID
            LPAD('', 11, '0') || -- 2051-2061: :P:IDR-U-CLM-PT-RESP
            RPAD('', 1, ' ') || -- 2062-2062: :P:IDR-U-ASSIGN-BENEF-IND
            RPAD('', 1, ' ') || -- 2063-2063: :P:IDR-U-FORMAT-TYPE
            RPAD('', 1, ' ') || -- 2064-2064: FILLER
            RPAD('', 1, ' ') || -- 2065-2065: :P:IDR-B-CUR-IND
            RPAD('', 15, ' ') || -- 2066-2080: :P:IDR-B-ICN
            LPAD('', 8, '0') || -- 2081-2088: :P:IDR-B-DATE
            RPAD('', 1, ' ') || -- 2089-2089: :P:IDR-B-CUR-IND
            RPAD('', 15, ' ') || -- 2090-2104: :P:IDR-B-ICN
            LPAD('', 8, '0') || -- 2105-2112: :P:IDR-B-DATE
            RPAD('', 1, ' ') || -- 2113-2113: :P:IDR-B-CUR-IND
            RPAD('', 15, ' ') || -- 2114-2128: :P:IDR-B-ICN
            LPAD('', 8, '0') || -- 2129-2136: :P:IDR-B-DATE
            RPAD('', 1, ' ') || -- 2137-2137: :P:IDR-B-CUR-IND
            RPAD('', 15, ' ') || -- 2138-2152: :P:IDR-B-ICN
            LPAD('', 8, '0') || -- 2153-2160: :P:IDR-B-DATE
            RPAD('', 1, ' ') || -- 2161-2161: :P:IDR-B-CUR-IND
            RPAD('', 15, ' ') || -- 2162-2176: :P:IDR-B-ICN
            LPAD('', 8, '0') || -- 2177-2184: :P:IDR-B-DATE
            RPAD('', 1, ' ') || -- 2185-2185: :P:IDR-C-TYPE
            RPAD('', 1, ' ') || -- 2186-2186: :P:IDR-C-OLD-STAT
            RPAD('', 1, ' ') || -- 2187-2187: :P:IDR-C-NEW-STAT
            RPAD('', 13, ' ') || -- 2188-2200: :P:IDR-C-ICN
            RPAD('', 2, ' ') || -- 2201-2202: :P:IDR-C-DET-NUMB
            LPAD('', 7, '0') || -- 2203-2209: :P:IDR-C-AMOUNT
            RPAD('', 2, ' ') || -- 2210-2211: :P:IDR-C-REASON-TYPE
            RPAD('', 5, ' ') || -- 2212-2216: :P:IDR-C-REASON-CODE
            RPAD('', 4, ' ') || -- 2217-2220: :P:IDR-C-CLERK
            LPAD('', 8, '0') || -- 2221-2228: :P:IDR-C-DATE
            RPAD('', 1, ' ') || -- 2229-2229: :P:IDR-C-TYPE
            RPAD('', 1, ' ') || -- 2230-2230: :P:IDR-C-OLD-STAT
            RPAD('', 1, ' ') || -- 2231-2231: :P:IDR-C-NEW-STAT
            RPAD('', 13, ' ') || -- 2232-2244: :P:IDR-C-ICN
            RPAD('', 2, ' ') || -- 2245-2246: :P:IDR-C-DET-NUMB
            LPAD('', 7, '0') || -- 2247-2253: :P:IDR-C-AMOUNT
            RPAD('', 2, ' ') || -- 2254-2255: :P:IDR-C-REASON-TYPE
            RPAD('', 5, ' ') || -- 2256-2260: :P:IDR-C-REASON-CODE
            RPAD('', 4, ' ') || -- 2261-2264: :P:IDR-C-CLERK
            LPAD('', 8, '0') || -- 2265-2272: :P:IDR-C-DATE
            RPAD('', 1, ' ') || -- 2273-2273: :P:IDR-C-TYPE
            RPAD('', 1, ' ') || -- 2274-2274: :P:IDR--C-OLD-STAT
            RPAD('', 1, ' ') || -- 2275-2275: :P:IDR-C-NEW-STAT
            RPAD('', 13, ' ') || -- 2276-2288: :P:IDR-C-ICN
            RPAD('', 2, ' ') || -- 2289-2290: :P:IDR-C-DET-NUMB
            LPAD('', 7, '0') || -- 2291-2297: :P:IDR-C-AMOUNT
            RPAD('', 2, ' ') || -- 2298-2299: :P:IDR-C-REASON-TYPE
            RPAD('', 5, ' ') || -- 2300-2304: :P:IDR-C-REASON-CODE
            RPAD('', 4, ' ') || -- 2305-2308: :P:IDR-C-CLERK
            LPAD('', 8, '0') || -- 2309-2316: :P:IDR-C-DATE
            RPAD('', 1, ' ') || -- 2317-2317: :P:IDR-C-TYPE
            RPAD('', 1, ' ') || -- 2318-2318: :P:IDR-C-OLD-STAT
            RPAD('', 1, ' ') || -- 2319-2319: :P:IDR-C-NEW-STAT
            RPAD('', 13, ' ') || -- 2320-2332: :P:IDR-C-ICN
            RPAD('', 2, ' ') || -- 2333-2334: :P:IDR-C-DET-NUMB
            LPAD('', 7, '0') || -- 2335-2341: :P:IDR-C-AMOUNT
            RPAD('', 2, ' ') || -- 2342-2343: :P:IDR-C-REASON-TYPE
            RPAD('', 5, ' ') || -- 2344-2348: :P:IDR-C-REASON-CODE
            RPAD('', 4, ' ') || -- 2349-2352: :P:IDR-C-CLERK
            LPAD('', 8, '0') || -- 2353-2360: :P:IDR-C-DATE
            RPAD('', 1, ' ') || -- 2361-2361: :P:IDR-C-TYPE
            RPAD('', 1, ' ') || -- 2362-2362: :P:IDR-C-OLD-STAT
            RPAD('', 1, ' ') || -- 2363-2363: :P:IDR-C-NEW-STAT
            RPAD('', 13, ' ') || -- 2364-2376: :P:IDR-C-ICN
            RPAD('', 2, ' ') || -- 2377-2378: :P:IDR-C-DET-NUMB
            LPAD('', 7, '0') || -- 2379-2385: :P:IDR-C-AMOUNT
            RPAD('', 2, ' ') || -- 2386-2387: :P:IDR-C-REASON-TYPE
            RPAD('', 5, ' ') || -- 2388-2392: :P:IDR-C-REASON-CODE
            RPAD('', 4, ' ') || -- 2393-2396: :P:IDR-C-CLERK
            LPAD('', 8, '0') || -- 2397-2404: :P:IDR-C-DATE
            RPAD('', 1, ' ') || -- 2405-2405: :P:IDR-C-TYPE
            RPAD('', 1, ' ') || -- 2406-2406: :P:IDR-C-OLD-STAT
            RPAD('', 1, ' ') || -- 2407-2407: :P:IDR-C-NEW-STAT
            RPAD('', 13, ' ') || -- 2408-2420: :P:IDR-C-ICN
            RPAD('', 2, ' ') || -- 2421-2422: :P:IDR-C-DET-NUMB
            LPAD('', 7, '0') || -- 2423-2429: :P:IDR-C-AMOUNT
            RPAD('', 2, ' ') || -- 2430-2431: :P:IDR-C-REASON-TYPE
            RPAD('', 5, ' ') || -- 2432-2436: :P:IDR-C-REASON-CODE
            RPAD('', 4, ' ') || -- 2437-2440: :P:IDR-C-CLERK
            LPAD('', 8, '0') || -- 2441-2448: :P:IDR-C-DATE
            RPAD('', 1, ' ') || -- 2449-2449: :P:IDR-C-TYPE
            RPAD('', 1, ' ') || -- 2450-2450: :P:IDR-C-OLD-STAT
            RPAD('', 1, ' ') || -- 2451-2451: :P:IDR-C-NEW-STAT
            RPAD('', 13, ' ') || -- 2452-2464: :P:IDR-C-ICN
            RPAD('', 2, ' ') || -- 2465-2466: :P:IDR-C-DET-NUMB
            LPAD('', 7, '0') || -- 2467-2473: :P:IDR-C-AMOUNT
            RPAD('', 2, ' ') || -- 2474-2475: :P:IDR-C-REASON-TYPE
            RPAD('', 5, ' ') || -- 2476-2480: :P:IDR-C-REASON-CODE
            RPAD('', 4, ' ') || -- 2481-2484: :P:IDR-C-CLERK
            LPAD('', 8, '0') || -- 2485-2492: :P:IDR-C-DATE
            RPAD('', 1, ' ') || -- 2493-2493: :P:IDR-C-TYPE
            RPAD('', 1, ' ') || -- 2494-2494: :P:IDR-C-OLD-STAT
            RPAD('', 1, ' ') || -- 2495-2495: :P:IDR-C-NEW-STAT
            RPAD('', 13, ' ') || -- 2496-2508: :P:IDR-C-ICN
            RPAD('', 2, ' ') || -- 2509-2510: :P:IDR-C-DET-NUMB
            LPAD('', 7, '0') || -- 2511-2517: :P:IDR-C-AMOUNT
            RPAD('', 2, ' ') || -- 2518-2519: :P:IDR-C-REASON-TYPE
            RPAD('', 5, ' ') || -- 2520-2524: :P:IDR-C-REASON-CODE
            RPAD('', 4, ' ') || -- 2525-2528: :P:IDR-C-CLERK
            LPAD('', 8, '0') || -- 2529-2536: :P:IDR-C-DATE
            RPAD('', 1, ' ') || -- 2537-2537: :P:IDR-C-TYPE
            RPAD('', 1, ' ') || -- 2538-2538: :P:IDR-C-OLD-STAT
            RPAD('', 1, ' ') || -- 2539-2539: :P:IDR-C-NEW-STAT
            RPAD('', 13, ' ') || -- 2540-2552: :P:IDR-C-ICN
            RPAD('', 2, ' ') || -- 2553-2554: :P:IDR-C-DET-NUMB
            LPAD('', 7, '0') || -- 2555-2561: :P:IDR-C-AMOUNT
            RPAD('', 2, ' ') || -- 2562-2563: :P:IDR-C-REASON-TYPE
            RPAD('', 5, ' ') || -- 2564-2568: :P:IDR-C-REASON-CODE
            RPAD('', 4, ' ') || -- 2569-2572: :P:IDR-C-CLERK
            LPAD('', 8, '0') || -- 2573-2580: :P:IDR-C-DATE
            RPAD('', 1, ' ') || -- 2581-2581: :P:IDR-C-TYPE
            RPAD('', 1, ' ') || -- 2582-2582: :P:IDR-C-OLD-STAT
            RPAD('', 1, ' ') || -- 2583-2583: :P:IDR-C-NEW-STAT
            RPAD('', 13, ' ') || -- 2584-2596: :P:IDR-C-ICN
            RPAD('', 2, ' ') || -- 2597-2598: :P:IDR-C-DET-NUMB
            LPAD('', 7, '0') || -- 2599-2605: :P:IDR-C-AMOUNT
            RPAD('', 2, ' ') || -- 2606-2607: :P:IDR-C-REASON-TYPE
            RPAD('', 5, ' ') || -- 2608-2612: :P:IDR-C-REASON-CODE
            RPAD('', 4, ' ') || -- 2613-2616: :P:IDR-C-CLERK
            LPAD('', 8, '0') || -- 2617-2624: :P:IDR-C-DATE
            RPAD('', 1, ' ') || -- 2625-2625: :P:IDR-C-TYPE
            RPAD('', 1, ' ') || -- 2626-2626: :P:IDR-C-OLD-STAT
            RPAD('', 1, ' ') || -- 2627-2627: :P:IDR-C-NEW-STAT
            RPAD('', 13, ' ') || -- 2628-2640: :P:IDR-C-ICN
            RPAD('', 2, ' ') || -- 2641-2642: :P:IDR-C-DET-NUMB
            LPAD('', 7, '0') || -- 2643-2649: :P:IDR-C-AMOUNT
            RPAD('', 2, ' ') || -- 2650-2651: :P:IDR-C-REASON-TYPE
            RPAD('', 5, ' ') || -- 2652-2656: :P:IDR-C-REASON-CODE
            RPAD('', 4, ' ') || -- 2657-2660: :P:IDR-C-CLERK
            LPAD('', 8, '0') || -- 2661-2668: :P:IDR-C-DATE
            RPAD('', 1, ' ') || -- 2669-2669: :P:IDR-C-TYPE
            RPAD('', 1, ' ') || -- 2670-2670: :P:IDR-C-OLD-STAT
            RPAD('', 1, ' ') || -- 2671-2671: :P:IDR-C-NEW-STAT
            RPAD('', 13, ' ') || -- 2672-2684: :P:IDR-C-ICN
            RPAD('', 2, ' ') || -- 2685-2686: :P:IDR-C-DET-NUMB
            LPAD('', 7, '0') || -- 2687-2693: :P:IDR-C-AMOUNT
            RPAD('', 2, ' ') || -- 2694-2695: :P:IDR-C-REASON-TYPE
            RPAD('', 5, ' ') || -- 2696-2700: :P:IDR-C-REASON-CODE
            RPAD('', 4, ' ') || -- 2701-2704: :P:IDR-C-CLERK
            LPAD('', 8, '0') || -- 2705-2712: :P:IDR-C-DATE
            RPAD('', 1, ' ') || -- 2713-2713: :P:IDR-C-TYPE
            RPAD('', 1, ' ') || -- 2714-2714: :P:IDR-C-OLD-STAT
            RPAD('', 1, ' ') || -- 2715-2715: :P:IDR-C-NEW-STAT
            RPAD('', 13, ' ') || -- 2716-2728: :P:IDR-C-ICN
            RPAD('', 2, ' ') || -- 2729-2730: :P:IDR-C-DET-NUMB
            LPAD('', 7, '0') || -- 2731-2737: :P:IDR-C-AMOUNT
            RPAD('', 2, ' ') || -- 2738-2739: :P:IDR-C-REASON-TYPE
            RPAD('', 5, ' ') || -- 2740-2744: :P:IDR-C-REASON-CODE
            RPAD('', 4, ' ') || -- 2745-2748: :P:IDR-C-CLERK
            LPAD('', 8, '0') || -- 2749-2756: :P:IDR-C-DATE
            RPAD('', 1, ' ') || -- 2757-2757: :P:IDR-C-TYPE
            RPAD('', 1, ' ') || -- 2758-2758: :P:IDR-C-OLD-STAT
            RPAD('', 1, ' ') || -- 2759-2759: :P:IDR-C-NEW-STAT
            RPAD('', 13, ' ') || -- 2760-2772: :P:IDR-C-ICN
            RPAD('', 2, ' ') || -- 2773-2774: :P:IDR-C-DET-NUMB
            LPAD('', 7, '0') || -- 2775-2781: :P:IDR-C-AMOUNT
            RPAD('', 2, ' ') || -- 2782-2783: :P:IDR-C-REASON-TYPE
            RPAD('', 5, ' ') || -- 2784-2788: :P:IDR-C-REASON-CODE
            RPAD('', 4, ' ') || -- 2789-2792: :P:IDR-C-CLERK
            LPAD('', 8, '0') || -- 2793-2800: :P:IDR-C-DATE
            RPAD('', 1, ' ') || -- 2801-2801: :P:IDR-C-TYPE
            RPAD('', 1, ' ') || -- 2802-2802: :P:IDR-C-OLD-STAT
            RPAD('', 1, ' ') || -- 2803-2803: :P:IDR-C-NEW-STAT
            RPAD('', 13, ' ') || -- 2804-2816: :P:IDR-C-ICN
            RPAD('', 2, ' ') || -- 2817-2818: :P:IDR-C-DET-NUMB
            LPAD('', 7, '0') || -- 2819-2825: :P:IDR-C-AMOUNT
            RPAD('', 2, ' ') || -- 2826-2827: :P:IDR-C-REASON-TYPE
            RPAD('', 5, ' ') || -- 2828-2832: :P:IDR-C-REASON-CODE
            RPAD('', 4, ' ') || -- 2833-2836: :P:IDR-C-CLERK
            LPAD('', 8, '0') || -- 2837-2844: :P:IDR-C-DATE
            RPAD('', 1, ' ') || -- 2845-2845: :P:IDR-F-TYPE
            RPAD('', 1, ' ') || -- 2846-2846: :P:IDR-F-TRLR-NUMB
            RPAD('', 9, ' ') || -- 2847-2855: :P:IDR-F-BENE-INT-EOB
            RPAD(
                COALESCE(ppr.payment_response_json->'beneCheck'->>'higlasClaimCheckNumber', ''),
                9,
                ' '
            ) || -- 2856-2864: :P:IDR-F-BENE-EXT-EOB
            LPAD(
                COALESCE(pc.claim_jsonb->>'patientPaidAmount', '0'),
                7,
                '0'
            ) || -- 2865-2871: :P:IDR-F-BENE-PAY-AMT
            LPAD('', 7, '0') || -- 2872-2878: :P:IDR-F-BENE-OFF-AMT
            RPAD('', 1, ' ') || -- 2879-2879: :P:IDR-F-2ND-CHK-IND
            RPAD('', 9, ' ') || -- 2880-2888: :P:IDR-F-PROV-INT-EOB
            RPAD(
                COALESCE(ppr.payment_response_json->'providerCheck'->>'higlasClaimCheckNumber', ''),
                9,
                ' '
            ) || -- 2889-2897: :P:IDR-F-PROV-EXT-EOB
            LPAD('', 7, '0') || -- 2898-2904: :P:IDR-F-PROV-PAY-AMT
            LPAD('', 7, '0') || -- 2905-2911: :P:IDR-F-PROV-OFF-AMT
            RPAD('', 4, ' ') || -- 2912-2915: :P:IDR-F-CLERK
            LPAD('', 8, '0') || -- 2916-2923: :P:IDR-F-DATE
            RPAD('', 1, ' ') || -- 2924-2924: :P:IDR-F-TYPE
            RPAD('', 1, ' ') || -- 2925-2925: :P:IDR-F-TRLR-NUMB
            RPAD('', 9, ' ') || -- 2926-2934: :P:IDR-F-BENE-INT-EOB
            RPAD('', 9, ' ') || -- 2935-2943: :P:IDR-F-BENE-EXT-EOB
            LPAD(
                COALESCE(pc.claim_jsonb->>'patientPaidAmount', '0'),
                7,
                '0'
            ) || -- 2944-2950: :P:IDR-F-BENE-PAY-AMT
            LPAD('', 7, '0') || -- 2951-2957: :P:IDR-F-BENE-OFF-AMT
            RPAD('', 1, ' ') || -- 2958-2958: :P:IDR-F-2ND-CHK-IND
            RPAD('', 9, ' ') || -- 2959-2967: :P:IDR-F-PROV-INT-EOB
            RPAD('', 9, ' ') || -- 2968-2976: :P:IDR-F-PROV-EXT-EOB
            LPAD('', 7, '0') || -- 2977-2983: :P:IDR-F-PROV-PAY-AMT
            LPAD('', 7, '0') || -- 2984-2990: :P:IDR-F-PROV-OFF-AMT
            RPAD('', 4, ' ') || -- 2991-2994: :P:IDR-F-CLERK
            LPAD('', 8, '0') || -- 2995-3002: :P:IDR-F-DATE
            RPAD('', 5, ' ') || -- 3003-3007: :P:IDR-W-COBA-NUMBER
            LPAD('', 8, '0') || -- 3008-3015: :P:IDR-W-COBA-EFF-DATE
            LPAD('', 8, '0') || -- 3016-3023: :P:IDR-W-COBA-END-DATE
            RPAD('', 1, ' ') || -- 3024-3024: :P:IDR-W-COBA-TEST-IND
            LPAD('', 8, '0') || -- 3025-3032: :P:IDR-W-COBA-RECV-DATE
            RPAD('', 1, ' ') || -- 3033-3033: :P:IDR-W-COBA-RECV-IND
            RPAD('', 1, ' ') || -- 3034-3034: :P:IDR-W-COBA-RSN-CREATN
            RPAD('', 1, ' ') || -- 3035-3035: :P:IDR-W-COBA-T-5010-IND
            RPAD('', 32, ' ') || -- 3036-3067: :P:IDR-W-COBA-NAME
            LPAD('', 8, '0') || -- 3068-3075: :P:IDR-W-COBA-ABORT-DATE
            RPAD('', 1, ' ') || -- 3076-3076: :P:IDR-W-COBA-MSN-IND
            RPAD('', 8, ' ') || -- 3077-3084: FILLER
            RPAD('', 5, ' ') || -- 3085-3089: :P:IDR-W-COBA-NUMBER
            LPAD('', 8, '0') || -- 3090-3097: :P:IDR-W-COBA-EFF-DATE
            LPAD('', 8, '0') || -- 3098-3105: :P:IDR-W-COBA-END-DATE
            RPAD('', 1, ' ') || -- 3106-3106: :P:IDR-W-COBA-TEST-IND
            LPAD('', 8, '0') || -- 3107-3114: :P:IDR-W-COBA-RECV-DATE
            RPAD('', 1, ' ') || -- 3115-3115: :P:IDR-W-COBA-RECV-IND
            RPAD('', 1, ' ') || -- 3116-3116: :P:IDR-W-COBA-RSN-CREATN
            RPAD('', 1, ' ') || -- 3117-3117: :P:IDR-W-COBA-T-5010-IND
            RPAD('', 32, ' ') || -- 3118-3149: :P:IDR-W-COBA-NAME
            LPAD('', 8, '0') || -- 3150-3157: :P:IDR-W-COBA-ABORT-DATE
            RPAD('', 1, ' ') || -- 3158-3158: :P:IDR-W-COBA-MSN-IND
            RPAD('', 8, ' ') || -- 3159-3166: FILLER
            RPAD('', 5, ' ') || -- 3167-3171: :P:IDR-W-COBA-NUMBER
            LPAD('', 8, '0') || -- 3172-3179: :P:IDR-W-COBA-EFF-DATE
            LPAD('', 8, '0') || -- 3180-3187: :P:IDR-W-COBA-END-DATE
            RPAD('', 1, ' ') || -- 3188-3188: :P:IDR-W-COBA-TEST-IND
            LPAD('', 8, '0') || -- 3189-3196: :P:IDR-W-COBA-RECV-DATE
            RPAD('', 1, ' ') || -- 3197-3197: :P:IDR-W-COBA-RECV-IND
            RPAD('', 1, ' ') || -- 3198-3198: :P:IDR-W-COBA-RSN-CREATN
            RPAD('', 1, ' ') || -- 3199-3199: :P:IDR-W-COBA-T-5010-IND
            RPAD('', 32, ' ') || -- 3200-3231: :P:IDR-W-COBA-NAME
            LPAD('', 8, '0') || -- 3232-3239: :P:IDR-W-COBA-ABORT-DATE
            RPAD('', 1, ' ') || -- 3240-3240: :P:IDR-W-COBA-MSN-IND
            RPAD('', 8, ' ') || -- 3241-3248: FILLER
            RPAD('', 5, ' ') || -- 3249-3253: :P:IDR-W-COBA-NUMBER
            LPAD('', 8, '0') || -- 3254-3261: :P:IDR-W-COBA-EFF-DATE
            LPAD('', 8, '0') || -- 3262-3269: :P:IDR-W-COBA-END-DATE
            RPAD('', 1, ' ') || -- 3270-3270: :P:IDR-W-COBA-TEST-IND
            LPAD('', 8, '0') || -- 3271-3278: :P:IDR-W-COBA-RECV-DATE
            RPAD('', 1, ' ') || -- 3279-3279: :P:IDR-W-COBA-RECV-IND
            RPAD('', 1, ' ') || -- 3280-3280: :P:IDR-W-COBA-RSN-CREATN
            RPAD('', 1, ' ') || -- 3281-3281: :P:IDR-W-COBA-T-5010-IND
            RPAD('', 32, ' ') || -- 3282-3313: :P:IDR-W-COBA-NAME
            LPAD('', 8, '0') || -- 3314-3321: :P:IDR-W-COBA-ABORT-DATE
            RPAD('', 1, ' ') || -- 3322-3322: :P:IDR-W-COBA-MSN-IND
            RPAD('', 8, ' ') || -- 3323-3330: FILLER
            RPAD('', 5, ' ') || -- 3331-3335: :P:IDR-W-COBA-NUMBER
            LPAD('', 8, '0') || -- 3336-3343: :P:IDR-W-COBA-EFF-DATE
            LPAD('', 8, '0') || -- 3344-3351: :P:IDR-W-COBA-END-DATE
            RPAD('', 1, ' ') || -- 3352-3352: :P:IDR-W-COBA-TEST-IND
            LPAD('', 8, '0') || -- 3353-3360: :P:IDR-W-COBA-RECV-DATE
            RPAD('', 1, ' ') || -- 3361-3361: :P:IDR-W-COBA-RECV-IND
            RPAD('', 1, ' ') || -- 3362-3362: :P:IDR-W-COBA-RSN-CREATN
            RPAD('', 1, ' ') || -- 3363-3363: :P:IDR-W-COBA-T-5010-IND
            RPAD('', 32, ' ') || -- 3364-3395: :P:IDR-W-COBA-NAME
            LPAD('', 8, '0') || -- 3396-3403: :P:IDR-W-COBA-ABORT-DATE
            RPAD('', 1, ' ') || -- 3404-3404: :P:IDR-W-COBA-MSN-IND
            RPAD('', 8, ' ') || -- 3405-3412: FILLER
            RPAD('', 5, ' ') || -- 3413-3417: :P:IDR-W-COBA-NUMBER
            LPAD('', 8, '0') || -- 3418-3425: :P:IDR-W-COBA-EFF-DATE
            LPAD('', 8, '0') || -- 3426-3433: :P:IDR-W-COBA-END-DATE
            RPAD('', 1, ' ') || -- 3434-3434: :P:IDR-W-COBA-TEST-IND
            LPAD('', 8, '0') || -- 3435-3442: :P:IDR-W-COBA-RECV-DATE
            RPAD('', 1, ' ') || -- 3443-3443: :P:IDR-W-COBA-RECV-IND
            RPAD('', 1, ' ') || -- 3444-3444: :P:IDR-W-COBA-RSN-CREATN
            RPAD('', 1, ' ') || -- 3445-3445: :P:IDR-W-COBA-T-5010-IND
            RPAD('', 32, ' ') || -- 3446-3477: :P:IDR-W-COBA-NAME
            LPAD('', 8, '0') || -- 3478-3485: :P:IDR-W-COBA-ABORT-DATE
            RPAD('', 1, ' ') || -- 3486-3486: :P:IDR-W-COBA-MSN-IND
            RPAD('', 8, ' ') || -- 3487-3494: FILLER
            RPAD('', 5, ' ') || -- 3495-3499: :P:IDR-W-COBA-NUMBER
            LPAD('', 8, '0') || -- 3500-3507: :P:IDR-W-COBA-EFF-DATE
            LPAD('', 8, '0') || -- 3508-3515: :P:IDR-W-COBA-END-DATE
            RPAD('', 1, ' ') || -- 3516-3516: :P:IDR-W-COBA-TEST-IND
            LPAD('', 8, '0') || -- 3517-3524: :P:IDR-W-COBA-RECV-DATE
            RPAD('', 1, ' ') || -- 3525-3525: :P:IDR-W-COBA-RECV-IND
            RPAD('', 1, ' ') || -- 3526-3526: :P:IDR-W-COBA-RSN-CREATN
            RPAD('', 1, ' ') || -- 3527-3527: :P:IDR-W-COBA-T-5010-IND
            RPAD('', 32, ' ') || -- 3528-3559: :P:IDR-W-COBA-NAME
            LPAD('', 8, '0') || -- 3560-3567: :P:IDR-W-COBA-ABORT-DATE
            RPAD('', 1, ' ') || -- 3568-3568: :P:IDR-W-COBA-MSN-IND
            RPAD('', 8, ' ') || -- 3569-3576: FILLER
            RPAD('', 5, ' ') || -- 3577-3581: :P:IDR-W-COBA-NUMBER
            LPAD('', 8, '0') || -- 3582-3589: :P:IDR-W-COBA-EFF-DATE
            LPAD('', 8, '0') || -- 3590-3597: :P:IDR-W-COBA-END-DATE
            RPAD('', 1, ' ') || -- 3598-3598: :P:IDR-W-COBA-TEST-IND
            LPAD('', 8, '0') || -- 3599-3606: :P:IDR-W-COBA-RECV-DATE
            RPAD('', 1, ' ') || -- 3607-3607: :P:IDR-W-COBA-RECV-IND
            RPAD('', 1, ' ') || -- 3608-3608: :P:IDR-W-COBA-RSN-CREATN
            RPAD('', 1, ' ') || -- 3609-3609: :P:IDR-W-COBA-T-5010-IND
            RPAD('', 32, ' ') || -- 3610-3641: :P:IDR-W-COBA-NAME
            LPAD('', 8, '0') || -- 3642-3649: :P:IDR-W-COBA-ABORT-DATE
            RPAD('', 1, ' ') || -- 3650-3650: :P:IDR-W-COBA-MSN-IND
            RPAD('', 8, ' ') || -- 3651-3658: FILLER
            RPAD('', 5, ' ') || -- 3659-3663: :P:IDR-W-COBA-NUMBER
            LPAD('', 8, '0') || -- 3664-3671: :P:IDR-W-COBA-EFF-DATE
            LPAD('', 8, '0') || -- 3672-3679: :P:IDR-W-COBA-END-DATE
            RPAD('', 1, ' ') || -- 3680-3680: :P:IDR-W-COBA-TEST-IND
            LPAD('', 8, '0') || -- 3681-3688: :P:IDR-W-COBA-RECV-DATE
            RPAD('', 1, ' ') || -- 3689-3689: :P:IDR-W-COBA-RECV-IND
            RPAD('', 1, ' ') || -- 3690-3690: :P:IDR-W-COBA-RSN-CREATN
            RPAD('', 1, ' ') || -- 3691-3691: :P:IDR-W-COBA-T-5010-IND
            RPAD('', 32, ' ') || -- 3692-3723: :P:IDR-W-COBA-NAME
            LPAD('', 8, '0') || -- 3724-3731: :P:IDR-W-COBA-ABORT-DATE
            RPAD('', 1, ' ') || -- 3732-3732: :P:IDR-W-COBA-MSN-IND
            RPAD('', 8, ' ') || -- 3733-3740: FILLER
            RPAD('', 5, ' ') || -- 3741-3745: :P:IDR-W-COBA-NUMBER
            LPAD('', 8, '0') || -- 3746-3753: :P:IDR-W-COBA-EFF-DATE
            LPAD('', 8, '0') || -- 3754-3761: :P:IDR-W-COBA-END-DATE
            RPAD('', 1, ' ') || -- 3762-3762: :P:IDR-W-COBA-TEST-IND
            LPAD('', 8, '0') || -- 3763-3770: :P:IDR-W-COBA-RECV-DATE
            RPAD('', 1, ' ') || -- 3771-3771: :P:IDR-W-COBA-RECV-IND
            RPAD('', 1, ' ') || -- 3772-3772: :P:IDR-W-COBA-RSN-CREATN
            RPAD('', 1, ' ') || -- 3773-3773: :P:IDR-W-COBA-T-5010-IND
            RPAD('', 32, ' ') || -- 3774-3805: :P:IDR-W-COBA-NAME
            LPAD('', 8, '0') || -- 3806-3813: :P:IDR-W-COBA-ABORT-DATE
            RPAD('', 1, ' ') || -- 3814-3814: :P:IDR-W-COBA-MSN-IND
            RPAD('', 8, ' ') || -- 3815-3822: FILLER
            LPAD('', 8, '0') || -- 3823-3830: :P:IDR-ADJ-DATE
            RPAD('', 15, ' ') || -- 3831-3845: :P:IDR-XREF-ICN
            RPAD('', 4, ' ') || -- 3846-3849: :P:IDR-ADJ-CLERK
            RPAD('', 15, ' ') || -- 3850-3864: :P:IDR-INIT-CCN
            LPAD('', 8, '0') || -- 3865-3872: :P:IDR-ADJ-CHK-WRT-DT
            LPAD('', 7, '0') || -- 3873-3879: :P:IDR-ADJ-B-EOMB-AMT
            LPAD('', 7, '0') || -- 3880-3886: :P:IDR-ADJ-P-EOMB-AMT
            LPAD('', 8, '0') || -- 3887-3894: :P:IDR-ADJ-DATE
            RPAD('', 15, ' ') || -- 3895-3909: :P:IDR-XREF-ICN
            RPAD('', 4, ' ') || -- 3910-3913: :P:IDR-ADJ-CLERK
            RPAD('', 15, ' ') || -- 3914-3928: :P:IDR-INIT-CCN
            LPAD('', 8, '0') || -- 3929-3936: :P:IDR-ADJ-CHK-WRT-DT
            LPAD('', 7, '0') || -- 3937-3943: :P:IDR-ADJ-B-EOMB-AMT
            LPAD('', 7, '0') || -- 3944-3950: :P:IDR-ADJ-P-EOMB-AMT
            LPAD('', 8, '0') || -- 3951-3958: :P:IDR-ADJ-DATE
            RPAD('', 15, ' ') || -- 3959-3973: :P:IDR-XREF-ICN
            RPAD('', 4, ' ') || -- 3974-3977: :P:IDR-ADJ-CLERK
            RPAD('', 15, ' ') || -- 3978-3992: :P:IDR-INIT-CCN
            LPAD('', 8, '0') || -- 3993-4000: :P:IDR-ADJ-CHK-WRT-DT
            LPAD('', 7, '0') || -- 4001-4007: :P:IDR-ADJ-B-EOMB-AMT
            LPAD('', 7, '0') || -- 4008-4014: :P:IDR-ADJ-P-EOMB-AMT
            LPAD('', 8, '0') || -- 4015-4022: :P:IDR-ADJ-DATE
            RPAD('', 15, ' ') || -- 4023-4037: :P:IDR-XREF-ICN
            RPAD('', 4, ' ') || -- 4038-4041: :P:IDR-ADJ-CLERK
            RPAD('', 15, ' ') || -- 4042-4056: :P:IDR-INIT-CCN
            LPAD('', 8, '0') || -- 4057-4064: :P:IDR-ADJ-CHK-WRT-DT
            LPAD('', 7, '0') || -- 4065-4071: :P:IDR-ADJ-B-EOMB-AMT
            LPAD('', 7, '0') || -- 4072-4078: :P:IDR-ADJ-P-EOMB-AMT
            LPAD('', 8, '0') || -- 4079-4086: :P:IDR-ADJ-DATE
            RPAD('', 15, ' ') || -- 4087-4101: :P:IDR-XREF-ICN
            RPAD('', 4, ' ') || -- 4102-4105: :P:IDR-ADJ-CLERK
            RPAD('', 15, ' ') || -- 4106-4120: :P:IDR-INIT-CCN
            LPAD('', 8, '0') || -- 4121-4128: :P:IDR-ADJ-CHK-WRT-DT
            LPAD('', 7, '0') || -- 4129-4135: :P:IDR-ADJ-B-EOMB-AMT
            LPAD('', 7, '0') || -- 4136-4142: :P:IDR-ADJ-P-EOMB-AMT
            LPAD('', 8, '0') || -- 4143-4150: :P:IDR-ADJ-DATE
            RPAD('', 15, ' ') || -- 4151-4165: :P:IDR-XREF-ICN
            RPAD('', 4, ' ') || -- 4166-4169: :P:IDR-ADJ-CLERK
            RPAD('', 15, ' ') || -- 4170-4184: :P:IDR-INIT-CCN
            LPAD('', 8, '0') || -- 4185-4192: :P:IDR-ADJ-CHK-WRT-DT
            LPAD('', 7, '0') || -- 4193-4199: :P:IDR-ADJ-B-EOMB-AMT
            LPAD('', 7, '0') || -- 4200-4206: :P:IDR-ADJ-P-EOMB-AMT
            LPAD('', 8, '0') || -- 4207-4214: :P:IDR-ADJ-DATE
            RPAD('', 15, ' ') || -- 4215-4229: :P:IDR-XREF-ICN
            RPAD('', 4, ' ') || -- 4230-4233: :P:IDR-ADJ-CLERK
            RPAD('', 15, ' ') || -- 4234-4248: :P:IDR-INIT-CCN
            LPAD('', 8, '0') || -- 4249-4256: :P:IDR-ADJ-CHK-WRT-DT
            LPAD('', 7, '0') || -- 4257-4263: :P:IDR-ADJ-B-EOMB-AMT
            LPAD('', 7, '0') || -- 4264-4270: :P:IDR-ADJ-P-EOMB-AMT
            LPAD('', 8, '0') || -- 4271-4278: :P:IDR-ADJ-DATE
            RPAD('', 15, ' ') || -- 4279-4293: :P:IDR-XREF-ICN
            RPAD('', 4, ' ') || -- 4294-4297: :P:IDR-ADJ-CLERK
            RPAD('', 15, ' ') || -- 4298-4312: :P:IDR-INIT-CCN
            LPAD('', 8, '0') || -- 4313-4320: :P:IDR--ADJ-CHK-WRT-DT
            LPAD('', 7, '0') || -- 4321-4327: :P:IDR-ADJ-B-EOMB-AMT
            LPAD('', 7, '0') || -- 4328-4334: :P:IDR-ADJ-P-EOMB-AMT
            LPAD('', 8, '0') || -- 4335-4342: :P:IDR-ADJ-DATE
            RPAD('', 15, ' ') || -- 4343-4357: :P:IDR-XREF-ICN
            RPAD('', 4, ' ') || -- 4358-4361: :P:IDR-ADJ-CLERK
            RPAD('', 15, ' ') || -- 4362-4376: :P:IDR-INIT-CCN
            LPAD('', 8, '0') || -- 4377-4384: :P:IDR-ADJ-CHK-WRT-DT
            LPAD('', 7, '0') || -- 4385-4391: :P:IDR-ADJ-B-EOMB-AMT
            LPAD('', 7, '0') || -- 4392-4398: :P:IDR-ADJ-P-EOMB-AMT
            LPAD('', 8, '0') || -- 4399-4406: :P:IDR-ADJ-DATE
            RPAD('', 15, ' ') || -- 4407-4421: :P:IDR-XREF-ICN
            RPAD('', 4, ' ') || -- 4422-4425: :P:IDR-ADJ-CLERK
            RPAD('', 15, ' ') || -- 4426-4440: :P:IDR-INIT-CCN
            LPAD('', 8, '0') || -- 4441-4448: :P:IDR-ADJ-CHK-WRT-DT
            LPAD('', 7, '0') || -- 4449-4455: :P:IDR-ADJ-B-EOMB-AMT
            LPAD('', 7, '0') || -- 4456-4462: :P:IDR-ADJ-P-EOMB-AMT
            LPAD('', 8, '0') || -- 4463-4470: :P:IDR-ADJ-DATE
            RPAD('', 15, ' ') || -- 4471-4485: :P:IDR-XREF-ICN
            RPAD('', 4, ' ') || -- 4486-4489: :P:IDR-ADJ-CLERK
            RPAD('', 15, ' ') || -- 4490-4504: :P:IDR-INIT-CCN
            LPAD('', 8, '0') || -- 4505-4512: :P:IDR-ADJ-CHK-WRT-DT
            LPAD('', 7, '0') || -- 4513-4519: :P:IDR-ADJ-B-EOMB-AMT
            LPAD('', 7, '0') || -- 4520-4526: :P:IDR-ADJ-P-EOMB-AMT
            LPAD('', 8, '0') || -- 4527-4534: :P:IDR-ADJ-DATE
            RPAD('', 15, ' ') || -- 4535-4549: :P:IDR-XREF-ICN
            RPAD('', 4, ' ') || -- 4550-4553: :P:IDR-ADJ-CLERK
            RPAD('', 15, ' ') || -- 4554-4568: :P:IDR-INIT-CCN
            LPAD('', 8, '0') || -- 4569-4576: :P:IDR-ADJ-CHK-WRT-DT
            LPAD('', 7, '0') || -- 4577-4583: :P:IDR-ADJ-B-EOMB-AMT
            LPAD('', 7, '0') || -- 4584-4590: :P:IDR-ADJ-P-EOMB-AMT
            LPAD('', 8, '0') || -- 4591-4598: :P:IDR-ADJ-DATE
            RPAD('', 15, ' ') || -- 4599-4613: :P:IDR-XREF-ICN
            RPAD('', 4, ' ') || -- 4614-4617: :P:IDR-ADJ-CLERK
            RPAD('', 15, ' ') || -- 4618-4632: :P:IDR-INIT-CCN
            LPAD('', 8, '0') || -- 4633-4640: :P:IDR-ADJ-CHK-WRT-DT
            LPAD('', 7, '0') || -- 4641-4647: :P:IDR-ADJ-B-EOMB-AMT
            LPAD('', 7, '0') || -- 4648-4654: :P:IDR-ADJ-P-EOMB-AMT
            LPAD('', 8, '0') || -- 4655-4662: :P:IDR-ADJ-DATE
            RPAD('', 15, ' ') || -- 4663-4677: :P:IDR-XREF-ICN
            RPAD('', 4, ' ') || -- 4678-4681: :P:IDR-ADJ-CLERK
            RPAD('', 15, ' ') || -- 4682-4696: :P:IDR-INIT-CCN
            LPAD('', 8, '0') || -- 4697-4704: :P:IDR-ADJ-CHK-WRT-DT
            LPAD('', 7, '0') || -- 4705-4711: :P:IDR-ADJ-B-EOMB-AMT
            LPAD('', 7, '0') || -- 4712-4718: :P:IDR-ADJ-P-EOMB-AMT
            LPAD('', 8, '0') || -- 4719-4726: :P:IDR-ADJ-DATE
            RPAD('', 15, ' ') || -- 4727-4741: :P:IDR-XREF-ICN
            RPAD('', 4, ' ') || -- 4742-4745: :P:IDR-ADJ-CLERK
            RPAD('', 15, ' ') || -- 4746-4760: :P:IDR-INIT-CCN
            LPAD('', 8, '0') || -- 4761-4768: :P:IDR-ADJ-CHK-WRT-DT
            LPAD('', 7, '0') || -- 4769-4775: :P:IDR-ADJ-B-EOMB-AMT
            LPAD('', 7, '0') || -- 4776-4782: :P:IDR-ADJ-P-EOMB-AMT
            LPAD('', 8, '0') || -- 4783-4790: :P:IDR-ADJ-DATE
            RPAD('', 15, ' ') || -- 4791-4805: :P:IDR-XREF-ICN
            RPAD('', 4, ' ') || -- 4806-4809: :P:IDR-ADJ-CLERK
            RPAD('', 15, ' ') || -- 4810-4824: :P:IDR-INIT-CCN
            LPAD('', 8, '0') || -- 4825-4832: :P:IDR-ADJ-CHK-WRT-DT
            LPAD('', 7, '0') || -- 4833-4839: :P:IDR-ADJ-B-EOMB-AMT
            LPAD('', 7, '0') || -- 4840-4846: :P:IDR-ADJ-P-EOMB-AMT
            LPAD('', 8, '0') || -- 4847-4854: :P:IDR-ADJ-DATE
            RPAD('', 15, ' ') || -- 4855-4869: :P:IDR-XREF-ICN
            RPAD('', 4, ' ') || -- 4870-4873: :P:IDR-ADJ-CLERK
            RPAD('', 15, ' ') || -- 4874-4888: :P:IDR-INIT-CCN
            LPAD('', 8, '0') || -- 4889-4896: :P:IDR-ADJ-CHK-WRT-DT
            LPAD('', 7, '0') || -- 4897-4903: :P:IDR-ADJ-B-EOMB-AMT
            LPAD('', 7, '0') || -- 4904-4910: :P:IDR-ADJ-P-EOMB-AMT
            RPAD('', 25, ' ') || -- 4911-4935: :P:IDR-AMB-PICKUP-ADDRES-LINE1
            RPAD('', 20, ' ') || -- 4936-4955: :P:IDR-AMB-PICKUP-ADDRES-LINE2
            RPAD('', 20, ' ') || -- 4956-4975: :P:IDR-AMB-PICKUP-CITY
            RPAD('', 2, ' ') || -- 4976-4977: :P:IDR-AMB-PICKUP-STATE
            RPAD('', 9, ' ') || -- 4978-4986: :P:IDR-AMB-PICKUP-ZIPCODE
            RPAD('', 24, ' ') || -- 4987-5010: :P:IDR-AMB-DROPOFF-NAME
            RPAD('', 25, ' ') || -- 5011-5035: :P:IDR-AMB-DROPOFF-ADDR-LINE1
            RPAD('', 20, ' ') || -- 5036-5055: :P:IDR-AMB-DROPOFF-ADDR-LINE2
            RPAD('', 20, ' ') || -- 5056-5075: :P:IDR-AMB-DROPOFF-CITY
            RPAD('', 2, ' ') || -- 5076-5077: :P:IDR-AMB-DROPOFF-STATE
            RPAD('', 9, ' ') || -- 5078-5086: :P:IDR-AMB-DROPOFF-ZIPCODE
            RPAD(
            COALESCE(
                pc.claim_jsonb->>'medicareBeneficiaryIdentifier',
                ''
            ),
            11,
            ' '
        ) || -- 5087-5097: :P:IDR-CLAIM-MBI
            RPAD('', 1, ' ') || -- 5098-5098: :P:IDR-SUB-BID-IND
            RPAD('', 10, ' ') || -- 5099-5108: :P:IDR-CMS-TRACKING
            RPAD('', 2, ' ') || -- 5109-5110: :P:IDR-RESP-REXMIT-CNTR
            RPAD('', 2, ' ') || -- 5111-5112: :P:IDR-RESP-REXMIT-CNTR
            RPAD('', 2, ' ') || -- 5113-5114: :P:IDR-RESP-REXMIT-CNTR
            RPAD('', 2, ' ') || -- 5115-5116: :P:IDR-RESP-REXMIT-CNTR
            RPAD('', 1, ' ') || -- 5117-5117: :P:IDR-Y-HIGLAS-IND
            RPAD('', 8, ' ') || -- 5118-5125: :P:IDR-Y-SEND-RECEIVE-DATE
            RPAD('', 1, ' ') || -- 5126-5126: :P:IDR-Y-HIGLAS-IND
            RPAD('', 8, ' ') || -- 5127-5134: :P:IDR-Y-SEND-RECEIVE-DATE
            RPAD('', 64, ' ') || -- 5135-5198: FILLER
            RPAD('', 8, ' ') || -- 5199-5206: :P:IDR-M-RECD-DATE
            RPAD('', 2, ' ') || -- 5207-5208: :P:IDR-M-TLR-CODE
            RPAD('', 1, ' ') || -- 5209-5209: :P:IDR-M-DELETE-IND-03
            RPAD('', 1, ' ') || -- 5210-5210: :P:IDR-M-VALID-IND
            RPAD('', 1, ' ') || -- 5211-5211: :P:IDR-M-MSP-TYPE
            RPAD('', 5, ' ') || -- 5212-5216: :P:IDR-M-CONTRACTOR
            RPAD('', 8, ' ') || -- 5217-5224: :P:IDR-M-ENTRY-DATE
            RPAD('', 5, ' ') || -- 5225-5229: :P:IDR-M-UPDATE-CNTR
            RPAD('', 8, ' ') || -- 5230-5237: :P:IDR-M-MAINT-DATE
            RPAD('', 1, ' ') || -- 5238-5238: :P:IDR-M-INS-TYPE
            RPAD('', 32, ' ') || -- 5239-5270: :P:IDR-M-INS-NAME
            RPAD('', 32, ' ') || -- 5271-5302: :P:IDR-M-INS-ADDR1
            RPAD('', 32, ' ') || -- 5303-5334: :P:IDR-M-INS-ADDR2
            RPAD('', 15, ' ') || -- 5335-5349: :P:IDR-M-INS-CITY
            RPAD('', 2, ' ') || -- 5350-5351: :P:IDR-M-INS-STATE
            RPAD('', 9, ' ') || -- 5352-5360: :P:IDR-M-INS-ZIP
            RPAD('', 17, ' ') || -- 5361-5377: :P:IDR-M-P-INS-POLICY
            RPAD('', 8, ' ') || -- 5378-5385: :P:IDR-M-MSP-EFF-DATE
            RPAD('', 8, ' ') || -- 5386-5393: :P:IDR-M-MSP-TER-DATE
            RPAD('', 1, ' ') || -- 5394-5394: :P:IDR-M-ORM-IND
            RPAD('', 2, ' ') || -- 5395-5396: :P:IDR-M-PAT-RELAT
            RPAD('', 9, ' ') || -- 5397-5405: : :P:IDR-M-SUB-F-NAME
            RPAD('', 16, ' ') || -- 5406-5421: :P:IDR-M-SUB-L-NAME
            RPAD('', 12, ' ') || -- 5422-5433: :P:IDR-M-EMP-ID-NUM
            RPAD('', 2, ' ') || -- 5434-5435: : P:IDR-M-SOURCE-CODE
            RPAD('', 1, ' ') || -- 5436-5436: :P:IDR-M-EMP-INFO
            RPAD('', 32, ' ') || -- 5437-5468: :P:IDR-M-EMP-NAME
            RPAD('', 32, ' ') || -- 5469-5500: : :P:IDR-M-EMP-ADDR1
            RPAD('', 32, ' ') || -- 5501-5532: : :P:IDR-M-EMP-ADDR2
            RPAD('', 15, ' ') || -- 5533-5547: :P:IDR-M-EMP-CITY
            RPAD('', 2, ' ') || -- 5548-5549: :P:IDR-M-EMP-STATE
            RPAD('', 9, ' ') || -- 5550-5558: :P:IDR-M-EMP-ZIP
            RPAD('', 20, ' ') || -- 5559-5578: :P:IDR-M-INS-GRP-NUM
            RPAD('', 17, ' ') || -- 5579-5595: :P:IDR-M-INS-GRP-NAME
            RPAD('', 8, ' ') || -- 5596-5603: :P:IDR-M-PREPAID-H-P
            RPAD('', 2, ' ') || -- 5604-5605: :P:IDR-M-REMARK-CDE1
            RPAD('', 2, ' ') || -- 5606-5607: :P:IDR-M-REMARK-CDE2
            RPAD('', 2, ' ') || -- 5608-5609: :P:IDR-M-REMARK-CDE3
            RPAD('', 10, ' ') || -- 5610-5619: :P:IDR-M-PAYER-ID
            RPAD('', 10, ' ') || -- 5620-5629: FILLER
            RPAD('', 8, ' ') || -- 5630-5637: :P:IDR-J-PBID-ENT-DATE
            RPAD('', 8, ' ') || -- 5638-5645: :P:IDR-J-PBID-TRM-DATE
            RPAD('', 2, ' ') || -- 5646-5647: :P:IDR-J-BILL-PROV-SPEC2
            RPAD('', 2, ' ') || -- 5648-5649: :P:IDR-J-BILL-PROV-SPEC3
            RPAD('', 2, ' ') -- 5650-5651: :P:IDR-J-BILL-PROV-SPEC4
        ) AS record_content
    FROM professional_claim pc
    JOIN claim_phase cp
        ON cp.claim_id = pc.id
    JOIN claim_key ck
        ON ck.claim_id = pc.id
    JOIN mac m
        ON m.mac_id = ck.mac_id
    LEFT JOIN professional_claim_payment_response ppr
        ON ppr.claim_id = pc.id
    CROSS JOIN extract_parameters ep
    WHERE ck.mac_id IS NOT NULL
      AND pc.claim_jsonb->>'receiptDate' = TO_CHAR(ep.extract_date, 'YYYY-MM-DD')
    ),
    claim_line AS (
            SELECT
        ch.mac_id,
        ch.phase,
        'CLAIM_LINE' AS record_type,
        ch.record_sequence + ROW_NUMBER() OVER (
            PARTITION BY ch.mac_id, ch.phase, ch.claim_id
            ORDER BY (sl->>'serviceLineNumber')::int
        ) AS record_sequence,
        ch.claim_sequence,
        ROW_NUMBER() OVER (
            PARTITION BY ch.mac_id, ch.phase, ch.claim_id
            ORDER BY (sl->>'serviceLineNumber')::int
        ) AS line_sequence,
        (
            RPAD('B', 1, ' ') || -- 1-1: :P:IDR-CLM-DT-CONTR-TYPE
            LPAD(
                ROW_NUMBER() OVER (
                    PARTITION BY ch.mac_id, ch.phase, ch.claim_id
                    ORDER BY (sl->>'serviceLineNumber')::int
                )::text,
                2,
                '0'
            ) || -- 2-3: :P:IDR-CLM-DT-REC-TYPE
            LPAD('00', 2, '0') || -- 4-5: :P:IDR-CLM-HD-PLAN
            LPAD(
                COALESCE(
                    COALESCE(sl->>'internalControlNumber', pc.claim_jsonb->>'internalControlNumber'),
                    '0'
                ),
                13,
                '0'
            ) || -- 6-18: :P:IDR-CLM-DT-ICN
            LPAD(
                COALESCE(
                    COALESCE(
                        sl->>'serviceLineNumber',
                        pc.claim_jsonb->>'serviceLineNumber'
                    ),
                    '0'
                ),
                2,
                '0'
            ) || -- 19-20: :P:IDR-DTL-NUMBER
            RPAD('', 1, ' ') || -- 21-21: :P:IDR-PAY-80-PER
            RPAD('', 1, ' ') || -- 22-22: :P:IDR-CASH-DED
            RPAD('', 1, ' ') || -- 23-23: :P:IDR-BLD-DED
            RPAD('', 1, ' ') || -- 24-24: :P:IDR-PT-LIMIT
            RPAD('', 1, ' ') || -- 25-25: :P:IDR-PSYCH-LIMIT
            RPAD('', 1, ' ') || -- 26-26: :P:IDR-OT-LIMIT
            RPAD('', 1, ' ') || -- 27-27: :P:IDR-DENIED
            RPAD(' ', 1, ' ') ||  -- 28-28: :P:IDR-DTL-STATUS (No Data Value)
            LPAD(
                REPLACE(
                    COALESCE(
                        COALESCE(
                            sl->>'cmsServiceDate',
                            pc.claim_jsonb->>'cmsServiceDate'
                        ),
                        '0'
                    ),
                    '-',
                    ' '
                ),
                8,
                '0'
            ) || -- 29-36: :P:IDR-DTL-FROM-DATE
            LPAD('', 8, '0') || -- 37-44: :P:IDR-DTL-TO-DATE
            LPAD('', 2, '0') || -- 45-46: :P:IDR-TWO-DIGIT-POS (Corrected from 8 to 2)
            RPAD(
                COALESCE(
                    COALESCE(
                        sl->>'healthCareServiceLocationFacilityCode',
                        pc.claim_jsonb->>'healthCareServiceLocationFacilityCode'
                    ),
                    ' '
                ),
                1,
                ' '
            ) || -- 47-47: :P:IDR-TOS (Corrected from 2 to 1)
            RPAD(
                COALESCE(
                    COALESCE(
                        sl->>'healthcareCommonProcedureCode',
                        pc.claim_jsonb->>'healthcareCommonProcedureCode'
                    ),
                    ' '
                ),
                5,
                ' '
            ) || -- 48-52: :P:IDR-PROC-CODE (Corrected from 1 to 5)
            RPAD(
                COALESCE(
                    COALESCE(
                        sl->>'healthcareCommonProcedureCodeModifiers',
                        pc.claim_jsonb->>'healthcareCommonProcedureCodeModifiers'
                    ),
                    ' '
                ),
                2,
                ' '
            ) || -- 53-54: :P:IDR-MOD-ONE
            RPAD(
                COALESCE(
                    COALESCE(
                        sl->>'healthcareCommonProcedureCodeModifiers',
                        pc.claim_jsonb->>'healthcareCommonProcedureCodeModifiers'
                    ),
                    ' '
                ),
                2,
                ' '
            ) || -- 55-56: :P:IDR-MOD-TWO
            RPAD(
                COALESCE(
                    COALESCE(
                        sl->>'healthcareCommonProcedureCodeModifiers',
                        pc.claim_jsonb->>'healthcareCommonProcedureCodeModifiers'
                    ),
                    ' '
                ),
                2,
                ' '
            ) || -- 57-58: :P:IDR-MOD-THREE
            RPAD(
                COALESCE(
                    COALESCE(
                        sl->>'healthcareCommonProcedureCodeModifiers',
                        pc.claim_jsonb->>'healthcareCommonProcedureCodeModifiers'
                    ),
                    ' '
                ),
                2,
                ' '
            ) || -- 59-60: :P:IDR-MOD-FOUR
            RPAD('', 1, ' ') || -- 61-61: :P:IDR-INC-DUPE (Corrected from 2 to 1)
            RPAD('', 1, ' ') || -- 62-62: :P:IDR-DME-PATH-DET
            RPAD('', 1, ' ') || -- 63-63: :P:IDR-PEER-REVIEW
            LPAD('', 5, '0') || -- 64-68: :P:IDR-SERV-BILLED (Corrected from 1 to 5)
            LPAD('', 5, '0') || -- 69-73: :P:IDR-SERV-ALLOW
            LPAD('', 7, '0') || -- 74-80: :P:IDR-DTL-BILLED (Corrected from 5 to 7)
            LPAD(
                COALESCE(
                    COALESCE(
                        sl->>'billedAmount',
                        pc.claim_jsonb->>'billedAmount'
                    ),
                    '0'
                ),
                7,
                '0'
            ) || -- 81-87: :P:IDR-DTL-ALLOWED
            LPAD(
                COALESCE(
                    COALESCE(
                        sl->>'allowedAmount',
                        pc.claim_jsonb->>'allowedAmount'
                    ),
                    '0'
                ),
                7,
                '0'
            ) || -- 88-94: :P:IDR-DTL-PAID
            RPAD('', 1, ' ') || -- 95-95: :P:IDR-PRICE-FLAG (Corrected: Was mapping 7-digit amount to 1-byte flag)
            RPAD('', 7, ' ') || -- 96-102: :P:IDR-DTL-LVL1-PROF (Corrected from 1 to 7)
            LPAD('', 7, '0') || -- 103-109: :P:IDR-DTL-LVL2-PROF
            LPAD('', 7, '0') || -- 110-116: :P:IDR-DTL-LVL3-PROF
            LPAD('', 1, '0') || -- 117-117: :P:IDR-DTL-PROF-IND (Corrected from 7 to 1)
            LPAD('', 4, '0') || -- 118-121: :P:IDR-RREL-VAL-UNITS (Corrected from 1 to 4)
            RPAD('', 3, ' ') || -- 122-124: :P:IDR-DTL-NONCOV-MSG (Corrected from 4 to 3)
            RPAD('', 3, ' ') || -- 125-127: :P:IDR-DTL-NONCOV-AUD
            LPAD('', 1, '0') || -- 128-128: :P:IDR-DTL-NONC-AUD-IND (Corrected from 3 to 1)
            RPAD('', 1, ' ') || -- 129-129: :P:IDR-PAR-NONPAR
            RPAD('', 1, ' ') || -- 130-130: :P:IDR-PROC-FLAGS-A
            RPAD('', 1, ' ') || -- 131-131: :P:IDR-PROC-FLAGS-B
            RPAD('', 1, ' ') || -- 132-132: :P:IDR-PROC-FLAGS-C
            RPAD('', 1, ' ') || -- 133-133: :P:IDR-PROC-FLAGS-D
            RPAD('', 1, ' ') || -- 134-134: :P:IDR-PROC-FLAGS-E
            RPAD('', 1, ' ') || -- 135-135: :P:IDR-PROC-FLAGS-F
            RPAD('', 1, ' ') || -- 136-136: :P:IDR-PROC-FLAGS-G
            RPAD('', 1, ' ') || -- 137-137: :P:IDR-PROC-FLAGS-H
            RPAD('', 1, ' ') || -- 138-138: :P:IDR-PROC-FLAGS-I
            RPAD('', 1, ' ') || -- 139-139: :P:IDR-PROC-FLAGS-J
            RPAD('', 1, ' ') || -- 140-140: :P:IDR-PROC-FLAGS-K
            RPAD('', 1, ' ') || -- 141-141: :P:IDR-PROC-FLAGS-L
            RPAD('', 1, ' ') || -- 142-142: :P:IDR-PROC-FLAGS-M
            RPAD('', 1, ' ') || -- 143-143: :P:IDR-PROC-FLAGS-N
            RPAD('', 1, ' ') || -- 144-144: :P:IDR-PROC-FLAGS-O
            RPAD('', 1, ' ') || -- 145-145: :P:IDR-PROC-FLAGS-P
            RPAD('', 1, ' ') || -- 146-146: :P:IDR-PROC-FLAGS-Q
            RPAD('', 1, ' ') || -- 147-147: :P:IDR-PROC-FLAGS-R
            RPAD('', 1, ' ') || -- 148-148: :P:IDR-PROC-FLAGS-S
            RPAD('', 1, ' ') || -- 149-149: :P:IDR-PROC-FLAGS-T
            RPAD('', 1, ' ') || -- 150-150: :P:IDR-PROC-FLAGS-U
            RPAD('', 1, ' ') || -- 151-151: :P:IDR-PROC-FLAGS-V
            RPAD('', 1, ' ') || -- 152-152: :P:IDR-PROC-FLAGS-W
            RPAD('', 1, ' ') || -- 153-153: :P:IDR-PROC-FLAGS-X
            RPAD('', 1, ' ') || -- 154-154: :P:IDR-PROC-FLAGS-Y
            RPAD('', 1, ' ') || -- 155-155: :P:IDR-PROC-FLAGS-Z
            RPAD('', 1, ' ') || -- 156-156: :P:IDR-PROC-FLAGS-0
            RPAD('', 1, ' ') || -- 157-157: :P:IDR-PROC-FLAGS-1
            RPAD('', 1, ' ') || -- 158-158: :P:IDR-PROC-FLAGS-2
            RPAD('', 1, ' ') || -- 159-159: :P:IDR-PROC-FLAGS-3
            RPAD('', 1, ' ') || -- 160-160: :P:IDR-PROC-FLAGS-4
            RPAD('', 1, ' ') || -- 161-161: :P:IDR-PROC-FLAGS-5
            RPAD('', 1, ' ') || -- 162-162: :P:IDR-PROC-FLAGS-6
            RPAD('', 1, ' ') || -- 163-163: :P:IDR-PROC-FLAGS-7
            RPAD('', 1, ' ') || -- 164-164: :P:IDR-PROC-FLAGS-8
            RPAD('', 1, ' ') || -- 165-165: :P:IDR-PROC-FLAGS-9
            RPAD('', 1, ' ') || -- 166-166: :P:IDR-PROC-FLAGS-PLUS
            RPAD('', 1, ' ') || -- 167-167: :P:IDR-PROC-FLAGS-MINUS
            RPAD('', 1, ' ') || -- 168-168: :P:IDR-PROC-FLAGS-EQUAL
            RPAD('', 1, ' ') || -- 169-169: :P:IDR-PROC-FLAGS-STAR
            RPAD('', 1, ' ') || -- 170-170: :P:IDR-PAY-75-PER
            RPAD('', 2, ' ') || -- 171-172: :P:IDR-PERF-PROV-STATE
            LPAD('', 9, '0') || -- 173-181: :P:IDR-PERF-PROV-ZIP-CD
            RPAD('', 10, ' ') || -- 182-191: :P:IDR-PERF-PROV
            RPAD('', 10, ' ') || -- 192-201: :P:IDR-PERF-PROV-EIN
            RPAD('', 2, ' ') || -- 202-203: :P:IDR-PERF-PROV-TYPE
            RPAD('', 2, ' ') || -- 204-205: :P:IDR-PERF-PROV-SPEC
            RPAD('', 1, ' ') || -- 206-206: :P:IDR-PERF-PROV-GROUP
            RPAD('', 2, ' ') || -- 207-208: :P:IDR-PERF-PRICE-SPEC
            RPAD('', 2, ' ') || -- 209-210: :P:IDR-PERF-COUNTY
            RPAD(
                CASE
                    WHEN (pc.claim_jsonb->>'isParticipatingProvider')::boolean IS TRUE
                        THEN 'P'
                    ELSE 'N'
                END,
                1,
                ' '
            ) || -- 211-211: :P:IDR-PERF-PROV-ST
            RPAD('', 2, ' ') || -- 212-213: :P:IDR-PERF-PROV-LOC
            RPAD(
                CASE
                    WHEN COALESCE(
                            pc.claim_jsonb->'diagnosisCodes'->>0,
                            sl->'diagnosisCodes'->>0
                        ) IS NULL THEN ' '
                    WHEN COALESCE(
                            pc.claim_jsonb->'diagnosisCodes'->>0
                        ) ~ '^[A-TV-Z]' THEN '0'   -- ICD-10
                    ELSE '9'                      -- ICD-9
                END,
                1,
                ' '
            ) || -- 214-214: :P:IDR-DTL-DIAG-ICD-TYPE
            RPAD(
                COALESCE(
                    pc.claim_jsonb->'diagnosisCodes'->>0,
                    ' '
                ),
                7,
                ' '
            ) || -- 215-221: :P:IDR-DTL-PRIMARY-DIAG-CODE
            LPAD('', 3, '0') || -- 222-224: :P:IDR-PRE-CARE-DAYS
            LPAD('', 3, '0') || -- 225-227: :P:IDR-POST-CARE-DAYS
            RPAD('', 1, ' ') || -- 228-228: :P:PROCEDURE-STAT-CODE
            RPAD('', 1, ' ') || -- 229-229: :P:PROF-TECH-COMPONENT
            RPAD('', 1, ' ') || -- 230-230: :P:MULTIPLE-SURGERY-IND
            RPAD('', 1, ' ') || -- 231-231: :P:BILATERAL-SURG-IND
            RPAD('', 1, ' ') || -- 232-232: :P:ASSISTANT-SURG-IND
            RPAD('', 1, ' ') || -- 233-233: :P:TWO-SURGERY-IND
            RPAD('', 1, ' ') || -- 234-234: :P:TEAM-SURGERY-IND
            RPAD('', 1, ' ') || -- 235-235: :P:BILLABLE-SUPPLY-IND
            RPAD('', 1, ' ') || -- 236-236: :P:SITE-OF-SERVICE-DIFF
            RPAD('', 3, ' ') || -- 237-239: :P:GLOBAL-SURGERY-DAYS
            RPAD('', 1, ' ') || -- 240-240: :P:PAYABLE-UNITS-IND
            RPAD('', 1, ' ') || -- 241-241: :P:IMAGING-CAP-IND
            RPAD('', 1, ' ') || -- 242-242: :P:IDR-PAC-CODE
            RPAD('', 3, ' ') || -- 243-245: :P:IDR-DTL-EOMB-MSG2
            RPAD('', 3, ' ') || -- 246-248: :P:IDR-DTL-EOMB-MSG3
            RPAD('', 15, ' ') || -- 249-263: :P:IDR-DUPE-ICN
            LPAD('', 8, '0') || -- 264-271: :P:IDR-DUPE-PAID-DT
            LPAD('', 9, '0') || -- 272-280: :P:IDR-DUPE-EXCHK-NUM
            RPAD('', 1, ' ') || -- 281-281: :P:IDR-DUPE-IND
            LPAD('', 7, '0') || -- 282-288: :P:IDR-DTL-HPSA-PYMT
            RPAD('', 1, ' ') || -- 289-289: :P:IDR-DTL-REND-PROV-FLAG
            RPAD('', 1, ' ') || -- 290-290: :P:IDR-DTL-PRICE-IN
            RPAD('', 5, ' ') || -- 291-295: FILLER
            RPAD('', 5, ' ') || -- 296-300: :P:IDR-ORIG-PROC
            RPAD('', 5, ' ') || -- 301-305: :P:IDR-SUBSEQ-PROC
            LPAD(
                COALESCE(
                    COALESCE(
                        sl->>'paidToProviderAmount',
                        pc.claim_jsonb->>'paidToProviderAmount'
                    ),
                    '0'
                ),
                7,
                '0'
            ) || -- 306-312: :P:IDR-DTL-PROV-PAID
            LPAD(
                COALESCE(
                    COALESCE(
                        sl->>'paidToBeneficiaryAmount',
                        pc.claim_jsonb->>'paidToBeneficiaryAmount'
                    ),
                    '0'
                ),
                7,
                '0'
            ) || -- 313-319: :P:IDR-DTL-BENE-PAID
            LPAD('', 1, '0') || -- 320-320: :P:IDR-DTL-BLOOD-DED
            LPAD(
                COALESCE(
                    COALESCE(
                        sl->>'appliedToDeductibleAmount',
                        pc.claim_jsonb->>'appliedToDeductibleAmount'
                    ),
                    '0'
                ),
                5,
                '0'
            ) || -- 321-325: :P:IDR-DTL-REG-DED
            LPAD('', 7, '0') || -- 326-332: :P:IDR-DTL-PSYCH-DED
            LPAD('', 7, '0') || -- 333-339: :P:IDR-DTL-PHY-THER-DED
            LPAD('', 7, '0') || -- 340-346: :P:IDR-DTL-OCC-THER-DED
            RPAD('', 2, ' ') || -- 347-348: :P:IDR-DTL-MSP-TYPE
            LPAD('', 7, '0') || -- 349-355: :P:IDR-DTL-MSP-ALLOW
            LPAD('', 7, '0') || -- 356-362: :P:IDR-DTL-MSP-PAID
            LPAD('', 7, '0') || -- 363-369: :P:IDR-DTL-CPT-INT
            LPAD('', 7, '0') || -- 370-376: :P:IDR-DTL-HPSA-P-CMPT
            LPAD('', 7, '0') || -- 377-383: :P:IDR-DTL-COINS
            LPAD(
                COALESCE(
                    COALESCE(
                        sl->>'coinsuranceAmount',
                        pc.claim_jsonb->>'coinsuranceAmount'
                    ),
                    '0'
                ),
                7,
                '0'
            ) || -- 384-390: :P:IDR-DTL-MSP-CUTBACK
            LPAD(
                COALESCE(
                    COALESCE(
                        sl->>'cutbackAmounts',
                        pc.claim_jsonb->>'cutbackAmounts'
                    ),
                    '0'
                ),
                7,
                '0'
            ) || -- 391-397: :P:IDR-DTL-LATE-RED
            RPAD(
                COALESCE(
                    COALESCE(
                        sl->>'renderingProviderNpi',
                        pc.claim_jsonb->>'renderingProviderNpi'
                    ),
                    ''
                ),
                10,
                ' '
            ) || -- 398-407: :P:IDR-DTL-REND-NPI
            RPAD(
                COALESCE(
                    COALESCE(
                        sl->>'renderingProviderPtan',
                        pc.claim_jsonb->>'renderingProviderPtan'
                    ),
                    ''
                ),
                10,
                ' '
            ) || -- 408-417: :P:IDR-DTL-REND-PROV
            RPAD('', 6, ' ') || -- 418-423: :P:IDR-DTL-REND-UPIN
            RPAD('', 2, ' ') || -- 424-425: :P:IDR-DTL-REND-TYPE
            RPAD(
                COALESCE(
                    COALESCE(
                        sl->>'renderingProviderSpecialtyCode',
                        pc.claim_jsonb->>'renderingProviderSpecialtyCode'
                    ),
                    ''
                ),
                2,
                ' '
            ) || -- 426-427: :P:IDR-DTL-REND-SPEC
            LPAD('', 7, '0') || -- 428-434: :P:IDR-DEMO-CUTBACK
            LPAD('', 7, '0') || -- 435-441: :P:IDR-DTL-ORIG-ALLOW
            LPAD('', 7, '0') || -- 442-448: :P:IDR-DTL-REAS-AMT
            RPAD('', 5, ' ') || -- 449-453: :P:IDR-ENDO-PROC
            LPAD('', 7, '0') || -- 454-460: :P:IDR-ENDO-FEE
            RPAD('', 1, ' ') || -- 461-461: :P:IDR-DTL-DIAG-POINTER
            RPAD('', 1, ' ') || -- 462-462: :P:IDR-DTL-DIAG-POINTER
            RPAD('', 1, ' ') || -- 463-463: :P:IDR-DTL-DIAG-POINTER
            RPAD('', 1, ' ') || -- 464-464: :P:IDR-DTL-DIAG-POINTER
            RPAD('', 1, ' ') || -- 465-465: :P:IDR-ASC-PROC-IND
            RPAD('', 1, ' ') || -- 466-466: :P:IDR-ASC-COINS-IND
            RPAD('', 1, ' ') || -- 467-467: :P:IDR-ASC-MULT-PROC
            RPAD('', 1, ' ') || -- 468-468: :P:IDR-ASC-MOD-IND
            RPAD('', 1, ' ') || -- 469-469: :P:IDR-DTL-PCIP-ELIG
            LPAD('', 9, '0') || -- 470-478: :P:IDR-DTL-PCIP-AMT
            RPAD('', 1, ' ') || -- 479-479: :P:IDR-DTL-HSIP-ELIG
            LPAD('', 9, '0') || -- 480-488: :P:IDR-DTL-HSIP-AMT
            LPAD('', 9, '0') || -- 489-497: :P:IDR-DTL-NON-FAC-RTF
            LPAD('', 9, '0') || -- 498-506: :P:IDR-DTL-NON-FAC-RVU
            RPAD('', 1, ' ') || -- 507-507: :P:IDR-DTL-FL2-FEE-REDCT
            RPAD('', 50, ' ') || -- 508-557: :P:IDR-DTL-RND-TAXONOMY
            RPAD('', 48, ' ') || -- 558-605: :P:IDR-DTL-NDC
            LPAD('', 15, '0') || -- 606-620: :P:IDR-DTL-NDC-UNIT-COUNT
            RPAD('', 2, ' ') || -- 621-622: :P:IDR-DTL-BASIS-FOR-MSMT
            RPAD('', 1, ' ') || -- 623-623: :P: IDR-DTL-REND-GRP-FLAG
            RPAD('', 4, ' ') || -- 624-627: :P:IDR-DTL-PIONEER-ACO-ID
            LPAD('', 3, '0') || -- 628-630: :P-IDR-DTL-PIONEER-PERCENT-ACO-PERCENT
            RPAD('', 14, ' ') || -- 631-644: :P:IDR-K-PRIOR-AUTH-UTN
            RPAD('', 4, ' ') || -- 645-648: :P:IDR-K-PA-PROGRAM-ID
            LPAD('', 4, '0') || -- 649-652: :P:IDR-DTL-PHASE-SEQ-NUM
            RPAD('', 5, ' ') || -- 653-657: :P:IDR-DTL-MOLECULAR-TEST-ID
            RPAD('', 10, ' ') || -- 658-667: :P:IDR-DTL-ACO-MODEL-ID
            RPAD('', 5, ' ') || -- 668-672: :P:IDR-DTL-ACO-MODEL-FLAGS
            LPAD('', 3, '0') || -- 673-675: :P:IDR-DTL-ACO-MODEL-PERCENT
            RPAD('', 1, ' ') || -- 676-676: :P:IDR-K-PA-PROGRAM-REP-PAY
            RPAD('', 3, ' ') || -- 677-679: :P:IDR-K-PRIOR-AUTH-PCT
            RPAD('', 4, ' ') || -- 680-683: FILLER
            RPAD('', 1, ' ') || -- 684-684: :P:IDR-K-MAN-PRICE-IND
            RPAD('', 1, ' ') || -- 685-685: :P:IDR-K-CUTB-ACTION-CD
            LPAD('', 3, '0') || -- 686-688: :P:IDR-K-CMP-CUTBK-CD
            RPAD('', 1, ' ') || -- 689-689: :P:IDR-K-CMP-CUTBK-IND
            LPAD('', 7, '0') || -- 690-696: :P:IDR-K-CMP-CUTBK-AMT
            RPAD('', 1, ' ') || -- 697-697: :P:IDR-K-MAN-CUTBK-TYP
            LPAD('', 3, '0') || -- 698-700: :P:IDR-K-MAN-CUTBK-CD
            RPAD('', 1, ' ') || -- 701-701: :P:IDR-K-MAN-CUTBK-IND
            LPAD('', 7, '0') || -- 702-708: :P:IDR-K-MAN-CUTBK-AMT
            RPAD('', 1, ' ') || -- 709-709: :P:IDR-K-PRC-CUTBK-TYP
            LPAD('', 3, '0') || -- 710-712: :P:IDR-K-PRC-CUTBK-CD
            RPAD('', 1, ' ') || -- 713-713: :P:IDR-K-PRC-CUTBK-IND
            LPAD('', 7, '0') || -- 714-720: :P:IDR-K-PRC-CUTBK-AMT
            LPAD('', 3, '0') || -- 721-723: :P:IDR-K-SSA-CUTBK-CD
            RPAD('', 1, ' ') || -- 724-724: :P:IDR-K-SSA-CUTBK-IND
            LPAD('', 7, '0') || -- 725-731: :P:IDR-K-SSA-CUTBK-AMT
            RPAD('', 3, ' ') || -- 732-734: :P:IDR-K-MSRG-CUTBK-CD
            RPAD('', 1, ' ') || -- 735-735: :P:IDR-K-MSRG-CUTBK-IND
            LPAD('', 7, '0') || -- 736-742: :P:IDR-K-MSRG-CUTBK-AMT
            LPAD('', 3, '0') || -- 743-745: :P:IDR-K-AUDIT-NUM
            RPAD('', 1, ' ') || -- 746-746: :P:IDR-K-AUDIT-IND
            RPAD('', 1, ' ') || -- 747-747: :P:IDR-K-AUDIT-DISP
            LPAD('', 3, '0') || -- 748-750: :P:IDR-K-AUDIT-NUM
            RPAD('', 1, ' ') || -- 751-751: :P:IDR-K-AUDIT-IND
            RPAD('', 1, ' ') || -- 752-752: :P:IDR-K-AUDIT-DISP
            LPAD('', 3, '0') || -- 753-755: :P:IDR-K-AUDIT-NUM
            RPAD('', 1, ' ') || -- 756-756: :P:IDR-K-AUDIT-IND
            RPAD('', 1, ' ') || -- 757-757: :P:IDR-K-AUDIT-DISP
            LPAD('', 3, '0') || -- 758-760: :P:IDR-K-AUDIT-NUM
            RPAD('', 1, ' ') || -- 761-761: :P:IDR-K-AUDIT-IND
            RPAD('', 1, ' ') || -- 762-762: :P:IDR-K-AUDIT-DISP
            LPAD('', 3, '0') || -- 763-765: :P:IDR-K-AUDIT-NUM
            RPAD('', 1, ' ') || -- 766-766: :P:IDR-K-AUDIT-IND
            RPAD('', 1, ' ') || -- 767-767: :P:IDR-K-AUDIT-DISP
            LPAD('', 3, '0') || -- 768-770: :P:IDR-K-AUDIT-NUM
            RPAD('', 1, ' ') || -- 771-771: :P:IDR-K-AUDIT-IND
            RPAD('', 1, ' ') || -- 772-772: :P:IDR-K-AUDIT-DISP
            LPAD('', 3, '0') || -- 773-775: :P:IDR-K-AUDIT-NUM
            RPAD('', 1, ' ') || -- 776-776: :P:IDR-K-AUDIT-IND
            RPAD('', 1, ' ') || -- 777-777: :P:IDR-K-AUDIT-DISP
            LPAD('', 3, '0') || -- 778-780: :P:IDR-K-AUDIT-NUM
            RPAD('', 1, ' ') || -- 781-781: :P:IDR-K-AUDIT-IND
            RPAD('', 1, ' ') || -- 782-782: :P:IDR-K-AUDIT-DISP
            LPAD('', 3, '0') || -- 783-785: :P:IDR-K-AUDIT-NUM
            RPAD('', 1, ' ') || -- 786-786: :P:IDR-K-AUDIT-IND
            RPAD('', 1, ' ') || -- 787-787: :P:IDR-K-AUDIT-DISP
            LPAD('', 3, '0') || -- 788-790: :P:IDR-K-AUDIT-NUM
            RPAD('', 1, ' ') || -- 791-791: :P:IDR-K-AUDIT-IND
            RPAD('', 1, ' ') || -- 792-792: :P:IDR-K-AUDIT-DISP
            LPAD('', 3, '0') || -- 793-795: :P:IDR-K-AUDIT-NUM
            RPAD('', 1, ' ') || -- 796-796: :P:IDR-K-AUDIT-IND
            RPAD('', 1, ' ') || -- 797-797: :P:IDR-K-AUDIT-DISP
            LPAD('', 3, '0') || -- 798-800: :P:IDR-K-AUDIT-NUM
            RPAD('', 1, ' ') || -- 801-801: :P:IDR-K-AUDIT-IND
            RPAD('', 1, ' ') || -- 802-802: :P:IDR-K-AUDIT-DISP
            RPAD('', 4, ' ') || -- 803-806: :P:IDR-K-MPA-OVERRIDE-CODES
            LPAD('', 3, '0') || -- 807-809: :P:IDR-K-MPA-OVR-AUDIT
            RPAD('', 1, ' ') || -- 810-810: :P:IDR-K-MPA-OVR-IND
            RPAD('', 4, ' ') || -- 811-814: :P:IDRK-GDX-RULE-NUM
            LPAD('', 8, '0') || -- 815-822: :P:IDR-K-GDX-RULE-DATE
            RPAD('', 4, ' ') || -- 823-826: :P:IDR-K-GDX-RULE-NUM
            LPAD('', 8, '0') || -- 827-834: :P:IDR-K-GDX-RULE-DATE
            RPAD('', 4, ' ') || -- 835-838: :P:IDR-K-GDX-RULE-NUM
            LPAD('', 8, '0') || -- 839-846: :P:IDR-K-GDX-RULE-DATE
            RPAD('', 4, ' ') || -- 847-850: :P:IDR-K-GDX-RULE-NUM
            LPAD('', 8, '0') || -- 851-858: :P:IDR-K-GDX-RULE-DATE
            RPAD('', 4, ' ') || -- 859-862: :P:IDR-K-GDX-RULE-NUM
            LPAD('', 8, '0') || -- 863-870: :P:IDR-K-GDX-RULE-DATE
            RPAD('', 4, ' ') || -- 871-874: :P:IDR-K-GDX-RULE-NUM
            LPAD('', 8, '0') || -- 875-882: :P:IDR-K-GDX-RULE-DATE
            LPAD('', 7, '0') || -- 883-889: :P:IDR-K-DTL-OTAF
            RPAD('', 3, ' ') || -- 890-892: :P:IDR-K-CUTB-MSG
            RPAD('', 3, ' ') || -- 893-895: :P:IDR-K-PR-CUTB-MSG
            RPAD('', 3, ' ') || -- 896-898: :P:IDR-K-MAN-CUTB-MSG
            RPAD('', 1, ' ') || -- 899-899: :P:IDR-K-MSP-CALC-TYP
            RPAD('', 5, ' ') || -- 900-904: :P:IDR-K-REBUN-PROC
            RPAD('', 2, ' ') || -- 905-906: :P:IDR-K-REBUN-MOD1
            RPAD('', 2, ' ') || -- 907-908: :P:IDR-K-REBUN-MOD2
            RPAD('', 1, ' ') || -- 909-909: :P:IDR-K-REBUN-AUD-FLG
            RPAD('', 1, ' ') || -- 910-910: :P:IDR-K-DEB-IND
            RPAD('', 10, ' ') || -- 911-920: :P:IDR-K-CLIA-NUM
            RPAD(
                COALESCE(
                    COALESCE(
                        sl->>'providerServiceLineId',
                        pc.claim_jsonb->>'providerServiceLineId'
                    ),
                    ''
                ),
                17,
                ' '
            ) || -- 921-937: :P:IDR-K-LN-ITEM-CTL-N
            LPAD('', 7, '0') || -- 938-944: :P:IDR-K-PROV-PREV-PD
            LPAD('', 7, '0') || -- 945-951: :P:IDR-K-BENE-PREV-PD
            LPAD('', 7, '0') || -- 952-958: :P:IDR-K-INT-PREV-PD
            LPAD('', 7, '0') || -- 959-965: :P:IDR-K-LTFL-PREV-PD
            LPAD('', 3, '0') || -- 966-968: :P:IDR-K-ORIG-REPT-AUD
            RPAD('', 1, ' ') || -- 969-969: :P:IDR-K-ORIG-REPT-IND
            RPAD('', 1, ' ') || -- 970-970: :P:IDR-K-ORG-REPT-AUD-D
            RPAD('', 1, ' ') || -- 971-971: :P:IDR-K-ORG-REPT-AUD-C
            RPAD('', 1, ' ') || -- 972-972: :P:IDR-K-LIMIT-CHRG-ADJ
            RPAD('', 2, ' ') || -- 973-974: :P:IDR-K-ADJ-ORIG-DTL
            RPAD('', 30, ' ') || -- 975-1004: :P:IDR-K-PRESCRIPTION-NUM
            LPAD('', 9, '0') || -- 1005-1013: :P:IDR-K-IMAGING-CAP-AMOUNT
            RPAD('', 1, ' ') || -- 1014-1014: :P:IDR-K-VOL-SVC-IND
            RPAD('', 8, ' ') || -- 1015-1022: FILLER
            LPAD('', 3, '0') || -- 1023-1025: :P:IDR-K-HCT-LEVEL
            LPAD('', 3, '0') || -- 1026-1028: :P:IDR-K-HGB-LEVEL
            RPAD('', 7, ' ') || -- 1029-1035: FILLER
            LPAD('', 1, '0') || -- 1036-1036: :P:IDR-K-DTL-MSP-ACTION-CODE
            RPAD('', 15, ' ') || -- 1037-1051: :P:INT-K-IG-NUM-1
            RPAD('', 5, ' ') || -- 1052-1056: :P:INT-K-IG-NUM-2
            RPAD('', 2, ' ') || -- 1057-1058: :P:IDR-K-PATIENT-COUNT
            RPAD('', 2, ' ') || -- 1059-1060: :P:IDR-K-PWK-COUNT
            RPAD('', 3, ' ') || -- 1061-1063: :P:IDR-K-NEG-PAY-ADJ-MSG
            LPAD('', 3, '0') || -- 1064-1066: :P:IDR-K-NEG-PAY-ADJ-AUD
            RPAD('', 1, ' ') || -- 1067-1067: :P:IDR-K-NEG-PAY-AUD-IND
            LPAD('', 9, '0') || -- 1068-1076: :P:IDR-K-NEG-PAY-ADJ-AMT
            LPAD('', 9, '0') || -- 1077-1085: :P:IDR-K-OTHER-PAT-RESP
            LPAD('', 9, '0') || -- 1086-1094: :P:IDR-K-TOTAL-PAT-RESP
            LPAD('', 13, '0') || -- 1095-1107: :P:IDR-K-AUDIT-ICN
            RPAD('', 1, ' ') || -- 1108-1108: :P:INT-K-MOD-PRICING-FLAGG
            RPAD(
                COALESCE(
                    COALESCE(
                        sl->>'serviceFacilityLocationLastOrOrganizationName',
                        pc.claim_jsonb->>'serviceFacilityLocationLastOrOrganizationName'
                    ),
                    ''
                ),
                60,
                ' '
            ) || -- 1109-1168: :P:IDR-K-POS-LNAME-ORG
            RPAD('', 35, ' ') || -- 1169-1203: :P:IDR-K-POS-FNAME
            RPAD('', 25, ' ') || -- 1204-1228: :P:IDR-K-POS-MNAME
            RPAD(
                COALESCE(
                    COALESCE(
                        sl->>'serviceFacilityLocationAddressLine1',
                        pc.claim_jsonb->>'serviceFacilityLocationAddressLine1'
                    ),
                    ''
                ),
                55,
                ' '
            ) || -- 1229-1283: :P:IDR-K-POS-ADDR1
            RPAD('', 55, ' ') ||    -- 1284-1338: :P:IDR-K-POS-ADDR2
            RPAD(
                COALESCE(
                    COALESCE(
                        sl->>'serviceFacilityLocationCity',
                        pc.claim_jsonb->>'serviceFacilityLocationCity'
                    ),
                    ''
                ),
                30,
                ' '
            ) || -- 1339-1368: :P:IDR-K-POS-CITY
            RPAD(
                COALESCE(
                    COALESCE(
                        sl->>'serviceFacilityLocationState',
                        pc.claim_jsonb->>'serviceFacilityLocationState'
                    ),
                    ''
                ),
                2,
                ' '
            ) || -- 1369-1370: :P:IDR-K-POS-STATE
            RPAD(
                COALESCE(
                    COALESCE(
                        sl->>'serviceFacilityLocationZipCode',
                        pc.claim_jsonb->>'serviceFacilityLocationZipCode'
                    ),
                    ''
                ),
                15,
                ' '
            ) || -- 1371-1385: :P:IDR-K-POS-ZIP
            RPAD('', 3, ' ') || -- 1386-1388: :P:IDR-K-LEG-RED-MSG
            LPAD('', 9, '0') || -- 1389-1391: :P:IDR-K-LEG-RED-AUD
            LPAD('', 1, '0') || -- 1392-1392: :P:IDR-K-LEG-RED-SUF
            LPAD('', 9, '0') || -- 1393-1401: :P:IDR-K-LEG-RED-AMT
            LPAD('', 1, ' ') || -- 1402-1402: :P:IDR-K-LEGIS-EFF-IND-1
            RPAD('', 1, ' ') || -- 1403-1403: :P:IDR-K-LEGIS-EFF-IND-2
            RPAD('', 1, ' ') || -- 1404-1404: :P:IDR-K-LEGIS-EFF-IND-3
            RPAD('', 1, ' ') || -- 1405-1405: :P:IDR-K-LEGIS-EFF-IND-4
            RPAD('', 1, ' ') || -- 1406-1406: :P:IDR-K-LEGIS-EFF-IND-5
            LPAD('', 9, '0') || -- 1407-1415: :P:IDR-K-TECH-COMP-FEE2
            LPAD('', 9, '0') || -- 1416-1424: :P:IDR-K-TECH-COMP-FEE3
            LPAD('', 9, '0') || -- 1425-1433: :P:IDR-K-TECH-COMP-FEE4
            LPAD('', 9, '0') || -- 1434-1442: :P:IDR-K-TECH-COMP-CAP2
            LPAD('', 9, '0') || -- 1443-1451: :P:IDR-K-TECH-COMP-CAP3
            LPAD('', 9, '0') || -- 1452-1460: :P:IDR-K-TECH-COMP-CAP4
            RPAD('', 2, ' ') ||	-- 1461-1462: :P:IDR-K-FPS-MODEL
            RPAD('', 3, ' ') ||	-- 1463-1465: :P:IDR-K-FPS-CARC
            RPAD('', 5, ' ') ||	-- 1466-1470: :P:IDR-K-FPS-RARC
            RPAD('', 5, ' ') ||	-- 1471-1475: :P:IDR-K-FPS-MSN-1
            RPAD('', 5, ' ') ||	-- 1476-1480: :P:IDR-K-FPS-MSN-2
            RPAD('', 1, ' ') ||	-- 1481-1481: :P:IDR-K-ANTI-MARKUP-FLG
            LPAD('', 9, '0') ||	-- 1482-1490: :P:IDR-K-ACQUIS-AMT
            RPAD('', 80, ' ') || -- 1491-1570: :P:IDR-K-PROC-DESC
            LPAD('', 9, '0') ||	-- 1571-1579: :P:IDR-K-ASC-CUTBK-AMT
            LPAD('', 3, '0') ||	-- 1580-1582: :P:IDR-K-ASC-AUDIT
            RPAD('', 1, ' ') ||	-- 1583-1583: :P:IDR-K-ASC-AUDIT-SUF
            LPAD('', 3, '0') ||	-- 1584-1586: :P:IDR-K-ACO-CUT-CD
            RPAD('', 1, ' ') ||	-- 1587-1587: :P-IDR-K-ACO-CUT-SUF
            LPAD('', 9, '0') ||	-- 1588-1596: :P-IDR-K-ACO-CUT-AMT
            RPAD('', 3, ' ') ||	-- 1597-1599: :P-IDR-K-ACO-CUT-MSG
            LPAD('', 9, '0') ||	-- 1600-1608: :P:IDR-K-PAID-WO-ACO
            LPAD('', 3, '0') ||	-- 1609-1611: :P:IDR-K-FEH-CUT-CD
            RPAD('', 1, ' ') ||	-- 1612-1612: :P:IDR-K-FEH-CUT-SUF
            RPAD('', 3, ' ') ||	-- 1613-1615: :P:IDR-K-FEH-CUT-MSG
            LPAD('', 3, '0') ||	-- 1616-1618: :P:IDR-K-MEH-CUT-CD
            RPAD('', 1, ' ') ||	-- 1619-1619: :P:IDR-K-MEH-CUT-SUF
            RPAD('', 3, ' ') ||	-- 1620-1622: :P:IDR-K-MEH-CUT-MSG
            LPAD('', 3, '0') ||	-- 1623-1625: :P:IDR-K-FPQ-CUT-CD
            RPAD('', 1, ' ') ||	-- 1626-1626: :P:IDR-K-FPQ-CUT-SUF
            RPAD('', 3, ' ') ||	-- 1627-1629: :P:IDR-K-FPQ-CUT-MSG
            LPAD('', 3, '0') ||	-- 1630-1632: :P:IDR-K-MPQ-CUT-CD
            RPAD('', 1, ' ') ||	-- 1633-1633: :P:IDR-K-MPQ-CUT-SUF
            RPAD('', 3, ' ') ||	-- 1634-1636: :P:IDR-K-MPQ-CUT-MSG
            LPAD('', 3, '0') ||	-- 1637-1639: :P:IDR-K-VBM-CUT-CD
            RPAD('', 1, ' ') ||	-- 1640-1640: :P:IDR-K-VBM-CUT-SUF
            RPAD('', 3, ' ') ||	-- 1641-1643: :P:IDR-K-VBM-CUT-MSG
            LPAD('', 9, '0') ||	-- 1644-1652: :P:IDR-K-VBM-PERCENT
            LPAD('', 3, '0') ||	-- 1653-1655: :P:IDR-K-ETC-CUT-CD
            RPAD('', 1, ' ') ||	-- 1656-1656: :P:IDR-K-ETC-CUT-SUF
            RPAD('', 3, ' ') ||	-- 1657-1659: :P:IDR-K-ETC-CUT-MSG
            RPAD('', 4, ' ') ||	-- 1660-1663: :P:IDR-K-EXEMP-PROG-ID
            RPAD('', 3, ' ') ||	-- 1664-1666: :P:IDR-K-HEA-CUT-CD
            RPAD('', 1, ' ') ||	-- 1667-1667: :P:IDR-K-HEA-CUT-SUF
            LPAD('', 9, '0') ||	-- 1668-1676: :P:IDR-K-HEA-CUT-AMT
            RPAD('', 3, ' ') ||	-- 1677-1679: :P:IDR-K-HEA-CUT-MSG
            LPAD('', 9, '0') ||	-- 1680-1688: :P:IDR-K-HEA-ADJ-AMT
            RPAD('', 34, ' ') || -- 1689-1722: FILLER
            RPAD('', 6, ' ') ||	-- 1723-1728: :P:IDR-K-MAMMOGRAPHY-CERT
            RPAD('', 1, ' ') ||	-- 1729-1729: :P:IDR-K-DTL-RES-PAY-IND
            RPAD('', 10, ' ') || -- 1730-1739: :P:IDR-K-DTL-FAC-PROV-NPI
            RPAD('', 2, ' ') ||	-- 1740-1741: :P: IDR-K-PA-PROV-VALID-TYPE
            RPAD('', 1, ' ') ||	-- 1742-1742: :P:IDR-K-PBID-IND
            RPAD('', 1, ' ') ||	-- 1743-1743: :P:IDR-DTL-HPSA-ELIG
            RPAD('', 1, ' ') ||	-- 1744-1744: :P:IDR-DTL-REVIEW-IND
            RPAD('', 11, ' ') || -- 1745-1755: :P:IDR-DTL-LMRP-POLICY-1
            RPAD('', 11, ' ') || -- 1756-1766: :P:IDR-DTL-LMRP-POLICY-2
            RPAD('', 11, ' ') || -- 1767-1777: :P:IDR-DTL-LMRP-POLICY-3
            RPAD('', 11, ' ') || -- 1778-1788: :P:IDR-DTL-2MRP-POLICY-4
            RPAD('', 4, ' ') ||	-- 1789-1792: :P:IDR-DTL-CWF-ERR-CD
            RPAD('', 1, ' ') ||	-- 1793-1793: :P:IDR-DTL-CWF-OVRD-CD
            RPAD('', 1, ' ') ||	-- 1794-1794: :P:IDR-DTL-CWF-SRC-IND(1)
            RPAD('', 4, ' ') ||	-- 1795-1798: :P:IDR-DTL-CWF-ERR-CD
            RPAD('', 1, ' ') ||	-- 1799-1799: :P:IDR-DTL-CWF-OVRD-CD
            RPAD('', 1, ' ') ||	-- 1800-1800: :P:IDR-DTL-CWF-SRC-IND(2)
            RPAD('', 4, ' ') ||	-- 1801-1804: :P:IDR-DTL-CWF-ERR-CD
            RPAD('', 1, ' ') ||	-- 1805-1805: :P:IDR-DTL-CWF-OVRD-CD
            RPAD('', 1, ' ') ||	-- 1806-1806: :P:IDR-DTL-CWF-SRC-IND(3)
            RPAD('', 4, ' ') ||	-- 1807-1810: :P:IDR-DTL-CWF-ERR-CD
            RPAD('', 1, ' ') ||	-- 1811-1811: :P:IDR-DTL-CWF-OVRD-CD
            RPAD('', 1, ' ') ||	-- 1812-1812: :P:IDR-DTL-CWF-SRC-IND(4)
            RPAD('', 4, ' ') ||	-- 1813-1816: :P:IDR-DTL-CWF-ERR-CD
            RPAD('', 1, ' ') ||	-- 1817-1817: :P:IDR-DTL-CWF-OVRD-CD
            RPAD('', 1, ' ') ||	-- 1818-1818: :P:IDR-DTL-CWF-SRC-IND(5)
            RPAD('', 1, ' ') ||	-- 1819-1819: :P:IDR-DTL-REVIEW-IND-2
            RPAD('', 1, ' ') ||	-- 1820-1820: :P:IDR-DTL-REVIEW-IND-3
            RPAD('', 1, ' ') ||	-- 1821-1821: :P:IDR-DTL-PAYMENT-CAP-IND
            RPAD('', 52, ' ') || -- 1822-1873: FILLER
            RPAD('', 25, ' ') || -- 1874-1898: :P:IDR-DTL-AMB-PICKUP-ADDRES-1
            RPAD('', 20, ' ') || -- 1899-1918: :P:IDR-DTL-AMB-PICKUP-ADDRES-2
            RPAD('', 20, ' ') || -- 1919-1938: :P:IDR-DTL-AMB-PICKUP-CITY
            RPAD('', 2, ' ') ||	-- 1939-1940: :P:IDR-DTL-AMB-PICKUP-STATE
            RPAD('', 9, ' ') ||	-- 1941-1949: :P:IDR-DTL-AMB-PICKUP-ZIPCODE
            RPAD('', 24, ' ') || -- 1950-1973: :P:IDR-DTL-AMB-DROPOFF-NAME
            RPAD('', 25, ' ') || -- 1974-1998: :P:IDR-DTL-AMB-DROPOFF-ADDR-L1
            RPAD('', 20, ' ') || -- 1999-2018: :P:IDR-DTL-AMB-DROPOFF-ADDR-L2
            RPAD('', 20, ' ') || -- 2019-2038: :P:IDR-DTL-AMB-DROPOFF-CITY
            RPAD('', 2, ' ') ||	-- 2039-2040: :P:IDR-DTL-AMB-DROPOFF-STATE
            RPAD('', 9, ' ') ||	-- 2041-2049: :P:IDR-DTL-AMB-DROPOFF-ZIPCODE
            LPAD('', 3, '0') ||	-- 2050-2052: :P:IDR-K-CTM-CUT-CD
            RPAD('', 1, ' ') ||	-- 2053-2053: :P:IDR-K-CTM-CUT-SUF
            LPAD('', 9, '0') ||	-- 2054-2062: :P:IDR-K-CTM-CUT-AMT
            RPAD('', 3, ' ') ||	-- 2063-2065: :P:IDR-K-CTM-CUT-MSG
            LPAD('', 3, '0') ||	-- 2066-2068: :P:IDR-K-PAU-CUT-CD
            RPAD('', 1, ' ') ||	-- 2069-2069: :P:IDR-K-PAU-CUT-SUF
            RPAD('', 3, ' ') ||	-- 2070-2072: :P:IDR-K-PAU-CUT-MSG
            LPAD('', 3, '0') ||	-- 2073-2075: :P:IDR-K-XRY-CUT-CD
            RPAD('', 1, ' ') ||	-- 2076-2076: :P:IDR-K-XRY-CUT-SUF
            LPAD('', 9, '0') ||	-- 2077-2085: :P:IDR-K-XRY-CUT-AMT
            RPAD('', 3, ' ') ||	-- 2086-2088: :P:IDR-K-XRY-CUT-MSG
            LPAD('', 3, '0') ||	-- 2089-2091: :P:IDR-K-CPC-CUT-CD
            RPAD('', 1, ' ') ||	-- 2092-2092: :P:IDR-K-CPC-CUT-SUF
            RPAD('', 3, ' ') ||	-- 2093-2095: :P:IDR-K-CPC-CUT-MSG
            LPAD('', 3, '0') ||	-- 2096-2098: :P:IDR-DTL-CPC-PERCENT
            LPAD('', 10, '0') || -- 2099-2108: :P:IDR-K-MDPP-COACH-NPI
            LPAD('', 11, '0') || -- 2109-2119: :P:IDR-K-DTL-COINS-AMT
            LPAD('', 11, '0') || -- 2120-2130: :P:IDR-K-DTL-DEDUCT-AMT
            LPAD('', 11, '0') || -- 2131-2141: :P:IDR-K-DTL-PAT-RESP-AMT
            LPAD('', 11, '0') || -- 2142-2152: :P:IDR-K-DTL-TOTAL-B-RESP
            LPAD('', 3, '0') ||	-- 2153-2155: :P:IDR-K-MIP-CUT-CD
            RPAD('', 1, ' ') ||	-- 2156-2156: :P:IDR-K-MIP-CUT-SUF
            RPAD('', 3, ' ') ||	-- 2157-2159: :P:IDR-K-MIP-CUT-MSG
            LPAD('', 5, '0') ||	-- 2160-2164: :P:IDR-K-MIP-PERCENT
            LPAD('', 3, '0') ||	-- 2165-2167: :P:IDR-K-MPC-CUT-CD
            RPAD('', 1, ' ') ||	-- 2168-2168: :P:IDR-K-MPC-CUT-SUF
            RPAD('', 3, ' ') ||	-- 2169-2171: :P:IDR-K-MPC-CUT-MSG
            LPAD('', 3, '0') ||	-- 2172-2174: :P:IDR-K-MPC-PERCENT
            RPAD('', 1, ' ') ||	-- 2175-2175: :P:IDR-K-MSP-CONFIRM-FLAG
            RPAD('', 2, ' ') ||	-- 2176-2177: :P:IDR-K-COST-AVOID-IND
            LPAD('', 3, '0') ||	-- 2178-2180: :P:IDR-K-ROM-CUT-CD
            RPAD('', 1, ' ') ||	-- 2181-2181: :P:IDR-K-ROM-CUT-SUF
            LPAD('', 9, '0') ||	-- 2182-2190: :P:IDR-K-ROM-AMT
            RPAD('', 3, ' ') ||	-- 2191-2193: :P:IDR-K-ROM-CUT-MSG
            RPAD('', 2, ' ') ||	-- 2194-2195: :P: IDR-K-DEMO-PRIC-IND
            LPAD('', 3, '0') ||	-- 2196-2198: :P:IDR-K-ET3-CUT-CD
            RPAD('', 1, ' ') ||	-- 2199-2199: :P:IDR-K-ET3-CUT-SUF
            RPAD('', 3, ' ') ||	-- 2200-2202: :P:IDR-K-ET3-CUT-MSG
            LPAD('', 9, '0') ||	-- 2203-2211: :P:IDR-K-DTL-OTH-AMT
            RPAD('', 2, ' ') ||	-- 2212-2213: :P:IDR-K-DTL-OTH-IND
            LPAD('', 9, '0') ||	-- 2214-2222: :P:IDR-K-DTL-OTH-AMT
            RPAD('', 2, ' ') ||	-- 2223-2224: :P:IDR-K-DTL-OTH-IND
            LPAD('', 9, '0') ||	-- 2225-2233: :P:IDR-K-DTL-OTH-AMT
            RPAD('', 2, ' ') ||	-- 2234-2235: :P:IDR-K-DTL-OTH-IND
            LPAD('', 9, '0') ||	-- 2236-2244: :P:IDR-K-DTL-OTH-AMT
            RPAD('', 2, ' ') ||	-- 2245-2246: :P:IDR-K-DTL-OTH-IND
            LPAD('', 9, '0') ||	-- 2247-2255: :P:IDR-K-DTL-OTH-AMT
            RPAD('', 2, ' ') ||	-- 2256-2257: :P:IDR-K-DTL-OTH-IND
            LPAD('', 9, '0') ||	-- 2258-2266: :P:IDR-K-DTL-OTH-AMT
            RPAD('', 2, ' ') ||	-- 2267-2268: :P:IDR-K-DTL-OTH-IND
            LPAD('', 9, '0') ||	-- 2269-2277: :P:IDR-K-DTL-OTH-AMT
            RPAD('', 2, ' ') || -- 2278-2279: :P:IDR-K-DTL-OTH-IND
            LPAD('', 3, '0') || -- 2280-2282: MOD CUTBACK AUDIT
            RPAD('', 1, ' ') || -- 2283-2283: MOD CUTBACK AUDIT SUFFIX
            RPAD('', 3, ' ') || -- 2284-2286: MOD CUTBACK MSG
            LPAD('', 3, '0') || -- 2287-2289: PPA CUTBACK AUDIT
            RPAD('', 1, ' ') || -- 2290-2290: PPA CUTBACK AUDIT SUFFIX
            RPAD('', 3, ' ') || -- 2291-2293: PPA CUTBACK MSG
            LPAD('', 5, '0') || -- 2294-2298: PPA Percent (99999V99 implied decimal)
            LPAD('', 9, '0') || -- 2299-2307: IDR-DTL-MP3-FVF-AMT
            RPAD('', 1, ' ') || -- 2308-2308: P:IDR-COINS-SRC (Co-insurance Source)
            LPAD('', 5, '0') || -- 2309-2313: P:IDR-COINS-PCT (Co-insurance Percentage)
            LPAD('', 9, '0') || -- 2314-2322: P:IDR-K-EOM-CUT-AMT (EOM Cutback Amount)
            LPAD('', 3, '0') || -- 2323-2325: P:IDR-K-EOM-CUT-CD (EOM Cutback Code)
            RPAD('', 1, ' ') || -- 2326-2326: P:IDR-K-EOM-CUT-SUF (EOM Cutback Suffix)
            RPAD('', 2, ' ') || -- 2327-2328: P:IDR-DTL-REND-SPEC-2 (Render Provider Specialty 2)
            RPAD('', 2, ' ') || -- 2329-2330: P:IDR-DTL-REND-SPEC-3 (Render Provider Specialty 3)
            RPAD('', 2, ' ') -- 2331-2332: P:IDR-DTL-REND-SPEC-4 (Render Provider Specialty 4)
        ) AS record_content
    FROM claim_header ch
    JOIN claim_key ck
        ON ck.claim_id = ch.claim_id
    JOIN professional_claim pc
        ON pc.id = ch.claim_id
    CROSS JOIN LATERAL jsonb_array_elements(pc.claim_jsonb->'serviceLines') sl
    CROSS JOIN extract_parameters ep
    WHERE pc.claim_jsonb->>'macId' IS NOT NULL
        AND pc.claim_jsonb->>'receiptDate' = TO_CHAR(ep.extract_date, 'YYYY-MM-DD')
),
file_trailer AS (
    SELECT
        mac_totals.mac_id,
        mac_totals.phase_value AS phase,
        'FILE_TRAILER' AS record_type,
        999999 AS record_sequence,
        NULL::INTEGER AS claim_sequence,
        NULL::INTEGER AS line_sequence,
        /* 1-44 */
        RPAD('MAP', 3)                              -- 1-3 (confirm MAP vs MCS requirement)
        || RPAD('T', 1)                             -- 4
        || RPAD(mac_totals.phase_value, 2)           -- 5-6
        || LPAD(mac_totals.mac_id::text, 5, '0')     -- 7-11 Workload ID (must match MAC ID)
        || LPAD(mac_totals.mac_id::text, 5, '0')     -- 12-16 MAC ID
        || RPAD('D', 1)                             -- 17
        || LPAD((1 + mac_totals.total_claim_headers + mac_totals.total_claim_lines + 1)::text, 9, '0') -- 18-26
        || LPAD(mac_totals.total_claim_headers::text, 9, '0')                                           -- 27-35
        || LPAD(mac_totals.total_claim_lines::text, 9, '0')                                             -- 36-44
        AS record_content
    FROM mac_totals
),
-- 5. Generate file metadata
file_metadata AS (
    SELECT DISTINCT
        mac_id,
        phase,
        'P.IDR.IN.EFT.MAP.' || phase || '.' || LPAD(mac_id, 5, '0') || '.D.' || TO_CHAR(CURRENT_DATE - 1, 'YYMMDD') || '.T' || TO_CHAR(
            CURRENT_TIMESTAMP AT TIME ZONE 'America/New_York',
            'HH24MISS'
        ) || '.txt' AS file_name
    FROM (
        SELECT mac_id, phase FROM file_header
    ) f
),
-- 6. Combine all records
all_records AS (
    SELECT mac_id, phase, record_type, record_sequence, claim_sequence, line_sequence, record_content
    FROM file_header
    UNION ALL
    SELECT mac_id, phase, record_type, record_sequence, claim_sequence, line_sequence, record_content
    FROM claim_header
    UNION ALL
    SELECT mac_id, phase, record_type, record_sequence, claim_sequence, line_sequence, record_content
    FROM claim_line
    UNION ALL
    SELECT mac_id, phase, record_type, record_sequence, claim_sequence, line_sequence, record_content
    FROM file_trailer
)
-- 7. Final output: one row per record
SELECT
    fm.file_name,
    ar.mac_id,
    ar.phase,
    ar.record_type,
    ar.record_sequence,
    ar.claim_sequence,
    ar.line_sequence,
    ar.record_content
FROM all_records ar
JOIN file_metadata fm ON ar.mac_id = fm.mac_id AND ar.phase = fm.phase
ORDER BY fm.file_name, ar.record_sequence;

-- =============================================================================
-- medications_first24h.sql
-- =============================================================================
-- PURPOSE: medication_count, antibiotic_flag, insulin_flag
--   (features E1-E3 in feature_engineering_plan.md, scope frozen to exactly
--   these three per the medication-features task)
--
-- 24-HOUR BOUNDARY: filter prescriptions.starttime to
--   [intime, intime + 24h) — icu_intime <= starttime < icu_intime + 24h,
--   mandatory to avoid pulling in medications ordered later in the stay.
--
-- JOINS: cohort --JOIN--> prescriptions on hadm_id. Unlike labevents (26%
--   null hadm_id), prescriptions was profiled and has ZERO null hadm_id and
--   ZERO null starttime across all 18,087 rows in this dataset — so, unlike
--   labs_first24h.sql, a plain hadm_id join is safe here and there is no
--   need for the subject_id + time-window join pattern used for labs.
--
-- AGGREGATION: one row per (stay_id) with three aggregates computed over the
--   24h-windowed prescription rows: COUNT(DISTINCT ...) for medication_count,
--   MAX(CASE WHEN ... THEN 1 ELSE 0 END) for the two flags — same
--   "many rows collapse to one flag/count per group" pattern as
--   comorbidities.sql.
--
-- DUPLICATE PREVENTION:
--   (1) drug_type = 'MAIN' filter — a single clinical order can appear as
--       multiple prescriptions rows (MAIN = the active drug, BASE/ADDITIVE =
--       carrier fluid / admixture components of the same IV order). Verified
--       in this dataset: 14,391 MAIN / 3,677 BASE / 19 ADDITIVE rows.
--       Counting all three would silently inflate medication_count by
--       counting one clinical decision as 2-3 "medications."
--   (2) TRIM(UPPER(drug)) before COUNT(DISTINCT ...) — verified duplicate
--       trap in this data: "Azithromycin" and "Azithromycin " (trailing
--       space) are two distinct raw strings for the same drug. Without
--       normalizing case/whitespace, medication_count would over-count.
--   (3) Final GROUP BY stay_id collapses the join's per-prescription-row
--       grain back to one row per stay, same pattern as comorbidities.sql.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Matching-rule derivation: BEFORE writing any matching logic, all 631
-- distinct `drug` strings in this dataset's prescriptions.csv were inspected
-- (via a full antibiotic/insulin keyword sweep, then manual clinical review
-- of every hit). This surfaced the exact same class of bug documented in
-- feature_engineering_plan.md E1/E2 — naive substring matching on fragments
-- like "sulfa", "azole", "mycin" catches unrelated drugs. Confirmed false
-- positives found in the ACTUAL data (none hypothetical):
--   "sulfa"  matches: Atropine Sulfate, Busulfan, Ferrous Sulfate,
--            Hydroxychloroquine Sulfate, Magnesium Sulfate, Morphine Sulfate,
--            Protamine Sulfate, Zinc Sulfate, Barium Sulfate, SulfaSALAzine
--            (an anti-inflammatory, not an antibiotic, despite the name)
--   "azole"  matches: Methimazole (antithyroid), Esomeprazole, Omeprazole,
--            Pantoprazole, Lansoprazole (all PPIs), Fluconazole, Voriconazole,
--            Clotrimazole, Miconazole (all antifungals, not antibiotics)
-- CONCLUSION (same as E1/E2): use a closed allowlist of verified, specific
-- generic antibiotic/insulin name substrings, never generic drug-class
-- suffix fragments. Every name below was confirmed present in this dataset's
-- distinct drug list before being added — nothing here is a guess.
-- -----------------------------------------------------------------------------

WITH cohort AS (
    SELECT stay_id, hadm_id, intime, feature_cutoff
    FROM {{ cohort_selection }}
)

, windowed_rx AS (
    SELECT
        c.stay_id,
        UPPER(TRIM(r.drug)) AS drug_norm,   -- normalizes case + trailing-space duplicates
        r.drug_type
    FROM cohort c
    JOIN prescriptions r
        ON r.hadm_id = c.hadm_id
       AND r.starttime >= c.intime
       AND r.starttime <  c.feature_cutoff
)

, flagged AS (
    SELECT
        stay_id,

        -- medication_count: distinct MAIN-component drugs only (see
        -- DUPLICATE PREVENTION note (1) above).
        COUNT(DISTINCT CASE WHEN drug_type = 'MAIN' THEN drug_norm END) AS medication_count,

        -- antibiotic_flag: verified generic-name allowlist (systemic route
        -- only). Names are specific full generic drug names, not suffix
        -- fragments, so no antifungal/PPI/electrolyte false positives.
        -- OPHTH/OTIC/CREAM route exclusion is a second safety net — three of
        -- the listed generics (ciprofloxacin, gentamicin, erythromycin) have
        -- BOTH a systemic and a topical/ophthalmic entry in this dataset
        -- under the same generic name; only the systemic one should count.
        MAX(CASE
            WHEN (
                    drug_norm LIKE '%ERTAPENEM%'      OR drug_norm LIKE '%AMOXICILLIN%'
                 OR drug_norm LIKE '%AMPICILLIN%'      OR drug_norm LIKE '%AZTREONAM%'
                 OR drug_norm LIKE '%CEFAZOLIN%'       OR drug_norm LIKE '%CEFTAZIDIME%'
                 OR drug_norm LIKE '%CEFTRIAXONE%'     OR drug_norm LIKE '%CEFEPIME%'
                 OR drug_norm LIKE '%CEFPODOXIME%'     OR drug_norm LIKE '%CEPHALEXIN%'
                 OR drug_norm LIKE '%CIPROFLOXACIN%'   OR drug_norm LIKE '%CLARITHROMYCIN%'
                 OR drug_norm LIKE '%CLINDAMYCIN%'     OR drug_norm LIKE '%DAPTOMYCIN%'
                 OR drug_norm LIKE '%DOXYCYCLINE%'     OR drug_norm LIKE '%ERYTHROMYCIN%'
                 OR drug_norm LIKE '%GENTAMICIN%'      OR drug_norm LIKE '%LEVOFLOXACIN%'
                 OR drug_norm LIKE '%LINEZOLID%'       OR drug_norm LIKE '%MEROPENEM%'
                 OR drug_norm LIKE '%METRONIDAZOLE%'   OR drug_norm LIKE '%MOXIFLOXACIN%'
                 OR drug_norm LIKE '%NITROFURANTOIN%'  OR drug_norm LIKE '%PIPERACILLIN%'
                 OR drug_norm LIKE '%SULFAMETHOXAZOLE%' OR drug_norm LIKE '%TRIMETHOPRIM%'
                 OR drug_norm LIKE '%TOBRAMYCIN%'      OR drug_norm LIKE '%VANCOMYCIN%'
                 )
                 AND drug_norm NOT LIKE '%OPHTH%'
                 AND drug_norm NOT LIKE '%OTIC%'
                 AND drug_norm NOT LIKE '%CREAM%'
            THEN 1 ELSE 0
        END) AS antibiotic_flag,

        -- insulin_flag: any actual insulin ADMINISTRATION entry, explicitly
        -- excluding the hyperkalemia-indication entry (different clinical
        -- use: potassium management, not glycemic control) and device/supply
        -- orders (pump, syringe — not an administration event). All three
        -- exclusion terms were found as real distinct strings in this data.
        MAX(CASE
            WHEN drug_norm LIKE '%INSULIN%'
                 AND drug_norm NOT LIKE '%HYPERKALEMIA%'
                 AND drug_norm NOT LIKE '%PUMP%'
                 AND drug_norm NOT LIKE '%SYRINGE%'
            THEN 1 ELSE 0
        END) AS insulin_flag

    FROM windowed_rx
    GROUP BY stay_id
)

-- LEFT JOIN back onto the FULL cohort (not just `flagged`) — a stay with
-- zero prescriptions in the 24h window has no group in `flagged` at all;
-- an INNER JOIN would silently drop it instead of correctly recording
-- medication_count=0 / antibiotic_flag=0 / insulin_flag=0. Same trap called
-- out in comorbidities.sql.
SELECT
    c.stay_id,
    COALESCE(f.medication_count, 0) AS medication_count,
    COALESCE(f.antibiotic_flag, 0)  AS antibiotic_flag,
    COALESCE(f.insulin_flag, 0)     AS insulin_flag
FROM cohort c
LEFT JOIN flagged f
    ON f.stay_id = c.stay_id;

-- VALIDATION HOOK: SELECT stay_id, COUNT(*) FROM <this output> GROUP BY
-- stay_id HAVING COUNT(*) > 1  must be zero rows. Also spot-check: pull the
-- raw drug list for a handful of antibiotic_flag=1 stays and manually
-- confirm a real systemic antibiotic is present, not a false-positive
-- match. See docs/validation_strategy.md, "Medication" section.

# Feature Engineering Plan — MIMIC-IV ICU LOS Project

17 features across 5 domains, all resolved to **exactly one row per `stay_id`**, all sourced
only from information available in `[intime, intime + 24h)`. This is a design document — SQL
logic is described in prose here; the executable pseudocode lives in `sql/features/*.sql`
(see `docs/validation_strategy.md` for how each feature will be verified once implemented).

Predictive-power ratings (Low/Medium/High) are *prior* clinical-literature expectations, not
measured results — they exist to flag which features justify the engineering effort and which
are included mainly for completeness/interpretability.

---

## A. Demographics

#### A1. `age_at_admission`
- **Source Table:** `patients` (+ `admissions.admittime` for the year)
- **SQL Extraction Logic:** MIMIC-IV date-shifts each patient's timeline but preserves internal
  consistency, so true age isn't `anchor_age` directly — it must be adjusted to the admission
  year: `age_at_admission = anchor_age + (YEAR(admittime) - anchor_year)`. Join `patients` to
  `admissions` on `subject_id`, compute the offset, attach to the cohort via `hadm_id`.
- **Available Time:** STATIC (known before admission)
- **Clinical Meaning:** Older patients trend toward longer, more complicated ICU courses.
- **Potential Leakage:** None.
- **Expected Predictive Power:** Medium — a consistently-cited LOS covariate but rarely dominant alone.
- **Missing Value Strategy:** None expected (`anchor_age`/`anchor_year` are non-nullable in `patients`); if a join fails to resolve, drop the stay from the cohort rather than impute demographics.
- **Include?** Yes.

#### A2. `gender`
- **Source Table:** `patients`
- **SQL Extraction Logic:** Direct passthrough of `patients.gender`, joined on `subject_id`.
- **Available Time:** STATIC
- **Clinical Meaning:** Sex-based differences in physiology and treatment patterns.
- **Potential Leakage:** None.
- **Expected Predictive Power:** Low — weak standalone LOS signal in most published models; kept for interpretability completeness and as a fairness/subgroup-analysis axis.
- **Missing Value Strategy:** None expected — profiling confirmed only `{M, F}`, no nulls.
- **Include?** Yes.

---

## B. Admission Context

#### B1. `admission_type`
- **Source Table:** `admissions`
- **SQL Extraction Logic:** Direct passthrough of `admissions.admission_type`, joined on `hadm_id`. Kept as a categorical (one-hot at modeling time), not collapsed, since the 9 observed categories (e.g. `URGENT`, `EW EMER.`, `ELECTIVE`, `SURGICAL SAME DAY ADMISSION`) carry distinct acuity meaning.
- **Available Time:** AT-ADMISSION
- **Clinical Meaning:** Emergent/urgent admissions generally run longer and less predictable courses than elective ones.
- **Potential Leakage:** None.
- **Expected Predictive Power:** High — admission acuity is one of the strongest early LOS predictors in the literature.
- **Missing Value Strategy:** None expected (non-nullable in source); if missing, impute category `"UNKNOWN"` rather than drop the stay.
- **Include?** Yes.

#### B2. `weekend_admission`
- **Source Table:** `icustays` (`intime`)
- **SQL Extraction Logic:** Boolean derived from `DAYOFWEEK(intime) IN (Saturday, Sunday)`.
- **Available Time:** AT-ADMISSION
- **Clinical Meaning:** Proxy for reduced weekend staffing/service availability ("weekend effect"), hypothesized to extend LOS.
- **Potential Leakage:** None — `intime` is the anchor itself.
- **Expected Predictive Power:** Low-Medium — a known but usually modest effect.
- **Missing Value Strategy:** None possible — derived from a non-nullable timestamp.
- **Include?** Yes.

#### B3. `night_admission`
- **Source Table:** `icustays` (`intime`)
- **SQL Extraction Logic:** Boolean derived from `HOUR(intime)` falling in `[20:00, 08:00)`.
- **Available Time:** AT-ADMISSION
- **Clinical Meaning:** Off-hours admissions may receive delayed workup, similarly to the weekend effect.
- **Potential Leakage:** None.
- **Expected Predictive Power:** Low.
- **Missing Value Strategy:** None possible.
- **Include?** Yes.

#### B4. `insurance`
- **Source Table:** `admissions`
- **SQL Extraction Logic:** Direct passthrough of `admissions.insurance`, joined on `hadm_id`.
- **Available Time:** AT-ADMISSION
- **Clinical Meaning:** Weak proxy for socioeconomic factors that can affect care pathways and disposition planning speed (which in turn affects LOS).
- **Potential Leakage:** None, but **flag for fairness review** — a socioeconomic proxy predicting a resource-allocation-relevant outcome deserves explicit discussion in the model card, not silent use.
- **Expected Predictive Power:** Low.
- **Missing Value Strategy:** Impute `"UNKNOWN"` category if null.
- **Include?** Yes, with a fairness caveat documented in `docs/model_card.md`.

---

## C. Comorbidities (from `diagnoses_icd`)

All four flags share the same extraction pattern: match `icd_code` against a curated,
version-aware prefix list, restricted **only** to conditions that are chronic by clinical
definition (never acute/complication codes), per the leakage caveat in the data dictionary.

#### C1. `diabetes_flag`
- **Source Table:** `diagnoses_icd`
- **SQL Extraction Logic:** Flag = 1 if any row for the `hadm_id` has `icd_version = 10 AND icd_code LIKE 'E10%' OR icd_code LIKE 'E11%' OR icd_code LIKE 'E13%'`, or `icd_version = 9 AND icd_code LIKE '250%'`. Aggregate with `MAX()` grouped by `hadm_id`/`stay_id` so multiple matching diagnosis rows collapse to one flag.
- **Available Time:** MEDIUM — technically coded post-discharge, but diabetes is a chronic diagnosis category, not a stay-acquired condition (see data dictionary caveat).
- **Clinical Meaning:** Pre-existing diabetes is associated with complication risk and longer ICU courses.
- **Potential Leakage:** Medium (documented proxy-leakage limitation, not eliminated).
- **Expected Predictive Power:** Medium.
- **Missing Value Strategy:** No missingness possible — absence of a matching code = 0 by construction (absence of evidence, treated as absence of the condition for this cohort).
- **Include?** Yes, with the leakage caveat explicitly documented.

#### C2. `hypertension_flag`
- **Source Table:** `diagnoses_icd`
- **SQL Extraction Logic:** Same pattern as C1: `icd_version=10 AND icd_code LIKE 'I10%'..'I15%'`, or `icd_version=9 AND icd_code LIKE '401%'..'405%'`.
- **Available Time:** MEDIUM (same caveat as C1)
- **Clinical Meaning:** Common comorbidity affecting hemodynamic management during critical illness.
- **Potential Leakage:** Medium.
- **Expected Predictive Power:** Low-Medium.
- **Missing Value Strategy:** Absence = 0.
- **Include?** Yes.

#### C3. `ckd_flag`
- **Source Table:** `diagnoses_icd`
- **SQL Extraction Logic:** `icd_version=10 AND icd_code LIKE 'N18%'`, or `icd_version=9 AND icd_code LIKE '585%'`.
- **Available Time:** MEDIUM (same caveat as C1)
- **Clinical Meaning:** Chronic kidney disease strongly correlates with ICU complexity (fluid management, drug dosing, dialysis needs).
- **Potential Leakage:** Medium.
- **Expected Predictive Power:** Medium-High — CKD is one of the more consistently LOS-associated comorbidities.
- **Missing Value Strategy:** Absence = 0.
- **Include?** Yes.

#### C4. `heart_failure_flag`
- **Source Table:** `diagnoses_icd`
- **SQL Extraction Logic:** `icd_version=10 AND icd_code LIKE 'I50%'`, or `icd_version=9 AND icd_code LIKE '428%'`.
- **Available Time:** MEDIUM (same caveat as C1)
- **Clinical Meaning:** Heart failure predisposes to volume-management complications and longer stabilization.
- **Potential Leakage:** Medium.
- **Expected Predictive Power:** Medium.
- **Missing Value Strategy:** Absence = 0.
- **Include?** Yes.

#### C5. `comorbidity_count`
- **Source Table:** `diagnoses_icd` (derived from C1–C4)
- **SQL Extraction Logic:** Sum of the four flags above, per stay. (Not a full Elixhauser/Charlson index in v1 — noted as a future extension.)
- **Available Time:** MEDIUM (inherits caveat from components)
- **Clinical Meaning:** Simple comorbidity burden score.
- **Potential Leakage:** Medium (inherits from components).
- **Expected Predictive Power:** Medium.
- **Missing Value Strategy:** None — arithmetic derivation, always defined (0–4).
- **Include?** Yes.

---

## D. Laboratory Features (`labevents`, first 24h)

All three share the same pattern: filter to the target `itemid`, restrict `charttime` to the
24h window anchored on `intime`, take the **first** (earliest `charttime`) value per stay,
require `valuenum IS NOT NULL`.

#### D1. `first_creatinine`
- **Source Table:** `labevents`
- **SQL Extraction Logic:** Filter `itemid = 50912` (verified empirically: mg/dL, ref range ~0.5–1.2). Join to cohort via `subject_id` + `charttime BETWEEN intime AND intime + 24h` (not `hadm_id`, since 26% of rows have null `hadm_id`). Rank rows by `charttime` ascending per `stay_id`, keep rank 1.
- **Available Time:** WITHIN-24H
- **Clinical Meaning:** Kidney function marker; elevated on admission signals renal impairment, a strong driver of ICU complexity.
- **Potential Leakage:** Low — strictly time-boxed.
- **Expected Predictive Power:** High.
- **Missing Value Strategy:** Not every stay has a creatinine drawn in the first 24h. Add a companion `first_creatinine_missing` indicator flag, then impute the numeric value with the cohort median (computed on training data only, applied to val/test — no leakage across the CV split). Missingness itself may be informative (patients not tested may be lower-acuity) — the indicator flag preserves that signal.
- **Include?** Yes.

#### D2. `first_wbc`
- **Source Table:** `labevents`
- **SQL Extraction Logic:** Same pattern as D1, `itemid = 51301` (verified: K/uL, ref range ~4–11).
- **Available Time:** WITHIN-24H
- **Clinical Meaning:** White blood cell count; elevated or depressed values indicate infection/inflammatory response, a common driver of prolonged ICU courses.
- **Potential Leakage:** Low.
- **Expected Predictive Power:** High.
- **Missing Value Strategy:** Same as D1 — missing indicator + training-median imputation.
- **Include?** Yes.

#### D3. `first_hemoglobin`
- **Source Table:** `labevents`
- **SQL Extraction Logic:** Same pattern as D1, `itemid = 51222` (verified: g/dL, ref range ~13.7–18).
- **Available Time:** WITHIN-24H
- **Clinical Meaning:** Anemia on admission is associated with transfusion needs and prolonged recovery.
- **Potential Leakage:** Low.
- **Expected Predictive Power:** Medium.
- **Missing Value Strategy:** Same as D1 — missing indicator + training-median imputation.
- **Include?** Yes.

> **Cross-cutting note:** all three use `charttime` (collection time) as the 24h boundary, not
> `storetime` (result-posting time). This is a documented, slightly optimistic simplification —
> see the data dictionary's leakage note on `labevents`. A stricter variant of this pipeline
> would filter on `storetime` instead; both are worth reporting in the model card as a
> sensitivity check.

---

## E. Medication Features (`prescriptions`, first 24h)

#### E1. `antibiotic_exposure`
- **Source Table:** `prescriptions`
- **SQL Extraction Logic:** Flag = 1 if any row for the stay has `starttime BETWEEN intime AND intime + 24h` and `drug` matches a **curated allowlist** of systemic antibiotic generic names (e.g. Vancomycin, Cefazolin, Cefepime, Ceftriaxone, Ceftazidime, Ampicillin(-Sulbactam), Piperacillin(-Tazobactam), Ciprofloxacin, Levofloxacin, Azithromycin, Clindamycin, Daptomycin, Meropenem, Ertapenem, Metronidazole, Gentamicin, Linezolid, Doxycycline, Sulfamethoxazole-Trimethoprim), explicitly **excluding** non-systemic formulations (route/name contains "Ophth", "Cream", "Topical", "Otic").
- **Available Time:** WITHIN-24H
- **Clinical Meaning:** Empiric or targeted antibiotic therapy signals suspected/confirmed infection — a major driver of ICU length of stay.
- **Potential Leakage:** Low — time-boxed to the 24h window.
- **Expected Predictive Power:** High.
- **Missing Value Strategy:** No missingness — absence from `prescriptions` in the window = 0.
- **Include?** Yes.
- **⚠️ Real false-positive risk found during data profiling:** a naive substring match (matching on fragments like `"sulfa"`, `"azole"`, `"mycin"`) against this cohort's actual `drug` values incorrectly catches **`Atropine Sulfate`**, **`Magnesium Sulfate`** (both contain "sulfa" but are not antibiotics), **`Clotrimazole`** (antifungal), and **`Esomeprazole`** (a PPI, acid reducer) — none of which are antibiotics. This is why the extraction logic above uses a closed allowlist of full generic names rather than keyword substrings. See `docs/validation_strategy.md` for how this will be regression-tested.

#### E2. `insulin_exposure`
- **Source Table:** `prescriptions`
- **SQL Extraction Logic:** Flag = 1 if any row for the stay has `starttime BETWEEN intime AND intime + 24h` and `drug` matches an allowlist of actual insulin administration entries (`Insulin`, `Insulin Human Regular`, `Insulin Glargine`, `Insulin Regular Human (U-500)`), **explicitly excluding** `"Insulin (Regular) for Hyperkalemia"` (a potassium-management indication, not diabetes control) and device/supply orders (`"Insulin Pump (Self Administering Medication)"`, `"Insulin Syringe U-500"`, which represent equipment, not an administration event).
- **Available Time:** WITHIN-24H
- **Clinical Meaning:** Active insulin therapy signals diabetes management or acute glycemic instability, both associated with ICU complexity.
- **Potential Leakage:** Low.
- **Expected Predictive Power:** Medium.
- **Missing Value Strategy:** Absence = 0.
- **Include?** Yes.
- **⚠️ Real ambiguity found during data profiling:** in this cohort, `"Insulin (Regular) for Hyperkalemia"` occurs as a distinct, clinically different indication from diabetes-management insulin. A naive "any drug LIKE '%Insulin%'" match would conflate the two. Flagged as a worked example in `docs/validation_strategy.md`.

#### E3. `medication_count`
- **Source Table:** `prescriptions`
- **SQL Extraction Logic:** Count of **distinct** `drug` values with `starttime BETWEEN intime AND intime + 24h`, restricted to `drug_type = 'MAIN'` so that `ADDITIVE`/`BASE` component rows of the same compounded order (e.g. an IV admixture's carrier fluid) don't inflate the count of a single clinical decision.
- **Available Time:** WITHIN-24H
- **Clinical Meaning:** Overall early medication burden as a coarse acuity proxy — more concurrent medications generally reflects more active management.
- **Potential Leakage:** Low.
- **Expected Predictive Power:** Medium.
- **Missing Value Strategy:** No missingness — 0 if no orders in window.
- **Include?** Yes.

---

## Summary Table

| # | Feature | Domain | Power (prior) | Leakage | Include |
|---|---|---|---|---|---|
| A1 | age_at_admission | Demographics | Medium | None | Yes |
| A2 | gender | Demographics | Low | None | Yes |
| B1 | admission_type | Admission Context | High | None | Yes |
| B2 | weekend_admission | Admission Context | Low-Medium | None | Yes |
| B3 | night_admission | Admission Context | Low | None | Yes |
| B4 | insurance | Admission Context | Low | None (fairness flag) | Yes |
| C1 | diabetes_flag | Comorbidity | Medium | Medium (documented) | Yes |
| C2 | hypertension_flag | Comorbidity | Low-Medium | Medium (documented) | Yes |
| C3 | ckd_flag | Comorbidity | Medium-High | Medium (documented) | Yes |
| C4 | heart_failure_flag | Comorbidity | Medium | Medium (documented) | Yes |
| C5 | comorbidity_count | Comorbidity | Medium | Medium (documented) | Yes |
| D1 | first_creatinine | Labs | High | Low | Yes |
| D2 | first_wbc | Labs | High | Low | Yes |
| D3 | first_hemoglobin | Labs | Medium | Low | Yes |
| E1 | antibiotic_exposure | Medication | High | Low | Yes |
| E2 | insulin_exposure | Medication | Medium | Low | Yes |
| E3 | medication_count | Medication | Medium | Low | Yes |

17/17 features included in v1. Nothing was excluded outright — the design work happened in
*how* each is extracted (allowlists over keyword matches, chronic-only ICD prefixes, time-window
join keys) rather than in dropping features. Anything riskier (dose intensity, full Elixhauser
index, `chartevents` vitals) is deferred to Future Extensions per the proposal.

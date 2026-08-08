# Data Dictionary — MIMIC-IV ICU LOS Project

Source: MIMIC-IV Clinical Database Demo v2.2. Unit of analysis: **one row = one ICU stay
(`stay_id`)**. All "time availability" and "leakage risk" judgments are relative to the
prediction anchor point **`t0 = icustays.intime`**, and the feature horizon
**`t0 → t0 + 24h`**.

This dictionary was built by reading every raw CSV header and empirically profiling key
columns (uniqueness, null rates, category values) — not from assumption. Profiling notes are
called out inline where they changed a design decision.

## Legend

**Time Availability**
| Code | Meaning |
|---|---|
| STATIC | Known independent of this admission (demographics) |
| AT-ADMISSION | Known at or before `intime` |
| WITHIN-24H | Only usable if its own timestamp falls in `[intime, intime+24h)` |
| POST-DISCHARGE | Not knowable until discharge or later — **excluded from features** |
| N/A | Identifier/metadata column, not time-bound |

**Leakage Risk**
| Code | Meaning |
|---|---|
| NONE | Value cannot change based on outcome or future events |
| LOW | Time-safe, but requires filtering logic to stay safe |
| MEDIUM | Safe only under a documented assumption (flagged explicitly) |
| HIGH | Directly encodes information from after the prediction window — **never used as a feature** |

---

## 1. `icustays` — cohort + label table

- **Primary Key:** `stay_id` (verified: 141 rows, 141 distinct `stay_id`, zero duplicates)
- **Foreign Keys:** `subject_id → patients.subject_id`, `hadm_id → admissions.hadm_id`
- **Profiling note:** `subject_id` repeats (max 5 stays for one patient) — confirms `stay_id`,
  not `subject_id`, must be the join anchor everywhere downstream, or joins will fan out.

| Column | Keep? | Reason for Dropping | Time Availability | Leakage Risk |
|---|---|---|---|---|
| `subject_id` | Keep | — | STATIC | NONE — join key only |
| `hadm_id` | Keep | — | AT-ADMISSION | NONE — join key only |
| `stay_id` | Keep | — | AT-ADMISSION | NONE — primary key |
| `first_careunit` | Keep | — | AT-ADMISSION | NONE — known at ICU entry |
| `intime` | Keep | — | AT-ADMISSION | NONE — this **is** t0, the anchor |
| `last_careunit` | Drop | Reflects the unit at transfer/discharge; only fully known once the stay's care-unit trajectory is complete | POST-DISCHARGE | HIGH |
| `outtime` | Drop | ICU discharge time — only known at the end of the stay | POST-DISCHARGE | HIGH |
| `los` | Drop from features | This is the **label source**, not a feature. Used only to derive the target `los > threshold`, then excluded from `X` | POST-DISCHARGE | HIGH (by definition) |

---

## 2. `patients` — demographics

- **Primary Key:** `subject_id`
- **Foreign Keys:** none (root table)

| Column | Keep? | Reason for Dropping | Time Availability | Leakage Risk |
|---|---|---|---|---|
| `subject_id` | Keep | — | STATIC | NONE — join key |
| `gender` | Keep | — | STATIC | NONE |
| `anchor_age` | Keep | — | STATIC | NONE (needs `anchor_year` to convert to age-at-admission, see §8 of feature plan) |
| `anchor_year` | Keep (support column) | Not a feature itself; required to compute age at admission | STATIC | NONE |
| `anchor_year_group` | Drop | De-identification/date-shift artifact (a 3-year banded era), not a clinically meaningful covariate; adds noise and out of proposal scope | STATIC | NONE |
| `dod` | Drop | Date of death — can occur during or after this stay; using it (even as a covariate) leaks outcome-adjacent information tied to mortality | POST-DISCHARGE | HIGH |

---

## 3. `admissions` — hospitalization context

- **Primary Key:** `hadm_id` (verified: 276 rows, 276 distinct `hadm_id`, zero duplicates)
- **Foreign Keys:** `subject_id → patients.subject_id`

| Column | Keep? | Reason for Dropping | Time Availability | Leakage Risk |
|---|---|---|---|---|
| `subject_id` | Keep | — | STATIC | NONE — join key |
| `hadm_id` | Keep | — | AT-ADMISSION | NONE — join key |
| `admittime` | Keep | — | AT-ADMISSION | NONE |
| `admission_type` | Keep | — | AT-ADMISSION | NONE |
| `admission_location` | Keep | — | AT-ADMISSION | NONE |
| `insurance` | Keep | — | AT-ADMISSION | NONE |
| `marital_status` | Keep | — | AT-ADMISSION | NONE |
| `race` | Keep | — | AT-ADMISSION | NONE |
| `edregtime` | Keep | — | AT-ADMISSION | NONE — ED registration precedes ICU intime |
| `edouttime` | Keep | — | AT-ADMISSION | LOW — precedes ICU entry in nearly all cases; validate `edouttime ≤ intime` per row before trusting |
| `language` | Drop | Not clinically predictive of LOS in this scope; adds high-cardinality noise for a 141-row cohort | STATIC | NONE |
| `admit_provider_id` | Drop | High-cardinality identifier, not a clinical signal | N/A | NONE |
| `dischtime` | Drop | Hospital discharge time — end of encounter | POST-DISCHARGE | HIGH |
| `discharge_location` | Drop | Only known at discharge; also outcome-adjacent (e.g. "died", "hospice") | POST-DISCHARGE | HIGH |
| `deathtime` | Drop | In-hospital death timestamp | POST-DISCHARGE | HIGH |
| `hospital_expire_flag` | Drop | In-hospital mortality outcome flag | POST-DISCHARGE | HIGH |

---

## 4. `diagnoses_icd` — comorbidities

- **Primary Key:** composite (`subject_id`, `hadm_id`, `seq_num`, `icd_version`) — `seq_num` is
  a *coding sequence position*, not a clinical priority ranking; do not treat low `seq_num` as
  "more severe."
- **Foreign Keys:** (`subject_id`, `hadm_id`) → `admissions`
- **Profiling note:** both coding systems are present — 2,313 rows ICD-10, 2,193 rows ICD-9 —
  so any comorbidity-matching logic must branch on `icd_version` or it will silently miss half
  the cohort's diagnoses.

| Column | Keep? | Reason for Dropping | Time Availability | Leakage Risk |
|---|---|---|---|---|
| `subject_id` | Keep | — | N/A | NONE — join key |
| `hadm_id` | Keep | — | N/A | NONE — join key |
| `icd_code` | Keep | — | MEDIUM (see below) | MEDIUM |
| `icd_version` | Keep | — | N/A | NONE — required to interpret `icd_code` |
| `seq_num` | Drop | Reflects coder ordering conventions, not clinical timing or severity; not used | N/A | NONE |

**⚠️ Table-level leakage caveat (important):** ICD diagnosis codes in MIMIC are assigned by
medical coders **after discharge**, based on the entire hospitalization — there is no
present-on-admission (POA) flag in this dataset. Strictly, `icd_code` is POST-DISCHARGE data.
This project's design decision (documented in `docs/decisions/`) is to use `diagnoses_icd`
**only** to flag a narrow set of chronic, present-by-definition conditions (diabetes,
hypertension, CKD, heart failure) via curated code-prefix lists, and explicitly **not** for any
acute/complication diagnosis (e.g. sepsis, AKI) that could plausibly have originated during the
stay itself. This is a documented proxy-leakage limitation, not a leakage-free guarantee — it is
called out in the project's Limitations section.

---

## 5. `labevents` — first-24h laboratory values

- **Primary Key:** `labevent_id`
- **Foreign Keys:** `subject_id → patients.subject_id`, `hadm_id → admissions.hadm_id` (**nullable**),
  `itemid → d_labitems.itemid` (dictionary table **not present** in this dataset — see gap note below)
- **Profiling notes:**
  - 28,420 / 107,728 rows (26%) have a **null `hadm_id`** — labs drawn before an admission
    record is linked (e.g. in the ED). Joining this table to the cohort on `hadm_id` alone would
    silently drop a quarter of the rows, including some of the earliest and most predictive
    labs. The join must key on `subject_id` + the `charttime` window instead (see
    `sql/features/labs_first24h.sql`).
  - 12,481 rows (11.6%) have a **null `valuenum`** (non-numeric/qualitative results) — must be
    filtered out before numeric aggregation.
  - Itemids `50912`, `51301`, `51222` were empirically verified against `value`, `valueuom`, and
    `ref_range_lower/upper` in this file and match physiologically plausible creatinine
    (mg/dL, ref ~0.5–1.2), WBC (K/uL, ref ~4–11), and hemoglobin (g/dL, ref ~13.7–18) ranges —
    consistent with their well-documented public MIMIC-IV itemid identities.

| Column | Keep? | Reason for Dropping | Time Availability | Leakage Risk |
|---|---|---|---|---|
| `subject_id` | Keep | — | N/A | NONE — join key |
| `hadm_id` | Keep (nullable) | — | N/A | NONE — secondary validation key, not primary join key |
| `itemid` | Keep | — | N/A | NONE — identifies which lab test |
| `charttime` | Keep | — | WITHIN-24H | LOW — this is the timestamp the 24h filter is applied against |
| `valuenum` | Keep | — | WITHIN-24H | LOW — the feature value itself |
| `valueuom` | Keep (QA only) | — | N/A | NONE — used to assert unit consistency, not a feature |
| `ref_range_lower` / `ref_range_upper` | Keep (QA only) | — | N/A | NONE — used for abnormal-value validation, not a feature |
| `flag` | Keep (QA only) | — | WITHIN-24H | NONE — cross-check against our own abnormal-value logic |
| `labevent_id` | Drop | Surrogate row identifier, no clinical content | N/A | NONE |
| `specimen_id` | Drop | Internal grouping key for rows drawn from the same specimen; not needed once `itemid`+`charttime` dedup is applied | N/A | NONE |
| `storetime` | Drop as filter basis, kept as QA field | See gap note below — result isn't truly "available" until stored, not merely collected | WITHIN-24H (stricter) | LOW |
| `order_provider_id` | Drop | High-cardinality identifier, not predictive | N/A | NONE |
| `priority` | Drop | Order priority (routine/stat) — out of scope for this feature set | N/A | NONE |
| `value` | Drop | Redundant with `valuenum` for the three numeric labs used; raw text not needed | N/A | NONE |
| `comments` | Drop | Free text, mostly null/non-standardized | N/A | NONE |

**⚠️ Data gap:** `d_labitems.csv` (the lab dictionary mapping `itemid → label`) is **not**
present in `data/raw/`. Itemid-to-lab-name mapping for this project was established by
empirical profiling (value ranges, units, reference ranges), not by dictionary lookup. Before
extending the lab feature set beyond the three labs already verified, obtain `d_labitems.csv`
(a small, static file from the same PhysioNet release) and cross-check any new itemid against it
rather than guessing from value shape alone.

**⚠️ Design decision — `charttime` vs `storetime`:** `charttime` is when the specimen was
*collected*; `storetime` is when the result was *posted to the chart* (always ≥ `charttime`,
often by hours). A value isn't actually knowable to a clinician (or a model deployed in
real-time) until `storetime`. Using `charttime` alone for the 24h filter is optimistic and
introduces a small look-ahead leak — a specimen drawn at hour 23 might not result until hour 27.
`sql/features/labs_first24h.sql` filters on `charttime` for the collection window but documents
`storetime` as the stricter, more realistic alternative (see that file's header comment).

---

## 6. `prescriptions` — first-24h medication exposure

- **Primary Key:** none of the provided columns is guaranteed unique per row on its own in this
  extract; treat the natural key as (`subject_id`, `hadm_id`, `pharmacy_id`, `starttime`, `drug`)
  for de-duplication purposes.
- **Foreign Keys:** `subject_id → patients.subject_id`, `hadm_id → admissions.hadm_id`
- **Profiling note:** `drug` (free text) is the only column that reliably identifies the
  medication in human-readable form in this extract; `formulary_drug_cd` / `gsn` / `ndc` are
  present but are coding-system identifiers layered on top of the same drug and are redundant
  for a name-based classification approach.

| Column | Keep? | Reason for Dropping | Time Availability | Leakage Risk |
|---|---|---|---|---|
| `subject_id` | Keep | — | N/A | NONE — join key |
| `hadm_id` | Keep | — | N/A | NONE — join key |
| `starttime` | Keep | — | WITHIN-24H | LOW — timestamp the 24h filter is applied against |
| `drug` | Keep | — | WITHIN-24H | LOW — source text for antibiotic/insulin classification |
| `drug_type` | Keep (QA only) | — | N/A | NONE — distinguishes MAIN/BASE/ADDITIVE components of one order; used to avoid double-counting a single clinical order as multiple medications |
| `stoptime` | Drop | Not needed — only presence/count within the 24h window is used, not duration | POST-24H (variable) | LOW (unused) |
| `pharmacy_id` / `poe_id` / `poe_seq` / `order_provider_id` | Drop | Internal order/identifier fields, no clinical content | N/A | NONE |
| `formulary_drug_cd` / `gsn` / `ndc` | Drop | Redundant coded identifiers for the same drug already captured in `drug` | N/A | NONE |
| `prod_strength` / `dose_val_rx` / `dose_unit_rx` / `form_val_disp` / `form_unit_disp` / `doses_per_24_hrs` / `route` | Drop (v1) | Dose-intensity features are out of scope for the proposal's exposure/count feature set; flagged as a future extension | WITHIN-24H | LOW (unused) |
| `form_rx` | Drop | Formulation detail, not needed for exposure/count features | N/A | NONE |

---

## Cross-Table Notes

1. **No dictionary tables are present** (`d_labitems`, `d_icd_diagnoses`, `d_items`, etc.) —
   consistent with the proposal's decision to exclude dictionary tables, but it means `itemid`
   and `icd_code` meaning must be resolved via curated reference lists in `data/external/`
   rather than a join, and those lists must be validated (see `docs/validation_strategy.md`).
2. **`stay_id` is the only safe one-row-per-cohort-unit anchor.** `subject_id` and `hadm_id` are
   not 1:1 with the cohort (a subject can have multiple stays across multiple admissions) —
   every join in `sql/features/*.sql` must resolve back to exactly one row per `stay_id`.
3. Every column marked **Drop** for leakage reasons (HIGH) is a real column in the raw data,
   not a hypothetical — this table doubles as the enforceable checklist behind
   `tests/test_no_leakage.py`.

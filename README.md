# Business Intelligence Copilot

An end-to-end banking analytics project built using the Berka (PKDD'99) Czech banking dataset. The project focuses on data engineering, business intelligence, descriptive analytics, and credit-risk analysis, with the longer-term goal of building an AI-powered analytics copilot.

## Project Overview

The objective is to transform raw banking data into a structured analytical warehouse, derive meaningful business insights, and develop a foundation for credit-risk analysis.

**Planned data flow:**

`Raw Data → PostgreSQL → Staging Layer → Analytics Star Schema → SQL Analysis → Power BI → Machine Learning → AI Copilot`

The project uses free and open-source tools wherever practical.

## Current Progress

- [x] Dataset selection and initial profiling
- [x] Raw data ingestion into PostgreSQL
- [x] Raw data validation against expected row counts and relationships
- [x] Staging layer with cleaned, typed, and standardized data
- [x] Analytics layer using a star schema
- [x] Analytics validation and descriptive KPI queries
- [ ] Diagnostic analysis and investigation of unusual transaction patterns
- [ ] Python-based analysis and visualizations
- [ ] Power BI dashboard
- [ ] Loan outcome analysis and machine-learning experiments
- [ ] API and AI-powered analytics interface

## Technology Stack

| Area | Technology |
|---|---|
| Programming | Python |
| Database | PostgreSQL |
| SQL development | DBeaver |
| Data ingestion | Python, psycopg, PostgreSQL `COPY` |
| Data transformation | SQL |
| Data analysis | SQL; pandas planned |
| Version control | Git and GitHub |
| Visualization | Power BI planned |
| Machine learning | Planned |

## Dataset

The project uses the Berka dataset from the PKDD'99 Discovery Challenge, containing anonymized Czech banking data from 1993 to 1998.

| Dataset component | Records |
|---|---:|
| Districts | 77 |
| Accounts | 4,500 |
| Clients | 5,369 |
| Account dispositions | 5,369 |
| Cards | 892 |
| Loans | 682 |
| Standing orders | 6,471 |
| Transactions | 1,056,320 |

Source: [PKDD'99 Berka Dataset](https://sorry.vse.cz/~berka/challenge/pkdd1999/berka.htm)

The original dataset files are not included in this repository. Check the dataset's applicable terms of use before redistributing the data.

## Data Architecture

### 1. Raw Layer

The `raw` schema preserves the source data in PostgreSQL. Python uses PostgreSQL's `COPY` mechanism for bulk ingestion, followed by validation of row counts and relationships.

### 2. Staging Layer

The `staging` schema standardizes data types, converts dates, maps transaction codes to readable categories, and creates derived fields for analysis.

### 3. Analytics Layer

The `analytics` schema uses a star-schema design for reporting and analytical queries.

**Fact tables**
- `fact_transactions` — one row per transaction
- `fact_loans` — one row per loan

**Dimension tables**
- `dim_date`
- `dim_account`
- `dim_district`
- `dim_txn_category`

The design supports analysis by time, account, region, transaction type, and loan outcome.

## Business Questions

The analysis is designed to investigate questions such as:

- How did account activity and transaction volumes change between 1993 and 1998?
- Which transaction categories dominate by transaction count and monetary value?
- How does activity per account vary across regions?
- How did the loan book change over time?
- Was transaction growth driven by account growth or increased activity per account?
- What explains unusual monthly transaction volumes and credit totals?
- Which characteristics are associated with loans classified as being in trouble?

The eventual credit-risk model will be evaluated separately from descriptive findings. Historical loan statuses are not treated as proof of future default.

## Repository Structure

```text
Business_Copilot/
├── Data/
│   └── raw/                       # Local source data; not committed
├── src/
│   └── load_raw_data.py           # PostgreSQL bulk loader
├── 01_create_raw_schema.sql
├── 02_verify_raw_load.sql
├── 03_initial_exploration.sql
├── 04_create_staging.sql
├── 05_validate_staging.sql
├── 06_create_analytics.sql
├── 07_validate_analytics.sql
├── 08_descriptive_kpis.sql
├── business_questions_and_kpis.md
├── requirements.txt
├── .gitignore
└── README.md
```

This structure reflects the current project layout; update it as additional scripts and modules are added.

## Setup

### Prerequisites

- Python installed
- PostgreSQL installed and running
- DBeaver or another PostgreSQL SQL client
- The Berka dataset downloaded and placed in `Data/raw/`

### 1. Clone the repository

```powershell
git clone https://github.com/TheTechBud/Business_Copilot.git
cd Business_Copilot
```

### 2. Create and activate a virtual environment

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
```

### 3. Install dependencies

```powershell
python -m pip install -r requirements.txt
```

### 4. Prepare the dataset

Place the eight source files in `Data/raw/`:

- `district.asc`
- `account.asc`
- `client.asc`
- `disp.asc`
- `card.asc`
- `loan.asc`
- `order.asc`
- `trans.asc`

These files are intentionally excluded from Git.

### 5. Create the database and raw schema

Create a PostgreSQL database named `business_analytics_copilot`, then execute `01_create_raw_schema.sql` in DBeaver.

### 6. Load and validate the raw data

Run the loader from the project directory:

```powershell
python src\load_raw_data.py
```

Follow the script's prompts for database connection details. Review its validation output before proceeding.

If the raw tables already contain data, inspect the loader's behavior and use its supported reload option only when a reload is intended.

### 7. Build and validate the staging layer

Execute `04_create_staging.sql`, then run the validation queries in `05_validate_staging.sql`.

### 8. Build and validate the analytics layer

Execute `06_create_analytics.sql`, then run the validation queries in `07_validate_analytics.sql`.

### 9. Run descriptive analysis

Execute the queries in `08_descriptive_kpis.sql` to analyze transaction activity, category distributions, regional patterns, fees, and loan statistics.

**Note:** The SQL files are executed individually in the current workflow. If the repository later adds an automated warehouse build script, update these instructions to reflect the tested implementation.

## Analytical Considerations

- The dataset has no explicit account-closure flag, so inactivity alone is not treated as definitive customer churn.
- Fee-related income is represented by a proxy based on statement fees and penalty interest; it is not total bank revenue.
- Interest credited to customers is treated as a cost to the bank.
- The loan trouble measure uses original loan amounts for selected historical statuses, not outstanding debt or realized losses.
- Historical loan outcomes may be incomplete because some loans were still running at the end of the observation period.
- Descriptive findings, model predictions, and AI-generated recommendations must remain distinct.

See [`business_questions_and_kpis.md`](business_questions_and_kpis.md) for the detailed business questions, KPI definitions, assumptions, and project decisions.

## Future Work

1. Complete diagnostic investigations and document evidence-based findings.
2. Build reproducible Python analysis and visualizations.
3. Develop a Power BI dashboard.
4. Analyze historical loan outcomes and establish a leakage-aware machine-learning baseline.
5. Develop an API and local-LLM interface for natural-language questions over validated analytics.

## Author

**TheTechBud**

GitHub: [github.com/TheTechBud](https://github.com/TheTechBud)

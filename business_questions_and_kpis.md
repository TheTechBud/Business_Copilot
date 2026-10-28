# Business questions, KPIs and decisions (DRAFT: rewrite in your own words)

This document is the "why" of the project. Every analysis, dashboard page and model should trace back to a
question below. If you cannot explain a question or a definition in an interview, change it until you can.

## 1. Facts about the dataset that shape the questions

- Berka (PKDD'99): real, anonymised Czech bank. 1993-01-01 to 1998-12-31, 4,500 accounts, 1,056,320 transactions, 682 loans.
- **"Customer" = account.** Every account has exactly one OWNER; other users (disponents) are ignored for now.
- **There is no revenue column.** The closest proxy is fee income (statement fees + penalty interest). Interest credited
  to customers is a cost. Interest earned on loans cannot be separated from loan repayments.
- **There is no churn or account-closure flag**, and inactivity is not usable: the bank posts interest to every account,
  and even without bank postings only 0.1-0.7% of accounts go silent for 90 days. So "churn = no transaction in X days"
  has almost no positive cases. The spec's primary ML problem is therefore changed (see decisions).
- **There is no time of day.** 43.7% of transactions share a date with another transaction of the same account, so the
  order within a day is unknown. No claims about intraday order or exact closing balances.
- Loan outcomes are **right-censored**: status C (running, OK) may still turn bad after 1998.

## 2. The ten questions

| # | Level | Question | Answered with | Status |
|---|---|---|---|---|
| D1 | Descriptive | How did accounts, customer activity and money flow change from 1993 to 1998? | `08_descriptive_kpis.sql` K1, K4 | |
| D2 | Descriptive | What do customers do with their accounts, by number of transactions and by value? | K2 | |
| D3 | Descriptive | Do regions differ in activity per account? | K3 | |
| D4 | Descriptive | How large is the loan book and how did it grow? | K5 | |
| G1 | Diagnostic | Is growth driven by new accounts or by more activity per account? | K1 + decomposition (task 1) | |
| G2 | Diagnostic | What explains the unusual months (Jan 1998 volume, Jun/Dec 1998 credits)? | your investigation | |
| G3 | Diagnostic | Using only information known when the loan starts, what distinguishes loans that end in trouble (B/D) from those that do not? | analysis + statistics phase | |
| P1 | Predictive | Which loans are likely to end in trouble? (primary ML: credit risk) | ML phase | |
| P2 | Predictive | Which accounts are likely to show a sharp drop in customer-initiated activity in the next 90 days? (secondary, a proxy, not churn) | ML phase, only if the base rate allows | |
| R1 | Prescriptive | Which regions and segments hold the most loan amount in trouble, and which active, high-balance accounts should be reviewed first? | dashboard recommendations page | |

## 3. KPI dictionary

| KPI | Definition | Caveat |
|---|---|---|
| Customer-initiated transaction | Any transaction whose category has `is_bank_generated = false` | Includes recurring payments (SIPO, POJISTNE, UVER, DUCHOD) that the customer arranged |
| Active account (period) | At least one customer-initiated transaction in the period | |
| Transactions per active account | Customer-initiated transactions / active accounts | Accounts opened mid-year have only part of a year, so early years look lower |
| Net flow | Sum of `signed_amount` (credits minus debits) | Transaction type VYBER is treated as a debit (verified on 9,597 unambiguous rows) |
| Fee income (revenue proxy) | Statement fees + penalty interest | Not total bank revenue |
| Interest paid to customers | Sum of `interest_credit` | A cost to the bank |
| Loan amount in trouble | Original amount of loans with status B or D | Original amount, not outstanding debt; status D is still running |
| Loan trouble rate | Loans with status B or D / all loans (by count or by amount) | Right-censored, and small regional samples |

## 4. Three kinds of statements (keep them apart everywhere)

1. **Fact**: computed by SQL from the data ("606 of the 682 loans are status A or C").
2. **Model prediction**: a probability from a trained model, with its evaluation and limits.
3. **AI recommendation**: text from the copilot. It must cite the facts and predictions it used and must not state causes
   the data cannot support.

## 5. Decisions log

| # | Decision | Why |
|---|---|---|
| 1 | Use Berka instead of the 50k-row synthetic Kaggle file | The synthetic file had random dates, unstable customer attributes and no behavioural signal |
| 2 | Raw layer loaded with PostgreSQL COPY in one verified transaction | The pandas multi-row INSERT exceeded PostgreSQL's 65,535-parameter limit |
| 3 | Type VYBER is a debit | Balance reconciles 100% on 9,597 unambiguous rows |
| 4 | Transaction category uses `k_symbol` before `operation` | 155,832 statement fees are recorded with operation VYBER (cash withdrawal) |
| 5 | Primary ML problem is loan trouble (P1), not churn | Churn by inactivity has almost no positive cases in this data |
| 6 | P2 (activity decline) is optional | Its label is a proxy; test its base rate in the analysis phase before committing |
| 7 | Account = customer | One owner per account; avoids a many-to-many link in the star schema |
| 8 | No exact closing balance or intraday order claims | No time of day; the `trans_id` tie-break was right only about half the time |

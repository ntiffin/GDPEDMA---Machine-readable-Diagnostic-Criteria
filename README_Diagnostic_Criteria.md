# GDM Guidelines Pipeline

Evaluates a dataset of pregnant women's glucose test results against multiple
gestational diabetes diagnostic guidelines (IADPSG, NICE, WHO, ADA, RCOG,
Diabetes UK, NHS/hospital-trust guidance, NDDG, Carpenter-Coustan, and DIPSI),
and produces one output row per person with a 0/1/NA result per guideline
plus a combined summary score.

## Files in this package

| File | What it is |
|---|---|
| `lookup_table.txt` | **The single source of truth.** One row per guideline: its thresholds, a ready-to-run R formula (`Algorithm_R`) that references those thresholds by name rather than hardcoding numbers, and an explicit `required_variables` variable listing exactly which datatable variables that formula needs. To change a threshold, add a guideline, or add a new required variable (e.g. age, parity - not just glucose values), edit this file - never edit a formula's numbers directly in code. |
| `run_guidelines.R` | The pipeline. Reads the lookup table and your datatable, works out per guideline what data each person needs, evaluates it, and writes the output. |
| `run_guidelines_mysql.sql` | The same pipeline as a MySQL stored procedure, for people who prefer to stay in their database. Uses the same lookup table (loaded into a MySQL table) and gives the same results. See "Running it in MySQL instead of R" below. |
| `synthetic_dataset.txt` | A made-up example dataset (1001 women), included so this script runs out of the box. Replace with your own data when ready - see below. |
| `README.md` | This file. |

If you need to regenerate `lookup_table.txt` from a raw Excel-exported
source table (e.g. because the underlying guideline definitions changed),
that's done by `clean_lookup_table.R` in the parent development folder,
not part of this package.

## Running it on your own data

Open `run_guidelines.R` and edit only the **CONFIGURATION** block near the
top of the file:

- `home_directory` - the folder everything else is relative to (this
  package's folder, unless you've moved things around).
- `lookuptable_filename` - usually leave as `lookup_table.txt`.
- `datatable_filename` - your own data file (tab-separated `.txt`). One row
  per person. Variable names must match the names in the lookup table's `required_variables` -
  see the data dictionary (e.g. `ogtt_75g_fasting_mmoll`). Missing values
  should be blank or the text `NULL`.
- `id_field` - the name of your datatable's unique-identifier variable (e.g.
  `"study_id"` or `"patient_id"`). Only used to make error messages easier
  to trace; the calculations don't depend on it.
- `output_filename` - where the results get written.

Then run the whole script. Nothing below the configuration block needs
editing to use it on new data - only edit further down if you're changing
how the pipeline itself works.

If your datatable has no variable with a name a guideline needs (a typo, or a
missing `_mmoll` suffix), the script says so at the start of the run and lists
which guidelines will come out NA for everyone, rather than quietly giving
NA.

## The output file

The output starts as an exact copy of your datatable (every original variable
preserved, in order), then has one new variable appended per guideline (1 =
criteria met, 0 = not met, NA = that person didn't have the measurements
that guideline needs), and finally one summary variable at the very end:
`outcome_combined`.

### `outcome_combined`

```
outcome_combined = sum(weight_i * guideline_i)
```

summed across whichever guidelines actually produced a result for that
person. A guideline that came back NA for someone (not enough data) is
excluded from the sum entirely - it does not count as a 0. If literally no
guideline could be evaluated for someone, `outcome_combined` is NA for them
too, rather than a misleading 0 (which would otherwise look identical to
"tested negative on everything").

By default every guideline has a weight of 1, so `outcome_combined` is just
a count of how many guidelines that person met.

**To change the weighting**, edit the `combined_outcome_weights_string`
line in the CONFIGURATION block (line 75 of `run_guidelines.R` as of
this version - search the file for `combined_outcome_weights_string` if
the line has since moved). Write it as comma-separated `ABBREVIATION=weight` pairs, using the same
spelling as the `Abbreviation` variable in the lookup table. Weights must be
between 0 and 5. Any guideline you don't mention keeps the default weight
of 1.

```r
combined_outcome_weights_string <- "IADPSG=2, WHO_1999=0.5"
```

Guideline abbreviations currently in the lookup table: `IADPSG`, `NICE`,
`WHO_1999`, `WHO_2013`, `ADA`, `RCOG`, `Diabetes_UK`, `India`, `NHS`,
`MKUH`, `Barnley`, `RCHT`, `NDDG`, `CC`.

Typos or out-of-range weights (outside 0-5) are ignored with a warning
rather than silently breaking the run - check the console output for any
`Ignoring weight for...` messages after running.

## Running only a subset of guidelines

By default every guideline in the lookup table is evaluated. To restrict a
run to a subset, open `run_guidelines.R`, find the commented-out line
just after the lookup table is read in (search for `OPTIONAL: restrict`),
uncomment it, and edit the list of `Abbreviation` values to the guidelines
you want, e.g.:

```r
lookuptable <- lookuptable[lookuptable$Abbreviation %in% c("IADPSG", "NICE"), ]
```

This only filters the in-memory copy used for that run - it never modifies
`lookup_table.txt` itself.

## Running it in MySQL instead of R

`run_guidelines_mysql.sql` does what `run_guidelines.R` does, entirely
inside MySQL. It is one script in four parts:

- **Part 0 - configuration (everything you edit is here).** The names of the
  two tables (`guideline_lookup_table`, `dataset_table`), the combined-outcome
  weights and an optional subset of guidelines as in the R script, and the
  locations of the two input files, which are loaded with
  `LOAD DATA LOCAL INFILE` in the two statements marked
  `>>> EDIT PATH AND FILE NAME <<<`.
- **Part 1 - one-time set-up.** Builds `guideline_lookup_table` from the lookup
  file. Run this once.
- **Part 2 - build your data table.** Builds `dataset_table` from your data
  file. Run this for each new data file.
- **Part 3 - the analysis.** A stored procedure that adds the results to
  `dataset_table` as new variables: one per guideline (1, 0, or NULL where R has
  NA) and `outcome_combined` last. There is no separate output table. The
  result of the `CALL` also lists how many people were positive for each
  guideline.

MySQL does not allow a `LOAD DATA` path to come from a variable, so the two file
locations are written inside those two statements rather than held in variables;
nothing below Part 0 contains a path or a file name. The tables
are built from the header line of each file, so a variable added to the lookup
file needs no change to the script. Each guideline's formula is in the lookup
table's `Algorithm_SQL` variable, which reads its thresholds from the threshold
variables exactly as `Algorithm_R` does, so changing a threshold in the lookup
table changes the R and the SQL results together. Your server needs
`local_infile` switched on (see the next section). The bottom of
the SQL file has a check you can run on `synthetic_dataset.txt` and the numbers
the R pipeline gives for it.

### Switching on `LOAD DATA LOCAL INFILE` (MySQL)

Loading the files needs this switched on in **two** places: the server, and the
client you run the script from. The server setting is the same either way. It
needs an administrator account such as `root`, and lasts until the MySQL service
restarts:

```sql
SET GLOBAL local_infile = 1;
SHOW GLOBAL VARIABLES LIKE 'local_infile';   -- should say ON
```

**Command line.** Start the client with the flag, choose a database, then run
the script (forward slashes in the path; quotes are only needed if the path
contains a space):

```text
mysql --local-infile=1 -u root -p
USE gdm;
source C:/path/to/run_guidelines_mysql.sql
```

If Windows says `mysql` is not recognized, either run it by its full path
(for example `"C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe"`), or add
that `bin` folder to your Path under Environment Variables and open a new
Command Prompt. `source` only works in the command-line client, not in
Workbench's query editor.

**MySQL Workbench.**
1. Menu **Database > Manage Connections...**. Click your connection in the left
   list, open the **Advanced** tab, and in the **Others** box type
   `OPT_LOCAL_INFILE=1`. Click **Close**.
2. Close all open query tabs, then open the connection again (double-click it
   on the Home screen). A tab that was already open keeps the old setting.
3. Run the script with **nothing selected**, using the first lightning-bolt
   button, so the whole script runs in one go. Running only a selected part can
   leave out the `DELIMITER $$` line and give a syntax error "near ''" at a
   `CREATE PROCEDURE`.

**If it fails.** Error 2068 ("file request rejected due to restrictions on
access") means the client setting is missing; error 3948 means the server
setting is off. An "unable to open file" error usually means a typo in the path
in PART 0 of the script.

## How a guideline result is calculated

For each person and each guideline, the pipeline:

1. Reads the guideline's `required_variables` field directly out of the
   lookup table - an explicit, hand-checked list of exactly which
   datatable variables that guideline's formula needs (never guessed from
   the formula text, and never from the lookup table's binary flag
   variables, which don't reliably match what each formula uses).
2. If the person is missing any of those variables, the result is `NA` - the
   formula is never even attempted.
3. Otherwise, it evaluates the guideline's `Algorithm_R` formula in an
   environment containing both the person's own measurements and that
   guideline's own threshold values (pulled live from the lookup table
   row), producing `1` or `0`.

## Using the pipeline for a different condition

Nothing in the R or MySQL code is specific to gestational diabetes: the
thresholds, formulas and required measurements all live in the lookup table.
To run a different condition and a different set of guidelines, build a new
lookup table with one row per guideline. The code only needs the following
(everything else in the lookup table, such as `Guideline`, the dates, `url`
and the flag variables, is ignored):

| Field | Needed by | What it must contain |
|---|---|---|
| `Abbreviation` | R and SQL | A short unique name per guideline. It becomes the name of the result variable. For the SQL version use letters, digits and underscores only. |
| `required_variables` | R and SQL | The exact names of the data variables the formula needs, separated by `\|`. If any is missing for a person, the result is `NA`. |
| `Algorithm_R` | R only | An R expression such as `ifelse(...)`. A leading `NAME <-` is allowed and is stripped off. |
| `Algorithm_SQL` | SQL only | A single MySQL expression that can sit inside `CASE WHEN ... THEN <expression>`. |
| the threshold variables | R and SQL | Any variables the formulas refer to by name. |

Things to be careful about:

- **The formula must return 1 (positive), 0 (negative) or NULL/NA.** The SQL
  result variables are `TINYINT`, positives are counted as `= 1`, and
  `outcome_combined` adds the results up. A formula that returns a score or a
  category will not work.
- **`Algorithm_R` and `Algorithm_SQL` are separate.** You only need the one for
  the version you run, but nothing checks that the two give the same answer,
  so check them against each other on example data.
- **MySQL: threshold variables must have `threshold` in their name** (for
  example `hba1c_threshold_percent`), and `threshold` must only be used in the
  names of numeric variables. That is how PART 1 decides which lookup variables are
  stored as numbers; any others are stored as text.
- **MySQL: every variable in `required_variables` must be numeric.** These
  variables are loaded as numbers, so a text measurement (for example yes/no)
  will cause an error. The R version accepts any type.
- **No variable in the data may have the same name as any variable in the lookup table.** The
  lookup table has variables called `weight`, `url` and `Guideline`, for example.
  In SQL a clash makes the formula ambiguous and gives an error. In R the lookup
  value silently replaces the person's value, so the results would be wrong
  without any warning from the formulas themselves. Both scripts therefore
  check for this at the start and print a warning naming the clashing variables.
  Rename the data variable (or the lookup variable) if you see it.

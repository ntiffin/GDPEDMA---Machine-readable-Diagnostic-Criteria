# =============================================================================
# GDM GUIDELINES PIPELINE
#
# What this script does:
#   For every person in your datatable, and for every guideline in the
#   lookup table, it works out whether that person's own measurements meet
#   that guideline's diagnostic criteria - producing 1 (criteria met),
#   0 (criteria not met), or NA (that person doesn't have the measurements
#   this guideline needs, so it genuinely cannot be calculated for them).
#   It then adds one combined summary score across all guidelines.
#
# The lookup table (lookup_table.txt, alongside this script) is the single
# source of truth for every guideline's logic and thresholds. This script
# never hardcodes a threshold number anywhere - if a threshold needs to
# change, edit the lookup table, not this file.You can also add new guidelines
# as new rows to the lookup table, without needing to modify the script 
# that you run.
#
# To deploy this on your own data: edit ONLY the CONFIGURATION section
# immediately below, then run the whole script. You should not need to
# touch anything past that section unless you are changing how the
# pipeline itself works.
# =============================================================================


# =============================================================================
# CONFIGURATION - edit this section for your own setup
# =============================================================================

# The folder everything else in this section is relative to.
# Change this to wherever you've put your own copy of the lookup table,
# your datatable, and where you want the output written.
home_directory <- "C:/Users/ntiffin/Dropbox/Documents/academic_programme/research/2024_GeD-GSN/2026_guidelines_paper/Nicki_code/final"

# The lookup table: one row per guideline, holding its thresholds and its
# ready-to-run R formula. You normally won't need to change this unless
# you keep your lookup table somewhere else.
lookuptable_filename <- "lookup_table.txt"

# Your own data: one row per person, with a variable per measurement. Variable
# names MUST match the variable names the lookup table's formulas use
# (e.g. ogtt_75g_fasting_mmoll) - see the data dictionary for the full list.
# Any measurement a person doesn't have should be blank or "NULL".
# (synthetic_dataset.txt is included here as a working example so this
# script runs out of the box - point this at your own file when ready.)
datatable_filename <- "synthetic_dataset.txt"

# The name of the variable in your datatable that uniquely identifies each
# person (e.g. "person", "study_id", "patient_id"). Used only to make
# error/warning messages easier to trace back to a specific person - the
# calculations themselves don't depend on this variable's name.
id_field <- "study_id"

# Where the results get written (tab-separated, same folder as above).
output_filename <- "output_table.txt"

# --- Combined outcome weighting -------------------------------------------
#
# outcome_combined = sum(weight_i * guideline_i) across every guideline
# that could actually be calculated for that person (guidelines that came
# back NA - not enough data - are excluded from the sum entirely, not
# counted as 0). If NO guideline could be calculated for someone at all,
# outcome_combined is NA for them too.
#
# By default every guideline gets a weight of 1, so outcome_combined is
# simply "how many guidelines this person met".
#
# To use different weights, write them here as "ABBREVIATION=weight" pairs
# separated by commas, using the same Abbreviation spelling as in the
# lookup table (IADPSG, NICE, WHO_1999, WHO_2013, ADA, RCOG, Diabetes_UK,
# India, NHS, MKUH, Barnley, RCHT, NDDG, CC). Weights should be between 0
# and 5. Any guideline you don't mention keeps the default weight of 1.
#
# Example: combined_outcome_weights_string <- "IADPSG=2, WHO_1999=0.5"
combined_outcome_weights_string <- ""


# =============================================================================
# From here on is the pipeline itself - you shouldn't need to edit below
# this line to run this on your own data.
# =============================================================================

setwd(home_directory)

# --- Section 1: read in the two input tables --------------------------------
#
# na.strings tells R to treat both a truly empty cell and the literal text
# "NULL" as missing data (NA), since both appear in these files depending
# on how they were exported from Excel.

if (!file.exists(lookuptable_filename)) {
  stop("Can't find the lookup table at: ", lookuptable_filename,
       " (check lookuptable_filename and home_directory above)")
}
if (!file.exists(datatable_filename)) {
  stop("Can't find the datatable at: ", datatable_filename,
       " (check datatable_filename and home_directory above)")
}

datatable <- read.delim(
  datatable_filename,
  stringsAsFactors = FALSE,
  na.strings = c("NULL", "")
)

lookuptable <- read.delim(
  lookuptable_filename,
  stringsAsFactors = FALSE,
  check.names = FALSE,      # keep variable names exactly as written, don't "fix" them
  na.strings = c("NULL", ""),
  fileEncoding = "UTF-8-BOM" # lookup_table.txt carries a UTF-8 BOM so it opens
                             # cleanly in Excel; this strips it back off on read
)
# Excel exports sometimes leave a trailing tab on the header row, which
# read.delim turns into one extra variable with no name - drop it if present.
lookuptable <- lookuptable[, names(lookuptable) != ""]

# --- OPTIONAL: restrict this run to a subset of guidelines ------------------
#
# By default every guideline in the lookup table is used. If you only want
# to evaluate a subset, uncomment the line below and edit the list to the
# Abbreviation values you want (see the lookup table's Abbreviation variable
# for the full list, e.g. IADPSG, NICE, WHO_1999, WHO_2013, ADA, RCOG,
# Diabetes_UK, India, NHS, MKUH, Barnley, RCHT, NDDG, CC).
#
# This only ever affects the in-memory copy of the lookup table for this
# run - it never modifies lookup_table.txt itself, so the single source of
# truth is untouched no matter what you subset here.

# lookuptable <- lookuptable[lookuptable$Abbreviation %in% c("IADPSG", "NICE"), ]

if (!(id_field %in% names(datatable))) {
  warning("id_field ('", id_field, "') was not found in the datatable - ",
          "row numbers will be used in messages instead.")
}

# Warn if any datatable variable has the same name as a lookup table variable
# (for example "weight", "url" or "Guideline"). The formulas are evaluated in an
# environment where the lookup row's values are assigned AFTER the person's, so
# a clash would silently replace the person's value with the lookup value.
name_clashes <- intersect(names(datatable), names(lookuptable))
if (length(name_clashes) > 0) {
  warning(
    "These datatable variables have the same name as a lookup table variable, so the ",
    "lookup table value will be used instead of the person's value wherever a ",
    "formula refers to them: ", paste(name_clashes, collapse = ", "),
    ".\nRename the variable in the datatable (or in the lookup table, including ",
    "in the formulas) to avoid wrong results.",
    call. = FALSE, immediate. = TRUE
  )
}

# --- Section 2: work out what each guideline actually needs -----------------
#
# required_variables is an explicit variable in the lookup table (pipe-
# separated exact datatable variable names) - the authoritative answer to
# "what does this guideline's formula need from the person". We do NOT
# guess this from the formula text or from the lookup table's binary flag
# variables (gct_50g_1h, fpg, etc.) - those flags don't reliably match what
# each formula actually uses, and a formula referencing something other
# than a "..._mmoll" measurement (e.g. age, parity) couldn't be detected
# by pattern-matching anyway. required_variables is written and checked
# by hand alongside each Algorithm_R in clean_lookup_table.R, so the two
# can never drift apart.

lookuptable$required_vars <- lapply(
  lookuptable$required_variables,
  function(x) trimws(strsplit(x, "\\|")[[1]])
)

# Warn up front about any guideline that cannot be calculated for anyone
# because the datatable has no variable with the name it needs. Without this
# the result is simply NA for everyone, which looks like "no data" rather
# than "wrong variable name" - for example a variable called ogtt_75g_fasting
# when the lookup table needs ogtt_75g_fasting_mmoll.
missing_by_guideline <- lapply(lookuptable$required_vars, setdiff, names(datatable))
names(missing_by_guideline) <- lookuptable$Abbreviation
missing_by_guideline <- missing_by_guideline[lengths(missing_by_guideline) > 0]
if (length(missing_by_guideline) > 0) {
  warning(
    "These guidelines will be NA for everyone because the datatable has no ",
    "variable with the name they need:\n",
    paste0("  ", names(missing_by_guideline), " needs ",
           sapply(missing_by_guideline, paste, collapse = ", "), collapse = "\n"),
    "\nVariable names must match the lookup table's required_variables exactly ",
    "(see the data dictionary).",
    call. = FALSE, immediate. = TRUE
  )
}

# Algorithm_R is written as "ABBREVIATION <- ifelse(...)". We only want to
# evaluate the right-hand side (the ifelse(...) part) and use its result
# directly, so strip off the "ABBREVIATION <- " prefix here, once, up front.
lookuptable$algorithm_expr <- sub("^[A-Za-z0-9_]+\\s*<-\\s*", "", lookuptable$Algorithm_R)

# --- Section 3: set up the output table --------------------------------------
#
# The output starts as an exact copy of the datatable (so every original
# variable is preserved), then gets one new variable appended per guideline,
# in the same order as the lookup table.

output_table <- datatable
guideline_cols <- lookuptable$Abbreviation
for (abbr in guideline_cols) {
  output_table[[abbr]] <- NA_real_
}

# --- Section 4: parse the combined-outcome weights ---------------------------
#
# This turns the CONFIGURATION string above into a named numeric vector,
# one weight per guideline, defaulting to 1 for anything not mentioned.
# This is done here (rather than back in the config section) because it
# needs to know the actual guideline names from the lookup table first, so
# it can catch typos in the config string rather than silently ignoring them.

parse_combined_outcome_weights <- function(weights_string, guideline_cols) {
  weights <- setNames(rep(1, length(guideline_cols)), guideline_cols)

  weights_string <- trimws(weights_string)
  if (nchar(weights_string) == 0) return(weights)

  entries <- strsplit(weights_string, ",")[[1]]
  for (entry in entries) {
    parts <- strsplit(trimws(entry), "=")[[1]]
    if (length(parts) != 2) {
      warning("Ignoring unreadable weight entry: '", entry, "'")
      next
    }
    guideline <- trimws(parts[1])
    weight    <- suppressWarnings(as.numeric(trimws(parts[2])))

    if (!(guideline %in% guideline_cols)) {
      warning("Ignoring weight for unknown guideline '", guideline, "' - ",
              "check spelling against the lookup table's Abbreviation variable.")
      next
    }
    if (is.na(weight) || weight < 0 || weight > 5) {
      warning("Ignoring invalid weight for '", guideline, "' - ",
              "must be a number between 0 and 5.")
      next
    }
    weights[guideline] <- weight
  }
  weights
}

combined_outcome_weights <- parse_combined_outcome_weights(combined_outcome_weights_string, guideline_cols)

if (all(combined_outcome_weights == 1)) {
  cat("outcome_combined: using the default - every guideline weighted equally (1).\n\n")
} else {
  cat("outcome_combined: using custom weights:\n")
  print(combined_outcome_weights)
  cat("\n")
}

# --- Section 5: main loop - for each person, for each guideline -------------
#
# This mirrors the original pseudocode structure: loop over the datatable,
# and within that, loop over the lookup table.

for (i in seq_len(nrow(datatable))) {

  person_row <- datatable[i, ]
  person_label <- if (id_field %in% names(person_row)) person_row[[id_field]] else paste("row", i)

  for (j in seq_len(nrow(lookuptable))) {

    rule_row <- lookuptable[j, ]
    abbr     <- rule_row$Abbreviation
    needed   <- rule_row$required_vars[[1]]

    # Step i: can this guideline even be calculated for this person? If any
    # of the measurements it needs are missing, don't attempt to run the
    # formula at all - just record NA and move on to the next guideline.
    
    have_all_needed <- all(needed %in% names(person_row)) &&
      all(!is.na(person_row[needed]))

    if (!have_all_needed) {
      output_table[i, abbr] <- NA
      next
    }

    # Step ii: it can be calculated - build an environment holding both
    # this person's own measurements AND this guideline's own threshold
    # variables, so the formula (which references both by name) can be
    # evaluated directly.
    env <- new.env()
    for (v in names(person_row)) assign(v, person_row[[v]], envir = env)
    for (v in names(rule_row))   assign(v, rule_row[[v]],   envir = env)

    result <- tryCatch(
      eval(parse(text = rule_row$algorithm_expr), envir = env),
      error = function(e) {
        warning(sprintf(
          "Error evaluating %s for %s (%s): %s",
          abbr, id_field, person_label, e$message
        ))
        NA
      }
    )

    output_table[i, abbr] <- result
  }
}

# --- Section 6: combined outcome, appended as the final variable --------------
#
# sum(weight * result) across whatever guidelines actually produced a
# result for that person. A guideline that came back NA contributes
# nothing to the sum (it's excluded, not treated as 0). If literally every
# guideline is NA for someone, outcome_combined is NA too, rather than
# misleadingly showing 0 (which would look identical to "tested negative
# on everything").

output_table$outcome_combined <- apply(
  output_table[, guideline_cols, drop = FALSE], 1,
  function(vals) {
    vals <- as.numeric(vals)
    if (all(is.na(vals))) return(NA_real_)
    sum(vals * combined_outcome_weights[guideline_cols], na.rm = TRUE)
  }
)

# --- Section 7: write the result ---------------------------------------------

write.table(
  output_table,
  output_filename,
  sep = "\t",
  row.names = FALSE,
  na = "NULL",
  quote = FALSE
)

cat(sprintf(
  "Done. Wrote %d rows x %d variables to '%s'.\n\n",
  nrow(output_table), ncol(output_table), output_filename
))
cat("Preview (first 6 rows):\n")
print(head(output_table))

# How many people were found positive (1) for each guideline. People for whom
# a guideline could not be calculated (NA) are simply not counted.
cat("\nNumber of people positive for each guideline:\n")
print(data.frame(
  guideline  = guideline_cols,
  n_positive = colSums(output_table[, guideline_cols, drop = FALSE] == 1, na.rm = TRUE),
  row.names  = NULL
))

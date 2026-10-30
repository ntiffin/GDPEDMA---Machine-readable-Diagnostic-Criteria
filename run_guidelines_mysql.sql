-- =============================================================================
-- GDM GUIDELINES PIPELINE - MySQL version
--
-- The SQL equivalent of run_guidelines.R, for people who would rather stay
-- inside their database. It
--
--   PART 0  is the configuration. Everything you need to edit is in it: the table
--           names, the weights, the optional subset of guidelines, and the
--           locations of the two input files.
--   PART 1  builds the guideline lookup table (from lookup_table.txt) as a MySQL
--           table, guideline_lookup_table. ONE-TIME SET-UP.
--   PART 2  builds your data table, dataset_table, from your data file.
--   PART 3  adds the results to that same dataset_table:
--             * one new variable per guideline, in lookup-table order:
--               1 = criteria met, 0 = not met, NULL = the person is missing a
--               measurement that guideline needs, so it cannot be calculated
--               (NULL here is the same thing as NA in the R script);
--             * outcome_combined as the last new variable:
--               sum(weight_i * guideline_i) across the guidelines that could be
--               calculated for that person. A NULL guideline is left out of the
--               sum, it is not counted as 0. If none could be calculated it is
--               NULL.
--           There is no separate output table. Your own variables stay exactly as
--           they were and the new variables are added after them.
--
-- The lookup table is the single source of truth, exactly as in the R script.
-- No threshold and no guideline is typed into this script: each guideline's
-- formula (the Algorithm_SQL variable) names its threshold variables, and the
-- numbers are read from the lookup table when the analysis runs. To change a
-- threshold, or to add a guideline, edit the lookup file and load it again.
--
-- Status: written alongside the R pipeline and meant to give identical results.
-- Check it on your own server with the section at the bottom of this file.
--
-- Needs
--   * MySQL 5.7 or later (8.0 recommended).
--   * Permission to create tables, stored procedures and temporary tables.
--   * LOAD DATA LOCAL INFILE switched on in BOTH places:
--       - on the server:  SET GLOBAL local_infile = 1;
--       - in your client, which has its own separate setting. mysql command line:
--         mysql --local-infile=1 . MySQL Workbench: edit the connection, Advanced
--         tab, Others box, add  OPT_LOCAL_INFILE=1  and reconnect. DBeaver: driver
--         property allowLoadLocalInfile=true.
--     If you see "Error 2068: LOAD DATA LOCAL INFILE file request rejected due to
--     restrictions on access", it is the client setting that is missing.
--   * Run the whole script in ONE session / connection, because the settings in
--     PART 0 are session variables.
--
-- How to use it
--   First time:   edit PART 0 (the table names, weights, subset and the two file
--                 locations), then run the script from top to bottom.
--   Later runs:   (new data, or different weights) edit PART 0 - the data file
--                 location, the weights - then run PART 0, PART 2 and PART 3
--                 again. Skip PART 1: the lookup table is already installed, so
--                 you can also comment out the lookup file block in PART 0.
--
-- How the R configuration maps onto this script
--     R script                              Here
--     lookuptable_filename                  lookup file location in PART 0 + @gdm_lookup_table
--     datatable_filename                    data file location in PART 0 + @gdm_dataset_table
--     output_filename                       not needed - results go into the dataset table
--     combined_outcome_weights_string       @gdm_weights
--     the commented-out subset line         @gdm_subset
--     id_field                              not needed (only used in R messages)
-- =============================================================================


-- =============================================================================
-- PART 0 - CONFIGURATION: edit this part for your own set-up
-- =============================================================================
CREATE DATABASE IF NOT EXISTS gdm_diagnostic_criteria_db;
USE gdm_diagnostic_criteria_db;

-- The table the lookup file is loaded into (created in PART 1).
SET @gdm_lookup_table  = 'guideline_lookup_table';

-- The table your data file is loaded into (created in PART 2). The results are
-- added to this table in PART 3. Use plain names: letters, digits, underscores.
SET @gdm_dataset_table = 'dataset_table';

-- Combined-outcome weights, as in the R script: comma-separated
-- ABBREVIATION=weight pairs, each weight between 0 and 5, using the spelling in
-- the lookup table's Abbreviation variable. Any guideline not mentioned keeps the
-- weight 1. '' means every guideline has weight 1.
--   Example:  SET @gdm_weights = 'IADPSG=2, WHO_1999=0.5';
SET @gdm_weights = '';

-- Run only some of the guidelines: a comma-separated list of Abbreviation
-- values. '' means every guideline in the lookup table.
--   Example:  SET @gdm_subset = 'IADPSG, NICE';
SET @gdm_subset = '';

-- -----------------------------------------------------------------------------
-- FILE LOCATIONS - where the two input files are
--
-- MySQL requires the path of a LOAD DATA file to be written inside the LOAD DATA
-- statement itself; it cannot be read from a variable. So the two file locations
-- are set here, in the only two LOAD DATA statements in this script, on the line
-- just below each marker
--     >>> EDIT PATH AND FILE NAME <<<
-- Nothing further down contains a path or a file name. Write each path with
-- forward slashes, for example  C:/Users/me/data/lookup_table.txt
--
-- Each statement only copies the lines of its file, exactly as they are, into a
-- small work table. PART 1 and PART 2 turn those lines into the real tables. The
-- "field terminator" is a character that never occurs in a text file, so each
-- whole line lands in the single variable called line.
-- -----------------------------------------------------------------------------

-- (a) The LOOKUP file (lookup_table.txt). It is only needed for the one-time
-- set-up in PART 1: once that has been run you can delete or comment out this
-- block.

DROP TABLE IF EXISTS gdm_stage_lookup_lines;
CREATE TABLE gdm_stage_lookup_lines (
    line_no INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    line    LONGTEXT
) DEFAULT CHARSET = utf8mb4;

-- >>> EDIT PATH AND FILE NAME <<<   (the line just below)
LOAD DATA LOCAL INFILE 'C:/path/to/lookup_table.txt'
-- LOAD DATA LOCAL INFILE 'C:/Users/ntiffin/Dropbox/Documents/academic_programme/research/2024_GeD-GSN/2026_guidelines_paper/Nicki_code/final/lookup_table.txt'
INTO TABLE gdm_stage_lookup_lines
CHARACTER SET utf8mb4
FIELDS TERMINATED BY '\b' ESCAPED BY ''
LINES TERMINATED BY '\n'
(line);

-- (b) YOUR DATA file: one row per person, tab-separated, with a first line that
-- gives the variable names.

DROP TABLE IF EXISTS gdm_stage_data_lines;
CREATE TABLE gdm_stage_data_lines (
    line_no INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    line    LONGTEXT
) DEFAULT CHARSET = utf8mb4;

-- >>> EDIT PATH AND FILE NAME <<<   (the line just below)
LOAD DATA LOCAL INFILE 'C:/path/to/your_data.txt'
-- LOAD DATA LOCAL INFILE 'C:/Users/ntiffin/Dropbox/Documents/academic_programme/research/2024_GeD-GSN/2026_guidelines_paper/Nicki_code/final/synthetic_dataset.txt'
INTO TABLE gdm_stage_data_lines
CHARACTER SET utf8mb4
FIELDS TERMINATED BY '\b' ESCAPED BY ''
LINES TERMINATED BY '\n'
(line);

-- OPTIONAL, untested: keeping the two locations in variables instead, as in the
-- R script. Some MySQL versions accept a LOAD DATA that is built as text and run
-- with PREPARE. If yours does, you can replace each LOAD DATA statement above
-- with the lines below (shown for the lookup file). If the server answers "This
-- command is not supported in the prepared statement protocol yet", keep the
-- plain statements above.
--
--   SET @gdm_lookup_file = 'C:/path/to/lookup_table.txt';
--   SET @gdm_sql = CONCAT('LOAD DATA LOCAL INFILE ', QUOTE(@gdm_lookup_file),
--       ' INTO TABLE gdm_stage_lookup_lines CHARACTER SET utf8mb4',
--       ' FIELDS TERMINATED BY ''\\b'' ESCAPED BY '''' LINES TERMINATED BY ''\\n'' (line)');
--   PREPARE gdm_stmt FROM @gdm_sql;
--   EXECUTE gdm_stmt;
--   DEALLOCATE PREPARE gdm_stmt;


-- =============================================================================
-- =============================================================================
-- PART 1 - ONE-TIME SET-UP: install the loader and build the lookup table
--
--   >>>  RUN THIS PART ONCE.  <<<
--
-- It installs a helper procedure, then creates guideline_lookup_table and fills
-- it from the lookup file lines loaded in PART 0(a). After that you do not need
-- to run it again unless the lookup file itself changes (running it again, after
-- PART 0, just rebuilds the table from the file).
-- =============================================================================
-- =============================================================================

-- 1a. The helper that builds a table from a delimited text file. It reads the
-- variable names from the file's first line, so the table always has exactly the
-- variables the file has - a new variable in the lookup file needs no change here.
-- Variables are stored as text, except the ones that must be numbers: those whose
-- name matches p_numeric_like, and those named in the required_variables variable
-- of the table p_numeric_from. In the file, a blank value or the word NULL
-- becomes a real NULL. The file must not contain a tab or a line break inside a
-- value, and values may be wrapped in double quotes.

DROP PROCEDURE IF EXISTS gdm_build_table_from_lines;

DELIMITER $$

CREATE PROCEDURE gdm_build_table_from_lines (
    IN p_stage         VARCHAR(64),    -- work table holding the lines of the file (loaded in PART 0)
    IN p_table         VARCHAR(64),    -- table to create (rebuilt if this script made it earlier)
    IN p_numeric_like  VARCHAR(100),   -- variables whose NAME matches this LIKE pattern are numbers (empty = none)
    IN p_numeric_from  VARCHAR(64),    -- variables named in the required_variables of this lookup table are numbers (empty = none)
    IN p_with_row_id   TINYINT         -- 1 = add a leading gdm_row_id counter that keeps the row order of the file
)
BEGIN
    DECLARE v_header   LONGTEXT;
    DECLARE v_rest     LONGTEXT;
    DECLARE v_col      VARCHAR(255);
    DECLARE v_pos      INT DEFAULT 0;
    DECLARE v_idx      INT DEFAULT 0;
    DECLARE v_ncols    INT DEFAULT 0;
    DECLARE v_isnum    TINYINT DEFAULT 0;
    DECLARE v_numlist  LONGTEXT DEFAULT '';
    DECLARE v_field    LONGTEXT;
    DECLARE v_defs     LONGTEXT DEFAULT '';
    DECLARE v_cols     LONGTEXT DEFAULT '';
    DECLARE v_exprs    LONGTEXT DEFAULT '';

    -- If anything goes wrong, put the session setting back and pass the error on.
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET SESSION sql_mode = @gdm_old_sql_mode;
        RESIGNAL;
    END;

    SET @gdm_old_sql_mode = @@SESSION.sql_mode;

    IF p_stage IS NULL OR p_table IS NULL
       OR p_stage NOT REGEXP '^[A-Za-z0-9_]+$'
       OR p_table NOT REGEXP '^[A-Za-z0-9_]+$'
       OR IFNULL(p_numeric_from, '') NOT REGEXP '^[A-Za-z0-9_]*$' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Table names may only contain letters, digits and underscores.';
    END IF;

    -- The first line of the file is the variable names. The lines were loaded into
    -- the work table in PART 0.
    SET @gdm_header = NULL;
    SET @gdm_sql = CONCAT('SELECT line FROM `', p_stage, '` WHERE line_no = 1 INTO @gdm_header');
    PREPARE gdm_stmt FROM @gdm_sql;
    EXECUTE gdm_stmt;
    DEALLOCATE PREPARE gdm_stmt;
    SET v_header = @gdm_header;
    IF v_header IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Nothing was loaded from the file - check the file location in PART 0 and that local_infile is on.';
    END IF;

    -- Never replace a table this script did not create.
    SET @gdm_tbl    = p_table;
    SET @gdm_marker = 'gdm_loaded_from_file';
    SET @gdm_exists = 0;
    SET @gdm_ours   = 0;
    SET @gdm_sql = 'SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? INTO @gdm_exists';
    PREPARE gdm_stmt FROM @gdm_sql;
    EXECUTE gdm_stmt USING @gdm_tbl;
    DEALLOCATE PREPARE gdm_stmt;
    SET @gdm_sql = 'SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND TABLE_COMMENT = ? INTO @gdm_ours';
    PREPARE gdm_stmt FROM @gdm_sql;
    EXECUTE gdm_stmt USING @gdm_tbl, @gdm_marker;
    DEALLOCATE PREPARE gdm_stmt;
    IF @gdm_exists > 0 AND @gdm_ours = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'A table with that name already exists and this script did not create it - use another name or drop it yourself.';
    END IF;

    -- Which variables must be numbers because a guideline formula uses them?
    IF IFNULL(p_numeric_from, '') <> '' THEN
        SET SESSION group_concat_max_len = 1000000;
        SET @gdm_numlist = '';
        SET @gdm_sql = CONCAT(
            'SELECT IFNULL(GROUP_CONCAT(REPLACE(REPLACE(required_variables, '' '', ''''), ''|'', '','') SEPARATOR '',''), '''') ',
            'FROM `', p_numeric_from, '` INTO @gdm_numlist');
        PREPARE gdm_stmt FROM @gdm_sql;
        EXECUTE gdm_stmt;
        DEALLOCATE PREPARE gdm_stmt;
        SET v_numlist = IFNULL(@gdm_numlist, '');
    END IF;

    -- Read the variable names from the first line: take off the byte-order-mark
    -- some programs put at the start of a file, the line-end character and any
    -- double quotes, then walk along it one tab-separated name at a time.
    SET v_header = REPLACE(v_header, CHAR(15711167 USING utf8mb4), '');
    SET v_header = REPLACE(REPLACE(v_header, CHAR(13), ''), CHAR(34), '');
    SET v_rest   = CONCAT(v_header, CHAR(9));

    WHILE CHAR_LENGTH(v_rest) > 0 DO
        SET v_pos  = LOCATE(CHAR(9), v_rest);
        SET v_col  = TRIM(LEFT(v_rest, v_pos - 1));
        SET v_rest = SUBSTRING(v_rest, v_pos + 1);
        SET v_idx  = v_idx + 1;

        -- An empty name (a stray tab at the end of the first line) is skipped.
        IF CHAR_LENGTH(v_col) > 0 THEN
            IF v_col NOT REGEXP '^[A-Za-z0-9_]+$' THEN
                SIGNAL SQLSTATE '45000'
                    SET MESSAGE_TEXT = 'A variable name in the first line has a character other than letters, digits or underscore.';
            END IF;

            SET v_isnum = 0;
            IF IFNULL(p_numeric_like, '') <> '' AND v_col LIKE p_numeric_like THEN
                SET v_isnum = 1;
            END IF;
            IF v_numlist <> '' AND FIND_IN_SET(v_col, v_numlist) > 0 THEN
                SET v_isnum = 1;
            END IF;

            SET v_ncols = v_ncols + 1;
            SET v_defs  = CONCAT(v_defs, IF(v_ncols = 1, '', ', '), '`', v_col, '` ',
                                 IF(v_isnum = 1, 'DECIMAL(18,6) NULL', 'TEXT NULL'));
            SET v_cols  = CONCAT(v_cols, IF(v_ncols = 1, '', ', '), '`', v_col, '`');

            -- The value of this variable on a data line: the v_idx-th tab-separated
            -- piece, with surrounding double quotes removed; blank and the word
            -- NULL become NULL.
            SET v_field = CONCAT('TRIM(BOTH CHAR(34) FROM SUBSTRING_INDEX(SUBSTRING_INDEX(s.txt, CHAR(9), ',
                                 v_idx, '), CHAR(9), -1))');
            SET v_exprs = CONCAT(v_exprs, IF(v_ncols = 1, '', ', '),
                IF(v_isnum = 1,
                   CONCAT('NULLIF(NULLIF(TRIM(', v_field, '), ''''), ''NULL'')'),
                   CONCAT('NULLIF(NULLIF(', v_field, ', ''''), ''NULL'')')));
        END IF;
    END WHILE;

    IF v_ncols = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'The first line of the file has no variable names.';
    END IF;

    -- Build the table and fill it. Strict mode is switched on for the fill so a
    -- value that is not a number in a numeric variable stops the load with an
    -- error that names it, instead of quietly becoming 0.
    SET SESSION sql_mode = CONCAT_WS(',', NULLIF(@gdm_old_sql_mode, ''), 'STRICT_TRANS_TABLES');

    SET @gdm_sql = CONCAT('DROP TABLE IF EXISTS `', p_table, '`');
    PREPARE gdm_stmt FROM @gdm_sql;
    EXECUTE gdm_stmt;
    DEALLOCATE PREPARE gdm_stmt;

    SET @gdm_sql = CONCAT(
        'CREATE TABLE `', p_table, '` (',
        IF(p_with_row_id = 1, 'gdm_row_id INT NOT NULL AUTO_INCREMENT PRIMARY KEY, ', ''),
        v_defs, ') DEFAULT CHARSET = utf8mb4 COMMENT = ''gdm_loaded_from_file''');
    PREPARE gdm_stmt FROM @gdm_sql;
    EXECUTE gdm_stmt;
    DEALLOCATE PREPARE gdm_stmt;

    SET @gdm_sql = CONCAT(
        'INSERT INTO `', p_table, '` (', v_cols, ') SELECT ', v_exprs,
        ' FROM (SELECT line_no, CONCAT(TRIM(TRAILING CHAR(13) FROM line), REPEAT(CHAR(9), ', v_idx, ')) AS txt',
        ' FROM `', p_stage, '` WHERE line_no > 1 AND CHAR_LENGTH(TRIM(TRAILING CHAR(13) FROM line)) > 0) AS s',
        ' ORDER BY s.line_no');
    PREPARE gdm_stmt FROM @gdm_sql;
    EXECUTE gdm_stmt;
    DEALLOCATE PREPARE gdm_stmt;

    SET SESSION sql_mode = @gdm_old_sql_mode;

    SET @gdm_rows = 0;
    SET @gdm_sql = CONCAT('SELECT COUNT(*) FROM `', p_table, '` INTO @gdm_rows');
    PREPARE gdm_stmt FROM @gdm_sql;
    EXECUTE gdm_stmt;
    DEALLOCATE PREPARE gdm_stmt;

    -- The work table has done its job.
    SET @gdm_sql = CONCAT('DROP TABLE IF EXISTS `', p_stage, '`');
    PREPARE gdm_stmt FROM @gdm_sql;
    EXECUTE gdm_stmt;
    DEALLOCATE PREPARE gdm_stmt;

    SELECT CONCAT('Created table ', p_table, ' with ', @gdm_rows, ' rows and ', v_ncols, ' variables') AS result;
END$$

DELIMITER ;


-- 1b. Create guideline_lookup_table from the first line of the lookup file (the
-- variable names) and fill it from the other lines. Variables with threshold in
-- their name become numbers (so use threshold only in the name of numeric
-- variables); the rest are text. gdm_row_id keeps the guidelines
-- in file order.

CALL gdm_build_table_from_lines('gdm_stage_lookup_lines', @gdm_lookup_table, '%threshold%', '', 1);


-- =============================================================================
-- =============================================================================
-- PART 2 - BUILD YOUR DATA TABLE (run this each time you have a new data file)
--
-- Creates dataset_table from the data file lines loaded in PART 0(b). One row per
-- person, one variable per measurement, tab-separated, a header line with the
-- variable names. The variable
-- names must be exactly the names the lookup table's required_variables variable
-- uses (ogtt_75g_fasting_mmoll, ...); those variables are stored as numbers, every
-- other variable is stored as text exactly as in the file. A blank value or the
-- word NULL becomes NULL. If dataset_table already exists from an earlier load
-- it is replaced, which also removes results added to it before.
-- =============================================================================
-- =============================================================================

CALL gdm_build_table_from_lines('gdm_stage_data_lines', @gdm_dataset_table, '', @gdm_lookup_table, 0);


-- =============================================================================
-- =============================================================================
-- PART 3 - THE ANALYSIS
--
-- 3a. Creates the stored procedure (do this once, and again only if you edit
--     it).  3b. Runs it on dataset_table.
-- =============================================================================
-- =============================================================================

-- 3a. The analysis procedure.

DROP PROCEDURE IF EXISTS run_guidelines;

DELIMITER $$

CREATE PROCEDURE run_guidelines (
    IN p_datatable    VARCHAR(64),     -- the dataset table. The results are ADDED to it
    IN p_lookuptable  VARCHAR(64),     -- the lookup table
    IN p_weights      VARCHAR(1000),   -- for example IADPSG=2, WHO_1999=0.5 (empty = every weight 1)
    IN p_subset       VARCHAR(1000)    -- for example IADPSG, NICE (empty = every guideline)
)
BEGIN
    DECLARE v_n        INT DEFAULT 0;
    DECLARE v_rn       INT;
    DECLARE v_k        INT DEFAULT 0;
    DECLARE v_ntokens  INT DEFAULT 0;
    DECLARE v_nreq     INT DEFAULT 0;
    DECLARE v_pos      INT DEFAULT 0;
    DECLARE v_abbr     VARCHAR(64);
    DECLARE v_weight   VARCHAR(1000);
    DECLARE v_rest     VARCHAR(1000);
    DECLARE v_entry    VARCHAR(1000);
    DECLARE v_name     VARCHAR(1000);
    DECLARE v_wtxt     VARCHAR(1000);
    DECLARE v_algo     LONGTEXT;
    DECLARE v_req      LONGTEXT;
    DECLARE v_gate     LONGTEXT;
    DECLARE v_abbrs    LONGTEXT;
    DECLARE v_add_list LONGTEXT DEFAULT '';
    DECLARE v_any_list LONGTEXT DEFAULT '';
    DECLARE v_sum_expr LONGTEXT DEFAULT '';

    -- If anything goes wrong, put the session setting back and pass the error on.
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET SESSION sql_safe_updates = @gdm_old_safe;
        RESIGNAL;
    END;

    SET @gdm_old_safe = @@SESSION.sql_safe_updates;

    -- --- Check the table names ---------------------------------------------
    -- The names are placed into SQL text below, so only plain names are accepted.

    IF p_datatable IS NULL OR p_lookuptable IS NULL
       OR p_datatable   NOT REGEXP '^[A-Za-z0-9_]+$'
       OR p_lookuptable NOT REGEXP '^[A-Za-z0-9_]+$' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Table names may only contain letters, digits and underscores (current database).';
    END IF;

    IF LOWER(p_datatable) = LOWER(p_lookuptable) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'The dataset table and the lookup table must be two different tables.';
    END IF;

    SET @gdm_tbl   = p_datatable;
    SET @gdm_found = 0;
    SET @gdm_sql = 'SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? INTO @gdm_found';
    PREPARE gdm_stmt FROM @gdm_sql;
    EXECUTE gdm_stmt USING @gdm_tbl;
    DEALLOCATE PREPARE gdm_stmt;
    IF @gdm_found = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'The dataset table does not exist - run PART 2 first.';
    END IF;

    SET @gdm_tbl   = p_lookuptable;
    SET @gdm_found = 0;
    PREPARE gdm_stmt FROM @gdm_sql;
    EXECUTE gdm_stmt USING @gdm_tbl;
    DEALLOCATE PREPARE gdm_stmt;
    IF @gdm_found = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'The lookup table does not exist - run PART 1 first.';
    END IF;
    SET @gdm_tbl = p_datatable;

    -- --- Working tables (they disappear when your session ends) -------------
    -- tmp_gdm_lookup : the guidelines being run, in lookup-table order
    -- tmp_gdm_log    : warnings and notes, returned as the result of the CALL

    DROP TEMPORARY TABLE IF EXISTS tmp_gdm_lookup;
    DROP TEMPORARY TABLE IF EXISTS tmp_gdm_log;

    CREATE TEMPORARY TABLE tmp_gdm_lookup (
        rn         INT           NOT NULL AUTO_INCREMENT PRIMARY KEY,
        abbr       VARCHAR(64)   NOT NULL,
        algo_sql   LONGTEXT      NOT NULL,
        req_vars   LONGTEXT      NOT NULL,
        weight_txt VARCHAR(1000) NOT NULL DEFAULT '1',
        runnable   TINYINT       NOT NULL DEFAULT 0
    );

    CREATE TEMPORARY TABLE tmp_gdm_log (
        id     INT           NOT NULL AUTO_INCREMENT PRIMARY KEY,
        kind   VARCHAR(10)   NOT NULL,
        detail VARCHAR(1000) NOT NULL
    );

    -- --- Pick the guidelines to run (all of them, or the p_subset list) ----
    -- Rows with no formula or no required_variables are skipped.

    SET @gdm_subset = REPLACE(IFNULL(p_subset, ''), ' ', '');
    SET @gdm_sql = CONCAT(
        'INSERT INTO tmp_gdm_lookup (abbr, algo_sql, req_vars) ',
        'SELECT TRIM(Abbreviation), Algorithm_SQL, required_variables FROM `', p_lookuptable, '` ',
        'WHERE Algorithm_SQL IS NOT NULL AND required_variables IS NOT NULL ',
        'AND (? = '''' OR FIND_IN_SET(TRIM(Abbreviation), ?) > 0) ',
        'ORDER BY gdm_row_id'
    );
    PREPARE gdm_stmt FROM @gdm_sql;
    EXECUTE gdm_stmt USING @gdm_subset, @gdm_subset;
    DEALLOCATE PREPARE gdm_stmt;

    SELECT COUNT(*) FROM tmp_gdm_lookup INTO v_n;

    IF v_n = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'No guidelines selected - check the lookup table and the subset.';
    END IF;

    IF @gdm_subset <> '' THEN
        SET v_ntokens = CHAR_LENGTH(@gdm_subset) - CHAR_LENGTH(REPLACE(@gdm_subset, ',', '')) + 1;
        IF v_ntokens <> v_n THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'The subset lists an Abbreviation that is not in the lookup table, or lists one twice.';
        END IF;
    END IF;

    IF EXISTS (SELECT 1 FROM tmp_gdm_lookup WHERE abbr NOT REGEXP '^[A-Za-z0-9_]+$') THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'A guideline Abbreviation may only contain letters, digits and underscores.';
    END IF;

    IF (SELECT COUNT(DISTINCT abbr) FROM tmp_gdm_lookup) <> v_n THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'The lookup table has two guidelines with the same Abbreviation.';
    END IF;

    IF EXISTS (SELECT 1 FROM tmp_gdm_lookup WHERE CHAR_LENGTH(TRIM(req_vars)) = 0) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'A guideline has an empty required_variables field.';
    END IF;

    -- --- Warn about variable names that exist in both tables --------------------
    -- A dataset variable with the same name as a lookup table variable (for example
    -- weight, url or Guideline) makes a formula that uses that name ambiguous,
    -- which gives an error. Variables this procedure added earlier are not counted.

    SET @gdm_tbl2  = p_lookuptable;
    SET @gdm_clash = NULL;
    SET @gdm_sql = CONCAT(
        'SELECT GROUP_CONCAT(d.COLUMN_NAME SEPARATOR '', '') ',
        'FROM information_schema.COLUMNS d JOIN information_schema.COLUMNS l ',
        'ON l.COLUMN_NAME = d.COLUMN_NAME ',
        'WHERE d.TABLE_SCHEMA = DATABASE() AND l.TABLE_SCHEMA = DATABASE() ',
        'AND d.TABLE_NAME = ? AND l.TABLE_NAME = ? ',
        'AND d.COLUMN_COMMENT <> ''gdm_pipeline_result'' INTO @gdm_clash');
    PREPARE gdm_stmt FROM @gdm_sql;
    EXECUTE gdm_stmt USING @gdm_tbl, @gdm_tbl2;
    DEALLOCATE PREPARE gdm_stmt;

    IF @gdm_clash IS NOT NULL THEN
        INSERT INTO tmp_gdm_log (kind, detail)
        VALUES ('warning', LEFT(CONCAT(
            'These dataset variables have the same name as a lookup table variable, so a formula using the name will fail: ',
            @gdm_clash, '. Rename the variable in the dataset table (or in the lookup table and its formulas)'), 1000));
    END IF;

    -- --- Read the weights ---------------------------------------------------
    -- Same rules as the R script: comma-separated ABBREVIATION=weight pairs,
    -- each weight between 0 and 5, anything not mentioned stays 1. Bad entries
    -- are ignored and reported in the result of the CALL.

    SET v_rest = REPLACE(IFNULL(p_weights, ''), ' ', '');

    WHILE CHAR_LENGTH(v_rest) > 0 DO
        SET v_pos = LOCATE(',', v_rest);
        IF v_pos = 0 THEN
            SET v_entry = v_rest;
            SET v_rest  = '';
        ELSE
            SET v_entry = LEFT(v_rest, v_pos - 1);
            SET v_rest  = SUBSTRING(v_rest, v_pos + 1);
        END IF;

        IF CHAR_LENGTH(v_entry) > 0 THEN
            SET v_name = SUBSTRING_INDEX(v_entry, '=', 1);
            SET v_wtxt = SUBSTRING_INDEX(v_entry, '=', -1);

            IF LOCATE('=', v_entry) = 0 OR v_wtxt NOT REGEXP '^-?[0-9]+(\\.[0-9]+)?$' THEN
                INSERT INTO tmp_gdm_log (kind, detail)
                VALUES ('warning', CONCAT('Ignoring unreadable weight entry: ', LEFT(v_entry, 200)));
            ELSEIF CAST(v_wtxt AS DECIMAL(12,4)) < 0 OR CAST(v_wtxt AS DECIMAL(12,4)) > 5 THEN
                INSERT INTO tmp_gdm_log (kind, detail)
                VALUES ('warning', CONCAT('Ignoring invalid weight for ', LEFT(v_name, 100), ' - it must be between 0 and 5'));
            ELSEIF NOT EXISTS (SELECT 1 FROM tmp_gdm_lookup WHERE abbr = v_name) THEN
                INSERT INTO tmp_gdm_log (kind, detail)
                VALUES ('warning', CONCAT('Ignoring weight for unknown guideline ', LEFT(v_name, 100)));
            ELSE
                UPDATE tmp_gdm_lookup SET weight_txt = v_wtxt WHERE abbr = v_name;
            END IF;
        END IF;
    END WHILE;

    -- --- Clear out the results of an earlier run ----------------------------
    -- The variables this procedure adds are marked with the comment
    -- gdm_pipeline_result, so running it again replaces them. A variable of your
    -- own is never touched.

    SET SESSION group_concat_max_len = 1000000;
    SET @gdm_marker    = 'gdm_pipeline_result';
    SET @gdm_drop_list = NULL;
    SET @gdm_sql = CONCAT(
        'SELECT GROUP_CONCAT(CONCAT(''DROP COLUMN `'', COLUMN_NAME, ''`'') SEPARATOR '', '') ',
        'FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? ',
        'AND COLUMN_COMMENT = ? INTO @gdm_drop_list');
    PREPARE gdm_stmt FROM @gdm_sql;
    EXECUTE gdm_stmt USING @gdm_tbl, @gdm_marker;
    DEALLOCATE PREPARE gdm_stmt;

    IF @gdm_drop_list IS NOT NULL THEN
        SET @gdm_sql = CONCAT('ALTER TABLE `', p_datatable, '` ', @gdm_drop_list);
        PREPARE gdm_stmt FROM @gdm_sql;
        EXECUTE gdm_stmt;
        DEALLOCATE PREPARE gdm_stmt;
    END IF;

    -- A variable of your own that already has the name of a guideline would be in the way.
    SELECT GROUP_CONCAT(abbr) FROM tmp_gdm_lookup INTO v_abbrs;
    SET @gdm_cols  = CONCAT(v_abbrs, ',outcome_combined');
    SET @gdm_found = 0;
    SET @gdm_sql = 'SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND FIND_IN_SET(COLUMN_NAME, ?) > 0 INTO @gdm_found';
    PREPARE gdm_stmt FROM @gdm_sql;
    EXECUTE gdm_stmt USING @gdm_tbl, @gdm_cols;
    DEALLOCATE PREPARE gdm_stmt;
    IF @gdm_found > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'The dataset table already has a variable named like a guideline or outcome_combined - rename it first.';
    END IF;

    -- --- For each guideline: can it be calculated with this dataset? --------
    -- A guideline can only be calculated if the dataset table has a variable for
    -- every variable it needs. If a variable does not exist at all, the guideline
    -- is NULL for everyone - say so rather than failing. Also build the list of
    -- new variables and the outcome_combined formula.

    SELECT MIN(rn) FROM tmp_gdm_lookup INTO v_rn;

    WHILE v_rn IS NOT NULL DO

        SELECT abbr, REPLACE(req_vars, ' ', ''), weight_txt
          FROM tmp_gdm_lookup
         WHERE rn = v_rn
          INTO v_abbr, v_req, v_weight;

        SET v_nreq = CHAR_LENGTH(v_req) - CHAR_LENGTH(REPLACE(v_req, '|', '')) + 1;

        SET @gdm_cols  = REPLACE(v_req, '|', ',');
        SET @gdm_found = 0;
        SET @gdm_sql   = 'SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND FIND_IN_SET(COLUMN_NAME, ?) > 0 INTO @gdm_found';
        PREPARE gdm_stmt FROM @gdm_sql;
        EXECUTE gdm_stmt USING @gdm_tbl, @gdm_cols;
        DEALLOCATE PREPARE gdm_stmt;

        IF @gdm_found < v_nreq THEN
            INSERT INTO tmp_gdm_log (kind, detail)
            VALUES ('warning', LEFT(CONCAT(
                v_abbr, ': the dataset table does not have a variable for every required variable (',
                v_req, '), so it is NULL for everyone'), 1000));
        ELSE
            UPDATE tmp_gdm_lookup SET runnable = 1 WHERE rn = v_rn;
        END IF;

        SET v_add_list = CONCAT(v_add_list, IF(v_k = 0, '', ', '),
                                'ADD COLUMN `', v_abbr, '` TINYINT NULL COMMENT ''gdm_pipeline_result''');
        SET v_any_list = CONCAT(v_any_list, IF(v_k = 0, '', ', '), '`', v_abbr, '`');
        SET v_sum_expr = CONCAT(v_sum_expr, IF(v_k = 0, '', ' + '),
                                'COALESCE(', v_weight, ' * `', v_abbr, '`, 0)');

        SET v_k = v_k + 1;
        SELECT MIN(rn) FROM tmp_gdm_lookup WHERE rn > v_rn INTO v_rn;
    END WHILE;

    -- --- Add the new variables to the dataset table ---------------------------
    -- One variable per guideline (after your own variables, in lookup-table order),
    -- then outcome_combined last.

    SET @gdm_sql = CONCAT('ALTER TABLE `', p_datatable, '` ', v_add_list,
                          ', ADD COLUMN outcome_combined DOUBLE NULL COMMENT ''gdm_pipeline_result''');
    PREPARE gdm_stmt FROM @gdm_sql;
    EXECUTE gdm_stmt;
    DEALLOCATE PREPARE gdm_stmt;

    -- --- Fill them in ----------------------------------------------------------
    -- For each guideline that can be calculated, one UPDATE joined to the
    -- lookup row of that guideline:
    --     CASE WHEN <every required variable is not NULL>
    --          THEN <the Algorithm_SQL of the guideline> ELSE NULL END
    -- The lookup row supplies the thresholds: the formula names its threshold
    -- variables, and the names in a formula never clash with your data variables.
    -- (Safe-update mode is switched off for these UPDATEs, which have no WHERE.)

    SET SESSION sql_safe_updates = 0;

    SELECT MIN(rn) FROM tmp_gdm_lookup WHERE runnable = 1 INTO v_rn;

    WHILE v_rn IS NOT NULL DO

        SELECT abbr, algo_sql, REPLACE(req_vars, ' ', '')
          FROM tmp_gdm_lookup
         WHERE rn = v_rn
          INTO v_abbr, v_algo, v_req;

        -- a|b|c  becomes  (a IS NOT NULL AND b IS NOT NULL AND c IS NOT NULL)
        SET v_gate = CONCAT('(', REPLACE(v_req, '|', ' IS NOT NULL AND '), ' IS NOT NULL)');

        SET @gdm_sql = CONCAT(
            'UPDATE `', p_datatable, '` AS d JOIN `', p_lookuptable, '` AS lk',
            ' ON TRIM(lk.Abbreviation) = ', QUOTE(v_abbr),
            ' SET d.`', v_abbr, '` = CASE WHEN ', v_gate, ' THEN ', v_algo, ' ELSE NULL END');
        PREPARE gdm_stmt FROM @gdm_sql;
        EXECUTE gdm_stmt;
        DEALLOCATE PREPARE gdm_stmt;

        SELECT MIN(rn) FROM tmp_gdm_lookup WHERE runnable = 1 AND rn > v_rn INTO v_rn;
    END WHILE;

    -- outcome_combined: the weighted sum of the guideline variables that are not
    -- NULL, and NULL if they are all NULL.
    SET @gdm_sql = CONCAT(
        'UPDATE `', p_datatable, '` SET outcome_combined = ',
        'CASE WHEN COALESCE(', v_any_list, ') IS NULL THEN NULL ELSE ', v_sum_expr, ' END');
    SET @gdm_generated_sql = @gdm_sql;      -- keep a copy: SELECT @gdm_generated_sql;
    PREPARE gdm_stmt FROM @gdm_sql;
    EXECUTE gdm_stmt;
    DEALLOCATE PREPARE gdm_stmt;

    SET SESSION sql_safe_updates = @gdm_old_safe;

    -- --- Report ---------------------------------------------------------------
    SET @gdm_rows = 0;
    SET @gdm_sql = CONCAT('SELECT COUNT(*) FROM `', p_datatable, '` INTO @gdm_rows');
    PREPARE gdm_stmt FROM @gdm_sql;
    EXECUTE gdm_stmt;
    DEALLOCATE PREPARE gdm_stmt;

    INSERT INTO tmp_gdm_log (kind, detail)
        SELECT 'weight', CONCAT(abbr, ' = ', weight_txt) FROM tmp_gdm_lookup ORDER BY rn;

    -- How many people are positive (1) for each guideline. People for whom a
    -- guideline could not be calculated (NULL) are simply not counted.
    SELECT MIN(rn) FROM tmp_gdm_lookup INTO v_rn;

    WHILE v_rn IS NOT NULL DO
        SELECT abbr FROM tmp_gdm_lookup WHERE rn = v_rn INTO v_abbr;

        SET @gdm_pos = 0;
        SET @gdm_sql = CONCAT('SELECT IFNULL(SUM(`', v_abbr, '` = 1), 0) FROM `', p_datatable, '` INTO @gdm_pos');
        PREPARE gdm_stmt FROM @gdm_sql;
        EXECUTE gdm_stmt;
        DEALLOCATE PREPARE gdm_stmt;

        INSERT INTO tmp_gdm_log (kind, detail)
        VALUES ('positive', CONCAT(v_abbr, ': ', @gdm_pos, ' positive'));

        SELECT MIN(rn) FROM tmp_gdm_lookup WHERE rn > v_rn INTO v_rn;
    END WHILE;

    INSERT INTO tmp_gdm_log (kind, detail)
        VALUES ('done', CONCAT('Added ', v_k, ' guideline variables and outcome_combined to ',
                               p_datatable, ' (', @gdm_rows, ' rows)'));

    SELECT kind, detail FROM tmp_gdm_log ORDER BY id;

    DROP TEMPORARY TABLE IF EXISTS tmp_gdm_lookup;
    DROP TEMPORARY TABLE IF EXISTS tmp_gdm_log;
END$$

DELIMITER ;


-- 3b. Run the analysis on the two tables, with the weights and subset set in
-- PART 0. Everything (warnings, the weights used, the number of people positive
-- for each guideline, and a 'done' line) comes back as one small result table;
-- the results themselves are the new variables in the dataset table. Running this
-- again replaces the variables it added last time.

CALL run_guidelines(@gdm_dataset_table, @gdm_lookup_table, @gdm_weights, @gdm_subset);

-- Look at the results (the dataset table's own name, if you changed it in PART 0):
--
--   SELECT * FROM dataset_table LIMIT 6;
--
-- To see the exact statement the procedure used to work out outcome_combined:
--
--   SELECT @gdm_generated_sql;
--
-- The abbreviations you can use in @gdm_weights and @gdm_subset are the values in
-- the lookup table's Abbreviation variable: IADPSG, NICE, WHO_1999, WHO_2013, ADA,
-- RCOG, Diabetes_UK, India, NHS, MKUH, Barnley, RCHT, NDDG, CC.


-- =============================================================================
-- CHECKING IT: compare with the R pipeline on the example data
-- =============================================================================
--
-- 1. In PART 0(b) point the data file location at synthetic_dataset.txt (it is in
--    this folder, 1001 rows) and run the script.
--
-- 2. Count the results per guideline (change dataset_table if you renamed it):
--
--   SELECT 'IADPSG' AS guideline, SUM(IADPSG = 1) AS n_1, SUM(IADPSG = 0) AS n_0, SUM(IADPSG IS NULL) AS n_null FROM dataset_table
--   UNION ALL SELECT 'NICE',        SUM(NICE = 1),        SUM(NICE = 0),        SUM(NICE IS NULL)        FROM dataset_table
--   UNION ALL SELECT 'WHO_1999',    SUM(WHO_1999 = 1),    SUM(WHO_1999 = 0),    SUM(WHO_1999 IS NULL)    FROM dataset_table
--   UNION ALL SELECT 'WHO_2013',    SUM(WHO_2013 = 1),    SUM(WHO_2013 = 0),    SUM(WHO_2013 IS NULL)    FROM dataset_table
--   UNION ALL SELECT 'ADA',         SUM(ADA = 1),         SUM(ADA = 0),         SUM(ADA IS NULL)         FROM dataset_table
--   UNION ALL SELECT 'RCOG',        SUM(RCOG = 1),        SUM(RCOG = 0),        SUM(RCOG IS NULL)        FROM dataset_table
--   UNION ALL SELECT 'Diabetes_UK', SUM(Diabetes_UK = 1), SUM(Diabetes_UK = 0), SUM(Diabetes_UK IS NULL) FROM dataset_table
--   UNION ALL SELECT 'India',       SUM(India = 1),       SUM(India = 0),       SUM(India IS NULL)       FROM dataset_table
--   UNION ALL SELECT 'NHS',         SUM(NHS = 1),         SUM(NHS = 0),         SUM(NHS IS NULL)         FROM dataset_table
--   UNION ALL SELECT 'MKUH',        SUM(MKUH = 1),        SUM(MKUH = 0),        SUM(MKUH IS NULL)        FROM dataset_table
--   UNION ALL SELECT 'Barnley',     SUM(Barnley = 1),     SUM(Barnley = 0),     SUM(Barnley IS NULL)     FROM dataset_table
--   UNION ALL SELECT 'RCHT',        SUM(RCHT = 1),        SUM(RCHT = 0),        SUM(RCHT IS NULL)        FROM dataset_table
--   UNION ALL SELECT 'NDDG',        SUM(NDDG = 1),        SUM(NDDG = 0),        SUM(NDDG IS NULL)        FROM dataset_table
--   UNION ALL SELECT 'CC',          SUM(CC = 1),          SUM(CC = 0),          SUM(CC IS NULL)          FROM dataset_table;
--
--   SELECT SUM(outcome_combined IS NULL) AS n_null, SUM(outcome_combined) AS total FROM dataset_table;
--
-- What the R pipeline gives on this same file (default weights, current
-- lookup table):
--
--     guideline      n_1   n_0  n_null
--     IADPSG         191   363    447
--     NICE           149   405    447
--     WHO_1999       130   424    447
--     WHO_2013       191   363    447
--     ADA            191   363    447
--     RCOG           149   405    447
--     Diabetes_UK    149   405    447
--     India           61   189    751
--     NHS            149   405    447
--     MKUH           149   405    447
--     Barnley        149   405    447
--     RCHT           149   405    447
--     NDDG            48   188    765
--     CC              84   152    765
--
--     outcome_combined:  n_null = 156,  total = 1939
--
-- If you change a threshold in the lookup table, the counts for that guideline
-- will change in both R and SQL by the same amount - these numbers are for the
-- lookup table as it was when this file was written.

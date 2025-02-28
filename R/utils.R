#' @rawNamespace import(data.table, except = transpose)
#' @import cmdstanr
#' @import ggplot2
#' @importFrom stats median rnorm
NULL

#' @title Check an object is a Date
#' @description Checks that an object is a date
#' @param x An object
#' @return A logical
#' @family utils
is.Date <- function(x) {
  # nolint
  inherits(x, "Date")
}

#' Read in a stan function file as a character string
#'
#' @inheritParams expose_stan_fns
#' @return A character string in the of stan functions.
#' @family utils
#' @importFrom purrr map_chr
stan_fns_as_string <- function(files, target_dir) {
  functions <- paste0(
    "\n functions{ \n",
    paste(
      purrr::map_chr(
        files,
        ~ paste(readLines(file.path(target_dir, .)), collapse = "\n")
      ),
      collapse = "\n"
    ),
    "\n }"
  )
  return(functions)
}

#' Convert Cmdstan to Rstan
#'
#' @param functions A character string of stan functions as produced using
#' [stan_fns_as_string()].
#'
#' @return A character string of stan functions converted for use in `rstan`.
#' @family utils
convert_cmdstan_to_rstan <- function(functions) {
  # nolint start: nonportable_path_linter
  # replace bars in CDF with commas
  functions <- gsub("_cdf\\(([^ ]+) *\\|([^)]+)\\)", "_cdf(\\1,\\2)", functions)
  # nolint end
  # replace lupmf with lpmf
  functions <- gsub("_lupmf", "_lpmf", functions, fixed = TRUE)
  # replace array syntax
  #   case 1a: array[] real x -> real[] x
  functions <- gsub(
    "array\\[(,?)\\] ([^ ]*) ([a-z_]+)", "\\2[\\1] \\3", functions
  )
  #   case 1b: array[n] real x -> real x[n], including the nested case
  functions <- gsub(
    "array\\[([a-z0-9_]+(\\[[^]]*\\])?)\\] ([^ ]*) ([a-z_]+)",
    "\\3 \\4[\\1]", functions
  )
  #   case 2: array[n] real x -> real x[n]
  functions <- gsub(
    "array\\[([^]]*)\\]\\s+([a-z_]+)\\s+([a-z_]+)", "\\2 \\3[\\1]", functions
  )
  #   case 3: array[nl, np] matrix[n, l] x -> matrix[n, l] x[nl, np]
  functions <- gsub(
    "array\\[([^]]*)\\]\\s+([a-z_]+)\\[([^]]*)\\]\\s+([a-z_]+)",
    "\\2[\\3] \\4[\\1]", functions
  )

  # Custom replacement of log_diff_exp usage
  functions <- gsub(
    "lpmf[3:n] = log_diff_exp(lcdf[3:n], lcdf[1:(n-2)])",
    "for (i in 3:n) lpmf[i] = log_diff_exp(lcdf[i], lcdf[i-2]);",
    functions,
    fixed = TRUE
  )
  functions <- gsub(
    "lhaz[3:(n-1)] = lprob[3:(n-1)] - log_diff_exp(lccdf[2:(n-2)], lcdf[1:(n-3)]);", # nolint
    "for (i in 3:(n-1)) lhaz[i] =  lprob[i] - log_diff_exp(lccdf[i-1], lcdf[i-2]);", # nolint
    functions,
    fixed = TRUE
  )
  # remove profiling code
  functions <- remove_profiling(functions)
  return(functions)
}

#' Expose stan functions in R
#'
#' @description This function builds on top of
#' [rstan::expose_stan_functions()] in order to facilitate exposing package
#' functions in R for internal use, testing, and exploration. Crucially
#' it performs a conversion between the package `cmdstan` stan code
#' and `rstan` compatible stan code. It is not generally recommended that users
#' make use of this function apart from when exploring package functionality.
#'
#' @param files A character vector of file names
#'
#' @param target_dir A character string giving the directory in which
#' files can be found.
#'
#' @param ... Arguments to pass to [rstan::expose_stan_functions()]
#'
#' @return NULL (indivisibly)
#' @family utils
#' @importFrom rstan expose_stan_functions stanc
expose_stan_fns <- function(files, target_dir, ...) {
  # Make functions into a string
  functions <- stan_fns_as_string(files, target_dir)
  # Convert from cmdstan -> rstan to allow for in R uses
  functions <- convert_cmdstan_to_rstan(functions)
  # expose stan codef
  rstan::expose_stan_functions(rstan::stanc(model_code = functions), ...)
  return(invisible(NULL))
}

#' Load a package example
#'
#' Loads examples of nowcasts produce using example scripts. Used to streamline
#' examples, in package tests and to enable users to explore package
#' functionality without needing to install `cmdstanr`.
#'
#' @param type A character string indicating the example to load.
#' Supported options are
#'  * "nowcast", for [epinowcast()] applied to [germany_covid19_hosp]
#'  * "preprocessed_observations", for [enw_preprocess_data()] applied to
#'  [germany_covid19_hosp]
#'  * "observations", for [enw_latest_data()] applied to [germany_covid19_hosp]
#'  * "script", the code used to generate these examples.
#'
#' @return Depending on `type`, a `data.table` of the requested output OR
#' the file name(s) to generate these outputs (`type` = "script")
#'
#' @family data
#' @export
#' @examples
#' # Load the nowcast
#' enw_example(type = "nowcast")
#'
#' # Load the preprocessed observations
#' enw_example(type = "preprocessed_observations")
#'
#' # Load the latest observations
#' enw_example(type = "observations")
#'
#' # Load the script used to generate these examples
#' # Optionally source this script to regenerate the example
#' readLines(enw_example(type = "script"))
enw_example <- function(type = c(
                          "nowcast", "preprocessed_observations",
                          "observations", "script"
                        )) {
  type <- match.arg(type)

  if (type %in% c("nowcast", "preprocessed_observations", "observations")) {
    return(readRDS(
      system.file("extdata", sprintf("%s.rds", type), package = "epinowcast")
    ))
  } else if (type == "script") {
    return(
      system.file("examples", "germany_dow.R", package = "epinowcast")
    )
  }
}

#' @title Coerce Dates
#'
#' @description Provides consistent coercion of inputs to [IDate]
#' with error handling
#'
#' @param dates A vector-like input, which the function attempts
#' to coerce via [data.table::as.IDate()]. Defaults to NULL.
#'
#' @return An [IDate] vector.
#'
#' @details If any of the elements of `dates` cannot be coerced,
#' this function will result in an error, indicating all indices
#' which cannot be coerced to [IDate].
#'
#' Internal methods of [epinowcast] assume dates are represented
#' as [IDate].
#'
#' @export
#' @importFrom data.table as.IDate
#' @importFrom cli cli_abort cli_warn
#' @family utils
#' @examples
#' # works
#' coerce_date(c("2020-05-28", "2020-05-29"))
#' # does not, indicates index 2 is problem
#' tryCatch(
#'   coerce_date(c("2020-05-28", "2020-o5-29")),
#'   error = function(e) {
#'     print(e)
#'   }
#' )
coerce_date <- function(dates = NULL) {
  if (is.null(dates)) {
    return(data.table::as.IDate(numeric()))
  }
  if (length(dates) == 0) {
    return(data.table::as.IDate(dates))
  }

  res <- data.table::as.IDate(vapply(dates, function(d) {
    tryCatch(
      data.table::as.IDate(d, optional = TRUE),
      error = function(e) {
        return(data.table::as.IDate(NA))
      }
    )
  }, FUN.VALUE = data.table::as.IDate(0)))

  if (anyNA(res)) {
    cli::cli_abort(paste0(
      "Failed to parse with `as.IDate`: {toString(dates[is.na(res)])} ",
      "(indices {toString(which(is.na(res)))})."
    ))
  } else {
    return(res)
  }
}

#' Get internal timestep
#'
#' This function converts the string representation of the timestep to its
#' corresponding numeric value or returns the numeric input (if it is a whole
#' number). For "day", "week", it returns 1 and 7 respectively.
#' For "month", it returns "month" as months are not a fixed number of days.
#' If the input is a numeric whole number, it is returned as is.
#'
#' @param timestep The timestep to used. This can be a string ("day",
#' "week", "month") or a numeric whole number representing the number of days.
#'
#' @return A numeric value representing the number of days for "day" and
#' "week", "month" for "month",  or the input value if it is a numeric whole
#' number.
#' @importFrom cli cli_abort
#' @family utils
get_internal_timestep <- function(timestep) {
  # check if the input is a character
  if (is.character(timestep)) {
    switch(
      timestep,
      day = 1,
      week = 7,
      month = "month",  # months are not a fixed number of days
      cli::cli_abort(
        "Invalid timestep. Acceptable string inputs are 'day', 'week', 'month'."
      )
    )
  } else if (is.numeric(timestep) && timestep == round(timestep)) {
    # check if the input is a whole number
    return(timestep)
  } else {
    cli::cli_abort(
      paste0(
        "Invalid timestep. If timestep is a numeric, it should be a whole ",
        "number representing the number of days."
      )
    )
  }
}

#' Internal function to perform rolling sum aggregation
#'
#' This function takes a data.table and applies a rolling sum over a given
#' timestep,
#' aggregating by specified columns. It's particularly useful for aggregating
#' observations over certain periods.
#'
#' @param dt A `data.table` to be aggregated.
#' @param internal_timestep An integer indicating the period over which to
#' aggregate.
#' @param by A character vector specifying the columns to aggregate by.
#'
#' @return A modified data.table with aggregated observations.
#'
#' @importFrom data.table frollsum
#' @family utils
aggregate_rolling_sum <- function(dt, internal_timestep, by = NULL) {
  dt <- dt[,
    `:=`(
      confirm = {
        n_vals <- if (.N <= internal_timestep) {
          seq_len(.N)
        } else {
          c(
            1:(internal_timestep - 1),
            rep(internal_timestep, .N - (internal_timestep - 1))
          )
        }
        frollsum(confirm, n_vals, adaptive = TRUE)
      }
    ),
    by = by
  ]
  return(dt[])
}

#' Convert date column to numeric and calculate its modulus with given timestep.
#'
#' This function processes a date column in a `data.table`, converting it to a
#' numeric representation and then computing the modulus with the provided
#' timestep.
#'
#' @param dt A data.table.
#'
#' @param date_column A character string representing the name of the date
#' column in dt.
#'
#' @param timestep An integer representing the internal timestep.
#'
#' @return A modified data.table with two new columns: one for the numeric
#' representation of the date minus the minimum date and another for its
#' modulus with the timestep.
#'
#' @family utils
date_to_numeric_modulus <- function(dt, date_column, timestep) {
  mod_col_name <- paste0(date_column, "_mod")

  dt[, c(mod_col_name) := as.numeric(
        get(date_column) - min(get(date_column), na.rm = TRUE)
      ) %% timestep
  ]
  return(dt[])
}

utils::globalVariables(
  c(
    ".", ".draw", "max_treedepth", "no_at_max_treedepth",
    "per_at_max_treedepth", "q20", "q5", "q80", "q95", "quantile",
    "sd", "..by", "cmf", "day_of_week", "delay", "new_confirm",
    "observed", ".old_group", "reference_date", "report_date",
    "reported_cases", "s", "time", "extend_date", "effects",
    "confirm", "effects", "fixed", ".group", "logmean", "logsd",
    ".new_group", "observed", "latest_confirm", "mad", "variable",
    "fit", "patterns", ".draws", "prop_reported", "max_confirm",
    "run_time", "cum_prop_reported", "..by_with_group_id",
    "reference_missing", "prop_missing", "day", "posteriors",
    "formula", ".id", "n", ".confirm_avail", "prediction", "true_value",
    "person", "id", "latest", "num_reference_date", "num_report_date",
    "rep_mod", "ref_mod", "count", "reference_date_mod", "report_date_mod",
    "timestep", ".observed", "lookup", "max_obs_delay"
  )
)

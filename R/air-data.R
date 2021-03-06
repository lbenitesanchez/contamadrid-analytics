##########################################################################
# Luz Frias, 2016-06-12
# Downloads and cleans Madrid air data (current and historical)
#
# Data format detailed in
# http://datos.madrid.es/FWProjects/egob/contenidos/datasets/ficheros/Interprete_ficheros_%20calidad_%20del_%20aire_global.pdf
##########################################################################

##########################################################################
# Libraries
##########################################################################

library(reshape2)
library(data.table)

source("R/db.R")

##########################################################################
# Constants
##########################################################################

HISTORICAL_AIR_DATA_URL <- "http://datos.madrid.es/egob/catalogo/201200-__ID__-calidad-aire-horario.zip"
CURRENT_DAY_AIR_DATA_URL <- "http://www.mambiente.munimadrid.es/opendata/horario.txt"
CURRENT_AIR_DATA_DIR <- "dat/air_current/"
HISTORICAL_AIR_DATA_MAPPING <- "dat/historical_year_download_id.tsv"
HISTORICAL_AIR_DATA_DIR <- "dat/air_hist/"
HISTORICAL_AIR_DATA_ZIP_DIR <- paste0(HISTORICAL_AIR_DATA_DIR, "zip/")
HISTORICAL_AIR_DATA_RAW_DIR <- paste0(HISTORICAL_AIR_DATA_DIR, "raw/")
HISTORICAL_AIR_DATA_RES_DIR <- paste0(HISTORICAL_AIR_DATA_DIR, "res/")
HISTORICAL_AIR_DATA_FORMAT <- c(
  station     = 8,
  variable    = 2,
  technique   = 2,
  periodicity = 2,
  year        = 2,
  month       = 2,
  day         = 2,
  value       = rep(6, 24)
)

##########################################################################
# Functions
##########################################################################

load_historical_air_data <- function(station.ids = NA) {
  files <- list.files(HISTORICAL_AIR_DATA_RES_DIR)
  
  read.year <- function(file) {
    f <- fread(paste0(HISTORICAL_AIR_DATA_RES_DIR, file))
    if (!is.na(station.ids)) {
      f <- f[station %in% station.ids]
    }
    
    f[, date := as.Date(date)]
    f
  }
  
  data <- rbindlist(lapply(files, read.year))
}

load_historical_air_data_into_db <- function() {
  files <- list.files(HISTORICAL_AIR_DATA_RES_DIR)
  
  load.year <- function(file) {
    print(paste("Loading file", file, "into DB"))
    f <- fread(paste0(HISTORICAL_AIR_DATA_RES_DIR, file))
    f[, valid := as.numeric(valid)]
    f[is.na(value), value := 0]
    
    write.table(f, "/tmp/measure_tmp.tsv", sep = "\t", row.names = FALSE)
    system(paste0("PGPASSWORD=", G.DB.PASS, " psql -h ", G.DB.HOST," -U ", G.DB.USER,
                  " -d ", G.DB.DATABASE, ' -f "resources/historical-air-data.sql"'))
  }
  
  lapply(files, load.year)
}

load_current_air_data_into_db <- function() {
  files <- list.files(CURRENT_AIR_DATA_DIR)
  current.file <- max(files)
  
  f <- fread(paste0(CURRENT_AIR_DATA_DIR, current.file))
  f[, valid := as.numeric(valid)]
  f[is.na(value), value := 0]
  
  write.table(f, "/tmp/measure_tmp.tsv", sep = "\t", row.names = FALSE)
  system(paste0("PGPASSWORD=", G.DB.PASS, " psql -h ", G.DB.HOST," -U ", G.DB.USER,
                " -d ", G.DB.DATABASE, ' -f "resources/historical-air-data.sql"'))
}

load_contamination_variables <- function() {
  fread("dat/contamination_variables.tsv")
}

load_stations <- function() {
  fread("dat/stations.tsv")
}

download_current_day_air_data <- function() {
  raw <- fread(CURRENT_DAY_AIR_DATA_URL)
  
  # Station
  raw[, station := paste0(num_to_str(V1, 2),
                          num_to_str(V2, 3),
                          num_to_str(V3, 3))]
  
  # Variable, technique and periodicity
  raw[, variable    := V4]
  raw[, technique   := V5]
  raw[, periodicity := V6]  # hourly
  
  # Date
  raw[, date  := as.Date(paste0(V7, "-", V8, "-", V9))]
  
  # Hourly values
  for (i in 0:23) {
    first.col.ind  <- 10
    value.colname  <- paste0("V", 2 * i + first.col.ind)
    valid.colname  <- paste0("V", 2 * i + first.col.ind + 1)
    result.colname <- paste0("value", i)
    raw[, eval(result.colname) := paste0(get(value.colname), get(valid.colname))]
  }
  
  # Remove columns
  raw[, 1:57 := NULL]
  
  # Melt data in order to have one row per hour
  data.melted <- melt(raw, id.vars = c("station", "variable", "technique", "periodicity", "date"),
                      variable.name = "hour")
  data.melted[, hour := as.numeric(gsub("value([0-9]+)$", "\\1", hour))]
  
  # Split the value in the measured value and if it's valid
  data.melted[, valid := substr(value, nchar(value), nchar(value)) == "V"]
  data.melted[, value := as.numeric(substr(value, 1, nchar(value) - 1))]
  
  # If the value isn't numeric, mark the record as invalid.
  # This was observed only once, in 2013-08 record 32173
  data.melted[is.na(value), valid := FALSE]
  
  # Save this day data
  res.filename <- paste0(CURRENT_AIR_DATA_DIR, min(data.melted$date), ".tsv")
  write.table(data.melted, res.filename, sep = "\t", row.names = FALSE)
}

download_historical_air_data <- function() {
  mapping <- read.csv(HISTORICAL_AIR_DATA_MAPPING, sep="\t")
  years <- mapping$year
  
  for(year in years) {
    print(paste("Downloading and cleaning data from", year))
    download_hourly_air_data(year)
  }
}

download_hourly_air_data <- function(year) {
  # If it doesn't exist yet, create the file structure for historical data
  create_file_structure()
  
  # Get the download id
  mapping <- read.csv(HISTORICAL_AIR_DATA_MAPPING, sep="\t")
  download.id <- mapping[mapping$year == year,]$id
  if (length(download.id) == 0) {
    warning(paste("No data for year", year))
    return()
  }
  
  # Build the url and download the zipped data
  url <- gsub("__ID__", download.id, HISTORICAL_AIR_DATA_URL)
  zip.filename <- paste0(HISTORICAL_AIR_DATA_ZIP_DIR, year, ".zip")
  raw.dirname  <- paste0(HISTORICAL_AIR_DATA_RAW_DIR, year, "/")
  res.filename <- paste0(HISTORICAL_AIR_DATA_RES_DIR, year, ".tsv")
  download.file(url, zip.filename, quiet = TRUE)
  
  # Unzip it and read all the files in it
  unzip(zip.filename, exdir = raw.dirname)
  files <- list.files(raw.dirname, recursive = TRUE)
  
  data <- do.call("rbind", lapply(files, function(file)
    clean_historical_air_data(paste0(raw.dirname, file))))
  
  write.table(data, res.filename, sep = "\t", row.names = FALSE)
}

clean_historical_air_data <- function(input.file) {
  widths <- HISTORICAL_AIR_DATA_FORMAT
  data <- read.fwf(input.file, widths, stringsAsFactors = FALSE)
  colnames(data) <- names(widths)
  
  # Transform the date
  data$date <- as.Date(paste0(2000 + data$year, "-", data$month, "-", data$day))
  data$year  <- NULL
  data$month <- NULL
  data$day   <- NULL
  
  # Melt data in order to have one row per hour
  data.melted <- melt(data, id.vars = c("station", "variable", "technique", "periodicity", "date"),
                      variable.name = "hour")
  data.melted$hour <- as.numeric(gsub("value([0-9]+)$",
                                      "\\1",
                                      as.character(data.melted[, 6]))) - 1
  
  # Split the value in the measured value and if it's valid
  data.melted$valid <- substr(data.melted$value, 6, 6) == "V"
  data.melted$value <- as.numeric(substr(data.melted$value, 1, 5))
  
  # If the value isn't numeric, mark the record as invalid.
  # This was observed only once, in 2013-08 record 32173
  data.melted[is.na(data.melted$value), "valid"] <- FALSE
  
  return(data.melted)
}

num_to_str <- function(num, width) {
  formatC(num, width = width, format = "d", flag = "0")
}

create_file_structure <- function() {
  create_directory(HISTORICAL_AIR_DATA_DIR)
  create_directory(HISTORICAL_AIR_DATA_ZIP_DIR)
  create_directory(HISTORICAL_AIR_DATA_RAW_DIR)
  create_directory(HISTORICAL_AIR_DATA_RES_DIR)
  create_directory(CURRENT_AIR_DATA_DIR)
}

create_directory <- function(directory) {
  dir.create(directory, showWarnings = FALSE)
}

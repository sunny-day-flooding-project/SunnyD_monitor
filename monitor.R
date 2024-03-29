# Packages to load
library(dplyr)
library(dbplyr)
library(lubridate)
library(RPostgres)
library(DBI)
library(pool)
library(foreach)
library(dbx)
library(readr)
library(httr)
library(later)
library(googledrive)
library(googlesheets4)
library(tidyr)
library(stringr)
library(jsonlite)
library(crul)
library(MASS)
library(riem)
library(xml2)


#-------- Description --------------
# This code converts raw pressure data from a storm drain in
# Beaufort, NC to water level data. The water level data
# are then drift-corrected. Drift-corrected water level data
# are monitored, and any water level measurements above the road
# elevation trigger email alerts using Mailchimp.

# Github repo: https://github.com/SunnyD-Flood-Sensor-Network/SunnyD_monitor
# Project data viewer: http://go.unc.edu/flood-data


#-------- Setup ----------
# Source env variables if working on desktop
# source("/Users/adam/Documents/SunnyD/sunnyday_postgres_keys.R")

# Connect to database
con <- dbPool(
  drv = RPostgres::Postgres(),
  dbname = Sys.getenv("POSTGRESQL_DATABASE"),
  host = Sys.getenv("POSTGRESQL_HOSTNAME"),
  port = Sys.getenv("POSTGRESQL_PORT"),
  password = Sys.getenv("POSTGRESQL_PASSWORD"),
  user = Sys.getenv("POSTGRESQL_USER")
)

sensor_surveys <- con %>%
  tbl("sensor_surveys")

# These are just connections for reading/writing
raw_data <- con %>%
  tbl("sensor_data")

processed_data <- con %>%
  tbl("sensor_water_depth")

drift_corrected_data <- con %>%
  tbl("data_for_display")

fiman_gauge_key <- read_csv("fiman_gauge_key.csv")

#------------------------ Functions to retrieve atm pressure -------------------

noaa_atm <- function(id, begin_date, end_date) {
  # Should return a tibble with columns: place | date | pressure_mb | notes
  id = as.character(id)
  
  request <-
    httr::GET(
      url = "https://api.tidesandcurrents.noaa.gov/api/prod/datagetter/",
      query = list(
        "station" = id,
        "begin_date" = format(begin_date, "%Y%m%d %H:%M"),
        "end_date" = format(end_date, "%Y%m%d %H:%M"),
        "product" = "air_pressure",
        "units" = "metric",
        "time_zone" = "gmt",
        "format" = "json",
        "application" = "UNC_Institute_for_the_Environment, https://github.com/acgold"
      )
    )
  
  latest_atm_pressure <-
    tibble::as_tibble(jsonlite::fromJSON(rawToChar(request$content))$data)
  colnames(latest_atm_pressure) <-
    c("date", "pressure_mb", "codes")
  
  latest_atm_pressure <- latest_atm_pressure %>%
    transmute(
      id = id,
      date = ymd_hm(date),
      pressure_mb = as.numeric(pressure_mb),
      notes = "coop"
    )
  return(latest_atm_pressure)
}


nws_atm <- function(id, begin_date, end_date) {
  # Should return a tibble with columns: place | date | pressure_mb | notes
  id = as.character(id)
  
  request <-
    httr::GET(
      url = paste0("https://api.weather.gov/stations/",id,"/observations"),
      query = list(
        "start" = paste0(format(begin_date - hours(1), "%Y-%m-%dT%H:%M:%S+00:00")),
        "end" = paste0(format(end_date +hours(1), "%Y-%m-%dT%H:%M:%S+00:00"))
      ),
      add_headers(Accept= "application/geo+json")
    )
  
  raw_nws_data <-
    jsonlite::fromJSON(rawToChar(request$content))$features$properties
  
  timestamp <- lubridate::ymd_hms(raw_nws_data$timestamp)
  
  pressure <- raw_nws_data$barometricPressure$value/100
  
  latest_atm_pressure <- tibble::tibble(date = timestamp,
                                        pressure_mb = pressure) %>%
    na.omit() %>%

    arrange(date)
  
  latest_atm_pressure <- latest_atm_pressure %>%
    transmute(
      id = id,
      date = date,
      pressure_mb = pressure_mb,
      notes = "NWS"
    )
  
  return(latest_atm_pressure)
}


isu_atm <- function(id, begin_date, end_date){
  id = as.character(id)
  
  weather_data <- riem::riem_measures(station = id,
                      date_start = floor_date(begin_date, unit="day"),
                      date_end = ceiling_date(end_date, unit="day")
                      )
  
  latest_atm_pressure <- weather_data %>%
    transmute(
      id = station,
      date = valid,
      pressure_mb = alti * 1000 * 0.0338639,
      notes = "ISU"
    )
  
  return(latest_atm_pressure)
}


fiman_atm <- function(id, begin_date, end_date){
  station_keys <- fiman_gauge_key %>% 
    filter(site_id == id) %>% 
    filter(Sensor == "Barometric Pressure")
  
  request <- httr::GET(url = Sys.getenv("FIMAN_URL"),
                       query = list(
                         "site_id" = station_keys$site_id,
                         "data_start" = paste0(format(begin_date - hours(1), "%Y-%m-%d %H:%M:%S")),
                         "date_end" = paste0(format(end_date + hours(1), "%Y-%m-%d %H:%M:%S")),
                         "format_datetime"="%Y-%m-%d %H:%M:%S",
                         "tz" = "UTC",
                         "show_raw" = T,
                         "show_quality" = T,
                         "sensor_id" =  station_keys$sensor_id
                         
                       ))
  
  content <- request$content %>% 
    xml2::read_xml() %>% 
    xml2::as_list() %>% 
    as_tibble()

  parsed_content <- content$onerain$response %>% 
    as_tibble() %>% 
    unnest_wider("general") %>% 
    unnest(cols = names(.)) %>% 
    unnest(cols = names(.)) %>% 
    mutate(data_time = lubridate::ymd_hms(data_time),
           data_value = as.numeric(data_value))
  
  latest_atm_pressure <- parsed_content %>%
    transmute(
      id = id,
      date = data_time,
      pressure_mb = data_value,
      notes = "FIMAN"
    )
  
  return(latest_atm_pressure)
  }

get_atm_pressure <- function(atm_id, atm_src, begin_date, end_date) {
  # Each location will have its own function called within this larger function
  switch(toupper(atm_src),
         "NOAA" = noaa_atm(id = atm_id,
                           begin_date = begin_date,
                           end_date = end_date),
         "NWS" = nws_atm(id = atm_id,
                         begin_date = begin_date,
                         end_date = end_date),
         "ISU" = isu_atm(id = atm_id,
                         begin_date = begin_date,
                         end_date = end_date),
         "FIMAN" = fiman_atm(id = atm_id,
                             begin_date = begin_date,
                             end_date = end_date)
  )
  
}

interpolate_atm_data <- function(data, debug = T){
  place_names <- unique(data$place)
  
  interpolated_data <- foreach(i = 1:length(place_names), .combine = "bind_rows") %do% {
    
    selected_place_name <- place_names[i]
    
    # select new data for each place
    data_filtered <- data %>%
      dplyr::filter(place == selected_place_name)
    
    # extract the date range and duration
    new_data_date_range <- c(min(data_filtered$date, na.rm=T)-minutes(30), max(data_filtered$date, na.rm=T)+minutes(30))
    new_data_date_duration <- lubridate::time_length(diff(new_data_date_range), unit = "days")
    
    if(new_data_date_duration >= 30){
      chunks <- ceiling(new_data_date_duration / 30)
      span <- lubridate::duration(new_data_date_duration / chunks, units = "days")
      
      atm_tibble <- foreach(j = 1:chunks, .combine = "bind_rows") %do% {
        range_min <- new_data_date_range[1] + (span * (j - 1))
        range_max <- new_data_date_range[1] + (span * j)
        
        get_atm_pressure(atm_id = unique(data_filtered$atm_station_id)[1],
                         atm_src = unique(data_filtered$atm_data_src)[1],
                         begin_date = range_min,
                         end_date = range_max)
      }
      
      atm_tibble <- atm_tibble %>%
        dplyr::distinct(date, .keep_all=T)
    }
    
    if(new_data_date_duration < 30){
      # get atm pressure 
      atm_tibble <- get_atm_pressure(atm_id = unique(data_filtered$atm_station_id)[1],
                                     atm_src = unique(data_filtered$atm_data_src)[1],
                                     begin_date = new_data_date_range[1],
                                     end_date = new_data_date_range[2]) %>% 
        distinct()
      
    }
    
    if(nrow(atm_tibble) <= 1){
      return()
    }
    
    atm_tibble_bounds_data <- (min(data_filtered$date, na.rm=T) > min(atm_tibble$date, na.rm=T)) & (max(data_filtered$date, na.rm=T) < max(atm_tibble$date, na.rm=T))
    
    interpolated_data_filtered <- data_filtered %>%
      filter(date > min(atm_tibble$date, na.rm=T)) %>% 
      filter(date < max(atm_tibble$date, na.rm=T)) %>%
      mutate(pressure_mb = approxfun(atm_tibble$date, atm_tibble$pressure_mb)(date))
    
    if(debug == T) {
      cat("- New raw data detected for:", selected_place_name, "\n")
      cat("-",data_filtered %>% nrow(),"new rows", "\n")
      cat("- Date duration is",round(new_data_date_duration,digits = 2),"days", "\n")
      cat("-",(data_filtered %>% nrow())-(interpolated_data_filtered %>% nrow()),"new observation(s) filtered out b/c not within atm pressure date range","\n")
      cat("#################################","\n")
    }
    
    interpolated_data_filtered
  }
  
  return(interpolated_data)
}

#---------- Functions to adjust for drift ------------------
match_measurements_to_survey <- function(measurements, survey_data){
  sites <- unique(measurements$sensor_ID)
  
  matched_measurements <- foreach(i = 1:length(sites), .combine = "bind_rows") %do% {
    selected_site <- sites[i]
  
    selected_measurements <- measurements %>% 
      filter(sensor_ID == selected_site)
    
    site_survey_data <- survey_data %>% 
      filter(sensor_ID == selected_site)
    
    if(nrow(site_survey_data)==0){
      warning(paste0("There are no survey data for: ",selected_site,". Please add survey data using the `write_survey` API endpoint"))
      
      return()
    }
    
    survey_dates <- unique(site_survey_data$date_surveyed) %>% sort(decreasing = F)
    number_of_surveys <- length(survey_dates)
    
    if(min(measurements$date, na.rm=T) < min(survey_dates)){
      warning(paste0("There are data that precede the survey dates for: ",selected_site))
    }
    
    if(number_of_surveys == 1){
      selected_measurements_w_survey_date <- selected_measurements %>%
               mutate(date_surveyed = ymd_hms(ifelse(date >= survey_dates,format(survey_dates, "%Y-%m-%d %H:%M:%S"), NA)))
    }

    if(number_of_surveys > 1){
      selected_measurements_w_survey_date <- selected_measurements %>%
        mutate(date_surveyed = ymd_hms(cut.POSIXt(date, breaks = c(survey_dates, Sys.time()))))
    }
    
    selected_measurements_survey_merged <- selected_measurements_w_survey_date %>%
      left_join(site_survey_data, by = c("place","sensor_ID","date_surveyed"))
    
    selected_measurements_survey_merged
  }
  
  return(matched_measurements)
  
}

get_smooth_min_wl <- function(measurements){
  survey_dates <- unique(measurements$date_surveyed)
  number_of_surveys <- length(survey_dates)
  
  foreach(i = 1:number_of_surveys, .combine = "bind_rows") %do% {
    measurements_for_survey_dates <- measurements %>%
      filter(date_surveyed == survey_dates[i])
    
    min_wl <- foreach(j = 1:nrow(measurements_for_survey_dates), .combine = "c") %do% {
      
      the_date <- measurements_for_survey_dates$date[j]
      
      vals <- measurements_for_survey_dates$sensor_water_depth[(measurements_for_survey_dates$date >= (the_date-days(2))) & (measurements_for_survey_dates$date <= the_date)]
      
      min_val <- min(vals,na.rm=T)
      min_val
    }
    
    max_segment_date <- max(measurements_for_survey_dates$date, na.rm=T)
    
    z <- measurements_for_survey_dates %>%
      mutate(min_water_depth = min_wl) %>%
      mutate(deriv = c(NA,diff(min_water_depth)),
             change_pt = ifelse(date == max_segment_date, T,
                                ifelse(!is.na(deriv), ifelse(deriv != 0, T, F), F)))
    
    z_chng_pts <- z %>%
      filter(change_pt == T & (min_water_depth >= quantile(min_water_depth, 0.25) & min_water_depth <= quantile(min_water_depth, 0.75))) %>% 
      dplyr::select(place, sensor_ID, date, min_water_depth)
    
    if(nrow(z_chng_pts) < 3){
      return(
        z %>%
          left_join(z_chng_pts %>%
                      mutate(smoothed_min_water_depth = min_water_depth),
                    by = c("place","sensor_ID","date","min_water_depth")) %>%
          tidyr::fill(smoothed_min_water_depth,.direction = "downup") 
        
      )
    }
    
    if(nrow(z_chng_pts) >= 3){
      return(
        z %>%
          left_join(z_chng_pts %>%
                      mutate(smoothed_min_water_depth = loess(min_water_depth~as.numeric(date), data = .)$fitted),
                    by = c("place","sensor_ID","date","min_water_depth")) %>%
          tidyr::fill(smoothed_min_water_depth,.direction = "downup") 
        
      )
    }
    
    
    
  }
}

#---------- Functions to adjust for drift ------------------
adjust_wl <- function(time = Sys.time(), processed_data_db){
  
  min_date_x <-  time - days(14)
  min_date_x_shorter <- time - days(7)
  min_date_x_somewhat_shorter <- time - days(12)
  max_date_x <- time
  
  db_df_collected <- processed_data_db %>%
    filter(date >= min_date_x & date <= max_date_x) %>%
    collect() %>% 
    mutate(diff_lag = sensor_water_depth - lag(sensor_water_depth),
           time_lag = lubridate::time_length(date-lag(date), unit = "minute"),
           diff_per_time_lag = diff_lag/time_lag,
           qa_qc_flag = ifelse(is.na(diff_per_time_lag), F, ifelse((diff_per_time_lag >= abs(.1)) , T, F))
    ) %>% 
    filter(qa_qc_flag == F)
  
  if(nrow(db_df_collected) == 0){
    return(cat("No processed data over past 2 weeks available to adjust"))
  }
  

  sensor_list <- unique(db_df_collected$sensor_ID)
  
  aggregate_smooth_wl <- foreach(j = 1:length(sensor_list), .combine = "bind_rows") %do% {
    
    site_db_df_collected <- db_df_collected %>%
      filter(sensor_ID == sensor_list[j])
    
    sensor_surveys_collected <- sensor_surveys %>%
      filter(sensor_ID == !!sensor_list[j]) %>%
      collect() %>%
      arrange(desc(date_surveyed))
    
    if(nrow(sensor_surveys_collected) == 0){
      return()
    }
    
    site_db_df_collected_min_wl <- match_measurements_to_survey(measurements = site_db_df_collected,
                                                                survey_data = sensor_surveys_collected) %>%
      get_smooth_min_wl()
    
  }
  
  adjusted_df <- db_df_collected %>%
    left_join(aggregate_smooth_wl, by = c("place", "sensor_ID", "date", "atm_pressure", "sensor_pressure", "voltage", "sensor_water_depth", "qa_qc_flag", "tag")) %>%
    mutate(sensor_water_level = sensor_elevation + sensor_water_depth,
           road_water_level = sensor_water_level - road_elevation,
           road_water_level_adj = road_water_level - smoothed_min_water_depth,
           sensor_water_level_adj = sensor_water_level - smoothed_min_water_depth) %>%
    filter(date >= min_date_x_shorter) %>%
    dplyr::select(place, sensor_ID, date, voltage, sensor_water_depth, qa_qc_flag, date_surveyed, sensor_elevation,
                  road_elevation, lat, lng, alert_threshold, min_water_depth, deriv, change_pt, smoothed_min_water_depth,
                  sensor_water_level, road_water_level, sensor_water_level_adj, road_water_level_adj)
  
  return(adjusted_df)
}


flood_counter <- function(dates, start_number = 0, lag_hrs = 8){
  
  lagged_time <- difftime(dates, dplyr::lag(dates), units = "hours") %>% 
    replace_na(duration(0))
  
  lead_time <- difftime(dplyr::lead(dates),dates, units = "hours") %>% 
    replace_na(duration(0))
  
  group_change_vector <- foreach(i = 1:length(dates), .combine = "c") %do% {
    x <- 0
    
    if(abs(lagged_time[i]) > hours(lag_hrs)){
      x <- 1
    }
    
    x
  }
  
  group_vector <- cumsum(group_change_vector) + 1 + start_number
  return(group_vector)
}

detect_flooding <- function(x){
  latest_measurements <- x %>%
    group_by(sensor_ID) %>%
    slice_max(n=3,order_by = date) %>%
    collect() %>%
    mutate(sample_interval = lag(date) - date,
           min_interval = min(sample_interval, na.rm=T))
  
  current_time <- Sys.time() %>% lubridate::with_tz(tzone="UTC")
  
  last_measurement <- latest_measurements %>%
    filter(date == max(date, na.rm=T)) %>%
    mutate(above_alert_wl = sensor_water_level_adj >= alert_threshold,
           time_since_measurement = current_time - date,
           cutoff_time = lubridate::as.period(min_interval) + minutes(6) + minutes(6) + minutes(3),
           is_flooding = (time_since_measurement > cutoff_time) & above_alert_wl,
           alert_sent = F)
  
  return(last_measurement %>%
           ungroup() %>%
           transmute(place, sensor_ID, latest_measurement = date, current_time = current_time, is_flooding, alert_sent)
  )
}



is_flooding_ongoing <- function(x, lag_hrs = 4){

  latest_flood <- x %>%
    filter(flood_event == max(flood_event, na.rm=T)) %>%
    filter(date == max(date, na.rm=T))
  
  return((Sys.time() - latest_flood$date) <= hours(lag_hrs))
}

find_flood_events <- function(x, existing_flood_events, flood_cutoff = 0){
  n_flooding_measurements <- x %>%
    filter(road_water_level_adj >= flood_cutoff) %>%
    nrow()
  
  if(n_flooding_measurements == 0){
    cat("No flooding detected!\n")
    return()
  }
  
  flooded_measurements <- x %>%
    filter(road_water_level_adj >= flood_cutoff) %>%
    mutate(min_date = date - minutes(1),
           max_date = date + minutes(1)) %>%
    dplyr::select(place, sensor_ID, date, road_water_level_adj, road_water_level, voltage, min_date, max_date)
  

  start_stop_flood_events <- existing_flood_events %>%
    group_by(place, sensor_ID, flood_event) %>%
    summarize(min_date = min(date, na.rm=T) - minutes(30),
              max_date = max(date, na.rm=T) + minutes(30),
              .groups = "keep")
  

  existing_storm_intervals <- start_stop_flood_events %>%
    mutate(intervals = interval(start = min_date, end = max_date))
  
  sensors <- unique(flooded_measurements$sensor_ID)
  
  new_flood_events_df <- foreach(i = 1:length(sensors), .combine = "bind_rows") %do% {
    
    last_flood_number <- ifelse(nrow(existing_flood_events %>% filter(sensor_ID == sensors[i])) > 0, max(existing_flood_events %>% filter(sensor_ID == sensors[i]) %>% pull(flood_event), na.rm=T), 0)
    
    site_flood_measurements <- flooded_measurements %>%
      filter(sensor_ID == sensors[i]) %>%
      mutate(flood_event = flood_counter(date, start_number = 0, lag_hrs = 2), .before = "date")
    
    grouped_flood_measurements <- site_flood_measurements %>%
      group_by(place, sensor_ID, flood_event) %>%
      summarize(min_date = min(date, na.rm=T),
                max_date = max(date, na.rm=T),
                .groups = "keep") %>%
      mutate(intervals = interval(start = min_date, end = max_date)) %>%
      ungroup()
    
    site_existing_storm_intervals <- existing_storm_intervals %>%
      filter(sensor_ID == sensors[i])
    
    new_storm_intervals <- foreach(j = 1:nrow(grouped_flood_measurements), .combine = "bind_rows") %do%{
      is_new <- sum(purrr::map(.x = site_existing_storm_intervals$intervals,
                               .f = function(.x){
                                 int_overlaps(.x, grouped_flood_measurements$intervals[j,])
                               }) %>%
                      unlist()) == 0
      
      grouped_flood_measurements[j,][is_new,]
    }
    
    return(site_flood_measurements %>%
             filter(flood_event %in% new_storm_intervals$flood_event) %>%
             group_by(flood_event) %>% 
             arrange(date) %>% 
             mutate(flood_event = cur_group_id() + last_flood_number) %>% 
             dplyr::select(-c(min_date, max_date)) %>% 
             mutate(drift = road_water_level - road_water_level_adj, .before="voltage") %>% 
             mutate(flood_event_name = paste0(sensor_ID,"_",flood_event))
    )
    
  }
  
  if(nrow(new_flood_events_df) == 0){
    return(cat("No *NEW* flood events!\n"))
  }
  
  return(new_flood_events_df)
}


document_flood_events <- function(time = Sys.time() %>% with_tz(tzone = "UTC"), processed_data_db, write_to_sheet){
  # correct for drift
  adjusted_wl <- adjust_wl(time = time, processed_data_db = processed_data_db)
  
    dbx::dbxUpsert(conn = con,
                   table = "data_for_display",
                   records = adjusted_wl,
                   where_cols = c("place","sensor_ID","date"),
                   batch_size = 2000
    )
  
  cat("Wrote drift-corrected data!", "\n")
  
  alert_flooding(x = adjusted_wl)
  
  if(write_to_sheet == F){
    return(cat("Checked for loss of communications!\n"))
  }
  
  if(write_to_sheet == T){
    # Read in existing flood event data from Google Sheets
    existing_flood_events <- suppressMessages(googlesheets4::read_sheet(ss = sheets_ID))
    
    # segment the adjusted water level measurements into flood events
    flood_events_df <- find_flood_events(x = adjusted_wl, existing_flood_events = existing_flood_events)
    
    # No flood events detected, return the function
    if(is.null(flood_events_df)){
      return(cat("No flooding detected!\n"))
    }
    
    # check if it is currently flooding. If it is, remove the latest flood group
    # so it doesn't add unfinished flood event to the database
    flooding_sensors <- unique(flood_events_df$sensor_ID)
    
    flood_events_df <- foreach(i = 1:length(flooding_sensors), .combine = "bind_rows") %do% {
      if(is_flooding_ongoing(flood_events_df %>%
                             filter(sensor_ID == flooding_sensors[i])) == F){
        
        flood_events_df %>%
          filter(sensor_ID == flooding_sensors[i])
      }
      else(flood_events_df %>%
             filter(sensor_ID == flooding_sensors[i]) %>%
             slice(0))
    }
    
    if(nrow(flood_events_df) == 0){
      return(cat("No new flood events!\n"))
    }
    
    if(nrow(flood_events_df) > 0){
      
      flood_event_name <- unique(flood_events_df$flood_event_name)
      
      flood_events_df$pic_link <- "NA"
      
      flood_events_w_pic <- foreach(k = 1:length(flood_event_name), .combine = "bind_rows") %do% {
        selected_flood <- flood_events_df %>%
          filter(flood_event_name == flood_event_name[k])
        
        days_of_flood <- selected_flood %>%
          pull(date) %>%
          as_date() %>%
          unique()
        
        folder_info <- suppressMessages(googledrive::drive_get(path = paste0("Images/","CAM_",unique(selected_flood$sensor_ID),"/",days_of_flood,"/"),shared_drive = as_id(Sys.getenv("GOOGLE_SHARED_DRIVE_ID"))))
        
        if(nrow(folder_info) == 0){
          return(selected_flood %>% 
                   dplyr::select(-c(flood_event_name)) %>% 
                   mutate(pic_link = NA))
        }
        
        image_list <- foreach(l = 1:nrow(folder_info), .combine = "bind_rows") %do% {
          suppressMessages(drive_ls(folder_info$id[l])) %>%
            mutate(pic_time = ymd_hms(sapply(stringr::str_split(name, pattern = "_"), tail, 1)))
        }
        
        selected_flood_w_pic <- foreach(j = 1:nrow(selected_flood), .combine = "bind_rows") %do% {
          
          min_flood_time <- min(selected_flood$date[j], na.rm=T) - minutes(5)
          max_flood_time <- max(selected_flood$date[j], na.rm=T) + minutes(5)
          
          filtered_image_list <- image_list %>%
            filter(pic_time > min_flood_time & pic_time < max_flood_time)
          
          if(nrow(filtered_image_list) == 0){
            return(selected_flood[j,] %>%
                     dplyr::select(-c(flood_event_name)) %>% 
                     mutate(pic_link = NA))
          }
          
          filtered_image_list <- filtered_image_list %>%
            mutate(diff_to_pic_time = abs(selected_flood$date[j] - pic_time)) %>%
            filter(diff_to_pic_time == min(diff_to_pic_time)) %>%
            slice(1) %>%
            mutate(pic_link = drive_resource[[1]]$webViewLink)
          
          return(selected_flood[j,] %>%
                   dplyr::select(-c(flood_event_name)) %>% 
                   mutate(pic_link = filtered_image_list$pic_link))
        }
      }
    }
    
    suppressMessages(googlesheets4::sheet_append(ss = sheets_ID,
                                                 data = flood_events_w_pic))
    return(cat("Wrote new flood events!\n"))
  }
  
}

#------------ mailchimp functions ---------------
# Most functions are from super great chimpr package that is on GitHub - https://github.com/jdtrat/chimpr/blob/master/R/zzz.R
# It only handles GET requests and is not available on CRAN

chimpr_ua <- function() {
  versions <- c(
    paste0("r-curl/", utils::packageVersion("curl")),
    paste0("crul/", utils::packageVersion("crul"))
  )
  paste0(versions, collapse = " ")
}

chmp_base <- function(x="us20") sprintf("https://%s.api.mailchimp.com", x)

err_catcher <- function(x) {
  if (x$status_code > 201) {
    if (x$response_headers$`content-type` ==
        "application/problem+json; charset=utf-8") {
      
      xx <- jsonlite::fromJSON(x$parse("UTF-8"))
      xx <- paste0("\n  ", paste(names(xx), unname(xx), sep = ": ",
                                 collapse = "\n  "))
      stop(xx, call. = FALSE)
    } else {
      x$raise_for_status()
    }
  }
}

chmp_GET <- function(dc = "us20", path, key, query = list(), ...){
  cli <- crul::HttpClient$new(
    # url = "https://us20.api.mailchimp.com/3.0/ping",
    url = chmp_base(dc),
    opts = c(list(useragent = chimpr_ua()), ...),
    auth = crul::auth(user = "anystring", pwd = key)
    # auth = crul::auth(user = "anystring", pwd = check_key(key))
  )
  temp <- cli$get(
    path = file.path("3.0", path),
    query = query)
  err_catcher(temp)
  x <- temp$parse("UTF-8")
  return(x)
}

chmp_POST <- function(dc = "us20", path, key, query = list(), body = NULL,
                      disk = NULL, stream = NULL, encode = "json", ...) {
  
  cli <- crul::HttpClient$new(
    url = chmp_base(dc),
    opts = c(list(useragent = chimpr_ua()), ...),
    auth = crul::auth(user = "anystring", pwd = key)
  )
  
  temp <- cli$post(
    path = file.path("3.0", path),
    query = query,
    body = body,
    disk = disk,
    stream = stream,
    encode = encode)
  
  err_catcher(temp)
  x <- temp$parse("UTF-8")
  return(x)
}

chmp_PUT <- function(dc = "us20", path, key, query = list(), body = NULL,
                     disk = NULL, stream = NULL, encode = "json", ...) {
  
  cli <- crul::HttpClient$new(
    url = chmp_base(dc),
    opts = c(list(useragent = chimpr_ua()), ...),
    auth = crul::auth(user = "anystring", pwd = key)
  )
  
  temp <- cli$put(
    path = file.path("3.0", path),
    query = query,
    body = body,
    disk = disk,
    stream = stream,
    encode = encode)
  
  err_catcher(temp)
  x <- temp$parse("UTF-8")
  return(x)
}

send_new_alert <- function(place){
  list_id <- Sys.getenv("MAILCHIMP_LIST_ID")
  interest_id <- Sys.getenv("MAILCHIMP_INTEREST_ID")
  formatted_place <- str_replace(place, pattern = "North Carolina", replacement = "NC")
  
  site_options <- chmp_GET(path=paste0("lists/", list_id,"/interest-categories/",interest_id,"/interests"), 
                           key = Sys.getenv("MAILCHIMP_KEY")) %>% 
    fromJSON(flatten=T)
  
  site_options_df <- site_options$interests %>% 
    as.data.frame() %>% 
    as_tibble()
  
  interest_value_df <- site_options_df %>% 
    filter(name == formatted_place) 
  
  if(nrow(interest_value_df) == 0){
    return("Place is not registered as an option for the listserv")
  }
  
  new_campaign <- chmp_POST(path=paste0("campaigns"),
                            key = Sys.getenv("MAILCHIMP_KEY"),
                            body = paste0('{"type": "plaintext",
            "recipients": {"segment_opts": {
            "match": "all",
            "conditions":[
                          {
                   "condition_type": "Interests",
                   "field": "interests-',interest_id,'",
                   "op":  "interestcontains",
                   "value": ["',interest_value_df$id,'"]
                          }
            ]
            },
            "list_id": "',list_id,'"
            },
            "tracking": {
            "opens": false,
            "text_clicks": false
            },
            "settings": {
            "subject_line": "Flood Alert - Sunny Day Flooding Project",
            "preview_text": "Flood alert for ', formatted_place,'",
            "title": "', formatted_place,' Flood Alert - ', Sys.time() %>% with_tz(tzone="America/New_York") %>% as_date(),'",
            "from_name": "Sunny Day Flooding Project"  ,
            "reply_to": "sunnydayflood@gmail.com",
            "use_conversation": true,
            "to_name": "*|FNAME|* *|LNAME|*",
            "auto_footer": false
            }
}
'
                            )) %>% 
    jsonlite::fromJSON()
  
  new_campaign_id <- new_campaign$id
  
  chmp_PUT(path = paste0("campaigns/",new_campaign_id,"/content"),
           key = Sys.getenv("MAILCHIMP_KEY"),
           body=paste0('{"plain_text":"Flood Alert for ',formatted_place,
                       '\\n--------------------------------\\n\\nWater estimated on/near roadway at: ', 
                       format(Sys.time() %>% with_tz(tzone="America/New_York"),"%m/%d/%Y %H:%M%P %Z"),
                       '.\\n\\nVisit our data viewer to see live data and pictures of the site:\\nhttps://go.unc.edu/flood-data\\n\\nThis alert is informed by preliminary data and is for INFORMATIONAL PURPOSES ONLY. Please refer to your local National Weather Service station for actionable flooding info: https://water.weather.gov/ahps/region.php?state=nc  \\n\\n================================\\nYou are receiving this email because you opted in via our website: https://tarheels.live/sunnydayflood\\n\\nUnsubscribe *|HTML:EMAIL|* from this list: *|UNSUB|*\\n\\nUpdate Profile: *|UPDATE_PROFILE|*\\n\\nOur mailing address is:\\nSunny Day Flooding Project\\n223 E Cameron Ave\\nNew East Building, CB#3140\\nChapel Hill, NC 27599-3140\\nUSA"}'))
  
  chmp_POST(path=paste0("campaigns/",new_campaign_id,"/actions/send"), key = Sys.getenv("MAILCHIMP_KEY"))
  
  cat("Sent new flood alert for: \n", place,"\n")
}

alert_flooding <- function(x){
  is_flooding <- detect_flooding(x)
  
  places <- unique(is_flooding$place)
  
  flood_status_df <- con %>% 
    tbl("flood_status") %>% 
    collect()
  
  for(i in 1:length(places)){
    site_data <- is_flooding %>%
      filter(place == places[i])
    
    flood_status_site <- flood_status_df %>% 
      filter(place == places[i])
    
    any_flooding <- sum(site_data$is_flooding) > 0
    
    if(any_flooding){
      
      site_flooding_data <- site_data %>%
        filter(is_flooding == T) 
      
      if(flood_status_site %>%
         filter(alert_sent == T) %>% 
         nrow() > 0){
        
        site_flooding_data <- site_flooding_data %>% 
          mutate(alert_sent = T)
        
        cat("Flooding, but alert previously sent for: ", places[i],"\n")
        
        dbx::dbxUpsert(conn = con, table = "flood_status", records = site_flooding_data, where_cols = c("place","sensor_ID"), skip_existing = F)
      }
      
      if(flood_status_site %>%
         filter(alert_sent == T) %>% 
         nrow() == 0){
        
        send_new_alert(places[i])
        
        site_flooding_data <- site_flooding_data %>% 
          mutate(alert_sent = T)
        
        dbx::dbxUpsert(conn = con, table = "flood_status", records = site_flooding_data, where_cols = c("place","sensor_ID"), skip_existing = F)
      }
      

    }
    
    if(any_flooding == F){
      
      dbx::dbxUpsert(conn = con, table = "flood_status", records = site_data, where_cols = c("place","sensor_ID"), skip_existing = F)
      cat("No flood alert sent for: ", places[i],"\n")
      
    }
  }
}

#-------------------- Functions to process the data ---------------------------
monitor_function <- function(debug = T) {
  
  new_data <- raw_data %>%
    filter(processed == F,
           pressure > 800) %>%
    collect() %>% 
    mutate(place = tools::toTitleCase(place),
           sensor_ID = toupper(sensor_ID))
  
  if(nrow(new_data) == 0){
    if (debug == T) {
      cat("- No new raw data!", "\n")
    }
  }
  
  if(nrow(new_data) > 0){
    
    # Get all of the unique sensor_IDs so we can match them with survey data. 
    # The survey data contain information about where to pull atmospheric pressure data from
    sensors_w_new_data <- unique(new_data$sensor_ID)
    
    # # Get all of the place names of the new data so we can iterate through
    # place_names <- unique(new_data$place)
    
    # Create a column for the atm pressure, fill it with NAs, remove any duplicated rows
    # Match sensor_IDs with their survey data
    pre_interpolated_data <- new_data %>%
      dplyr::mutate("pressure_mb" = NA_real_) %>%
      group_by(place) %>%
      arrange(date) %>%
      distinct() %>%
      ungroup() %>% 
      match_measurements_to_survey(survey_data = sensor_surveys %>% 
                                     filter(sensor_ID %in% !!sensors_w_new_data) %>% collect()) %>% 
      mutate(notes = notes.x) %>% 
      dplyr::select(-c("notes.x", "notes.y"))
    
    
    interpolated_data <- interpolate_atm_data(data = pre_interpolated_data, debug = debug)
    
    processing_data <- interpolated_data %>%
      transmute(
        place,
        sensor_ID,
        date,
        atm_pressure = pressure_mb,
        sensor_pressure = ifelse(pressure < 500, pressure/10 * 68.9476, pressure),
        voltage,
        notes,
        atm_data_src,
        atm_station_id
      ) %>%
      mutate(
        sensor_water_depth = ((((sensor_pressure - atm_pressure) * 100
        ) / (1020 * 9.81)) * 3.28084),
        qa_qc_flag = F,
        tag = "new_data"
      )
    
    
    # If there is no interpolated_data, return nothing
    if(is.null(processing_data) | nrow(processing_data) == 0){
      return(cat("No data to write \n"))
    }
    
    # If there are interpolated data to be written to the processed database, do so
    dbx::dbxUpsert(
      conn = con,
      table = "sensor_water_depth",
      records = processing_data,
      where_cols = c("place", "sensor_ID", "date"),
      skip_existing = F
    )
    
    dbx::dbxUpsert(
      conn = con,
      table="sensor_data",
      records = new_data %>%
        semi_join(processing_data, by = c("place","sensor_ID","date")) %>%
        mutate(processed = T),
      where_cols = c("place", "sensor_ID", "date"),
      skip_existing = F
      )
    
    if (debug == T) {
      cat("- Wrote to database!", "\n")
    }
  }
}

#-------- Google Auth ---------

# load google authentications
folder_ID <- Sys.getenv("GOOGLE_DRIVE_FOLDER_ID")
sheets_ID <- Sys.getenv("GOOGLE_SHEET_ID")

googledrive::drive_auth(path = Sys.getenv("GOOGLE_JSON_KEY"))
googlesheets4::gs4_auth(token = googledrive::drive_token())

# -------- Monitoring loop -------------
# Run infinite loop that updates atm data and processes it
run = T
flood_tracker = 0

last_time <- processed_data %>%
  slice_max(order_by = date, n=1) %>%
  pull(date)

while(run ==T){
  start_time <- Sys.time()
  print(start_time)
  
  # calculate water level and write data
  monitor_function(debug = T)
  
  if(flood_tracker == 10){
    flood_tracker <- 0
  }
  
  if(flood_tracker == 0){
    # Extract flood events and write to Google Sheets if needed. Will send alerts
    document_flood_events(processed_data_db = processed_data, write_to_sheet = F)
  }
  
  if(flood_tracker > 0){
    # This code only checks for active flooding (via loss of communications). Will send alerts
    document_flood_events(processed_data_db = processed_data, write_to_sheet = F)
  }
  
  flood_tracker <- flood_tracker + 1
  
  # Wait to make the delay 6 minutes
  delay <- difftime(Sys.time(),start_time, units = "secs")
  
  Sys.sleep((60*6) - delay)
}


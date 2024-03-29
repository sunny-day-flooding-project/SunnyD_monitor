FROM rocker/r-ver:latest

# system libraries of general use
## install debian packages
RUN apt-get update -qq && apt-get -y --no-install-recommends install \
    libxml2-dev \
    libpq-dev \
    libssh2-1-dev \
    unixodbc-dev \
    libcurl4-openssl-dev \
    libssl-dev \
    odbc-postgresql 

## update system libraries
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get clean

# install renv & restore packages
RUN install2.r vctrs dplyr dbplyr lubridate RPostgres DBI foreach dbx readr pool httr later googledrive googlesheets4 tidyr stringr jsonlite crul MASS riem xml2

RUN groupadd -r monitor && useradd --no-log-init -r -g monitor monitor

ADD monitor.R /monitor.R
ADD fiman_gauge_key.csv /fiman_gauge_key.csv

EXPOSE 5432

USER monitor

CMD Rscript monitor.R
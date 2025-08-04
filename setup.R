# setup.R

# Load packages
library(tidyverse)
library(brms)
library(mice)
library(tidybayes)
library(posterior)
library(ggplot2)

# Define root directory based on RProject location
root_dir <- here::here()

# Define folders
data_dir <- file.path(root_dir, "01_data")
code_dir <- file.path(root_dir, "02_code")
results_dir <- file.path(root_dir, "03_results")

# Create folders if they don't exist
dir.create(data_dir, showWarnings = FALSE)
dir.create(code_dir, showWarnings = FALSE)
dir.create(results_dir, showWarnings = FALSE)

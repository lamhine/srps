# Load packages
library(tidyverse)
library(brms)
library(mice)
library(tidybayes)
library(posterior)
library(ggplot2)

set.seed(2025)

# -----------------------------
# Simulated Individual-Level Data (Reference Only)
# -----------------------------

# Simulate 1,000 individuals in 16 cities
n_cities <- 16
n <- 1000

city_ids <- paste0("City", 1:n_cities)
race_levels <- c("Black", "White")

sim_data <- tibble(
  id = 1:n,
  city_id = factor(sample(city_ids, size = n, replace = TRUE)),
  race = factor(sample(race_levels, n, TRUE, prob = c(0.4, 0.6)), levels = race_levels),
  age = round(rnorm(n, mean = 65, sd = 10)),
  sex = factor(sample(c("Male", "Female"), n, TRUE)),
  insured = factor(sample(c("Yes", "No"), n, TRUE, prob = c(0.85, 0.15))),
  married = factor(sample(c("Yes", "No"), n, TRUE, prob = c(0.6, 0.4)))
)

# Inject 5% missingness for imputation testing
sim_data <- sim_data %>%
  mutate(
    age     = ifelse(runif(n) < 0.05, NA, age),
    sex     = ifelse(runif(n) < 0.05, NA, as.character(sex)),
    insured = ifelse(runif(n) < 0.05, NA, as.character(insured)),
    married = ifelse(runif(n) < 0.05, NA, as.character(married))
  ) %>%
  mutate(across(c(sex, insured, married), ~factor(.x, levels = c("Yes", "No", "Male", "Female"))[1:2]))

# Simulate a city-level policy index
city_policy <- tibble(
  city_id = city_ids,
  policy_index = round(runif(n_cities, min = 0.3, max = 0.9), 2)
)

sim_data <- sim_data %>%
  left_join(city_policy, by = "city_id") %>%
  mutate(
    race_effect = if_else(race == "Black", -0.6, 0),
    policy_effect = 0.8 * policy_index,
    linpred = -0.5 + race_effect + policy_effect,
    prob_survived = plogis(linpred),
    survived_2y = rbinom(n, size = 1, prob = prob_survived)
  ) %>%
  select(id, city_id, race, age, sex, insured, married, policy_index, survived_2y)

# Ensure factor structure
sim_data <- sim_data %>%
  mutate(across(c(race, sex, insured, married, city_id), factor))

# -----------------------------
# Start here to run analysis with real data
# -----------------------------
# sim_data <- real_data_frame

# -----------------------------
# Multiple Imputation (mice)
# -----------------------------

imp_data <- mice(sim_data, m = 5, seed = 2025, print = FALSE)
completed_list <- complete(imp_data, action = "all")

# Ensure consistent factor structure across imputations
completed_list <- lapply(completed_list, function(df) {
  df %>% mutate(across(c(race, sex, insured, married, city_id), factor))
})

# -----------------------------
# Fit Bayesian Model
# -----------------------------

priors <- c(
  prior(normal(0, 1.5), class = "b"),
  prior(normal(0, 1.5), class = "Intercept"),
  prior(exponential(1), class = "sd", group = "city_id")
)

brms_model <- brm_multiple(
  formula = survived_2y ~ race * policy_index + age + sex + insured + married + (1 | city_id),
  data = completed_list,
  family = bernoulli(),
  prior = priors,
  chains = 2,
  cores = 2,
  iter = 2000,
  warmup = 500,
  seed = 2025,
  control = list(adapt_delta = 0.95)
)

saveRDS(brms_model, "model_black_white_survival.rds")

# -----------------------------
# Predict and Estimate Disparity
# -----------------------------

# Create a base prediction grid (fixed covariates; policy varies)
base_grid <- crossing(
  policy_index = seq(0.3, 0.9, by = 0.01),
  age = 65,
  sex = "Male",
  insured = "Yes",
  married = "Yes"
) %>%
  mutate(.row = row_number())

# Predict for each race separately
pred_black <- add_epred_draws(
  brms_model,
  newdata = base_grid %>% mutate(race = factor("Black", levels = c("Black", "White"))),
  re_formula = NA
) %>% rename(black_pred = .epred)

pred_white <- add_epred_draws(
  brms_model,
  newdata = base_grid %>% mutate(race = factor("White", levels = c("Black", "White"))),
  re_formula = NA
) %>% rename(white_pred = .epred)

# Combine predictions and compute racial disparity
pred_draws_wide <- left_join(
  pred_black %>% select(.draw, .row, policy_index, black_pred),
  pred_white %>% select(.draw, .row, policy_index, white_pred),
  by = c(".draw", ".row", "policy_index")
) %>%
  mutate(black_minus_white = black_pred - white_pred)

# Summarize across posterior draws
disparity_summary <- pred_draws_wide %>%
  group_by(policy_index) %>%
  summarise(
    mean_diff = mean(black_minus_white),
    lower = quantile(black_minus_white, 0.025),
    upper = quantile(black_minus_white, 0.975),
    .groups = "drop"
  )

saveRDS(disparity_summary, "disparity_black_white_over_policy.rds")

# -----------------------------
# Visualize Disparity
# -----------------------------

ggplot(disparity_summary, aes(x = policy_index, y = mean_diff)) +
  geom_ribbon(aes(ymin = lower, ymax = upper), fill = "gray80", alpha = 0.5) +
  geom_line(color = "blue", size = 1) +
  geom_hline(yintercept = 0, linetype = "dashed") +
  labs(
    title = "Posterior Mean Disparity (Black – White) by Policy Index",
    x = "Policy Index",
    y = "Difference in Predicted 2-Year Survival"
  ) +
  theme_minimal()

ggsave("plot_black_white_disparity.png", width = 7, height = 5)

# -----------------------------
# Save Posterior Fixed Effects
# -----------------------------

fixef(brms_model) %>%
  as_tibble(rownames = "term") %>%
  rename(est = Estimate, lci = Q2.5, uci = Q97.5) %>%
  write_csv("table2_posterior_effects.csv")
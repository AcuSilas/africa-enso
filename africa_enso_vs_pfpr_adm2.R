#####  Africa: El Niño rainfall and temperature forecast vs PfPR by ADM2  #####

cli::cli_h1(
  "Africa: El Niño rainfall and temperature anomaly forecast vs PfPR by ADM2"
)

## ---------------------------------------------------------------------------##
# Setup and parameters ---------------------------------------------------------
## ---------------------------------------------------------------------------##

# inputs : C3S multi-system seasonal forecast anomalies of rainfall and 2 m
#          temperature (CDS API), MAP PfPR 2-10 raster (malariaAtlas),
#          WorldPop R2025A 1 km population (per country, mosaicked),
#          geoBoundaries CGAZ ADM2
# outputs: GeoTIFFs, ADM2 summary table (csv), three maps (png)
# setup  : ecmwfr::wf_set_key(key = "<your CDS key>") once, and accept the
#          licence on the CDS dataset page before running


# forecast: lead 1 is the initialisation month, so 2:6 = Nov 2026 to Mar 2027
init_year <- "2026"

init_month <- "10"

lead_months <- 2:6

# CDS area order is N, W, S, E; wide enough to take in Cabo Verde, the
# Seychelles and Mauritius
africa_area <- c(38, -26, -36, 60)

# PfPR
dataset_id <- "Malaria__202608_Global_Pf_Parasite_Rate"

pfpr_year <- 2025

# ADM2 units with less than this share of their population inside MAP's Pf
# transmission limits get no PfPR value, so a few border pixels cannot stand
# in for a whole district (e.g. Algerian wilayas touching the Mali border).
# 0.25 still gives a value to highland districts with substantial lowland
# transmission, such as Lubero and Masisi (DRC) or Arsi (Ethiopia)
min_pfpr_coverage <- 0.25

# paths
out_dir <- here::here("outputs", "enso_pfpr")

bnd_dir <- file.path(out_dir, "boundaries")

c3s_dir <- file.path(out_dir, "c3s")

pfpr_dir <- file.path(out_dir, "pfpr")

pop_dir <- file.path(out_dir, "worldpop")

for (d in c(bnd_dir, c3s_dir, pfpr_dir, pop_dir)) {
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
}

# large downloads (CGAZ boundaries, WorldPop, MAP) can exceed the default
# 60 s timeout
options(timeout = 3600)

# preferred system per centre. centres upgrade periodically; if the CDS no
# longer offers a system for the initialisation date, the newest one it does
# offer is used instead and a message says so
c3s_systems <- c(
  ecmwf = "51",
  ukmo = "610",
  meteo_france = "9",
  dwd = "22",
  cmcc = "4",
  ncep = "2",
  jma = "4",
  eccc = "5",
  bom = "2"
)

# how long this run waits on the CDS queue. jobs still queued are saved and
# collected by the next run, not resubmitted
c3s_timeout_hours <- 3

## ---------------------------------------------------------------------------##
# ADM2 boundaries --------------------------------------------------------------
## ---------------------------------------------------------------------------##

cli::cli_h2("ADM2 boundaries (geoBoundaries CGAZ)")

# CGAZ is geoBoundaries' seamless global composite: neighbouring countries
# share one border line, so units neither overlap nor leave slivers (the
# per-country gbOpen files overlapped by ~85,000 km2 and left ~33,000 km2 of
# gaps across Africa). countries without ADM2 (Libya, Mauritius) carry ADM1.
# the Africa subset is cached so re-runs use the same boundaries; delete the
# file to refresh
bnd_file <- file.path(bnd_dir, "adm2_africa_cgaz.gpkg")

africa_iso3 <- countrycode::codelist |>
  dplyr::filter(continent == "Africa", !is.na(iso3c)) |>
  dplyr::pull(iso3c)

# CGAZ files disputed areas as separate units with numeric codes; these are
# the African ones (adm0 "DISP", except Western Sahara which keeps ESH)
africa_disputed <- c("Abyei", "Koualou", "Western Sahara")

# geometry work below uses GEOS on the plane, which tolerates polygons that
# self-intersect on the sphere (s2)
use_s2 <- sf::sf_use_s2()

suppressMessages(sf::sf_use_s2(FALSE))

if (file.exists(bnd_file)) {
  adm2 <- sf::st_read(bnd_file, quiet = TRUE)

  cli::cli_alert_info("Using cached boundaries ({basename(bnd_file)})")
} else {
  # the global file is ~240 MB; only the Africa subset is kept
  cgaz_file <- tempfile(fileext = ".gpkg")

  utils::download.file(
    paste0(
      "https://github.com/wmgeolab/geoBoundaries/raw/main/releaseData/",
      "CGAZ/geoBoundariesCGAZ_ADM2.gpkg"
    ),
    cgaz_file,
    mode = "wb",
    quiet = TRUE
  )

  adm2 <- sf::st_read(
    cgaz_file,
    query = paste0(
      "SELECT * FROM globalADM2 WHERE shapeGroup IN (",
      paste0("'", africa_iso3, "'", collapse = ","),
      ") OR shapeName IN (",
      paste0("'", africa_disputed, "'", collapse = ","),
      ")"
    ),
    quiet = TRUE
  ) |>
    sf::st_set_crs(4326) |>
    suppressWarnings() |>
    dplyr::transmute(
      adm0 = dplyr::if_else(shapeGroup %in% africa_iso3, shapeGroup, "DISP"),
      adm2 = shapeName,
      adm2_id = shapeID,
      adm_level = shapeType
    )

  sf::st_write(adm2, bnd_file, delete_dsn = TRUE, quiet = TRUE)

  unlink(cgaz_file)
}

adm2 <- sf::st_make_valid(adm2)

# adm2 names repeat across and within countries, so adm2_id is the true key
adm_keys <- c("adm0", "adm2", "adm2_id", "adm_level")

# full-detail polygons are used for extraction; the maps use a ~1 km
# simplification, which is far below one pixel at Africa scale. outlines
# are dissolved from the full-detail units (which share edges exactly) and
# simplified afterwards; dissolving simplified units leaves stray edges
adm2_map <- adm2 |>
  sf::st_simplify(preserveTopology = TRUE, dTolerance = 0.01) |>
  suppressWarnings()

adm0_outline <- adm2 |>
  dplyr::group_by(adm0) |>
  dplyr::summarise(.groups = "drop") |>
  sf::st_simplify(preserveTopology = TRUE, dTolerance = 0.01) |>
  suppressMessages() |>
  suppressWarnings()

suppressMessages(sf::sf_use_s2(use_s2))

cli::cli_alert_success(
  "{nrow(adm2)} units across {length(unique(adm2$adm0))} countries
  ({sum(adm2$adm_level == 'ADM1')} of them ADM1)"
)

## ---------------------------------------------------------------------------##
# Download MAP PfPR raster -----------------------------------------------------
## ---------------------------------------------------------------------------##

cli::cli_h2("MAP PfPR 2-10")

pfpr_file <- file.path(pfpr_dir, paste0("pfpr_africa_", pfpr_year, ".tif"))

if (file.exists(pfpr_file)) {
  cli::cli_alert_info("PfPR {pfpr_year} raster already downloaded")
} else {
  for (attempt in 1:3) {
    res <- try(
      malariaAtlas::getRaster(
        dataset_id = dataset_id,
        year = pfpr_year,
        extent = matrix(c(-20, -36, 55, 38), nrow = 2)
      ),
      silent = TRUE
    )

    if (!inherits(res, "try-error")) break

    cli::cli_alert_warning(
      "{pfpr_year}: attempt {attempt} failed -
      {conditionMessage(attr(res, 'condition'))}"
    )

    Sys.sleep(5)
  }

  if (inherits(res, "try-error")) {
    cli::cli_abort("Could not download {dataset_id} for {pfpr_year}")
  }

  terra::writeRaster(res, pfpr_file, overwrite = TRUE)

  cli::cli_alert_success("Downloaded PfPR {pfpr_year}")
}

# layer 1 = central estimate, layers 3 and 4 = lower and upper bounds
pfpr <- terra::rast(pfpr_file)

## ---------------------------------------------------------------------------##
# Download WorldPop population -------------------------------------------------
## ---------------------------------------------------------------------------##

cli::cli_h2("WorldPop R2025A 1 km population")

# WorldPop publishes R2025A per country; the 1 km UN-adjusted constrained
# files are small, so download each African country and mosaic them
get_worldpop <- function(iso3) {
  file_name <- paste0(
    tolower(iso3), "_pop_", pfpr_year, "_CN_1km_R2025A_UA_v1.tif"
  )

  dest <- file.path(pop_dir, file_name)

  if (file.exists(dest)) return(dest)

  url <- paste0(
    "https://data.worldpop.org/GIS/Population/Global_2015_2030/R2025A/",
    pfpr_year, "/", iso3, "/v1/1km_ua/constrained/", file_name
  )

  # download under a temporary name so an interrupted download never leaves
  # a truncated file that later runs would treat as complete
  part <- paste0(dest, ".part")

  ok <- tryCatch(
    {
      utils::download.file(url, part, mode = "wb", quiet = TRUE)
      TRUE
    },
    error = function(e) FALSE,
    warning = function(w) FALSE
  )

  if (!ok) {
    unlink(part)
    cli::cli_alert_warning("{iso3}: no WorldPop {pfpr_year} file, skipped")
    return(NULL)
  }

  file.rename(part, dest)

  dest
}

# disputed units have no WorldPop file of their own; they get population
# only where a neighbouring country's raster covers them
pop_files <- lapply(intersect(unique(adm2$adm0), africa_iso3), get_worldpop) |>
  unlist()

pop_mosaic_file <- file.path(
  pop_dir,
  paste0("pop_africa_", pfpr_year, ".tif")
)

# rebuild whenever a country file is newer than the mosaic
rebuild_mosaic <- !file.exists(pop_mosaic_file) ||
  any(file.mtime(pop_files) > file.mtime(pop_mosaic_file))

if (rebuild_mosaic) {
  africa_ext <- terra::ext(
    africa_area[2], africa_area[4], africa_area[3], africa_area[1]
  )

  # some country files (e.g. Eritrea) are stored with a global extent, so
  # crop each to Africa before merging
  lapply(pop_files, function(f) terra::crop(terra::rast(f), africa_ext)) |>
    terra::sprc() |>
    terra::merge(filename = pop_mosaic_file, overwrite = TRUE)

  cli::cli_alert_success("Mosaicked {length(pop_files)} countries")
}

pop_1km <- terra::rast(pop_mosaic_file)[[1]]

# WorldPop cells are people counts, so they are summed onto the coarser
# PfPR grid rather than interpolated; this keeps totals and weights right
pop <- terra::project(pop_1km, pfpr, method = "sum")

pop_total <- c(
  terra::global(pop_1km, "sum", na.rm = TRUE)[[1]],
  terra::global(pop, "sum", na.rm = TRUE)[[1]]
)

cli::cli_alert_info(
  "Population on 1 km grid {round(pop_total[1] / 1e6)}M, on PfPR grid
  {round(pop_total[2] / 1e6)}M"
)

## ---------------------------------------------------------------------------##
# Population-weighted PfPR by ADM2 ---------------------------------------------
## ---------------------------------------------------------------------------##

cli::cli_h2("Population-weighted PfPR by ADM2")

# same statistics as batch_extract_weighted_stats() with stat_type = "median"

# weights are people x pixel share inside the polygon; weightedMedian()
# interpolates between pixel values where the 50% point falls between them
weighted_median_fun <- function(values, coverage_fractions, weights) {
  total_weights <- weights * coverage_fractions

  valid_idx <- !is.na(values) &
    !is.na(total_weights) &
    total_weights > 0 &
    coverage_fractions > 0

  if (sum(valid_idx) == 0) return(NA_real_)

  matrixStats::weightedMedian(
    values[valid_idx],
    w = total_weights[valid_idx],
    na.rm = TRUE
  )
}

# share of the ADM2 population living in pixels MAP gives a PfPR value to
# (MAP leaves pixels outside the Pf transmission limits empty)
coverage_fun <- function(values, coverage_fractions, weights) {
  total_weights <- weights * coverage_fractions

  total_weights[is.na(total_weights)] <- 0

  if (sum(total_weights) == 0) return(NA_real_)

  sum(total_weights[!is.na(values)]) / sum(total_weights)
}

summarise_pfpr_layer <- function(layer, suffix) {
  value_rast <- pfpr[[layer]]

  # missing population counts as zero weight (default_weight = 0)
  weighted <- suppressWarnings(
    exactextractr::exact_extract(
      value_rast,
      adm2,
      fun = weighted_median_fun,
      weights = pop,
      default_weight = 0,
      progress = FALSE
    )
  )

  # exactextractr's median weights pixels by coverage fraction only
  unweighted <- suppressWarnings(
    exactextractr::exact_extract(
      value_rast,
      adm2,
      fun = "median",
      progress = FALSE
    )
  )

  stats <- data.frame(weighted, unweighted)

  names(stats) <- paste0(c("weighted_", "unweighted_"), suffix)

  stats
}

# totals come from the 1 km raster, so small units are not distorted by the
# coarser PfPR grid
adm2_pop <- suppressWarnings(
  exactextractr::exact_extract(
    pop_1km,
    adm2,
    fun = "sum",
    progress = FALSE
  )
) |>
  round()

pfpr_coverage <- suppressWarnings(
  exactextractr::exact_extract(
    pfpr[[1]],
    adm2,
    fun = coverage_fun,
    weights = pop,
    default_weight = 0,
    progress = FALSE
  )
)

pfpr_adm2 <- adm2 |>
  sf::st_drop_geometry() |>
  dplyr::bind_cols(
    summarise_pfpr_layer(1, "median"),
    summarise_pfpr_layer(3, "lower"),
    summarise_pfpr_layer(4, "upper")
  ) |>
  dplyr::mutate(
    pop_sum = adm2_pop,
    pfpr_pop_coverage = round(pfpr_coverage, 3),
    in_limits = !is.na(pfpr_coverage) & pfpr_coverage >= min_pfpr_coverage
  ) |>
  dplyr::transmute(
    dplyr::across(dplyr::all_of(adm_keys)),
    pop_sum,
    pfpr_pop_coverage,
    pfpr_pct = dplyr::if_else(in_limits, 100 * weighted_median, NA_real_),
    pfpr_lower_pct = dplyr::if_else(in_limits, 100 * weighted_lower, NA_real_),
    pfpr_upper_pct = dplyr::if_else(in_limits, 100 * weighted_upper, NA_real_),
    pfpr_unweighted_pct = dplyr::if_else(
      in_limits,
      100 * unweighted_median,
      NA_real_
    )
  )

n_missing <- sum(is.na(pfpr_adm2$pfpr_pct))

if (n_missing > 0) {
  cli::cli_alert_info(
    "{n_missing} unit{?s} have no PfPR estimate (mostly outside MAP's Pf
    transmission limits, or no population)"
  )
}

## ---------------------------------------------------------------------------##
# PfPR map ---------------------------------------------------------------------
## ---------------------------------------------------------------------------##

cli::cli_h2("PfPR map")

map_theme <- ggplot2::theme_void(base_size = 11) +
  ggplot2::theme(
    legend.position = "bottom",
    legend.key.width = ggplot2::unit(1.6, "cm"),
    plot.title = ggplot2::element_text(face = "bold"),
    plot.subtitle = ggplot2::element_text(margin = ggplot2::margin(b = 8)),
    strip.text = ggplot2::element_text(
      face = "bold",
      margin = ggplot2::margin(b = 4)
    ),
    plot.margin = ggplot2::margin(10, 10, 10, 10)
  )

# ggsave() only warns when it can't write the file (e.g. it is open in an
# image viewer), so check the file was actually updated
save_map <- function(p, file, width, height) {
  started <- Sys.time()

  ggplot2::ggsave(
    file.path(out_dir, file),
    p,
    width = width,
    height = height,
    dpi = 300,
    bg = "white"
  )

  if (file.mtime(file.path(out_dir, file)) < started - 1) {
    cli::cli_alert_danger(
      "Could not write {file}; close it if it is open in another program and
      re-run"
    )
  } else {
    cli::cli_alert_success("Saved {file}")
  }
}

country_borders <- ggplot2::geom_sf(
  data = adm0_outline,
  fill = NA,
  colour = "grey35",
  linewidth = 0.15
)

pfpr_labels <- c(
  "<1", "1-5", "5-10", "10-25", "25-50", "≥50"
)

outside_label <- "Outside Pf limits /\nno estimate"

pfpr_fill <- c(
  stats::setNames(scales::brewer_pal(palette = "YlOrRd")(6), pfpr_labels),
  stats::setNames("grey85", outside_label)
)

# NA becomes its own legend class, so grey is explained on the map
p_pfpr <- adm2_map |>
  dplyr::left_join(pfpr_adm2, by = adm_keys) |>
  dplyr::mutate(
    pfpr_class = as.character(cut(
      pfpr_pct,
      breaks = c(0, 1, 5, 10, 25, 50, 100),
      labels = pfpr_labels,
      right = FALSE,
      include.lowest = TRUE
    )),
    pfpr_class = factor(
      dplyr::coalesce(pfpr_class, outside_label),
      levels = names(pfpr_fill)
    )
  ) |>
  ggplot2::ggplot() +
  ggplot2::geom_sf(
    ggplot2::aes(fill = pfpr_class),
    colour = NA
  ) +
  country_borders +
  ggplot2::scale_fill_manual(
    values = pfpr_fill,
    drop = FALSE,
    name = expression(italic(Pf) * "PR"[2 - 10] * " (%)"),
    guide = ggplot2::guide_legend(nrow = 1, label.position = "bottom")
  ) +
  ggplot2::labs(
    title = expression(
      "MAP-modeled " * italic(Pf) * "PR"[2 - 10] * " by ADM2"
    ),
    subtitle = paste0(
      "Population-weighted median, ",
      pfpr_year
    )
  ) +
  map_theme +
  ggplot2::theme(legend.key.width = ggplot2::unit(1, "cm"))

save_map(p_pfpr, "map_pfpr_adm2.png", width = 8, height = 8.5)

## ---------------------------------------------------------------------------##
# C3S multi-system seasonal forecast anomalies ---------------------------------
## ---------------------------------------------------------------------------##

cli::cli_h2("C3S seasonal forecast anomalies")

# both are ensemble-mean anomalies against each model's own hindcast
# climatology. rainfall is the main spatial expression of El Niño over
# Africa; temperature matters most where transmission is temperature-limited
# (highlands, southern fringe)
c3s_vars <- c(
  rain = "total_precipitation_anomalous_rate_of_accumulation",
  temp = "2m_temperature_anomaly"
)

c3s_prefix <- c(rain = "prate_anom", temp = "t2m_anom")

init_tag <- paste0(init_year, init_month)

cds_key <- ecmwfr::wf_get_key(user = "ecmwfr")

# the CDS publishes which systems exist for each initialisation date; check
# against it so a system upgrade doesn't silently drop a centre
cds_constraints <- tryCatch(
  jsonlite::fromJSON(
    paste0(
      "https://cds.climate.copernicus.eu/api/catalogue/v1/collections/",
      "seasonal-postprocessed-single-levels/constraints.json"
    ),
    simplifyVector = FALSE
  ),
  error = function(e) NULL
)

# systems a centre offers for every variable at this initialisation date
offered_systems <- function(centre) {
  per_var <- lapply(c3s_vars, function(variable) {
    blocks <- Filter(
      function(b) {
        centre %in% unlist(b$originating_centre) &&
          init_year %in% unlist(b$year) &&
          init_month %in% unlist(b$month) &&
          "ensemble_mean" %in% unlist(b$product_type) &&
          variable %in% unlist(b$variable) &&
          all(as.character(lead_months) %in% unlist(b$leadtime_month))
      },
      cds_constraints
    )

    unique(unlist(lapply(blocks, `[[`, "system")))
  })

  Reduce(intersect, per_var)
}

if (is.null(cds_constraints)) {
  cli::cli_alert_warning(
    "Could not read the CDS constraints; using c3s_systems as set"
  )
} else {
  for (centre in names(c3s_systems)) {
    offered <- offered_systems(centre)

    if (length(offered) == 0) {
      cli::cli_alert_warning(
        "{centre}: no {init_tag} forecast on the CDS yet, skipped"
      )

      c3s_systems <- c3s_systems[names(c3s_systems) != centre]
    } else if (!c3s_systems[[centre]] %in% offered) {
      newest <- as.character(max(as.integer(offered)))

      cli::cli_alert_info(
        "{centre}: system {c3s_systems[[centre]]} not offered for
        {init_tag}, using {newest}"
      )

      c3s_systems[[centre]] <- newest
    }
  }
}

# file names carry the variable, system and init date, so a new forecast or
# system never reuses an old file
c3s_path <- function(var, centre) {
  file.path(
    c3s_dir,
    paste0(
      c3s_prefix[[var]], "_", centre, "_s", c3s_systems[[centre]], "_",
      init_tag, ".nc"
    )
  )
}

# one layer per lead month in lead order, or NULL if the file is missing or
# incomplete
read_c3s <- function(f) {
  if (!file.exists(f)) return(NULL)

  r <- tryCatch(terra::rast(f), error = function(e) NULL)

  if (is.null(r)) return(NULL)

  leads <- suppressWarnings(
    as.integer(sub(".*forecastMonth=(\\d+).*", "\\1", names(r)))
  )

  if (terra::nlyr(r) != length(lead_months) || !setequal(leads, lead_months)) {
    return(NULL)
  }

  r[[order(leads)]]
}

# job status: "accepted", "running", "successful", "failed", "gone" (deleted
# or expired on the CDS), or NA if the API didn't answer this time
cds_status <- function(job_url) {
  res <- tryCatch(
    httr::GET(
      job_url,
      httr::add_headers(`PRIVATE-TOKEN` = cds_key),
      httr::timeout(120)
    ),
    error = function(e) NULL
  )

  if (is.null(res)) return(NA_character_)

  if (httr::status_code(res) == 404) return("gone")

  if (httr::http_error(res)) return(NA_character_)

  status <- httr::content(res, as = "parsed")$status

  if (is.null(status)) NA_character_ else status
}

# downloads a finished job's file to dest via a temporary name; the CDS
# sometimes wraps netcdf output in a zip
cds_fetch <- function(job_url, dest) {
  res <- tryCatch(
    httr::GET(
      paste0(job_url, "/results"),
      httr::add_headers(`PRIVATE-TOKEN` = cds_key),
      httr::timeout(120)
    ),
    error = function(e) NULL
  )

  if (is.null(res) || httr::http_error(res)) return(FALSE)

  href <- httr::content(res, as = "parsed")$asset$value$href

  part <- paste0(dest, ".part")

  ok <- tryCatch(
    {
      utils::download.file(href, part, mode = "wb", quiet = TRUE)
      TRUE
    },
    error = function(e) FALSE,
    warning = function(w) FALSE
  )

  if (!ok) {
    unlink(part)
    return(FALSE)
  }

  if (grepl("\\.zip$", href)) {
    nc <- utils::unzip(part, exdir = tempfile())

    nc <- nc[grepl("\\.nc$", nc)]

    unlink(part)

    if (length(nc) != 1) return(FALSE)

    return(file.copy(nc, dest, overwrite = TRUE))
  }

  file.rename(part, dest)
}

# every variable x centre that has no valid file yet
todo <- expand.grid(
  var = names(c3s_vars),
  centre = names(c3s_systems),
  stringsAsFactors = FALSE
)

todo <- todo[
  vapply(
    seq_len(nrow(todo)),
    function(i) is.null(read_c3s(c3s_path(todo$var[i], todo$centre[i]))),
    logical(1)
  ),
]

# jobs submitted by earlier runs that are still worth collecting
pending_file <- file.path(c3s_dir, paste0("pending_jobs_", init_tag, ".csv"))

pending <- if (file.exists(pending_file)) {
  readr::read_csv(pending_file, col_types = readr::cols(.default = "c"))
} else {
  data.frame(
    var = character(),
    centre = character(),
    system = character(),
    job_url = character()
  )
}

# files written before temperature was added only held rainfall jobs
if (!"var" %in% names(pending)) pending$var <- "rain"

pending <- pending |>
  dplyr::semi_join(todo, by = c("var", "centre")) |>
  dplyr::filter(system == c3s_systems[centre]) |>
  dplyr::select(var, centre, system, job_url)

if (nrow(pending) > 0) {
  cli::cli_alert_info(
    "Collecting {nrow(pending)} job{?s} queued by an earlier run:
    {paste(pending$var, pending$centre)}"
  )
}

# submit the rest at once so they queue on the CDS together, saving each
# job's address straight away
to_submit <- dplyr::anti_join(todo, pending, by = c("var", "centre"))

for (i in seq_len(nrow(to_submit))) {
  var <- to_submit$var[i]

  centre <- to_submit$centre[i]

  unlink(c3s_path(var, centre))

  req <- list(
    dataset_short_name = "seasonal-postprocessed-single-levels",
    originating_centre = centre,
    system = c3s_systems[[centre]],
    variable = c3s_vars[[var]],
    product_type = "ensemble_mean",
    year = init_year,
    month = init_month,
    leadtime_month = as.character(lead_months),
    area = africa_area,
    data_format = "netcdf",
    target = basename(c3s_path(var, centre))
  )

  job <- tryCatch(
    suppressWarnings(
      ecmwfr::wf_request(
        req,
        path = c3s_dir,
        transfer = FALSE,
        verbose = FALSE
      )
    ),
    error = function(e) {
      cli::cli_alert_warning(
        "{var} {centre}: request rejected ({conditionMessage(e)})"
      )

      NULL
    }
  )

  if (is.null(job)) next

  pending <- dplyr::bind_rows(
    pending,
    data.frame(
      var = var,
      centre = centre,
      system = c3s_systems[[centre]],
      job_url = job$get_url()
    )
  )

  readr::write_csv(pending, pending_file)
}

# poll every job until it is downloaded, has failed, or this run times out
deadline <- Sys.time() + c3s_timeout_hours * 3600

n_polls <- 0

while (nrow(pending) > 0) {
  if (n_polls %% 15 == 0) {
    cli::cli_alert_info(
      "{format(Sys.time(), '%H:%M')} waiting on the CDS queue for
      {nrow(pending)} job{?s}: {paste(pending$var, pending$centre)}"
    )
  }

  for (i in rev(seq_len(nrow(pending)))) {
    job_name <- paste(pending$var[i], pending$centre[i])

    status <- cds_status(pending$job_url[i])

    if (identical(status, "successful")) {
      dest <- c3s_path(pending$var[i], pending$centre[i])

      if (cds_fetch(pending$job_url[i], dest)) {
        cli::cli_alert_success("{job_name}: downloaded")

        pending <- pending[-i, ]
      }
    } else if (status %in% c("failed", "dismissed", "gone")) {
      cli::cli_alert_warning(
        "{job_name}: CDS job {status}; it will be resubmitted next run"
      )

      pending <- pending[-i, ]
    }
  }

  if (nrow(pending) == 0) {
    unlink(pending_file)
    break
  }

  readr::write_csv(pending, pending_file)

  if (Sys.time() > deadline) {
    cli::cli_alert_warning(
      "Still queued after {c3s_timeout_hours} h:
      {paste(pending$var, pending$centre)}. Re-run later to collect them"
    )

    break
  }

  n_polls <- n_polls + 1

  Sys.sleep(60)
}

# month labels and column suffixes come from month.abb, so they don't
# depend on the locale R runs in
target_dates <- seq(
  as.Date(paste(init_year, init_month, "01", sep = "-")),
  by = "month",
  length.out = max(lead_months)
)[lead_months]

target_months <- paste(
  month.abb[as.integer(format(target_dates, "%m"))],
  format(target_dates, "%Y")
)

month_cols <- tolower(sub(" ", "_", target_months))

season_label <- paste(
  target_months[1],
  "to",
  target_months[length(target_months)],
  "mean"
)

# equal-weight multi-model mean of one variable and the centres in it, or
# NULL if no centre has downloaded yet
build_mme <- function(var) {
  stacks <- lapply(names(c3s_systems), function(centre) {
    read_c3s(c3s_path(var, centre))
  })

  names(stacks) <- names(c3s_systems)

  stacks <- Filter(Negate(is.null), stacks)

  if (length(stacks) == 0) return(NULL)

  if (length(stacks) < length(c3s_systems)) {
    cli::cli_alert_warning(
      "{var}: missing or incomplete: {setdiff(names(c3s_systems),
      names(stacks))}"
    )
  }

  cli::cli_alert_info(
    "{var}: {length(stacks)} of {length(c3s_systems)} centres in the
    multi-model mean"
  )

  # all centres are on a 1 degree grid, but align defensively
  stacks <- lapply(stacks, terra::resample, y = stacks[[1]])

  mme <- Reduce(`+`, stacks) / length(stacks)

  names(mme) <- target_months

  list(mme = mme, centres = names(stacks))
}

rain <- build_mme("rain")

if (is.null(rain)) {
  cli::cli_abort(
    "No C3S rainfall forecast downloaded yet. The PfPR map is saved; re-run
    later to collect the queued jobs and finish the forecast outputs"
  )
}

# m/s to mm/day
rain$mme <- rain$mme * 86400 * 1000

terra::writeRaster(
  rain$mme,
  file.path(out_dir, "c3s_mme_prate_anom_mm_day.tif"),
  overwrite = TRUE
)

# anomalies in K, which are the same size in degrees C
temp <- build_mme("temp")

if (is.null(temp)) {
  cli::cli_alert_warning(
    "No C3S temperature forecast downloaded yet; its CSV columns are left
    empty and its map is skipped. Re-run later to add them"
  )
} else {
  terra::writeRaster(
    temp$mme,
    file.path(out_dir, "c3s_mme_t2m_anom_c.tif"),
    overwrite = TRUE
  )
}

# both are physical fields, so each unit gets an area-weighted mean, per
# month and for the season (the mean of the months)
summarise_anom <- function(mme, prefix) {
  anom <- exactextractr::exact_extract(
    c(mme, terra::app(mme, mean)),
    adm2,
    "mean",
    progress = FALSE
  )

  names(anom) <- paste0(prefix, "_", c(month_cols, "season"))

  anom
}

rain_adm2 <- summarise_anom(rain$mme, "rain_anom")

temp_adm2 <- if (is.null(temp)) {
  as.data.frame(
    matrix(
      NA_real_,
      nrow = nrow(adm2),
      ncol = length(month_cols) + 1,
      dimnames = list(NULL, paste0("temp_anom_", c(month_cols, "season")))
    )
  )
} else {
  summarise_anom(temp$mme, "temp_anom")
}

## ---------------------------------------------------------------------------##
# Combine and save -------------------------------------------------------------
## ---------------------------------------------------------------------------##

adm2_tbl <- adm2 |>
  sf::st_drop_geometry() |>
  dplyr::bind_cols(rain_adm2, temp_adm2) |>
  dplyr::left_join(pfpr_adm2, by = adm_keys)

readr::write_csv(
  adm2_tbl,
  file.path(out_dir, "adm2_enso_anom_vs_pfpr.csv")
)

## ---------------------------------------------------------------------------##
# Forecast anomaly maps --------------------------------------------------------
## ---------------------------------------------------------------------------##

cli::cli_h2("Forecast anomaly maps")

# one panel per forecast month plus the season mean, on a 3-column grid
anomaly_map <- function(anom_tbl, prefix, fill_scale, title, subtitle,
                        caption, file) {
  anom_long <- adm2_map |>
    dplyr::select(adm2_id) |>
    dplyr::bind_cols(anom_tbl) |>
    tidyr::pivot_longer(
      cols = dplyr::starts_with(prefix),
      names_to = "month",
      values_to = "anom"
    ) |>
    dplyr::mutate(
      month = factor(
        month,
        levels = paste0(prefix, "_", c(month_cols, "season")),
        labels = c(target_months, season_label)
      )
    )

  p <- ggplot2::ggplot(anom_long) +
    ggplot2::geom_sf(
      ggplot2::aes(fill = anom),
      colour = NA
    ) +
    country_borders +
    ggplot2::facet_wrap(~month, ncol = 3) +
    fill_scale +
    ggplot2::labs(title = title, subtitle = subtitle, caption = caption) +
    map_theme

  save_map(p, file, width = 12, height = 9.5)
}

# diverging at zero: brown = drier than normal, teal = wetter than normal
anomaly_map(
  rain_adm2,
  prefix = "rain_anom",
  fill_scale = ggplot2::scale_fill_fermenter(
    palette = "BrBG",
    direction = 1,
    breaks = c(-2, -1, -0.5, -0.2, 0.2, 0.5, 1, 2),
    limits = c(-3, 3),
    oob = scales::squish,
    na.value = "grey85",
    name = "Rainfall anomaly (mm/day)"
  ),
  title = "Forecast rainfall anomaly during the 2026-27 El Niño",
  subtitle = paste0(
    "C3S multi-system ensemble mean of ",
    length(rain$centres),
    " centres"
  ),
  caption = "Brown = drier than normal, teal = wetter.",
  file = "map_enso_rain_anom_adm2.png"
)

# white around zero, blue = cooler than normal, red = warmer. anomalies
# against the 1993-2016 hindcast climate include the warming since then, so
# most classes are on the warm side (Oct 2026 init: 0 to 2.9 degrees C).
# each class gets one RdBu colour, placed at the class midpoint
temp_breaks <- c(-1, -0.5, 0.5, 1, 1.5, 2, 2.5)

temp_limits <- c(-1.5, 3)

temp_class_mid <- c(-1.25, -0.75, 0, 0.75, 1.25, 1.75, 2.25, 2.75)

if (!is.null(temp)) {
  anomaly_map(
    temp_adm2,
    prefix = "temp_anom",
    fill_scale = ggplot2::scale_fill_stepsn(
      colours = c(
        "#4393C3", "#92C5DE", "#F7F7F7", "#FDDBC7",
        "#F4A582", "#D6604D", "#B2182B", "#67001F"
      ),
      values = scales::rescale(temp_class_mid, from = temp_limits),
      breaks = temp_breaks,
      limits = temp_limits,
      oob = scales::squish,
      na.value = "grey85",
      name = "Temperature anomaly (°C)"
    ),
    title = paste(
      "Forecast near-surface temperature anomaly during the 2026-27 El Niño"
    ),
    subtitle = paste0(
      "C3S multi-system ensemble mean of ",
      length(temp$centres),
      " centres"
    ),
    caption = "Red = warmer than normal, blue = cooler.",
    file = "map_enso_temp_anom_adm2.png"
  )
}

## ---------------------------------------------------------------------------##
# Finish -----------------------------------------------------------------------
## ---------------------------------------------------------------------------##

invisible(gc())

cli::cli_rule(
  left = "Africa ENSO vs PfPR complete",
  right = format(Sys.time(), "%Y-%m-%d %H:%M:%S")
)

# El Niño rainfall and temperature forecasts vs malaria risk across Africa (ADM2)

This analysis puts three layers side by side for every second-level administrative unit (ADM2) in Africa:

1. **Forecast rainfall anomaly**: how much wetter or drier than normal each of the coming months is expected to be during the 2026–27 El Niño.
2. **Forecast temperature anomaly**: how much warmer or cooler than normal the near-surface air is expected to be over the same months.
3. **Current malaria burden**: the *Plasmodium falciparum* parasite rate in children aged 2–10 (PfPR 2–10).

The aim is to show where El Niño is expected to shift rainfall and temperature in places that already carry a high malaria burden. Those districts can then be flagged for closer monitoring, preparedness or response planning.

Everything runs from a single, self-contained script, `africa_enso_vs_pfpr_adm2.R`. 

## Why forecast anomalies and not "El Niño intensity"

El Niño is defined by sea surface temperatures in the equatorial Pacific (the Niño 3.4 region), so its intensity is one number for the whole event. What varies from place to place is the effect El Niño has on local climate. This analysis therefore maps forecast anomalies of the two climate variables that matter most for malaria, as the spatial expression of El Niño over Africa:

- **Rainfall** creates and removes mosquito breeding sites.
- **Temperature** controls how fast the parasite develops inside the mosquito and how long mosquitoes survive.

The forecasts come from dynamical seasonal models. These simulate the El Niño together with everything else that drives African climate, including the Indian Ocean Dipole, which makes them more reliable than projecting the Niño 3.4 index onto historical relationships.

## Data sources

| Layer | Source | Resolution | Access |
|---|---|---|---|
| Rainfall anomaly forecast | Copernicus C3S seasonal forecast multi-system, dataset `seasonal-postprocessed-single-levels`, ensemble mean of `total_precipitation_anomalous_rate_of_accumulation` | 1° × 1°, monthly | CDS API (free account required) |
| Temperature anomaly forecast | Same dataset, ensemble mean of `2m_temperature_anomaly` | 1° × 1°, monthly | CDS API |
| Malaria burden | Malaria Atlas Project (MAP), PfPR 2–10, release `Malaria__202608_Global_Pf_Parasite_Rate`, year 2025 | ~5 km, annual | `malariaAtlas` R package |
| Boundaries | geoBoundaries CGAZ ADM2, the seamless global composite. ADM1 for countries with no ADM2 (currently Libya and Mauritius); Western Sahara, Abyei and Koualou as disputed units | Vector | One global GeoPackage from the geoBoundaries GitHub (no account needed) |
| Population | WorldPop Global 2015–2030 R2025A, constrained, UN-adjusted, 1 km, one file per country | ~1 km, annual | data.worldpop.org (no account needed) |

The C3S multi-system combines forecasts from nine centres: ECMWF, UK Met Office, Météo-France, DWD, CMCC, NCEP, JMA, ECCC and BoM. Each centre's anomalies are calculated against that model's own hindcast climatology (1993–2016), so systematic model biases are removed before the models are averaged.

## Method

The script runs in this order. The PfPR side comes first, so a slow Copernicus queue only holds up the forecast outputs.

1. **Boundaries.** The geoBoundaries CGAZ ADM2 layer (about 240 MB, global) is downloaded once. The script keeps the units of every African country listed in `countrycode::codelist`, plus three disputed areas, and caches them as `boundaries/adm2_africa_cgaz.gpkg`. CGAZ is built from the national geoBoundaries data with international borders made to match, so neighbouring countries share one line and units neither overlap nor leave slivers. (The per-country gbOpen files overlapped by about 85,000 km² and left about 33,000 km² of gaps across Africa.)
   - **ADM1 fallback.** Where a country has no ADM2, CGAZ carries ADM1, and the `adm_level` column records which.
   - **Disputed areas.** CGAZ files these as separate units with numeric codes. The script keeps the three in Africa: Western Sahara, Abyei, and Koualou on the Benin–Burkina Faso border. They get `adm_level` `DISP`, and `adm0` `ESH` for Western Sahara and `DISP` for the other two.
   - **Missing territories.** Mayotte, Réunion and St Helena are not in CGAZ under an African code.
   - **Map geometry.** The polygons are repaired with GEOS (`sf::st_make_valid()` with s2 off). Maps use a copy simplified to about 1 km, which is invisible at Africa scale, and all statistics use the full-detail polygons.

2. **PfPR download.** The MAP PfPR 2–10 raster for the chosen year is downloaded for the Africa extent, with up to three attempts, and saved as `pfpr/pfpr_africa_<year>.tif`. If that file already exists it is not downloaded again.

3. **Population.** WorldPop 1 km files for the PfPR year are downloaded for each country in the boundary layer.
   - **Safe downloads.** Each file is written under a temporary name and renamed only once complete, so an interrupted run never leaves a truncated file.
   - **Mosaic.** The files are cropped to Africa and mosaicked into `worldpop/pop_africa_<year>.tif`. Cropping matters because some files, such as Eritrea's, are stored with a global extent. The mosaic is rebuilt whenever a country file is newer than it.
   - **Aggregation.** WorldPop cells are people counts, so the mosaic is summed onto the 5 km PfPR grid (`method = "sum"`) rather than interpolated. This deliberately differs from `batch_extract_weighted_stats()` in `sntutils`, which resamples population bilinearly. That reads only a few of the 25 one-km cells in each 5 km cell, so totals come out about 25 times too low. The script prints the Africa total on both grids so you can check they match.

4. **PfPR summaries.** PfPR is summarised with the same statistics as `process_weighted_raster_collection()` with `stat_type = "median"`, reproduced in the script so `sntutils` isn't needed.
   - **Weighted median.** For each unit, every PfPR pixel is weighted by the share of the pixel inside the polygon multiplied by the number of people in it (missing population counts as zero). The weighted median is computed with `matrixStats::weightedMedian()`, which interpolates between pixel values.
   - **Unweighted median.** This is `exactextractr`'s built-in median, which weights pixels by their share inside the polygon only.
   - **Layers.** Both are computed for the central estimate (layer 1) and the lower and upper bounds (layers 3 and 4), then converted from fractions to percentages. Unit population totals are extracted from the 1 km mosaic.
   - **Coverage rule.** MAP leaves pixels outside the *P. falciparum* transmission limits empty, so the script records `pfpr_pop_coverage`: the share of each unit's population living in pixels that have a PfPR value. Below `min_pfpr_coverage` (default 0.25) the PfPR columns are set to missing, so a handful of border pixels cannot stand in for a whole district (Adrar in Algeria would otherwise get 9.8% from pixels along the Mali border). The threshold is low enough that highland districts with substantial lowland transmission still get a value, such as Lubero and Masisi in DRC (about 40% coverage) or Arsi in Ethiopia (45%).

5. **PfPR map.** Saved as soon as the summaries are done (see step 9 for the style).

6. **Forecast download.** One CDS request is made per variable and centre (2 × 9).
   - **System check.** The script first reads the CDS catalogue's list of systems published for the initialisation date. If a centre's system in `c3s_systems` has been retired, it uses the newest one offered and prints a message.
   - **Queueing and tracking.** All missing requests are submitted together, and each job's address is saved to `c3s/pending_jobs_<yyyymm>.csv` as soon as it is submitted. The script polls every job until it has downloaded, failed or `c3s_timeout_hours` runs out, and reports each outcome. Jobs still queued at the timeout are collected by the next run instead of being submitted again, so re-running never piles duplicate requests into your CDS queue.
   - **File check.** A downloaded file is only accepted if it has exactly one layer per lead month. Partial files are requested again on the next run.

7. **Multi-model means.** For each variable, the centres are aligned to a common grid and averaged with equal weight to form the multi-model ensemble mean (MME). Rainfall is converted from m/s to mm/day. Temperature anomalies are in kelvin, which are the same size as °C.
   - **Missing rainfall.** If no rainfall file has arrived yet, the script stops here; the PfPR map is already saved.
   - **Missing temperature.** If no temperature file has arrived yet, the run continues, leaves the temperature columns empty and skips the temperature map.

8. **Forecast summaries.** Rainfall and temperature are physical fields, so each unit gets an area-weighted mean with `exactextractr`, for each forecast month and for the season (the mean of the months).

9. **Maps.** All maps have country borders.
   - **Rainfall and temperature.** One panel per forecast month plus a season-mean panel, on a 3-column grid, with the number of centres in the subtitle and the colour key in the caption. Rainfall uses a diverging brown-to-teal scale centred on zero (brown is drier than normal, teal is wetter). Temperature uses blue-to-red RdBu classes with white for −0.5 to 0.5 °C (blue is cooler, red is warmer). Because the anomalies include warming since the 1993–2016 baseline, most classes are on the warm side, in 0.5 °C steps up to 3 °C.
   - **PfPR.** A sequential yellow-to-red scale with classes at 1, 5, 10, 25 and 50%. Its legend includes a grey class for units outside the Pf limits or with no estimate.

## Requirements

### R packages

```r
install.packages(c(
  "cli", "here", "countrycode", "jsonlite", "sf", "dplyr", "tidyr",
  "readr", "terra", "exactextractr", "ecmwfr", "malariaAtlas",
  "ggplot2", "scales", "matrixStats", "httr"
))
```

No other packages or project files are needed. The script calls every function with an explicit `pkg::fun()` namespace and loads nothing with `library()`.

### Copernicus Climate Data Store access (one-time setup)

1. Create a free account at https://cds.climate.copernicus.eu.
2. Open the dataset page **"Seasonal forecast anomalies on single levels"**, go to the *Download* tab and accept the licence. Requests fail until the licence is accepted.
3. Copy your API key from your CDS profile page and register it in R:

   ```r
   ecmwfr::wf_set_key(key = "YOUR-API-KEY")
   ```

## Configuration

These parameters are set at the top of the script.

| Parameter | Current value | Meaning |
|---|---|---|
| `init_year`, `init_month` | `"2026"`, `"10"` | The forecast initialisation date. C3S publishes each month's forecasts around the 13th. |
| `lead_months` | `2:6` | Forecast months to map. Lead 1 is the initialisation month itself, so `2:6` covers November 2026 to March 2027. |
| `africa_area` | `c(38, -26, -36, 60)` | Bounding box for the CDS requests and the WorldPop mosaic, in N, W, S, E order. It reaches 26°W and 60°E so that Cabo Verde, the Seychelles and Mauritius (except Rodrigues) are covered. |
| `dataset_id` | `"Malaria__202608_Global_Pf_Parasite_Rate"` | MAP release. Check for newer releases with `malariaAtlas::listRaster()`. |
| `pfpr_year` | `2025` | PfPR year to map. Requesting a year the release does not contain returns an error. |
| `min_pfpr_coverage` | `0.25` | Minimum share of a unit's population inside MAP's Pf transmission limits for it to get a PfPR value. |
| `out_dir` | `outputs/enso_pfpr` | Output folder. Paths use `here::here()`, which resolves to the project root if the folder has an `.Rproj` file or is a git repository, and otherwise to the current working directory. |
| `c3s_systems` | named vector | Preferred system version for each C3S centre (Oct 2026: ECMWF 51, UKMO 610, Météo-France 9, DWD 22, CMCC 4, NCEP 2, JMA 4, ECCC 5, BoM 2). If the CDS no longer offers one for the initialisation date, the newest offered system is used automatically. |
| `c3s_timeout_hours` | `3` | How long one run waits on the CDS queue. Jobs still queued are saved and collected by the next run. |

The forecast variables themselves are set in `c3s_vars` at the start of the forecast section. Any other anomaly variable from the same dataset can be added there with a short file prefix in `c3s_prefix`, though it will also need its own summary and map.

## Running

From the folder you want the outputs in (or the project root, if it has one):

```r
source("africa_enso_vs_pfpr_adm2.R")
```

or from a terminal:

```bash
Rscript africa_enso_vs_pfpr_adm2.R
```

A first run downloads the boundaries (about 240 MB), the PfPR raster and about 55 WorldPop files. That takes a few minutes, and the PfPR map follows about 5 minutes later. Re-runs use the cached files.

The forecasts depend on the Copernicus queue, which you can watch at https://cds.climate.copernicus.eu/live. When it is quiet a request finishes in minutes; when it is busy, requests can wait many hours. In October 2026, nine requests submitted at 15:15 started one after another between 21:50 and 04:30 local time. Each took under a minute once started.

If the queue is slow, let the run time out and run the script again later. It collects the queued jobs rather than resubmitting them, downloads them, and finishes the outputs in about 10 minutes. The number of centres in each multi-model mean is printed and shown in the map subtitles, so check it before using the results.

ECMWF asks users not to flood the Data Stores with requests, and warns that repeatedly submitting invalid requests can get an account suspended. The script checks system numbers against the catalogue before submitting and never resubmits a job that is still queued, which keeps it within those limits.

## Outputs

All outputs are written to `outputs/enso_pfpr/`:

| File | Contents |
|---|---|
| `adm2_enso_anom_vs_pfpr.csv` | One row per unit; see the column table below. The main output for further analysis. |
| `map_pfpr_adm2.png` | PfPR 2–10 by ADM2. |
| `map_enso_rain_anom_adm2.png` | Forecast rainfall anomaly by ADM2, one panel per month plus the season mean. |
| `map_enso_temp_anom_adm2.png` | Forecast temperature anomaly by ADM2, one panel per month plus the season mean. |
| `c3s_mme_prate_anom_mm_day.tif` | Multi-model mean rainfall anomaly in mm/day, one band per forecast month. |
| `c3s_mme_t2m_anom_c.tif` | Multi-model mean 2 m temperature anomaly in °C, one band per forecast month. |
| `c3s/prate_anom_<centre>_s<system>_<yyyymm>.nc`, `c3s/t2m_anom_<centre>_s<system>_<yyyymm>.nc` | Raw ensemble-mean anomaly forecasts from each C3S centre, named by variable, system and initialisation date. |
| `c3s/pending_jobs_<yyyymm>.csv` | CDS jobs still queued when the last run stopped (variable, centre, system, job URL). Collected and removed by the next run; absent once everything has downloaded. |
| `pfpr/pfpr_africa_<year>.tif` | MAP PfPR 2–10 raster for Africa (fraction; layer 1 is the central estimate, layer 2 an empty mask, layers 3 and 4 the lower and upper bounds). |
| `worldpop/` | The per-country WorldPop files and `pop_africa_<year>.tif`, the 1 km Africa mosaic used for weighting. |
| `boundaries/adm2_africa_cgaz.gpkg` | The cached Africa subset of CGAZ. Delete it to download fresh boundaries. |

### CSV columns

| Column | Units | Meaning |
|---|---|---|
| `adm0` | | ISO3 country code (`ESH` for Western Sahara, `DISP` for Abyei and Koualou) |
| `adm2`, `adm2_id` | | Unit name and geoBoundaries ID. Names repeat across and within countries, so join on `adm2_id`. |
| `adm_level` | | `ADM2`, `ADM1` where a country has no ADM2, or `DISP` for a disputed area |
| `rain_anom_nov_2026` … `rain_anom_mar_2027` | mm/day | Forecast rainfall anomaly for each month, area-weighted mean |
| `rain_anom_season` | mm/day | Mean of the monthly rainfall anomalies |
| `temp_anom_nov_2026` … `temp_anom_mar_2027` | °C | Forecast 2 m temperature anomaly for each month, area-weighted mean |
| `temp_anom_season` | °C | Mean of the monthly temperature anomalies |
| `pop_sum` | people | WorldPop population of the unit, rounded |
| `pfpr_pop_coverage` | share | Share of the unit's population inside MAP's Pf transmission limits |
| `pfpr_pct` | % | Population-weighted median PfPR 2–10, central estimate (the value mapped) |
| `pfpr_lower_pct`, `pfpr_upper_pct` | % | Population-weighted median of MAP's lower and upper bounds |
| `pfpr_unweighted_pct` | % | Area-based median, for comparison |

The month in the forecast column names follows `init_month` and `lead_months`. The PfPR columns are empty where `pfpr_pop_coverage` is below `min_pfpr_coverage`.

## Interpreting the results

**Rainfall: direction of effect.** Rainfall anomalies in either direction can change malaria transmission, and the relationship is not simple.
- **Wetter.** Wetter-than-normal conditions can create breeding sites, and have historically been linked to epidemics in the East African highlands during strong El Niño years.
- **Drier.** Drier conditions can reduce transmission in some places, but can increase it elsewhere, for example where people store water or where rivers shrink into pools.

A teal district is therefore not automatically higher risk, and a brown one is not automatically lower risk. Local transmission ecology is needed to interpret each case.

**Temperature: direction of effect.** *P. falciparum* transmission is possible roughly between 16 and 34 °C and peaks around 25 °C (Mordecai et al., 2013, *Ecology Letters*).
- **Cool areas.** In highlands and other places where transmission is held back by cool temperatures, such as the East African, Ethiopian and Malagasy highlands or the southern edge of transmission, a warm anomaly raises transmission potential. Together with wetter conditions, this combination drove past highland epidemics.
- **Hot areas.** Where temperatures are already near the upper limit, for example the hot season in the Sahel, further warming can reduce it.

The anomalies are monthly means of air temperature 2 m above ground, so they say nothing about night-time minimums or the microclimates mosquitoes actually rest in.

**Temperature and the warming trend.** Each model's anomalies are measured against its 1993–2016 hindcast climate. Part of any warm anomaly therefore reflects long-term warming since that period, not El Niño alone. Expect warm anomalies almost everywhere. For malaria, what matters is the temperature people and mosquitoes will experience, so this is not an error, but don't read the whole anomaly as the El Niño effect.

**Absolute rainfall anomalies.** Rainfall anomalies are in absolute units (mm/day). The same anomaly is a much larger relative change in a semi-arid district than in a very wet one, and in the dry season than in the rainy season. The rainfall map can therefore understate the significance of anomalies in dry regions and months. Standardised or percent-of-normal anomalies would correct for this, but require additional hindcast or climatology data.

**Forecast skill.** Seasonal forecasts are probabilistic, and their skill varies by region, season and variable. Temperature forecasts are generally more skilful than rainfall forecasts. Rainfall skill is highest in regions with strong El Niño teleconnections, such as East Africa during October–December and southern Africa during December–February, and lower elsewhere. The ensemble mean shows the most likely direction and rough size of an anomaly, not a guaranteed outcome, and it smooths out extremes.

**Resolution.** The forecasts are on a 1° grid (roughly 110 km), so small units may sit within a single forecast cell, and their values reflect conditions over a wider area. Differences between neighbouring small districts should not be over-interpreted.

**PfPR.** MAP PfPR surfaces are modelled estimates with their own uncertainty, which is why the lower and upper bounds are kept in the CSV.
- **Population weighting.** The mapped value is population-weighted, so it reflects the prevalence where people actually live rather than averaging in empty land. Where `pfpr_pct` and `pfpr_unweighted_pct` differ a lot, the district's population lives in areas with very different transmission from the rest of it, often a town within a large rural district.
- **Grey units.** These have most of their population outside MAP's Pf transmission limits (check `pfpr_pop_coverage`), lie in a country MAP does not model, or have no population in the WorldPop raster. This is why some countries are part coloured and part grey. In Ethiopia and Kenya, for example, the central highlands, Addis Ababa and Nairobi are outside the transmission limits. In South Africa only the north-eastern lowveld is inside them.
- **Partly covered units.** For units between 25% and 100% coverage, the median describes only the people living inside the transmission limits.

**Boundaries.**
- **Programme boundaries.** geoBoundaries names and codes may not match national or programme boundaries. For country-level work, replace them with the official boundaries used in the relevant SNT pipeline, so that district names join cleanly to routine data.
- **Disputed borders.** CGAZ resolves disputed borders (for example the Halaib triangle, the Ilemi triangle and Abyei) by following the US Department of State's boundary lines, and shows Western Sahara, Abyei and Koualou as separate disputed units. This is a mapping convention, not a position on those disputes.
- **Lakes.** CGAZ includes inland lakes in the surrounding districts. This has no effect on PfPR, because nobody lives on the lakes, but lakes take the colour of their district on the maps.

**Coastal population.** CGAZ's coastline is more generalised than the national boundaries it is built from, so some coastal WorldPop pixels fall outside every unit.
- **How much.** Across Africa this is about 12 million people (0.8%). Mainland malaria-endemic countries keep 98–100% of their population.
- **Where.** North African coastal cities lose the most: Algeria's units hold 88.6% of its WorldPop population (Algiers and Oran are clipped) and Libya's 90.8% (Tripoli). Small island states hold 84–95%.
- **Effect.** `pop_sum` is therefore low for those coastal units, and their PfPR medians leave out the clipped coastal pixels.

Rodrigues (Mauritius, 63°E) lies outside the forecast area and has no forecast values.

## Updating the analysis

- **New forecast.** To refresh with a newer forecast, change `init_month` (and `init_year` if needed), choose suitable `lead_months`, and run the script again. Forecast files and the pending-jobs file are named by initialisation date, so old forecasts are never reused by mistake, and earlier months' files can be deleted. Monthly updates are worthwhile while the El Niño is evolving, because forecasts issued closer to the target season are more reliable.
- **New MAP release or year.** Change `dataset_id` or `pfpr_year`, and delete `pfpr/pfpr_africa_<year>.tif` if the year stays the same.
- **Fresh boundaries.** Delete `boundaries/adm2_africa_cgaz.gpkg`.
- **Files from earlier versions of the script.** `c3s/prate_anom_ecmwf.nc` and `boundaries/adm2_africa.gpkg` are no longer used and can be deleted.

For the headline El Niño outlook (alert status and the probabilities of El Niño, neutral and La Niña conditions), refer to the monthly NOAA CPC ENSO Diagnostic Discussion and the IRI ENSO forecast page.

## Troubleshooting

| Problem | Likely cause and fix |
|---|---|
| CDS request rejected or returns "not authorised" | The licence for the dataset hasn't been accepted, or the API key isn't set. See the CDS setup steps above. |
| A centre is "skipped: no forecast on the CDS yet" | That centre hasn't published the chosen initialisation month for every variable. C3S releases around the 13th; re-run later. |
| Jobs "still queued" after the timeout | The CDS queue was slower than `c3s_timeout_hours`. Re-run later; saved jobs are collected rather than resubmitted. Or raise the timeout. |
| "No C3S rainfall forecast downloaded yet" | Every rainfall job is still queued. The PfPR map is already saved; re-run later to finish the forecast maps and CSV. |
| "No C3S temperature forecast downloaded yet" | The temperature jobs are still queued. The rainfall outputs and CSV are written with empty temperature columns; re-run later to fill them and draw the temperature map. |
| "Missing or incomplete" centre | Its file didn't have one layer per lead month. It is requested again on the next run. |
| CGAZ download fails or times out | GitHub was unreachable, or the 240 MB download exceeded `options(timeout)`. Re-run; nothing is cached until the Africa subset has been written. |
| `getRaster()` fails | The release ID or year is wrong. Check both with `malariaAtlas::listRaster()`. Each download is attempted up to three times. |
| A WorldPop country is skipped | WorldPop has no R2025A file for that country and year, or the download failed. Re-run to retry; files already downloaded are kept. Units in a skipped country get no population weight, so their PfPR is missing. |
| PfPR is empty for every unit | The WorldPop mosaic failed or doesn't overlap the PfPR raster. Check that `worldpop/pop_africa_<year>.tif` opens and covers Africa, and that the two population totals printed during the run match. |
| A territory is missing from the maps | Mayotte, Réunion and St Helena are not in CGAZ under an African country code. Supply boundaries from another source if needed. |
| "Could not write map_….png" | The PNG was open in another program (an image viewer or preview pane) when the script tried to save it, so the old file is still there. Close it and re-run. |
| GEOS "TopologyException" while building outlines | A cached boundary file was made valid with s2 rather than GEOS. Delete `boundaries/adm2_africa_cgaz.gpkg` and re-run. |

## Data licences and citation

- **C3S seasonal forecasts:** Copernicus Climate Change Service. All C3S seasonal multi-system data may be used and redistributed without restriction. Cite the C3S seasonal forecast datasets and acknowledge the Copernicus Climate Change Service.
- **PfPR:** Malaria Atlas Project. Cite the MAP release used and follow MAP's terms of use.
- **Boundaries:** geoBoundaries (Runfola et al., 2020, *PLoS ONE*), CGAZ composite of the gbOpen release, with international borders from the US Department of State's Large Scale International Boundaries. Licences of the underlying data vary by country, and each country's licence is recorded in the geoBoundaries metadata.
- **Population:** WorldPop, under its stated licence.
- **Temperature thresholds:** Mordecai, E. A. et al. (2013). Optimal temperature for malaria transmission is dramatically lower than previously predicted. *Ecology Letters*, 16(1), 22–30.

# El Niño rainfall forecast vs malaria risk across Africa (ADM2)

This analysis puts two layers side by side for every second-level administrative unit (ADM2) in Africa. The first is the forecast rainfall anomaly driven by the 2026–27 El Niño over the coming months, and the second is the current malaria burden, measured as the *Plasmodium falciparum* parasite rate in children aged 2–10 (PfPR 2–10). The aim is to show where El Niño is expected to shift rainfall in places that already carry a high malaria burden, so those districts can be flagged for closer monitoring, preparedness or response planning.

Everything runs from a single script, `africa_enso_vs_pfpr_adm2.R`.

## Why rainfall anomaly and not "El Niño intensity"

El Niño is defined by sea surface temperatures in the equatorial Pacific (the Niño 3.4 region), so its intensity is one number for the whole event. What varies from place to place is the effect El Niño has on local climate. This analysis therefore maps the forecast rainfall anomaly (how much wetter or drier than normal each month is expected to be) as the spatial expression of El Niño over Africa.

The forecasts come from dynamical seasonal models, which simulate the El Niño together with everything else that drives African rainfall, including the Indian Ocean Dipole. This makes them more reliable than projecting the Niño 3.4 index onto historical relationships.

## Data sources

| Layer | Source | Resolution | Access |
|---|---|---|---|
| Rainfall anomaly forecast | Copernicus C3S seasonal forecast multi-system, dataset `seasonal-postprocessed-single-levels`, ensemble mean of `total_precipitation_anomalous_rate_of_accumulation` | 1° × 1°, monthly | CDS API via `ecmwfr` (free account required) |
| Malaria burden | Malaria Atlas Project (MAP), PfPR 2–10, release `Malaria__202608_Global_Pf_Parasite_Rate` | ~5 km, annual | `malariaAtlas` R package |
| Boundaries | geoBoundaries gbOpen ADM2, simplified geometries | Vector | geoBoundaries API (no account needed) |
| Population (optional) | WorldPop, or any population raster | Any | Local file you provide |

The C3S multi-system combines forecasts from nine centres: ECMWF, UK Met Office, Météo-France, DWD, CMCC, NCEP, JMA, ECCC and BoM. Each centre's anomalies are calculated against that model's own hindcast climatology, so systematic model biases are already removed before the models are averaged.

## Method

1. **Boundaries.** ADM2 polygons are downloaded for every African country listed in `countrycode::codelist`. A country with no ADM2 layer in geoBoundaries is skipped, and a warning is printed. The polygons are combined into one layer and their geometries repaired with `sf::st_make_valid()`.

2. **Rainfall forecast.** For each C3S centre, the script requests the ensemble-mean precipitation anomaly for the chosen initialisation month and lead months, cropped to Africa. Files that already exist are not requested again, so an interrupted run can be resumed. The centres are aligned to a common grid and averaged with equal weight to form the multi-model ensemble mean (MME). The result is converted from m/s to mm/day.

3. **PfPR.** The MAP PfPR 2–10 surface for the chosen year is downloaded for the Africa extent and converted from a fraction to a percentage.

4. **ADM2 summaries.** Both rasters are summarised to ADM2 with `exactextractr`, which weights each raster cell by the fraction of it that falls inside the polygon. Rainfall anomaly is an area-weighted mean. PfPR is also an area-weighted mean by default, or a population-weighted mean if a population raster is supplied.

5. **Maps.** Two maps are drawn. The rainfall map has one panel per forecast month and uses a diverging brown-to-teal scale centred on zero (brown is drier than normal, teal is wetter). The PfPR map uses a sequential yellow-to-red scale with class breaks at 1, 5, 10, 25 and 50%.

## Requirements

### R packages

```r
install.packages(c(
  "cli", "here", "countrycode", "jsonlite", "sf", "dplyr", "tidyr",
  "readr", "terra", "exactextractr", "ecmwfr", "malariaAtlas",
  "ggplot2", "scales"
))
```

The script calls every function with an explicit `pkg::fun()` namespace and loads nothing with `library()`.

### Copernicus Climate Data Store access (one-time setup)

1. Create a free account at https://cds.climate.copernicus.eu.
2. Open the dataset page **"Seasonal forecast anomalies on single levels"**, go to the *Download* tab and accept the licence. Requests fail until the licence is accepted.
3. Copy your API key from your CDS profile page and register it in R:

   ```r
   ecmwfr::wf_set_key(key = "YOUR-API-KEY")
   ```

## Configuration

All parameters are set at the top of the script.

| Parameter | Current value | Meaning |
|---|---|---|
| `init_year`, `init_month` | `"2026"`, `"10"` | The forecast initialisation date. C3S publishes each month's forecasts around the 13th. |
| `lead_months` | `2:6` | Forecast months to map. Lead 1 is the initialisation month itself, so `2:6` covers November 2026 to March 2027. |
| `africa_area` | `c(38, -20, -36, 55)` | Bounding box for the CDS request, in N, W, S, E order. |
| `pfpr_dataset` | `"Malaria__202608_Global_Pf_Parasite_Rate"` | MAP release. Check for newer releases with `malariaAtlas::listRaster()`. |
| `pfpr_year` | set to the latest year in the release | PfPR year to map. Requesting a year the release does not contain returns an error. |
| `pop_path` | `NULL` | Path to a population raster. If set, PfPR is population-weighted. |
| `out_dir` | `outputs/enso_pfpr` | Output folder, relative to the project root (via `here`). |
| `c3s_systems` | named vector | The system version for each C3S centre. Centres upgrade periodically, so confirm the current numbers in the CDS download form. |

## Running

From the project root:

```r
source("africa_enso_vs_pfpr_adm2.R")
```

or from a terminal:

```bash
Rscript africa_enso_vs_pfpr_adm2.R
```

CDS requests are queued on the Copernicus side and can take anywhere from a few minutes to a few hours. Downloaded files are kept in `outputs/enso_pfpr/c3s/`. If the run stops partway, run it again and only the missing centres will be requested. If a centre fails, the script prints a warning and continues, and the multi-model mean uses whichever centres downloaded successfully. The number of centres used is printed during the run.

## Outputs

All outputs are written to `outputs/enso_pfpr/`:

| File | Contents |
|---|---|
| `c3s/prate_anom_<centre>.nc` | Raw ensemble-mean anomaly forecast from each C3S centre. |
| `c3s_mme_prate_anom_mm_day.tif` | Multi-model mean rainfall anomaly in mm/day, with one band per forecast month. |
| `pfpr_pct_<year>.tif` | PfPR 2–10 for Africa, in %. |
| `adm2_enso_anom_vs_pfpr.csv` | One row per ADM2 with `adm0` (ISO3), `adm2` (name), `adm2_id` (geoBoundaries ID), one rainfall anomaly column per forecast month (mm/day), and `pfpr_pct`. |
| `map_enso_rain_anom_adm2.png` | Forecast rainfall anomaly by ADM2, one panel per month. |
| `map_pfpr_adm2.png` | PfPR 2–10 by ADM2. |

The CSV is the most useful output for further analysis. Use it to rank districts, flag those with both high PfPR and large rainfall anomalies, or join the results to programme data.

## Interpreting the results

**Direction of effect.** Rainfall anomalies in either direction can change malaria transmission, and the relationship is not simple. Wetter-than-normal conditions can create breeding sites and have historically been linked to epidemics in the East African highlands during strong El Niño years. Drier conditions can reduce transmission in some places, but can increase it elsewhere, for example where people store water or where rivers shrink into pools. Temperature also matters, especially at higher altitudes. A teal district is therefore not automatically higher risk, and a brown one is not automatically lower risk. Local transmission ecology is needed to interpret each case.

**Absolute anomalies and climatology.** The anomalies are in absolute units (mm/day). The same anomaly is a much larger relative change in a semi-arid district than in a very wet one, so the map can understate the significance of anomalies in dry regions. Standardised or percent-of-normal anomalies would correct for this, but require additional hindcast data.

**Forecast skill.** Seasonal rainfall forecasts are probabilistic and their skill varies by region and season. Skill is generally higher in regions with strong El Niño teleconnections, such as East Africa during October–December and southern Africa during December–February, and lower elsewhere. The ensemble mean shows the most likely direction and rough size of the anomaly, not a guaranteed outcome, and it smooths out extremes.

**Resolution.** The forecasts are on a 1° grid (roughly 110 km), so small ADM2 units may sit within a single forecast cell, and their values reflect conditions over a wider area. Differences between neighbouring small districts should not be over-interpreted.

**PfPR.** MAP PfPR surfaces are modelled estimates with their own uncertainty, and they describe a recent baseline year rather than current conditions. The area-weighted mean gives the same weight to empty land as to populated areas. For large, sparsely populated districts, a population-weighted mean (`pop_path`) better represents the burden people actually experience.

**Boundaries.** geoBoundaries ADM2 names and codes may not match national or programme boundaries. For country-level work, replace them with the official boundaries used in the relevant SNT pipeline so that district names join cleanly to routine data.

## Updating the analysis

To refresh with a newer forecast, change `init_month` (and `init_year` if needed), choose suitable `lead_months`, delete or move the old files in `outputs/enso_pfpr/c3s/`, and run the script again. Monthly updates are worthwhile while the El Niño is evolving. Forecasts issued closer to the target season are more reliable.

For the headline El Niño outlook (alert status and the probabilities of El Niño, neutral and La Niña conditions), refer to the monthly NOAA CPC ENSO Diagnostic Discussion and the IRI ENSO forecast page.

## Troubleshooting

| Problem | Likely cause and fix |
|---|---|
| CDS request rejected or returns "not authorised" | The licence for the dataset hasn't been accepted, or the API key isn't set. See the CDS setup steps above. |
| A centre fails with an invalid request | Its system number has changed. Check the current number in the CDS download form and update `c3s_systems`. |
| "expected N layers" error | A centre returned fewer lead months than requested, often because that month's forecast is not yet published. Wait, or remove that centre's file and its entry. |
| `getRaster()` fails | The release ID or year is wrong. Check both with `malariaAtlas::listRaster()`. |
| A country is missing from the maps | geoBoundaries has no ADM2 layer for it. The run log names it. Supply ADM2 from another source, or use ADM1 for that country. |
| Very slow plotting | Africa-wide ADM2 is several thousand polygons. Simplify further with `sf::st_simplify()`, or plot a subset of countries. |

## Data licences and citation

- **C3S seasonal forecasts:** Copernicus Climate Change Service. All C3S seasonal multi-system data may be used and redistributed without restriction. Cite the C3S seasonal forecast datasets and acknowledge the Copernicus Climate Change Service.
- **PfPR:** Malaria Atlas Project. Cite the MAP release used and follow MAP's terms of use.
- **Boundaries:** geoBoundaries (Runfola et al., 2020, *PLoS ONE*), gbOpen release. Licences vary by country, and each country's licence is recorded in the geoBoundaries metadata.
- **Population (if used):** WorldPop, under its stated licence.

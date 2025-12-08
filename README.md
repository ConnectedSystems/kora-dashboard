# coralflow-dashboard

Dashboard for CoralFlow, a model developed to simulate representative transects of coral
reefs.


## Setup

```shell
julia --project=.
]instantiate
```

## Usage

Place required data into the `data` directory.

- `ecorrap to cscape species.csv` : Mapping of EcoRRAP species to relevant functional groups
- `ecorrap_adult_juv_combined_2021_2023_24062025.csv` : Collated EcoRRAP data
- `DHWs/dhwRCP45.nc` : NetCDF of SSP2-4.5 scenarios

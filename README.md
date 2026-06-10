# kora-dashboard

Dashboard for Kora, a model developed to simulate representative transects of coral
reefs for comparative assessment and decision support purposes.


## Setup

```shell
julia --project=.
]instantiate
```

## Usage

Place required data into the `data` directory.

- `ecorrap_to_cscape_species.csv` : Mapping of EcoRRAP species to relevant functional groups
- `ecorrap_expanded.parquet` : Collated EcoRRAP data (Parquet format)
- `DHWs/dhwRCP45.nc` : NetCDF of SSP2-4.5 scenarios

To launch:

```julia
include("bin/main.jl")
```

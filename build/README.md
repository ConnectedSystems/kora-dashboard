# Kora app

Example dashboard for the Kora coral reef ecosystem using a model defined for the
Offshore North region, not any specific reef.

## Instructions

Unzip the files into a location of your choice.

Navigate to the folder and double click on the launch script for your system (`.ps1` for
Windows, `.sh` for linux).

It should launch the app in a web browser (but the program runs locally, on your machine).

## Notes

The model is initialized with all coral groups contributing proportionally equal cover
For example, if the assumed initial cover is 30%, each of the five coral groups will
contribute 1/5th towards that 30%.

Each click of the "run" button will produce an ensemble of 25 evaluations of the Kora model,
allowing some indication of potential model projection uncertainty.

Each run will overlay on top of previous runs to allow comparison of outcomes.

The DHW sequence used is based on SSP 2-4.5 conditions but is for example purposes only.

This app is for demonstration and does not include any scenario analysis or uncertainty
assessment capability. It merely provides indicative projections under a hypothetical
climate conditions as represented by the synthetic DHW trajectory.

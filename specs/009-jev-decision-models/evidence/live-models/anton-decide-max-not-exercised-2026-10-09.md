# decide-max NOT exercised (2026-10-09)

Not exercised: GGUF `jevk5-9b-v0.3.3-Q8_0.gguf` is 9,527,501,280 bytes (8.87 GiB). Measured on this host the same run shape needs about model + 3 GB resident (decide-pro: 4.4 GB model -> VmHWM 7.36 GB; decide-2b: 7.8 GB), so the expected peak is ~12-13 GB > the 10G bounded-run cap. MemAvailable was 23.5 GB / free 0.8-1.5 GB (mostly page cache), swap 53% free, GPU free 3.6-4.4 GB. Per the run rules (peak would exceed the cap) it was not downloaded or run. Re-run needs either a larger cap with a fresh host-safety review or a GPU with >=12 GB free.

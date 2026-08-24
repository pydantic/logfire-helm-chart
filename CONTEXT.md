# Domain context

## FusionFire query execution settings

The resolved runtime settings that control how a FusionFire query process uses
CPU, memory, DataFusion threads, I/O parallelism, and per-worker query capacity.
They do not decide whether queries execute in the query intake workload or in a
remote query worker; workload topology owns that choice.

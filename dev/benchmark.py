#!/usr/bin/env python3

# run this script from factorio's script-output directory

cybersyn_path = "/storage/Projects/factorio/project-cybersyn/cybersyn"
#cybersyn_path = "/storage/Projects/factorio/project-cybersyn" + sys.argv[1] + "/cybersyn"

binary_path = "/storage/Steam/steamapps/common/Factorio/bin/x64/factorio"
save_name = "devOriginalBench2"
#save_name = "Cybersyn Benchmark Cold"
benchmark_runs = 4
benchmark_ticks = 36000
bench_keys = ["wholeUpdate", "scriptUpdate"]
profile_keys = ["tick_poll_station", "tick_dispatch"]
enable_profiling = False
enable_plotting = False
enable_sort_plots = False

# TODO: make this script into a proper module

import subprocess, re, sys
from statistics import mean
from pathlib import Path

if enable_plotting:
    mpl_backend = 'GTK4Agg' # https://matplotlib.org/stable/users/explain/figure/backends.html
    import matplotlib
    matplotlib.use(mpl_backend)
    import numpy as np
    import matplotlib.pyplot as plt

Path("../mods/cybersyn").unlink(False)
Path("../mods/cybersyn").symlink_to(cybersyn_path)

Path("cybersyn_totals.csv").unlink(True)

for key in profile_keys:
    Path("cybersyn_" + key + ".csv").unlink(True)

central_planning_path = Path(cybersyn_path + "/scripts/central-planning.lua")
central_planning_src = central_planning_path.read_text()
if enable_profiling:
    central_planning_src = central_planning_src.replace("PROFILING_ENABLED = nil", "PROFILING_ENABLED = true")
else:
    central_planning_src = central_planning_src.replace("PROFILING_ENABLED = true", "PROFILING_ENABLED = nil")
central_planning_path.write_text(central_planning_src)

out = subprocess.run([
    binary_path,
    "--benchmark", save_name,
    "--benchmark-verbose", ','.join(bench_keys),
    "--benchmark-runs", str(benchmark_runs),
    "--benchmark-ticks", str(benchmark_ticks)
    ], text=True, capture_output=True
)
# TODO: factorio writes most errors to stdout, so we need to parse it to know if something failed
#print(out.stdout)
if out.stderr: print(out.stderr)

def print_key_times(key, times):
    times = list(map(min, zip(*times)))
    print("┃ {:20} │ {:12.5f}ms │ {:9.5f}ms │ {:9.5f}ms │ {:8} ┃".format(key, sum(times), mean(times), max(times), len(times)))
    if enable_plotting:
        # TODO: make the graph a bit less ugly
        title = '"' + cybersyn_path + '" - ' + key
        x = range(len(times))
        if enable_sort_plots:
            y = sorted(times, reverse=True)
        else:
            y = times
        plt.style.use('_mpl-gallery')
        fig, ax = plt.subplots()
        ax.plot(x, y, linewidth=1.0)
        ax.grid(True, axis='y')
        # TODO: use different y limits for different keys
        ax.set(title=title, xlim=(0, len(times)), ylim=(0, 1), xticks=(), yticks=np.arange(0.0, 1.1, 0.1))
        fm = plt.get_current_fig_manager()
        if mpl_backend == 'GTK4Agg':
            fm.window.set_title(title)
            fm.window.maximize()

def print_bench_times():
    lines = str(out.stdout).split('\n')[-benchmark_runs*(benchmark_ticks+2)-2 : -2]
    key_times = dict(((key, []) for key in bench_keys))
    for run_i in range(benchmark_runs):
        run_lines = lines[run_i*(benchmark_ticks+2)+2 : run_i*(benchmark_ticks+2)+2+benchmark_ticks]
        for key, run_times in zip(bench_keys, zip(*((float(t) / 1000000.0 for t in l.split(',')[1:-1]) for l in run_lines))):
            key_times[key].append(run_times)
    for key, times in key_times.items():
        print_key_times(key, times)

def print_profile_times():
    for key in profile_keys:
        times = []
        for line in Path("cybersyn_" + key + ".csv").read_text().split('\n')[1:]:
            run_times = map(float, re.findall(r"Duration: (.+?)ms", line))
            times.append(run_times)
        print_key_times(key, times)

print("Path:", cybersyn_path)
if enable_profiling:
    print(" Totals: " + Path("cybersyn_totals.csv").read_text().replace(', ', ' = ').replace('\n', ', '))
print("┏━━━━━━━━━━━━━━━━━━━━━━┯━━━━━━━━━━━━━━━━┯━━━━━━━━━━━━━┯━━━━━━━━━━━━━┯━━━━━━━━━━┓")
print("┃ Key                  │ Total          │ Average     │ Maximum     │ Count    ┃")
print("┠──────────────────────┼────────────────┼─────────────┼─────────────┼──────────┨")
print_bench_times()
if enable_profiling: print_profile_times()
print("┗━━━━━━━━━━━━━━━━━━━━━━┷━━━━━━━━━━━━━━━━┷━━━━━━━━━━━━━┷━━━━━━━━━━━━━┷━━━━━━━━━━┛")

if enable_plotting:
    try:
        plt.show()
    except KeyboardInterrupt:
        print()
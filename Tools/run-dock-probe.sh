#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
script_path=${0:A}
benchmark_probe=""
benchmark_active_backup=""
benchmark_active_marker=""

run_reload_benchmark() {
    local run_name=${1:-}
    local confirmation=${2:-}
    local evidence_dir="$repo_dir/artifacts/dock-probe"
    benchmark_probe="$repo_dir/.build/release/DockProbe"
    benchmark_active_backup=""
    benchmark_active_marker=""
    umask 077

    benchmark_usage() {
        print -u2 -- "Usage: DOCKIT_RUN_REAL_DOCK_BENCHMARK=1 $script_path benchmark <run-name> --confirm-real-dock-mutation"
        print -u2 -- "The runner builds and safe-checks the release probe before any Dock mutation."
    }

    benchmark_recover_and_finish() {
        local incoming_status=$?
        local recovery_status=0
        local marker_state=""

        trap - EXIT INT TERM
        set +e
        if [[ -n "$benchmark_active_marker" && -f "$benchmark_active_marker" && -n "$benchmark_active_backup" && -f "$benchmark_active_backup" ]]; then
            IFS= read -r marker_state < "$benchmark_active_marker" || marker_state=""
            case "$marker_state" in
                (DOCKIT_BENCHMARK_RECOVERY_RESTORED|DOCKIT_BENCHMARK_RECOVERY_NO_MUTATION)
                    print -u2 -- "The probe already confirmed recovery state $marker_state."
                    ;;
                (*)
                    print -u2 -- "Attempting forced-baseline recovery from $benchmark_active_backup"
                    "$benchmark_probe" --restore-backup "$benchmark_active_backup" || recovery_status=$?
                    ;;
            esac
        fi
        if (( recovery_status != 0 )); then
            exit "$recovery_status"
        fi
        exit "$incoming_status"
    }

    if (( $# != 2 )) || [[ "$confirmation" != "--confirm-real-dock-mutation" ]]; then
        benchmark_usage
        exit 64
    fi
    if [[ "${DOCKIT_RUN_REAL_DOCK_BENCHMARK:-}" != "1" ]]; then
        print -u2 -- "Refusing to mutate the real Dock without DOCKIT_RUN_REAL_DOCK_BENCHMARK=1. No Dock change was attempted."
        exit 64
    fi
    case "$run_name" in
        (""|*[!A-Za-z0-9._-]*)
            print -u2 -- "The run name may use only letters, numbers, periods, underscores, and hyphens."
            exit 64
            ;;
    esac
    if [[ -e "$evidence_dir/reload-benchmark-$run_name" || -L "$evidence_dir/reload-benchmark-$run_name" ]]; then
        print -u2 -- "Refusing to reuse an existing benchmark evidence directory. Choose a new run name."
        exit 73
    fi
    if ! (cd "$repo_dir" && swift build -c release); then
        print -u2 -- "The release probe did not build. No Dock change was attempted."
        exit 66
    fi
    if [[ ! -x "$benchmark_probe" ]]; then
        print -u2 -- "The release build did not produce $benchmark_probe. No Dock change was attempted."
        exit 66
    fi
    set +e
    local self_test_output
    self_test_output=$("$benchmark_probe" --benchmark-report-self-test 2>&1)
    local self_test_status=$?
    set -e
    print -- "$self_test_output"
    if (( self_test_status != 0 )) || [[ "$self_test_output" != *"DOCKIT_BENCHMARK_REPORT_SELF_TEST_PASSED"* ]]; then
        print -u2 -- "The release probe does not support the safe benchmark self-test. Rebuild with swift build -c release."
        exit 66
    fi

    local run_dir="$evidence_dir/reload-benchmark-$run_name"
    local -a strategies
    strategies=(
        forcedTermination
        gracefulTerminationWithForcedFallback
        forcedTerminationAndExplicitRelaunch
    )

    local strategy
    mkdir -p "$run_dir"
    trap benchmark_recover_and_finish EXIT INT TERM

    for strategy in "${strategies[@]}"; do
        local backup="$run_dir/$strategy-backup.plist"
        local report="$run_dir/$strategy-report.json"
        local log="$run_dir/$strategy.log"
        local marker="$run_dir/$strategy-recovery.marker"
        local -a statuses
        benchmark_active_backup="$backup"
        benchmark_active_marker="$marker"

        print -- "Starting 20-switch Dock reload benchmark for $strategy"
        set +e
        "$benchmark_probe" \
            --benchmark-reload \
            --confirm-real-dock-mutation \
            --strategy "$strategy" \
            --switch-count 20 \
            --backup "$backup" \
            --report "$report" \
            --recovery-marker "$marker" 2>&1 | tee "$log"
        statuses=("${pipestatus[@]}")
        set -e
        if (( statuses[1] != 0 )); then
            exit "${statuses[1]}"
        fi
        if (( statuses[2] != 0 )); then
            exit "${statuses[2]}"
        fi

        set +e
        "$benchmark_probe" --validate-benchmark-report "$report" 2>&1 | tee -a "$log"
        statuses=("${pipestatus[@]}")
        set -e
        if (( statuses[1] != 0 )); then
            exit "${statuses[1]}"
        fi
        if (( statuses[2] != 0 )); then
            exit "${statuses[2]}"
        fi
        local marker_state=""
        if [[ ! -f "$marker" ]]; then
            print -u2 -- "The benchmark finished without a recovery marker. Evidence is incomplete."
            exit 70
        fi
        IFS= read -r marker_state < "$marker" || marker_state=""
        if [[ "$marker_state" != "DOCKIT_BENCHMARK_RECOVERY_RESTORED" ]]; then
            print -u2 -- "The benchmark report passed without a confirmed recovery marker. Evidence is incomplete."
            exit 70
        fi
        benchmark_active_backup=""
        benchmark_active_marker=""
    done

    print -- "All three 20-switch preservation checks passed. Evidence is in $run_dir"
    print -- "Visual timing is not verified by this probe. Review the recordings and evaluate them with Tools/AnalyzeDockTiming.mjs before selecting a strategy."
}

if [[ "${1:-}" == "benchmark" ]]; then
    shift
    run_reload_benchmark "$@"
    exit 0
fi

evidence_dir="$repo_dir/artifacts/dock-probe"
run_name=${1:-recorded}
non_profile_folder=${2:-}
probe="$repo_dir/.build/release/DockProbe"
backup="$evidence_dir/$run_name-backup.plist"
report="$evidence_dir/$run_name-report.json"
recording="$evidence_dir/$run_name.mov"
recording_process=""
probe_status=0

mkdir -p "$evidence_dir"

restore_and_finish() {
    local incoming_status=$?
    local recovery_status=0

    trap - EXIT INT TERM
    set +e
    # The probe restores the Dock itself on every path it controls. Forcing the
    # backup back in on success restarts the Dock a second time, right on top of
    # the first, and that double restart was misread as a slow reload.
    if [[ -f "$backup" && ( $probe_status -ne 0 || $incoming_status -ne 0 ) ]]; then
        "$probe" --restore-backup "$backup" || recovery_status=$?
    fi
    if [[ -n "$recording_process" ]]; then
        wait "$recording_process" || true
    fi
    if (( recovery_status != 0 )); then
        exit "$recovery_status"
    fi
    if (( probe_status != 0 )); then
        exit "$probe_status"
    fi
    exit "$incoming_status"
}

trap restore_and_finish EXIT INT TERM

# Record the bottom 130 points of the main display, wherever the Dock lives today.
screen_size=$(osascript -l JavaScript -e 'ObjC.import("AppKit"); const f = $.NSScreen.mainScreen.frame; f.size.width + "," + f.size.height' 2>/dev/null)
screen_width=${${(s:,:)screen_size}[1]%.*}
screen_height=${${(s:,:)screen_size}[2]%.*}
screen_width=${screen_width:-1800}
screen_height=${screen_height:-1169}
screencapture -v -V30 -x -R0,$((screen_height - 130)),$screen_width,130 "$recording" &
recording_process=$!
# screencapture needs about a second before it records anything. Without this
# wait the first Dock restart happens off camera.
sleep 2

probe_arguments=(
    --backup "$backup"
    --report "$report"
    --hold-seconds "${DOCKIT_PROBE_HOLD_SECONDS:-5}"
)
if [[ -n "$non_profile_folder" ]]; then
    probe_arguments+=(--non-profile-folder "$non_profile_folder")
fi
# Any further arguments reach the probe unchanged, for example --reload sigterm.
if (( $# > 2 )); then
    probe_arguments+=("${@[3,-1]}")
fi

set +e
"$probe" "${probe_arguments[@]}" || probe_status=$?
exit "$probe_status"

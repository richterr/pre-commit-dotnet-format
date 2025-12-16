#! /usr/bin/env bash

set -Eeuo pipefail

PROJECT_FILE_EXTENSION="csproj"

find_project_file(){
    local file="${1}"
    local absolute_file_path=""
    absolute_file_path="$(readlink -f "$file")"

    local search_directory=""
    search_directory="$(dirname "$absolute_file_path")"

    local project_file=""

    while [ "$search_directory" != "$root_directory" ]; do
        project_file=$(find "$search_directory" -maxdepth 1 -type f -name "*.$PROJECT_FILE_EXTENSION" -print -quit)

        if [ "$project_file" != "" ]; then
            break
        fi

        search_directory="$(dirname "$search_directory")"
    done

    echo "$project_file"
}

project_is_new(){
    local file="${1}"
    local project_files=("${@:2}")

    local found_project=0

    for element in "${project_files[@]}"; do
        if [[ "$element" == "$file" ]]; then
            found_project=1
            break
        fi
    done

    if [[ $found_project -eq 1 ]]; then
        return 1  # Not new (already in list)
    else
        return 0  # Is new
    fi
}

restore_project(){
    local executable="${1}"
    local project_file="${2}"

    local project_dir=""
    project_dir="$(dirname "$project_file")"

    local lock_file="$project_dir/packages.lock.json"
    local restore_lock_dir="$project_dir/obj/.dotnet-restore.lock"

    mkdir -p "$project_dir/obj"

    # Acquire lock using mkdir (atomic operation, cross-platform)
    local lock_acquired=0
    local lock_wait_attempts=0
    local max_lock_wait=30

    while [ $lock_wait_attempts -lt $max_lock_wait ]; do
        if mkdir "$restore_lock_dir" 2>/dev/null; then
            lock_acquired=1
            break
        fi

        # Lock exists, check if restore already completed
        if [ -f "$project_dir/obj/project.assets.json" ]; then
            return 0
        fi

        echo "Waiting for concurrent restore to complete..." >&2
        sleep 1
        lock_wait_attempts=$((lock_wait_attempts + 1))
    done

    if [ $lock_acquired -eq 0 ]; then
        echo "Failed to acquire restore lock after ${max_lock_wait}s" >&2
        return 11
    fi

    # Ensure lock is released on exit
    # shellcheck disable=SC2064
    # the local variable restore_lock_dir is expanded at trap definition time
    # it won't exist when the trap is executed therefore disable SC2064
    trap "rmdir '$restore_lock_dir' 2>/dev/null || true" EXIT RETURN

    local max_attempts=3
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        # clean obj directory to avoid "file already exists" errors
        if [ $attempt -gt 1 ]; then
            rm -rf "$project_dir/obj"
            mkdir -p "$project_dir/obj"
            mkdir "$restore_lock_dir"
        fi

        if [ -f "$lock_file" ]; then
            if "$executable" restore "$project_file" --locked-mode --verbosity quiet 2>&1; then
                rmdir "$restore_lock_dir" 2>/dev/null || true
                trap - EXIT RETURN
                return 0
            fi
        else
            if "$executable" restore "$project_file" --verbosity quiet 2>&1; then
                rmdir "$restore_lock_dir" 2>/dev/null || true
                trap - EXIT RETURN
                return 0
            fi
        fi

        if [ $attempt -lt $max_attempts ]; then
            sleep_time=$((2 ** attempt))
            echo "Restore failed (attempt $attempt/$max_attempts), retrying in ${sleep_time}s..." >&2
            sleep $sleep_time
        fi

        attempt=$((attempt + 1))
    done

    rmdir "$restore_lock_dir" 2>/dev/null || true
    trap - EXIT RETURN
    echo "Failed to restore project $project_file after $max_attempts attempts" >&2
    return 12
}

format(){
    local executable=""

    echo "Checking DOTNET_ROOT: ${DOTNET_ROOT:-<not set>}" >&2

    if [[ -n "${DOTNET_ROOT:-}" && -x "${DOTNET_ROOT}/dotnet" ]]; then
        executable="${DOTNET_ROOT}/dotnet"
    else
        executable="$(which dotnet)"
    fi

    echo "Using dotnet executable at: $executable" >&2

    local root_directory
    root_directory="$(git rev-parse --show-toplevel)"
    local project_files=()
    local restored_projects=()

    for file in "$@"; do
        local project_file=""
        project_file="$(find_project_file "$file")"

        if [[ -z "$project_file" ]]; then
            echo "No project file found for $file" >&2
            return 10
        fi

        if ! project_is_new "$project_file" "${project_files[@]}"; then
            continue
        fi

        if project_is_new "$project_file" "${restored_projects[@]}"; then
            restore_project "$executable" "$project_file"
            local restore_exit_code=$?

            if [[ "$restore_exit_code" -ne 0 ]]; then
                return "$restore_exit_code"
            fi

            restored_projects+=("$project_file")
        fi

        errors=()
        while IFS= read -r line; do
            errors+=("$line")
        done < <("$executable" format "$project_file" --severity info --verbosity detailed --verify-no-changes 2>&1)

        format_exit_code=$?

        if [[ $format_exit_code -ne 0 ]]; then
            # Non-zero exit code means formatting changes are needed
            for error in "${errors[@]}"; do
                echo "$error" >&2
            done

            # Apply the formatting
            "$executable" format "$project_file" --severity info --verbosity quiet > /dev/null 2>&1
        fi

        project_files+=("$project_file")
    done
}

format "$@"

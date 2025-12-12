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
    local restore_lock_file="$project_dir/obj/.dotnet-restore.lock"

    mkdir -p "$project_dir/obj"

    # prevent concurrent restores of the same project
    local lock_fd=200
    eval "exec $lock_fd>$restore_lock_file"

    if ! flock -n $lock_fd; then
        echo "Waiting for concurrent restore to complete..." >&2
        flock $lock_fd

        # verify restore success
        if [ -f "$project_dir/obj/project.assets.json" ]; then
            eval "exec $lock_fd>&-"
            return 0
        fi
    fi

    local max_attempts=3
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        # clean obj directory to avoid "file already exists" errors
        if [ $attempt -gt 1 ]; then
            rm -rf "$project_dir/obj"
            mkdir -p "$project_dir/obj"
        fi

        if [ -f "$lock_file" ]; then
            if "$executable" restore "$project_file" --locked-mode --verbosity quiet 2>&1; then
                eval "exec $lock_fd>&-"
                return 0
            fi
        else
            if "$executable" restore "$project_file" --verbosity quiet 2>&1; then
                eval "exec $lock_fd>&-"
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

    eval "exec $lock_fd>&-"
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

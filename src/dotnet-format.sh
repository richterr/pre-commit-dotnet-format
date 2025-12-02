#! /usr/bin/env bash

set -Eeuo pipefail

PROJECT_FILE_EXTENSION="csproj"
EXECUTABLE=$(which dotnet)

find_project_file(){
    file="${1}"
    absolute_file_path="$(readlink -f "$file")"
    search_directory="$(dirname "$absolute_file_path")"

    project_file=""

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
    file="${1}"
    project_files=("${@:2}")

    found_project=0
    for element in "${project_files[@]}"; do
        if [[ "$element" == "$file" ]]; then
            found_project=1
            break
        fi
    done

    if [[ $found_project -eq 1 ]]; then
        echo ""
    else
        echo "$file"
    fi
}

restore_project(){
    project_file="${1}"
    project_dir="$(dirname "$project_file")"

    lock_file="$project_dir/packages.lock.json"

    max_attempts=3
    attempt=1

    while [ $attempt -le $max_attempts ]; do
        if [ -f "$lock_file" ]; then
            if "$EXECUTABLE" restore "$project_file" --locked-mode --verbosity quiet 2>&1; then
                return 0
            fi
        else
            if "$EXECUTABLE" restore "$project_file" --verbosity quiet 2>&1; then
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

    echo "Failed to restore project $project_file after $max_attempts attempts" >&2
    return 1
}

format(){
    root_directory="$(git rev-parse --show-toplevel)"
    project_files=()
    restored_projects=()

    for file in "$@"; do
        project_file="$(find_project_file "$file")"
        new_project_file=$(project_is_new "$project_file" "${project_files[@]}")

        if [ "$new_project_file" != "" ]; then
            needs_restore=$(project_is_new "$new_project_file" "${restored_projects[@]}")

            if [ "$needs_restore" != "" ]; then
                if ! restore_project "$new_project_file"; then
                    exit 1
                fi
                restored_projects+=("$new_project_file")
            fi

            errors=()
            while IFS= read -r line; do
                errors+=("$line")
            done < <("$EXECUTABLE" format "$new_project_file" --severity info --verbosity detailed --verify-no-changes 2>&1)

            format_exit_code=$?

            if [[ $format_exit_code -ne 0 ]]; then
                # Non-zero exit code means formatting changes are needed
                for error in "${errors[@]}"; do
                    echo "$error" >&2
                done

                # Apply the formatting
                "$EXECUTABLE" format "$new_project_file" --severity info --verbosity quiet > /dev/null 2>&1
            fi

            project_files+=("$new_project_file")
        fi
    done
}

format "$@"

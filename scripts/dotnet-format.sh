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

format(){
    root_directory="$(git rev-parse --show-toplevel)"
    project_files=()

    for file in "$@"; do
        project_file="$(find_project_file "$file")"
        new_project_file=$(project_is_new "$project_file" "${project_files[@]}")

        if [ "$new_project_file" != "" ]; then
            errors=()
            while IFS= read -r line; do
                errors+=("$line")
            done < <("$EXECUTABLE" format "$new_project_file" --severity info --verbosity detailed 2>&1 > /dev/null)

            # eval "$("$EXECUTABLE" format "$new_project_file" --severity info --verbosity detailed) 2> >(readarray -t errors; typeset -p errors))"
            if [[ ${#errors[@]} != 0 ]]; then
                for error in "${errors[@]}"; do
                    echo "$error" >&2
                done
                exit 1
            fi

            project_files+=("$new_project_file")
        fi
    done
}

format "$@"
